@testable import AppBundle
import Common

final class TestApp: AbstractApp {
    let pid: Int32
    let rawAppBundleId: String?
    let name: String?
    let execPath: String? = nil
    let bundlePath: String? = nil
    @MainActor
    static let shared = TestApp()
    /// [FORK gmjain/AeroSpace] a second app, for focus-guard tests that need a different bundle id
    @MainActor
    static let other = TestApp(pid: 1, rawAppBundleId: "bobko.AeroSpace.test-app-other")

    private init(pid: Int32 = 0, rawAppBundleId: String = "bobko.AeroSpace.test-app") {
        self.pid = pid
        self.rawAppBundleId = rawAppBundleId
        self.name = rawAppBundleId
    }

    var _windows: [Window] = []
    var windows: [Window] {
        get { _windows }
        set {
            if let focusedWindow {
                check(newValue.contains(focusedWindow))
            }
            _windows = newValue
        }
    }

    private var _focusedWindow: Window? = nil
    var focusedWindow: Window? {
        get { _focusedWindow }
        set {
            if let window = newValue {
                check(windows.contains(window))
            }
            _focusedWindow = newValue
        }
    }
    @MainActor func getFocusedWindow(_ cm: CancellationMode) -> Window? { _focusedWindow }
}
