// Compile-only substitutes for application/SDL symbols. This lets CI check
// the production handler against the real UIKit SDK before native libs finish.
// Full application linking still uses the real types and C bridge.
import UIKit

enum SessionDeviceType { case adb, vnc }
struct ADBSessionOptions { var drawingToolkit = DrawingToolkitOptions() }
final class ScrcpySessionModel {
    var deviceType = SessionDeviceType.adb
    var adbOptions = ADBSessionOptions()
}
final class SessionConnectionManager {
    static let shared = SessionConnectionManager()
    var currentSession: ScrcpySessionModel?
}
func SDL_GetKeyboardFocus() -> OpaquePointer? { nil }
func SDL_GetMouseFocus() -> OpaquePointer? { nil }
func SDL_GetWindowID(_ window: OpaquePointer) -> UInt32 { 0 }
func ScrcpySendStylusEvent(_ window: UInt32, _ action: UInt8, _ tool: UInt8,
                          _ x: Float, _ y: Float, _ pressure: Float, _ tilt: Float,
                          _ orientation: Float, _ buttons: UInt32, _ time: UInt64) -> Bool { false }
func ScrcpySendDrawingKey(_ window: UInt32, _ code: UInt32, _ modifiers: UInt32, _ down: Bool) -> Bool { false }
