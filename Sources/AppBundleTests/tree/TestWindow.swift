@testable import AppBundle
import AppKit

final class TestWindow: Window, CustomStringConvertible {
    private var _rect: Rect?
    var isMacosFullscreenForTest = false

    @MainActor
    private init(
        _ id: UInt32,
        _ parent: NonLeafTreeNodeObject,
        _ adaptiveWeight: CGFloat,
        _ rect: Rect?,
        _ app: TestApp, // [FORK gmjain/AeroSpace]
    ) {
        _rect = rect
        super.init(id: id, app, lastFloatingSize: nil, parent: parent, adaptiveWeight: adaptiveWeight, index: INDEX_BIND_LAST)
    }

    @discardableResult
    @MainActor
    static func new(
        id: UInt32,
        parent: NonLeafTreeNodeObject,
        adaptiveWeight: CGFloat = 1,
        rect: Rect? = nil,
        app: TestApp? = nil, // [FORK gmjain/AeroSpace] nil = TestApp.shared
    ) -> TestWindow {
        let app = app ?? TestApp.shared
        let wi = TestWindow(id, parent, adaptiveWeight, rect, app)
        app._windows.append(wi)
        return wi
    }

    nonisolated var description: String { "TestWindow(\(windowId))" }

    @MainActor
    override func nativeFocusImpl() { // [FORK gmjain/AeroSpace] Window.nativeFocus is final: notes the request first
        let app = app as! TestApp // [FORK gmjain/AeroSpace] TestApp.shared or TestApp.other
        appForTests = app
        app.focusedWindow = self
    }

    override func closeAxWindow() {
        unbindFromParent()
    }

    override func getTitle(_ cm: CancellationMode) async throws -> String { description }

    @MainActor override func getAxRect(_ cm: CancellationMode) async throws -> Rect? { // todo change to not Optional
        _rect
    }

    @MainActor override func getAxSize(_ cm: CancellationMode) async throws -> CGSize? {
        _rect.map { CGSize(width: $0.width, height: $0.height) }
    }

    override func isMacosFullscreen(_ cm: CancellationMode) async throws -> Bool { isMacosFullscreenForTest }
}
