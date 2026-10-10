import Foundation

@main enum DrawingToolkitTests {
    static func main() throws {
        let defaults = try JSONDecoder().decode(DrawingToolkitOptions.self, from: Data("{}".utf8))
        precondition(!defaults.enabled && defaults.mode == .stylus)
        var options = defaults
        options.enabled = true
        options.offsetX = -7.5
        options.doubleTapShortcut = DrawingShortcut(key: "z", control: true)
        let data = try JSONEncoder().encode(options)
        let restored = try JSONDecoder().decode(DrawingToolkitOptions.self, from: data)
        precondition(restored == options)
        let malformed = Data(#"{"mode":"future-mode","tickIntervalUS":-4,"offsetX":900,"hookFilterDepth":40,"equalizationDepth":3,"curve":[{"x":0,"y":0},{"x":0,"y":1}]}"#.utf8)
        let safe = try JSONDecoder().decode(DrawingToolkitOptions.self, from: malformed)
        precondition(safe.mode == .stylus && safe.tickIntervalUS == 1000 && safe.offsetX == 15)
        precondition(safe.equalizationDepth == 40 && safe.curve == DrawingPressureCurve.linear)
        let linear = DrawingPressureCurve.lookup(DrawingPressureCurve.linear)
        for i in 0..<2048 { precondition(abs(linear[i] - Double(i) / 2047) < 0.000001) }
        let curved = DrawingPressureCurve.lookup([.init(x: 0, y: 0), .init(x: 0.1, y: 0.8), .init(x: 1, y: 1)])
        for pair in zip(curved, curved.dropFirst()) { precondition(pair.1 >= pair.0 && pair.1 <= 1) }
        precondition(DrawingPressureCurve.calibrated(samples: [0.5, 0.5]) == nil)
        let calibration = DrawingPressureCurve.calibrated(samples: (0...100).map { 0.1 + Double($0) * 0.008 })!
        precondition(DrawingPressureCurve.value(0.05, points: calibration) == 0)
        precondition(DrawingPressureCurve.value(0.95, points: calibration) == 1)
        var stroke = DrawingStrokePressure()
        options.highDensity = true
        options.hookFilterDepth = 2
        options.equalizationDepth = 3 // one-sample transition must not divide by zero
        options.equalizationStrength = 2
        precondition(stroke.map(0.5, options: options, lut: linear) == 0)
        precondition(stroke.map(0.5, options: options, lut: linear) == 0)
        let mapped = stroke.map(0.5, options: options, lut: linear)
        precondition(mapped.isFinite && abs(mapped - 0.5) < 0.001)
        stroke.reset()
        options.highDensity = false
        precondition(stroke.map(0.5, options: options, lut: linear) > 0)
        precondition(DrawingShortcut(key: "Z", control: true).keycode == 54)
        precondition(DrawingShortcut(key: "Z", control: true).modifiers == 0x1000)
        precondition(DrawingShortcut(key: "F12").keycode == 142)
        precondition(DrawingShortcut(key: "unsupported").keycode == nil)
        print("Drawing settings migration/round-trip, curves, calibration, stroke phases and shortcuts passed.")
    }
}
