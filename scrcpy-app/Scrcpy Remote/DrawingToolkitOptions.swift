import Foundation

enum PencilInputMode: String, Codable, CaseIterable {
    case stylus, hoverDisabled, mouse, touch
    var title: String {
        switch self {
        case .stylus: return "Stylus"
        case .hoverDisabled: return "Hovering Disabled"
        case .mouse: return "Mouse"
        case .touch: return "Touch"
        }
    }
}

struct DrawingPressurePoint: Codable, Equatable {
    var x: Double
    var y: Double
}

struct DrawingShortcut: Codable, Equatable {
    var key = ""
    var control = false
    var shift = false
    var alt = false
    var meta = false

    var keycode: UInt32? {
        let key = key.trimmingCharacters(in: .whitespaces).uppercased()
        if key.count == 1, let c = key.unicodeScalars.first?.value {
            if (65...90).contains(c) { return c - 65 + 29 }
            if (48...57).contains(c) { return c - 48 + 7 }
        }
        if key.hasPrefix("F"), let n = UInt32(key.dropFirst()), (1...12).contains(n) { return 130 + n }
        return ["SPACE": 62, "ENTER": 66, "TAB": 61, "ESC": 111, "BACKSPACE": 67,
                "DELETE": 112, "UP": 19, "DOWN": 20, "LEFT": 21, "RIGHT": 22][key]
    }
    var modifiers: UInt32 {
        (control ? 0x1000 : 0) | (shift ? 1 : 0) | (alt ? 2 : 0) | (meta ? 0x10000 : 0)
    }
    var title: String {
        guard !key.isEmpty else { return NSLocalizedString("None", comment: "No Pencil shortcut") }
        return [control ? "Ctrl" : nil, shift ? "Shift" : nil, alt ? "Alt" : nil,
                meta ? "Meta" : nil, key.uppercased()].compactMap { $0 }.joined(separator: "+")
    }
}

struct DrawingToolkitOptions: Codable, Equatable {
    var enabled = false
    var highDensity = false
    var tickIntervalUS = 4000
    var offsetX = 0.0
    var offsetY = 0.0
    var pressureCurveEnabled = true
    var curve = DrawingPressureCurve.linear
    var hookFilterDepth = 0
    var equalizationDepth = 0
    var equalizationStrength = 1.0
    var pausesFingerTouch = true
    var disablePencilSlide = true
    var mode: PencilInputMode = .stylus
    var eraser = false
    var transmitTilt = true
    var doubleTapSwitchesTool = true
    var doubleTapShortcut = DrawingShortcut()
    var doubleTapAlternateShortcut = DrawingShortcut()
    var squeezePressShortcut = DrawingShortcut()
    var squeezeReleaseShortcut = DrawingShortcut()
    var squeezeHoldsShortcut = false

    init() {}

    // Decode each setting independently, so older/imported sessions remain
    // usable when a new option is introduced or an enum value is unknown.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        enabled = read(.enabled, false)
        highDensity = read(.highDensity, false)
        tickIntervalUS = read(.tickIntervalUS, 4000)
        offsetX = read(.offsetX, 0)
        offsetY = read(.offsetY, 0)
        pressureCurveEnabled = read(.pressureCurveEnabled, true)
        curve = read(.curve, DrawingPressureCurve.linear)
        hookFilterDepth = read(.hookFilterDepth, 0)
        equalizationDepth = read(.equalizationDepth, 0)
        equalizationStrength = read(.equalizationStrength, 1)
        pausesFingerTouch = read(.pausesFingerTouch, true)
        disablePencilSlide = read(.disablePencilSlide, true)
        mode = read(.mode, .stylus)
        eraser = read(.eraser, false)
        transmitTilt = read(.transmitTilt, true)
        doubleTapSwitchesTool = read(.doubleTapSwitchesTool, true)
        doubleTapShortcut = read(.doubleTapShortcut, DrawingShortcut())
        doubleTapAlternateShortcut = read(.doubleTapAlternateShortcut, DrawingShortcut())
        squeezePressShortcut = read(.squeezePressShortcut, DrawingShortcut())
        squeezeReleaseShortcut = read(.squeezeReleaseShortcut, DrawingShortcut())
        squeezeHoldsShortcut = read(.squeezeHoldsShortcut, false)
        sanitize()
    }

    mutating func sanitize() {
        tickIntervalUS = min(max(tickIntervalUS, 1000), 20000)
        offsetX = DrawingPressureCurve.clamp(offsetX, -15, 15)
        offsetY = DrawingPressureCurve.clamp(offsetY, -15, 15)
        hookFilterDepth = min(max(hookFilterDepth, 0), 60)
        equalizationDepth = min(max(equalizationDepth, hookFilterDepth), 120)
        equalizationStrength = DrawingPressureCurve.clamp(equalizationStrength, 0, 3)
        curve = DrawingPressureCurve.validated(curve)
    }
}

// Monotone cubic Hermite interpolation prevents overshoot between editable
// pressure points. The 2048-entry lookup table is built once per session.
enum DrawingPressureCurve {
    static let linear = (0...4).map { DrawingPressurePoint(x: Double($0) / 4, y: Double($0) / 4) }
    static func clamp(_ value: Double, _ lower: Double = 0, _ upper: Double = 1) -> Double {
        value.isFinite ? min(max(value, lower), upper) : lower
    }
    static func validated(_ points: [DrawingPressurePoint]) -> [DrawingPressurePoint] {
        guard (2...16).contains(points.count), points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return linear }
        let sorted = points.sorted { $0.x < $1.x }.map { DrawingPressurePoint(x: clamp($0.x), y: clamp($0.y)) }
        guard sorted.first?.x == 0, sorted.last?.x == 1,
              zip(sorted, sorted.dropFirst()).allSatisfy({ $1.x - $0.x >= 0.001 }) else { return linear }
        return sorted
    }
    static func value(_ input: Double, points: [DrawingPressurePoint]) -> Double {
        let x = clamp(input)
        let n = points.count
        guard n >= 2 else { return x }
        if x <= points[0].x { return points[0].y }
        if x >= points[n - 1].x { return points[n - 1].y }
        let slopes = (0..<(n - 1)).map { (points[$0 + 1].y - points[$0].y) / (points[$0 + 1].x - points[$0].x) }
        func tangent(_ i: Int) -> Double {
            if i == 0 { return slopes[0] }
            if i == n - 1 { return slopes[n - 2] }
            let a = slopes[i - 1], b = slopes[i]
            if a * b <= 0 { return 0 }
            let left = points[i].x - points[i - 1].x
            let right = points[i + 1].x - points[i].x
            let w1 = 2 * right + left, w2 = right + 2 * left
            return (w1 + w2) / (w1 / a + w2 / b)
        }
        let i = (0..<(n - 1)).first { x <= points[$0 + 1].x } ?? n - 2
        let h = points[i + 1].x - points[i].x
        let t = (x - points[i].x) / h
        let t2 = t * t, t3 = t2 * t
        return clamp((2 * t3 - 3 * t2 + 1) * points[i].y + (t3 - 2 * t2 + t) * h * tangent(i)
                     + (-2 * t3 + 3 * t2) * points[i + 1].y + (t3 - t2) * h * tangent(i + 1))
    }
    static func lookup(_ points: [DrawingPressurePoint]) -> [Double] {
        let safe = validated(points)
        return (0..<2048).map { value(Double($0) / 2047, points: safe) }
    }
    static func calibrated(samples: [Double]) -> [DrawingPressurePoint]? {
        let sorted = samples.filter { $0.isFinite && $0 > 0 && $0 <= 1 }.sorted()
        guard sorted.count >= 12 else { return nil }
        let low = sorted[sorted.count / 20], high = sorted[sorted.count * 19 / 20]
        guard high - low > 0.05 else { return nil }
        var points = [DrawingPressurePoint(x: 0, y: 0)]
        if low > 0.001 { points.append(.init(x: low, y: 0)) }
        if high < 0.999 { points.append(.init(x: high, y: 1)) }
        points.append(.init(x: 1, y: 1))
        return validated(points)
    }
}

struct DrawingStrokePressure {
    var sampleIndex = 0
    var previous = 0.0
    mutating func reset() { sampleIndex = 0; previous = 0 }
    mutating func map(_ raw: Double, options: DrawingToolkitOptions, lut: [Double]) -> Double {
        sampleIndex += 1
        let input = DrawingPressureCurve.clamp(raw)
        let mapped = options.pressureCurveEnabled ? lut[Int((input * 2047).rounded())] : input
        if options.highDensity && sampleIndex <= options.hookFilterDepth { return 0 }
        if sampleIndex <= options.equalizationDepth && sampleIndex > options.hookFilterDepth {
            let count = options.equalizationDepth - options.hookFilterDepth
            let progress = count <= 1 ? 1 : Double(sampleIndex - options.hookFilterDepth - 1) / Double(count - 1)
            previous = max(previous, mapped)
            return DrawingPressureCurve.clamp(previous * (options.equalizationStrength + (1 - options.equalizationStrength) * progress))
        }
        previous = mapped
        return mapped
    }
}
