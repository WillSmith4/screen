import UIKit

@objc final class DrawingInputHandler: NSObject, UIPencilInteractionDelegate {
    private weak var view: UIView?
    private var options = DrawingToolkitOptions()
    private var lut: [Double] = []
    private var stroke = DrawingStrokePressure()
    private var pencil: UITouch?
    private var forwardedFingers: Set<UITouch> = []
    private var suppressedFingers: Set<UITouch> = []
    private var cancelledFingers: Set<UITouch> = []
    private var lastPoint = CGPoint.zero
    private var lastTilt: Float = 0
    private var lastOrientation: Float = 0
    private var lastSampleTime: TimeInterval = -1
    private var lastSentTime: TimeInterval = -1
    private var windowID: UInt32 = 0
    private var hovering = false
    private var eraser = false
    private var strokeTool: UInt8 = 2
    private var alternatingShortcut = false
    private var heldShortcut: DrawingShortcut?
    private var hoverRecognizer: UIHoverGestureRecognizer?
    private var pencilInteraction: UIPencilInteraction?
    private var gestureTypes: [(UIGestureRecognizer, [NSNumber])] = []
    private var valid = true

    @objc init(view: UIView) {
        self.view = view
        super.init()
        guard let session = SessionConnectionManager.shared.currentSession, session.deviceType == .adb else { return }
        options = session.adbOptions.drawingToolkit
        options.sanitize()
        guard options.enabled else { return }
        eraser = options.eraser
        lut = DrawingPressureCurve.lookup(options.curve)
        if let window = SDL_GetKeyboardFocus() ?? SDL_GetMouseFocus() { windowID = SDL_GetWindowID(window) }
        if options.disablePencilSlide {
            var current: UIView? = view
            while let node = current {
                for recognizer in node.gestureRecognizers ?? [] {
                    gestureTypes.append((recognizer, recognizer.allowedTouchTypes))
                    recognizer.allowedTouchTypes = recognizer.allowedTouchTypes.filter { $0.intValue != UITouch.TouchType.pencil.rawValue }
                }
                current = node.superview
            }
        }
        let interaction = UIPencilInteraction()
        interaction.delegate = self
        view.addInteraction(interaction)
        pencilInteraction = interaction
        if options.mode == .stylus || options.mode == .mouse {
            let hover = UIHoverGestureRecognizer(target: self, action: #selector(hoverChanged(_:)))
            hover.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
            hover.cancelsTouchesInView = false
            view.addGestureRecognizer(hover)
            hoverRecognizer = hover
        }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(cancelInput), name: UIApplication.willResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(disconnect), name: NSNotification.Name("ScrcpyRequestDisconnectNotification"), object: nil)
        center.addObserver(self, selector: #selector(statusChanged(_:)), name: NSNotification.Name("ScrcpyStatusUpdated"), object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc func invalidate() {
        cancelInput()
        valid = false
        NotificationCenter.default.removeObserver(self)
        if let hover = hoverRecognizer { view?.removeGestureRecognizer(hover) }
        if let interaction = pencilInteraction { view?.removeInteraction(interaction) }
        for (recognizer, types) in gestureTypes { recognizer.allowedTouchTypes = types }
        gestureTypes = []
    }

    @objc private func disconnect() { cancelInput(); valid = false }
    @objc private func statusChanged(_ note: Notification) {
        if let status = note.userInfo?["status"] as? Int, status == 0 || status == 5 { disconnect() }
    }

    @objc func takeCancelledFingers() -> Set<UITouch> {
        let touches = cancelledFingers
        cancelledFingers = []
        return touches
    }

    // Called before SDL sees UIKit touches. Only opted-in ADB sessions filter
    // Pencil input; all other sessions take exactly the original SDL path.
    @objc(filterTouches:event:phase:)
    func filterTouches(_ touches: Set<UITouch>, event: UIEvent, phase: Int) -> Set<UITouch> {
        guard options.enabled, valid, let view = view else { return touches }
        let pencils = touches.filter { $0.type == .pencil }
        if phase == 0, let touch = pencils.first, pencil == nil {
            endHover()
            pencil = touch
            stroke.reset()
            lastSampleTime = -1
            lastSentTime = -1
            strokeTool = tool
            if options.pausesFingerTouch {
                cancelledFingers.formUnion(forwardedFingers)
                suppressedFingers.formUnion(forwardedFingers)
                forwardedFingers = []
            }
            send(touch, action: 0, view: view, force: true)
        }
        for touch in pencils where touch === pencil {
            if phase == 1 {
                let batch = options.highDensity ? event.coalescedTouches(for: touch) ?? [touch] : [touch]
                for sample in batch { send(sample, action: 2, view: view, force: false) }
            } else if phase == 2 || phase == 3 {
                // Flush any final real samples before lifting; never send predicted touches.
                if phase == 2 && options.highDensity {
                    for sample in event.coalescedTouches(for: touch) ?? [] where sample.timestamp > lastSampleTime {
                        send(sample, action: 2, view: view, force: true)
                    }
                }
                send(touch, action: phase == 3 ? 3 : 1, view: view, force: true)
                pencil = nil
            }
        }
        var forwarded: Set<UITouch> = []
        for touch in touches where touch.type != .pencil {
            if touch.type == .direct && options.pausesFingerTouch && pencil != nil { suppressedFingers.insert(touch) }
            if suppressedFingers.contains(touch) {
                if phase == 2 || phase == 3 { suppressedFingers.remove(touch) }
                continue
            }
            forwarded.insert(touch)
            if touch.type == .direct {
                if phase == 0 { forwardedFingers.insert(touch) }
                if phase == 2 || phase == 3 { forwardedFingers.remove(touch) }
            }
        }
        return forwarded
    }

    private var tool: UInt8 {
        if options.mode == .mouse { return 3 }
        if options.mode == .touch { return 1 }
        return eraser ? 4 : 2
    }
    private func send(_ touch: UITouch, action: UInt8, view: UIView, force: Bool) {
        if action == 2 && touch.timestamp <= lastSampleTime { return }
        lastSampleTime = touch.timestamp
        if !force && options.highDensity && (touch.timestamp - lastSentTime) * 1_000_000 < Double(options.tickIntervalUS) { return }
        let raw = touch.maximumPossibleForce > 0 ? Double(touch.force / touch.maximumPossibleForce) : 0
        let pressure = action == 1 || action == 3 ? 0 : stroke.map(raw, options: options, lut: lut)
        let point = touch.preciseLocation(in: view)
        lastPoint = CGPoint(x: point.x + options.offsetX, y: point.y + options.offsetY)
        lastTilt = options.transmitTilt ? Float(.pi / 2 - touch.altitudeAngle) : 0
        let azimuth = touch.azimuthAngle(in: view)
        lastOrientation = options.transmitTilt ? Float(atan2(cos(azimuth), -sin(azimuth))) : 0
        let buttons: UInt32 = options.mode == .mouse && action != 1 && action != 3 ? 1 : 0
        emit(action: action, tool: strokeTool, pressure: Float(pressure), buttons: buttons, timestamp: touch.timestamp)
        lastSentTime = touch.timestamp
    }
    private func emit(action: UInt8, tool: UInt8, pressure: Float = 0, buttons: UInt32 = 0, timestamp: TimeInterval) {
        guard let view = view, view.bounds.width > 0, view.bounds.height > 0, valid else { return }
        if windowID == 0, let window = SDL_GetKeyboardFocus() ?? SDL_GetMouseFocus() { windowID = SDL_GetWindowID(window) }
        _ = ScrcpySendStylusEvent(windowID, action, tool,
                                 Float(lastPoint.x / view.bounds.width), Float(lastPoint.y / view.bounds.height),
                                 pressure, lastTilt, lastOrientation, buttons, UInt64(max(0, timestamp) * 1_000_000))
    }
    @objc private func hoverChanged(_ hover: UIHoverGestureRecognizer) {
        guard valid, pencil == nil, let view = view else { return }
        let point = hover.location(in: view)
        lastPoint = CGPoint(x: point.x + options.offsetX, y: point.y + options.offsetY)
        if #available(iOS 16.4, *), options.transmitTilt {
            lastTilt = Float(.pi / 2 - hover.altitudeAngle)
            let azimuth = hover.azimuthAngle(in: view)
            lastOrientation = Float(atan2(cos(azimuth), -sin(azimuth)))
        }
        switch hover.state {
        case .began, .changed:
            emit(action: hovering ? 7 : 9, tool: tool, timestamp: ProcessInfo.processInfo.systemUptime)
            hovering = true
        case .ended, .cancelled, .failed: endHover()
        default: break
        }
    }
    private func endHover() {
        if hovering { emit(action: 10, tool: tool, timestamp: ProcessInfo.processInfo.systemUptime); hovering = false }
    }
    @objc private func cancelInput() {
        if pencil != nil {
            emit(action: 3, tool: strokeTool, timestamp: ProcessInfo.processInfo.systemUptime)
            pencil = nil
        }
        endHover()
        if let held = heldShortcut { sendShortcut(held, down: false); heldShortcut = nil }
    }
    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        guard valid, options.enabled else { return }
        let shortcut = alternatingShortcut && !options.doubleTapAlternateShortcut.key.isEmpty
            ? options.doubleTapAlternateShortcut : options.doubleTapShortcut
        if shortcut.keycode != nil { sendShortcut(shortcut); alternatingShortcut.toggle() }
        else if options.doubleTapSwitchesTool { endHover(); eraser.toggle() }
    }
    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        pencilInteractionDidTap(interaction)
    }
    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard valid, options.enabled else { return }
        switch squeeze.phase {
        case .began:
            if options.squeezeHoldsShortcut {
                if heldShortcut == nil { heldShortcut = options.squeezePressShortcut; sendShortcut(options.squeezePressShortcut, down: true) }
            } else { sendShortcut(options.squeezePressShortcut) }
        case .ended, .cancelled:
            if let held = heldShortcut { sendShortcut(held, down: false); heldShortcut = nil }
            else if squeeze.phase == .ended { sendShortcut(options.squeezeReleaseShortcut) }
        default: break
        }
    }
    private func sendShortcut(_ shortcut: DrawingShortcut, down: Bool? = nil) {
        guard let code = shortcut.keycode else { return }
        if down != false { _ = ScrcpySendDrawingKey(windowID, code, shortcut.modifiers, true) }
        if down != true { _ = ScrcpySendDrawingKey(windowID, code, shortcut.modifiers, false) }
    }
}
