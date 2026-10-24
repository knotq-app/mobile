import SwiftUI
import UIKit
import XCTest
@testable import KnotQMobile

/// Drives the real `DailyDayEditorSection` (real editor, real SwiftUI state) and
/// asserts when the "roll over" button is on screen: only on a genuinely blank
/// selected day, and live as the user types and deletes.
@MainActor
final class DailyCarryoverButtonTests: XCTestCase {
    private let today = "2026-10-23"
    private let yesterday = "2026-10-22"

    private func item(text: String = "", marker: String = "blank", indent: Int32 = 0) -> MobileItem {
        MobileItem(
            id: UUID().uuidString, text: text, marker: marker, indent: indent, kind: "text",
            done: false, start: nil, end: nil, notificationOffsetSecs: nil, repeatRule: nil,
            media: [], tables: [], content: []
        )
    }

    private func entry(_ items: [MobileItem]) -> MobileDailyEntry {
        MobileDailyEntry(
            date: today,
            scheme: MobileScheme(
                id: "daily-\(today)", name: "Daily \(today)", displayName: "Today", colorIndex: 0,
                isDailyQueue: true, isReadOnly: false, date: today, items: items
            )
        )
    }

    private struct Host {
        let controller: UIHostingController<AnyView>
        let window: UIWindow
        let model: AppModel
    }

    /// The view's `.task` asks the real core for a source day and — with no real
    /// yesterday in this process — clears it. Stand in for a core that reports
    /// yesterday, so what is under test is the view's own show/hide decision.
    private func reseed(_ host: Host) {
        spin(0.4)
        host.model.dailyCarryoverEntryDate = today
        host.model.dailyCarryoverSourceDate = yesterday
        spin(0.4)
    }

    /// `isEmpty` is what the Daily feed passes in: its looser text/date/media test.
    private func mount(_ items: [MobileItem]) -> Host {
        let model = AppModel()
        let loose = !items.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let root = DailyDayEditorSection(
            entry: entry(items), isEmpty: loose, selected: true, theme: .dark,
            autoFocusOnAppear: false, onSelect: {}
        )
        .environmentObject(model)
        let controller = UIHostingController(rootView: AnyView(root))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        spin(1.0)
        controller.view.layoutIfNeeded()
        let host = Host(controller: controller, window: window, model: model)
        reseed(host)
        return host
    }

    private func spin(_ seconds: TimeInterval = 0.6) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private var buttonLabel: String { L10n.t("daily.carryover.yesterday") }

    /// The SwiftUI button is not a UIKit view and is not surfaced through the hosting
    /// view's accessibility tree, so look for its label the way a user would: the
    /// accent-coloured pixels in the title row just above the editor.
    private func accentPixels(_ host: Host) -> Int {
        host.controller.view.layoutIfNeeded()
        let bounds = host.controller.view.bounds
        let image = UIGraphicsImageRenderer(bounds: bounds).image { _ in
            host.controller.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        guard let cg = image.cgImage, let editor = self.editor(host) else { return -1 }
        let scale = CGFloat(cg.width) / bounds.width
        let editorY = editor.convert(editor.bounds, to: host.controller.view).minY
        let rect = CGRect(x: 0, y: max(0, editorY - 70) * scale, width: CGFloat(cg.width), height: 70 * scale)
        guard let crop = cg.cropping(to: rect.integral) else { return -1 }
        var data = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        let ctx = CGContext(data: &data, width: crop.width, height: crop.height, bitsPerComponent: 8,
                            bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, al: CGFloat = 0
        UIColor(KnotQTheme.dark.accent).resolvedColor(with: host.controller.traitCollection).getRed(&r, green: &g, blue: &b, alpha: &al)
        var count = 0
        for i in stride(from: 0, to: data.count, by: 4) {
            let dr = abs(CGFloat(data[i]) / 255 - r), dg = abs(CGFloat(data[i + 1]) / 255 - g), db = abs(CGFloat(data[i + 2]) / 255 - b)
            if dr < 0.06 && dg < 0.06 && db < 0.06 { count += 1 }
        }
        return count
    }

    private func hasButton(_ host: Host) -> Bool { accentPixels(host) > 30 }

    private func editor(_ host: Host) -> EditorTextView? {
        func find(_ view: UIView) -> EditorTextView? {
            if let editor = view as? EditorTextView { return editor }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
        }
        return find(host.controller.view)
    }

    func testButtonShowsOnBlankDayAndTracksEdits() throws {
        let host = mount([item()])
        XCTAssertTrue(hasButton(host), "blank selected day should offer roll over")

        let editor = try XCTUnwrap(self.editor(host))
        XCTAssertTrue(editor.becomeFirstResponder())
        editor.insertText("hi")
        reseed(host)
        XCTAssertFalse(hasButton(host), "typing text must hide the button")

        editor.deleteBackward()
        editor.deleteBackward()
        reseed(host)
        XCTAssertTrue(hasButton(host), "deleting back to blank must bring the button back")
    }

    func testButtonHiddenWhenDayHoldsOnlyAnEmptyCheckbox() {
        let host = mount([item(marker: "checkbox")])
        XCTAssertFalse(hasButton(host), "an empty checkbox is content, not a blank day")
    }

    func testButtonHiddenWhenDayHoldsOnlyAnIndentedBlankLine() {
        let host = mount([item(indent: 1)])
        XCTAssertFalse(hasButton(host))
    }

    func testButtonHiddenWhenDayHasText() {
        let host = mount([item(text: "buy milk")])
        XCTAssertFalse(hasButton(host))
    }
}
