import SwiftUI
import UIKit

struct DrawingToolkitSection: View {
    @Binding var options: DrawingToolkitOptions
    var body: some View {
        Section(header: Text("Drawing Toolkit")) {
            Toggle("Enable Drawing Toolkit", isOn: $options.enabled.animation())
            if options.enabled {
                Picker("Pencil Mode", selection: $options.mode) {
                    ForEach(PencilInputMode.allCases, id: \.self) { mode in
                        Text(LocalizedStringKey(mode.title)).tag(mode)
                    }
                }
                Picker("Stroke Type", selection: $options.highDensity) {
                    Text("Regular").tag(false)
                    Text("HD").tag(true)
                }
                if options.highDensity {
                    Stepper(value: $options.tickIntervalUS, in: 1000...20000, step: 500) {
                        Text("Tick Interval: \(options.tickIntervalUS) µs")
                    }
                    Text("HD sends coalesced Pencil samples. The interval limits how often movement samples are sent; stroke start and end are always sent.")
                        .font(.caption).foregroundColor(.secondary)
                }
                NavigationLink("Pencil Tip Offset") { PencilTipOffsetView(options: $options) }
                NavigationLink("Pressure Curve") { DrawingPressureView(options: $options) }
                Toggle("Transmit Tilt and Orientation", isOn: $options.transmitTilt)
                Toggle("Use Eraser", isOn: $options.eraser)
                Toggle("Drawing Pauses Native Touch", isOn: $options.pausesFingerTouch)
                Toggle("Disable Slide Gesture for Pencil", isOn: $options.disablePencilSlide)
                NavigationLink("Custom Double Tap Keyboard Shortcut") {
                    Form {
                        Section {
                            Toggle("Double Tap Switches Pen and Eraser", isOn: $options.doubleTapSwitchesTool)
                        }
                        DrawingShortcutSection(title: "First Double Tap", shortcut: $options.doubleTapShortcut)
                        DrawingShortcutSection(title: "Next Double Tap", shortcut: $options.doubleTapAlternateShortcut)
                        Section {
                            Text("Custom shortcuts take priority over switching the tool. Leave the next shortcut empty to repeat the first. Requires a Pencil that supports double tap.")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }.navigationTitle("Double Tap")
                }
                NavigationLink("Custom Squeeze Keyboard Shortcut") {
                    Form {
                        DrawingShortcutSection(title: "Squeeze", shortcut: $options.squeezePressShortcut)
                        Section { Toggle("Hold Shortcut Until Released", isOn: $options.squeezeHoldsShortcut) }
                        if !options.squeezeHoldsShortcut {
                            DrawingShortcutSection(title: "Release Squeeze", shortcut: $options.squeezeReleaseShortcut)
                        }
                        Section {
                            Text("Requires Apple Pencil Pro and iPadOS 17.5 or later.")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }.navigationTitle("Squeeze")
                }
                Text("Streams Apple Pencil input to Android. Stylus mode carries pressure, tilt and eraser input; the Android drawing app must support them. Mouse and Touch modes provide compatibility input.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }
}

private struct DrawingShortcutSection: View {
    let title: LocalizedStringKey
    @Binding var shortcut: DrawingShortcut
    var body: some View {
        Section(header: Text(title)) {
            TextField("Key (for example B, E, Z or F1)", text: $shortcut.key)
                .autocapitalization(.allCharacters).autocorrectionDisabled()
            Toggle("Control", isOn: $shortcut.control)
            Toggle("Shift", isOn: $shortcut.shift)
            Toggle("Alt", isOn: $shortcut.alt)
            Toggle("Meta", isOn: $shortcut.meta)
            if !shortcut.key.isEmpty && shortcut.keycode == nil {
                Text("Use A–Z, 0–9, F1–F12, Space, Enter, Tab, Esc, Backspace, Delete or an arrow direction.")
                    .font(.caption).foregroundColor(.red)
            }
            Text(shortcut.title).foregroundColor(.secondary)
        }
    }
}

private struct PencilTipOffsetView: View {
    @Binding var options: DrawingToolkitOptions
    var body: some View {
        Form {
            Section {
                offsetSlider("X Offset", value: $options.offsetX)
                offsetSlider("Y Offset", value: $options.offsetY)
                Button("Reset") { options.offsetX = 0; options.offsetY = 0 }
            }
            Section {
                Text("Offsets are measured in points on the streaming view. Positive X moves right; positive Y moves down.")
                    .font(.caption).foregroundColor(.secondary)
                PencilPressurePad(offset: CGPoint(x: options.offsetX, y: options.offsetY)) { _ in }
                    .frame(height: 260).listRowInsets(EdgeInsets())
                    .accessibilityLabel("Pencil tip offset preview")
            }
        }.navigationTitle("Pencil Tip Offset")
    }
    private func offsetSlider(_ title: LocalizedStringKey, value: Binding<Double>) -> some View {
        VStack {
            HStack { Text(title); Spacer(); Text(String(format: "%.1f", value.wrappedValue)).foregroundColor(.secondary) }
            Slider(value: value, in: -15...15, step: 0.1)
        }
    }
}

struct DrawingPressureView: View {
    @Binding var options: DrawingToolkitOptions
    @State private var previousCurve: [DrawingPressurePoint]?
    @State private var testing = false
    @State private var samples: [Double] = []
    @State private var livePressure = 0.0
    @State private var calibrationError = false
    var body: some View {
        Form {
            Section {
                Toggle("Enable Pressure Curve", isOn: $options.pressureCurveEnabled)
                DrawingCurveGraph(points: $options.curve)
                    .frame(height: 240).padding(.vertical, 8)
                Text("Drag the points to change output pressure. The horizontal axis is Pencil pressure; the vertical axis is pressure sent to Android.")
                    .font(.caption).foregroundColor(.secondary)
                HStack {
                    Button("Reset") { previousCurve = options.curve; options.curve = DrawingPressureCurve.linear }
                    Spacer()
                    Button("Undo") {
                        if let curve = previousCurve { previousCurve = options.curve; options.curve = curve }
                    }.disabled(previousCurve == nil)
                }.buttonStyle(.borderless)
            }
            Section(header: Text("Pressure Range Test")) {
                Button(testing ? "Use Measured Range" : "Start Pressure Range Test") {
                    if testing {
                        if let curve = DrawingPressureCurve.calibrated(samples: samples) {
                            previousCurve = options.curve
                            options.curve = curve
                            testing = false
                        } else { calibrationError = true }
                    } else { samples = []; testing = true }
                }
                if testing {
                    Text("Draw several strokes from light to firm pressure in the area below.")
                        .font(.caption).foregroundColor(.secondary)
                    PencilPressurePad { pressure in
                        livePressure = pressure
                        if samples.count < 20000 { samples.append(pressure) }
                    }.frame(height: 220).listRowInsets(EdgeInsets())
                    ProgressView(value: livePressure) { Text("Pressure: \(Int(livePressure * 100))%") }
                    Button("Cancel Test") { testing = false }
                }
            }
            Section(header: Text("Stroke Start")) {
                Stepper("Hook Filtering Depth: \(options.hookFilterDepth)", value: $options.hookFilterDepth, in: 0...60)
                    .onChange(of: options.hookFilterDepth) { value in
                        options.equalizationDepth = max(value, options.equalizationDepth)
                    }
                Stepper("Equalization Depth: \(options.equalizationDepth)", value: $options.equalizationDepth,
                        in: options.hookFilterDepth...120)
                HStack {
                    Text("Force Scaling")
                    Spacer()
                    Text(String(format: "%.2f", options.equalizationStrength)).foregroundColor(.secondary)
                }
                Slider(value: $options.equalizationStrength, in: 0...3, step: 0.05)
                Text("HD hook filtering suppresses pressure in the first samples. Equalization gradually returns the starting force scale to 1. Set both depths to 0 to disable.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .navigationTitle("Pressure Curve")
        .alert("Draw More Pressure Levels", isPresented: $calibrationError) {
            Button("OK", role: .cancel) {}
        } message: { Text("Use Apple Pencil to draw both light and firm strokes before applying the measured range.") }
    }
}

private struct DrawingCurveGraph: View {
    @Binding var points: [DrawingPressurePoint]
    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color(UIColor.secondarySystemGroupedBackground))
                Path { p in
                    for i in 0...4 {
                        let t = CGFloat(i) / 4
                        p.move(to: CGPoint(x: t * size.width, y: 0)); p.addLine(to: CGPoint(x: t * size.width, y: size.height))
                        p.move(to: CGPoint(x: 0, y: t * size.height)); p.addLine(to: CGPoint(x: size.width, y: t * size.height))
                    }
                }.stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                Path { p in
                    for i in 0...100 {
                        let x = Double(i) / 100
                        let point = CGPoint(x: x * size.width, y: (1 - DrawingPressureCurve.value(x, points: points)) * size.height)
                        if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
                    }
                }.stroke(Color.accentColor, lineWidth: 2)
                ForEach(points.indices, id: \.self) { i in
                    Circle().fill(Color.accentColor).frame(width: 18, height: 18)
                        .position(x: points[i].x * size.width, y: (1 - points[i].y) * size.height)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("pressureGraph")).onChanged { value in
                            points[i].y = DrawingPressureCurve.clamp(1 - value.location.y / size.height)
                            if i > 0 && i < points.count - 1 {
                                points[i].x = min(max(value.location.x / size.width, points[i - 1].x + 0.01), points[i + 1].x - 0.01)
                            }
                        })
                        .accessibilityLabel("Pressure point \(i + 1)")
                        .accessibilityValue("\(Int(points[i].y * 100)) percent")
                        .accessibilityAdjustableAction { direction in
                            points[i].y = DrawingPressureCurve.clamp(points[i].y + (direction == .increment ? 0.05 : -0.05))
                        }
                }
            }.coordinateSpace(name: "pressureGraph")
        }
    }
}

private struct PencilPressurePad: UIViewRepresentable {
    var offset = CGPoint.zero
    var sample: (Double) -> Void
    func makeUIView(context: Context) -> PressurePadUIView { PressurePadUIView() }
    func updateUIView(_ view: PressurePadUIView, context: Context) { view.sample = sample; view.offset = offset }
}

private final class PressurePadUIView: UIView {
    var sample: ((Double) -> Void)?
    var offset = CGPoint.zero
    private var marks: [(CGPoint, CGFloat)] = []
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemGroupedBackground
        isMultipleTouchEnabled = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { record(touches, event) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { record(touches, event) }
    private func record(_ touches: Set<UITouch>, _ event: UIEvent?) {
        for touch in touches where touch.type == .pencil {
            for item in event?.coalescedTouches(for: touch) ?? [touch] {
                let pressure = item.maximumPossibleForce > 0 ? item.force / item.maximumPossibleForce : 0
                let p = item.preciseLocation(in: self)
                marks.append((CGPoint(x: p.x + offset.x, y: p.y + offset.y), 1 + pressure * 8))
                sample?(Double(pressure))
            }
        }
        if marks.count > 4000 { marks.removeFirst(marks.count - 4000) }
        setNeedsDisplay()
    }
    override func draw(_ rect: CGRect) {
        tintColor.setFill()
        for (point, radius) in marks {
            UIBezierPath(ovalIn: CGRect(x: point.x - radius, y: point.y - radius, width: 2 * radius, height: 2 * radius)).fill()
        }
    }
}
