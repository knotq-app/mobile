import SwiftUI
import UIKit
import XCTest
@testable import KnotQMobile

/// Guards the two things that made opening a scheme or a daily look broken.
///
/// Both were invisible to every existing test because neither is a wrong value —
/// they are a wrong *look*, and they only showed up frame-by-frame in a screen
/// recording. These assert the structural properties that the recordings traced
/// the defects back to, so a future change that reintroduces either fails here
/// instead of a year later in a bug report.
@MainActor
final class KeyboardAccessoryTests: XCTestCase {

    // MARK: No live material inside an input accessory

    /// The bug: a `UIVisualEffectView` with a live effect anywhere inside an
    /// input accessory made the system keyboard present wrong on the first
    /// focus of a process — a flat grey panel, rgb(149,152,155) against the
    /// settled keyboard's rgb(216,218,221), held ~350 ms before snapping to the
    /// real keyboard. Bisected by swapping only the effect: `UIGlassEffect` and
    /// `UIBlurEffect(.systemUltraThinMaterial)` both reproduced it, `effect: nil`
    /// did not.
    ///
    /// This is easy to reintroduce, because glass is exactly what the *rest* of
    /// the app's chrome uses (the top capsule bar, the daily's floating buttons)
    /// and those are fine — the constraint applies only inside an accessory.
    func testEditorToolbarContainsNoLiveMaterial() {
        let coordinator = EditorCoordinator()
        let toolbar = coordinator.makeToolbar(for: UITextView())
        assertNoLiveMaterial(in: toolbar, what: "the editor formatting toolbar")
    }

    func testTableCellAccessoryContainsNoLiveMaterial() {
        let editor = EditorTableCellEditor(hit: sampleHit, theme: .dark)
        let accessory = try? XCTUnwrap(editor.field.inputAccessoryView)
        assertNoLiveMaterial(in: accessory, what: "the table cell editor's accessory bar")
    }

    private func assertNoLiveMaterial(in root: UIView?, what: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let root else { return XCTFail("\(what) has no view", file: file, line: line) }
        // Without this the test passes for free if the bar ever stops being
        // built (wrong flag, early return, renamed factory) — it would be
        // walking an empty view and reporting no offenders.
        XCTAssertGreaterThan(
            descendantCount(of: root), 8,
            "\(what) looks empty — this test would pass vacuously",
            file: file, line: line
        )
        let offenders = liveEffectViews(in: root)
        XCTAssertTrue(
            offenders.isEmpty,
            """
            \(what) contains \(offenders.count) UIVisualEffectView(s) with a live effect: \
            \(offenders.map { String(describing: type(of: $0.effect!)) }).
            A material inside an input accessory breaks the system keyboard's first \
            presentation of the process — use AccessoryBarPanel (a flat fill) instead. \
            Glass elsewhere in the app is fine; this restriction is accessory-only.
            """,
            file: file, line: line
        )
    }

    private func descendantCount(of view: UIView) -> Int {
        view.subviews.reduce(view.subviews.count) { $0 + descendantCount(of: $1) }
    }

    private func liveEffectViews(in view: UIView) -> [UIVisualEffectView] {
        var found: [UIVisualEffectView] = []
        if let effectView = view as? UIVisualEffectView, effectView.effect != nil {
            found.append(effectView)
        }
        for subview in view.subviews {
            found += liveEffectViews(in: subview)
        }
        return found
    }

    // MARK: Accessory height is independent of the frame UIKit hands it

    /// The bug: `intrinsicContentSize` derived its height from `frame.height`,
    /// which is circular — whatever frame UIKit hands the view first becomes its
    /// permanent intrinsic height. During keyboard presentation that frame is
    /// briefly as tall as the whole keyboard.
    func testAccessoryHeightSurvivesBeingHandedAKeyboardSizedFrame() {
        let bar = TransparentInputAccessoryView(frame: CGRect(x: 0, y: 0, width: 440, height: 58))
        XCTAssertEqual(bar.intrinsicContentSize.height, 58)

        bar.frame = CGRect(x: 0, y: 0, width: 440, height: 376)
        bar.layoutIfNeeded()

        XCTAssertEqual(
            bar.intrinsicContentSize.height, 58,
            "the bar's own height must not be re-derived from a frame UIKit hands it mid-presentation"
        )
    }

    func testAccessoryWidthIsUnconstrained() {
        let bar = TransparentInputAccessoryView(frame: CGRect(x: 0, y: 0, width: 440, height: 58))
        XCTAssertEqual(
            bar.intrinsicContentSize.width, UIView.noIntrinsicMetric,
            "the bar spans the keyboard, so it must not pin its own width"
        )
    }

    // MARK: Keyboard handoff and destination focus

    /// The bug: opening Daily (or a scheme) pushes a screen and focuses its
    /// editor, and raising the keyboard while that push was still animating made
    /// it render against an unresolved backdrop — a flat dark panel, rgb(152)
    /// against the settled light keyboard's rgb(219), held ~300 ms before
    /// snapping to the real keyboard. 9 of 16 cold opens of Daily reproduced it.
    ///
    /// Easy to undo by "simplifying" the focus back to a plain dispatch, and
    /// invisible in the dark theme, so assert the rule directly.
    func testFocusWaitsForATransitionInsteadOfFiringDuringIt() {
        let transition = SpyTransition()
        var focused = false

        EditorAutoFocus.focus(after: transition) { focused = true }

        XCTAssertFalse(focused, "focusing mid-push is what renders the keyboard grey")
        transition.finish()
        XCTAssertTrue(focused, "the caret still has to arrive when the push lands")
    }

    /// Nothing to wait for is the common case (a pane already on screen, an iPad
    /// split view). Deferring there would cost a visible beat for no reason.
    func testFocusIsImmediateWithNoTransitionRunning() {
        var focused = false
        EditorAutoFocus.focus(after: nil) { focused = true }
        XCTAssertTrue(focused)
    }

    /// A coordinator refuses new work once the transition is already ending. That
    /// must fall through to focusing, not swallow the caret.
    func testFocusStillHappensWhenTheTransitionWontTakeIt() {
        let transition = SpyTransition()
        transition.accepts = false
        var focused = false

        EditorAutoFocus.focus(after: transition) { focused = true }

        XCTAssertTrue(focused, "a refused hand-off must not leave the editor unfocused")
    }

    /// The pre-navigation keyboard is only safe to claim when the source screen
    /// is idle; an already-visible keyboard or another text input must proceed
    /// normally instead of stealing its responder.
    func testKeyboardHandoffOnlyPreparesFromAnIdleSource() {
        XCTAssertTrue(EditorKeyboardHandoff.shouldPrepare(isKeyboardVisible: false, hasTextInput: false))
        XCTAssertFalse(EditorKeyboardHandoff.shouldPrepare(isKeyboardVisible: true, hasTextInput: false))
        XCTAssertFalse(EditorKeyboardHandoff.shouldPrepare(isKeyboardVisible: false, hasTextInput: true))
    }

    /// The bug: the launch warm-up takes first responder and resigns in the same
    /// runloop turn, and UIKit announces that as a real keyboard presentation.
    /// Building the first keyboard of the process blocks inside
    /// `becomeFirstResponder()` for ~1s and posts *three* notifications from in
    /// there: a `willShow` with a real 366pt frame, a second `willShow` with the
    /// accessory bar's 58pt frame, then a `willHide`.
    ///
    /// Believing them corrupts every observer that tracks visibility from
    /// show/hide. With none suppressed the floating dock was hidden on 8 of 8
    /// cold launches (and `KeyboardMetrics.isVisible` stuck true silently
    /// disabled the keyboard handoff on the first navigation of every launch);
    /// suppressing only the first left the second show hiding the dock and the
    /// hide bringing it back, a visible flicker on 3 of 3 recorded launches.
    ///
    /// So the whole burst has to be disowned, not one notification of it.
    func testWarmupSuppressesEveryNotificationItProvokes() {
        KeyboardWarmup.beginWarmingForTesting()
        defer { KeyboardWarmup.endWarmingForTesting() }

        for event in ["willShow (366pt)", "willShow (58pt)", "willHide"] {
            XCTAssertTrue(
                KeyboardWarmup.isSuppressingKeyboardEvents,
                "\(event) is the warm-up's own and describes no keyboard the user can see"
            )
        }
    }

    /// With no warm-up running, a keyboard event is the user's and has to be
    /// believed. Getting this backwards would leave the dock over the keyboard.
    func testKeyboardEventsAreBelievedWhenNothingIsWarming() {
        KeyboardWarmup.endWarmingForTesting()
        XCTAssertFalse(KeyboardWarmup.isSuppressingKeyboardEvents)
    }

    /// Waiting for `didShow` serialized the keyboard and navigation animations,
    /// taking tap-to-settled from 1.42s to 2.01s. `willShow` is late enough that
    /// UIKit has committed the safe source-screen presentation, but early enough
    /// for the keyboard and push to travel together.
    func testKeyboardHandoffStartsNavigationAtWillShow() {
        XCTAssertEqual(EditorKeyboardHandoff.navigationTrigger, UIResponder.keyboardWillShowNotification)
        XCTAssertNotEqual(EditorKeyboardHandoff.navigationTrigger, UIResponder.keyboardDidShowNotification)
    }

    /// The bug: a new note pushes with `autoFocusTitleOnAppear`, but the handoff
    /// was always given to the *document*. The caret blinked in the body for the
    /// length of the push (~0.5s), then jumped up to the title and select-all
    /// highlighted it. The handoff has to go to whichever field the open ends on.
    func testTitleFocusTakesTheTitleAndNotTheDocument() {
        let (editor, window) = editorInWindow(titleEditable: true)
        defer { window.isHidden = true }

        XCTAssertTrue(editor.focusTitle(), "an editable title has to accept the handoff")
        XCTAssertFalse(
            editor.isFirstResponder,
            "the document taking the caret first is exactly the flash this removes"
        )
        XCTAssertTrue(
            firstResponderIsTextField(in: editor),
            "the title field should hold the keyboard"
        )
    }

    /// The formatting bar is built lazily by the document's `becomeFirstResponder`
    /// and the title borrows it through the responder chain. Focusing the title
    /// without ever focusing the document must still install it, or a new note
    /// opens with no toolbar.
    func testTitleFocusStillInstallsTheFormattingBar() {
        let (editor, window) = editorInWindow(titleEditable: true)
        defer { window.isHidden = true }

        XCTAssertNil(editor.inputAccessoryView)
        editor.focusTitle()
        XCTAssertNotNil(editor.inputAccessoryView)
    }

    /// A title that isn't editable yet (the pane is still read-only, waiting on a
    /// core write) must report the refusal, so the handoff proxy keeps the
    /// keyboard rather than being torn down with nothing to hand it to.
    func testTitleFocusReportsRefusalWhenTheTitleIsNotEditable() {
        let (editor, window) = editorInWindow(titleEditable: false)
        defer { window.isHidden = true }

        XCTAssertFalse(editor.focusTitle())
        XCTAssertFalse(firstResponderIsTextField(in: editor))
    }

    /// `EditorTextView.coordinator` is weak, so the coordinator has to outlive
    /// the call — held here for the length of the test.
    private var testCoordinator: EditorCoordinator?

    private func editorInWindow(titleEditable: Bool) -> (EditorTextView, UIWindow) {
        let editor = EditorTextView()
        editor.frame = CGRect(x: 0, y: 0, width: 390, height: 400)
        editor.isEditable = true
        testCoordinator = EditorCoordinator()
        editor.coordinator = testCoordinator
        editor.configureTitle(
            title: "Untitled",
            theme: .dark,
            visible: titleEditable,
            editable: titleEditable,
            validator: { _ in nil },
            onCommit: { _ in }
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(editor)
        window.makeKeyAndVisible()
        return (editor, window)
    }

    private func firstResponderIsTextField(in view: UIView) -> Bool {
        if view is UITextField, view.isFirstResponder { return true }
        return view.subviews.contains(where: firstResponderIsTextField)
    }

    /// Changing text-input traits with the responder transfer makes iOS rebuild
    /// the prediction row after the navigation animation. The proxy and editor
    /// must describe the same document keyboard from the outset.
    func testHandoffAndDocumentUseMatchingPredictionTraits() {
        let handoff = UITextView()
        let document = UITextView()
        EditorDocumentInputTraits.apply(to: handoff)
        EditorDocumentInputTraits.apply(to: document)

        XCTAssertEqual(handoff.autocapitalizationType, document.autocapitalizationType)
        XCTAssertEqual(handoff.autocorrectionType, document.autocorrectionType)
        XCTAssertEqual(handoff.spellCheckingType, document.spellCheckingType)
        XCTAssertEqual(handoff.smartDashesType, document.smartDashesType)
        XCTAssertEqual(handoff.smartQuotesType, document.smartQuotesType)
        XCTAssertNotEqual(handoff.autocorrectionType, .no)
    }

    /// UIKit's generic first-responder reveal moves the Daily feed even when its
    /// end caret is already visible above the handoff keyboard. The opening guard
    /// must reject that programmatic offset without making the scroll view
    /// permanently immovable.
    func testDailyInitialCaretGuardBlocksOnlyWhileArmed() {
        let scroll = DailyFeedScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        scroll.contentSize = CGSize(width: 320, height: 600)
        scroll.contentOffset = CGPoint(x: 0, y: 100)

        scroll.blocksInitialCaretReveal = true
        scroll.scrollRectToVisible(CGRect(x: 0, y: 300, width: 10, height: 10), animated: false)
        scroll.setContentOffset(CGPoint(x: 0, y: 180), animated: false)
        XCTAssertEqual(scroll.contentOffset.y, 100)

        scroll.blocksInitialCaretReveal = false
        scroll.setContentOffset(CGPoint(x: 0, y: 180), animated: false)
        XCTAssertEqual(scroll.contentOffset.y, 180)
    }

    /// The bug: a day row measured a different height depending on where it was
    /// scrolled. Each `UIHostingController` inherited the pane's top safe area
    /// clipped to its own overlap with it and folded that into its intrinsic
    /// height, and UIKit recomputed safe areas *after* the feed was revealed —
    /// so the selected day's content dropped 34pt about 1.7s after the tap, on
    /// 7 of 10 cold opens. The feed owns its insets outright; a row must not
    /// inset itself for the same chrome as well.
    func testDailyDayHostTakesNoSafeAreaOfItsOwn() {
        let chrome = UIEdgeInsets(top: 101, left: 0, bottom: 0, right: 0)
        let configured = dailyDayHost(in: chrome) { DailyDayHost.configure($0) }
        let unconfigured = dailyDayHost(in: chrome) { $0.sizingOptions = .intrinsicContentSize }
        // The pane's own inset, which is the chrome plus whatever the test's
        // window contributes — the row is 200pt tall, so it overlaps all of it.
        let inherited = unconfigured.parent?.view.safeAreaInsets.top ?? 0

        // The row still *reports* the inherited inset (`safeAreaRegions` governs
        // what the hosted SwiftUI does with it, not what UIKit propagates); what
        // must not happen is the row sizing itself around it.
        XCTAssertEqual(
            configured.view.intrinsicContentSize.height, 200,
            "a day's height must be its content's, wherever the row happens to sit"
        )
        // Without these the assertions above would pass for free if UIKit ever
        // stopped propagating the chrome into rows at all.
        XCTAssertTrue(
            (101...200).contains(inherited),
            "the setup has to put a real, fully overlapped inset on the row (got \(inherited))"
        )
        XCTAssertEqual(
            unconfigured.view.intrinsicContentSize.height, 200 + inherited,
            "the default really does fold the overlapped chrome into the row's height"
        )
    }

    /// Rows are self-sized from the editor's own TextKit measurement and drawn
    /// on the feed's background; a row that sizes to its container or paints its
    /// own would break the stack's layout and the selected-day highlight.
    func testDailyDayHostSelfSizesAndStaysTransparent() {
        let host = dailyDayHost(in: .zero) { DailyDayHost.configure($0) }

        XCTAssertEqual(host.sizingOptions, .intrinsicContentSize)
        XCTAssertEqual(host.view.backgroundColor, .clear)
    }

    /// A day hosting controller placed so that it fully overlaps `chrome`, which
    /// stands in for the pane's top safe area.
    private func dailyDayHost(
        in chrome: UIEdgeInsets,
        configure: (UIHostingController<AnyView>) -> Void
    ) -> UIHostingController<AnyView> {
        let width: CGFloat = 390
        let parent = UIViewController()
        parent.additionalSafeAreaInsets = chrome
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 844))
        window.rootViewController = parent
        window.isHidden = false

        let host = UIHostingController(rootView: AnyView(Color.clear.frame(height: 200)))
        configure(host)
        parent.addChild(host)
        host.view.frame = CGRect(x: 0, y: 0, width: width, height: 200)
        parent.view.addSubview(host.view)
        host.didMove(toParent: parent)
        parent.view.layoutIfNeeded()
        return host
    }

    /// The selected Daily editor is positioned before the feed is revealed. Its
    /// caret needs the same delta UIKit would request later, but calculated from
    /// the accessory's captured top edge so the heading cannot start underneath
    /// the formatting toolbar.
    func testDailyCaretVisibilityDeltaUsesTheAccessoryBoundary() {
        XCTAssertEqual(
            DailyCaretVisibility.offsetDelta(
                for: CGRect(x: 0, y: 180, width: 1, height: 20),
                visibleTop: 20,
                visibleBottom: 160
            ),
            40
        )
        XCTAssertEqual(
            DailyCaretVisibility.offsetDelta(
                for: CGRect(x: 0, y: 5, width: 1, height: 10),
                visibleTop: 20,
                visibleBottom: 160
            ),
            -15
        )
        XCTAssertEqual(
            DailyCaretVisibility.offsetDelta(
                for: CGRect(x: 0, y: 80, width: 1, height: 20),
                visibleTop: 20,
                visibleBottom: 160
            ),
            0
        )
    }

    func testDailyOpeningPositionsForTheEventualEndCaret() {
        XCTAssertEqual(DailyCaretVisibility.openingCaretOffset(textLength: 0), 0)
        XCTAssertEqual(DailyCaretVisibility.openingCaretOffset(textLength: 1), 0)
        XCTAssertEqual(DailyCaretVisibility.openingCaretOffset(textLength: 24), 23)
    }

    /// The selected date and final caret fit together on the iPhone 14. Treating
    /// them as one range keeps the heading visible when the caret is raised to
    /// the accessory boundary instead of opening with "today" underneath it.
    func testDailyOpeningKeepsHeadingAndCaretVisibleWhenTheyFit() {
        XCTAssertEqual(
            DailyCaretVisibility.openingOffsetDelta(
                sectionTop: 100,
                caretRect: CGRect(x: 0, y: 260, width: 1, height: 20),
                visibleTop: 20,
                visibleBottom: 200
            ),
            80
        )
    }

    /// If one day is taller than the keyboard-visible viewport, showing its end
    /// cannot also show its identity. Daily should open on the date heading and
    /// leave ordinary user scrolling to reach the rest.
    func testDailyOpeningPrefersHeadingWhenSelectedDayCannotFit() {
        XCTAssertEqual(
            DailyCaretVisibility.openingOffsetDelta(
                sectionTop: 100,
                caretRect: CGRect(x: 0, y: 500, width: 1, height: 20),
                visibleTop: 20,
                visibleBottom: 300
            ),
            80
        )
    }

    /// Repeated content height is not enough readiness on a physical phone: the
    /// handoff responder can arrive a frame later and change the final TextKit
    /// geometry. Only the focused selected editor releases the hidden pin.
    func testDailyOpeningWaitsForTheHandoffResponder() {
        XCTAssertTrue(DailyCaretVisibility.waitsForSelectedResponder(
            autoFocus: true,
            keyboardVisible: true,
            selectedEditorIsFirstResponder: false
        ))
        XCTAssertFalse(DailyCaretVisibility.waitsForSelectedResponder(
            autoFocus: true,
            keyboardVisible: true,
            selectedEditorIsFirstResponder: true
        ))
        XCTAssertFalse(DailyCaretVisibility.waitsForSelectedResponder(
            autoFocus: false,
            keyboardVisible: true,
            selectedEditorIsFirstResponder: false
        ))
    }

    /// Merely adding the obstruction (103pt here) does nothing when a short
    /// feed still has 135pt of unused viewport. The opening inset must consume
    /// both before UIKit can honor the caret offset.
    func testDailyCaretClearanceMakesAnOffsetReachableForShortContent() {
        XCTAssertEqual(
            DailyCaretVisibility.bottomInsetGrowth(
                from: -64,
                by: 103,
                contentHeight: 596,
                viewportHeight: 922,
                currentBottomInset: 127
            ),
            238
        )
        XCTAssertEqual(
            DailyCaretVisibility.bottomInsetGrowth(
                from: 100,
                by: 20,
                contentHeight: 1_000,
                viewportHeight: 600,
                currentBottomInset: 40
            ),
            0,
            "a feed with existing scroll range needs no extra clearance"
        )
    }

    // MARK: Keyboard metrics

    /// A recorded overlap has to come back out, or every pane that anticipates
    /// the keyboard silently falls back to the rough proportional guess and the
    /// open jumps again.
    func testRecordedOverlapIsReturnedForTheSameScreenWidth() {
        let width: CGFloat = 393
        KeyboardMetrics.record(overlap: 372, screenWidth: width)
        UserDefaults.standard.synchronize()

        XCTAssertEqual(KeyboardMetrics.rememberedOverlap(forScreenWidth: width), 372)
    }

    func testOverlapIsKeyedByScreenWidth() {
        KeyboardMetrics.record(overlap: 372, screenWidth: 393)
        KeyboardMetrics.record(overlap: 420, screenWidth: 440)

        XCTAssertEqual(KeyboardMetrics.rememberedOverlap(forScreenWidth: 393), 372)
        XCTAssertEqual(KeyboardMetrics.rememberedOverlap(forScreenWidth: 440), 420,
                       "a phone and a pad must not share one remembered height")
    }

    /// Nonsense must not be cached — a zero or negative overlap would park every
    /// later anticipation at "no keyboard".
    func testImplausibleOverlapsAreRejected() {
        KeyboardMetrics.record(overlap: 300, screenWidth: 1024)
        KeyboardMetrics.record(overlap: 0, screenWidth: 1024)
        KeyboardMetrics.record(overlap: -50, screenWidth: 1024)

        XCTAssertEqual(KeyboardMetrics.rememberedOverlap(forScreenWidth: 1024), 300)
    }

    /// A pane loses a different amount to the keyboard than the screen does —
    /// it stops at the top of the bottom safe area, inside a hierarchy SwiftUI
    /// also resizes. Deriving one from the other left the daily open handing
    /// 15pt back the instant the keyboard landed, so the pane's own measurement
    /// has to be kept separately and win.
    func testPaneOverlapIsRememberedSeparatelyFromTheScreenOverlap() {
        let width: CGFloat = 1284
        KeyboardMetrics.record(overlap: 403, screenWidth: width)
        KeyboardMetrics.recordPaneOverlap(369, screenWidth: width)

        XCTAssertEqual(KeyboardMetrics.rememberedOverlap(forScreenWidth: width), 403)
        XCTAssertEqual(
            KeyboardMetrics.rememberedPaneOverlap(forScreenWidth: width), 369,
            "a pane must reserve what it measured, not what the screen measured"
        )
    }

    /// A hardware keyboard leaves only the accessory bar. Remembering that as
    /// "the keyboard height" would under-reserve every later open by ~300pt.
    func testAccessoryOnlyOverlapIsNotRememberedAsAKeyboard() {
        let width: CGFloat = 1290
        KeyboardMetrics.recordPaneOverlap(369, screenWidth: width)
        KeyboardMetrics.recordPaneOverlap(58, screenWidth: width)

        XCTAssertEqual(KeyboardMetrics.rememberedPaneOverlap(forScreenWidth: width), 369)
    }

    /// With nothing measured yet the estimate still has to be in the right
    /// ballpark: too small and the open jumps, too large and the content is
    /// pushed off the top.
    func testUnmeasuredEstimateStaysWithinSaneBounds() {
        for height in [568.0, 667.0, 844.0, 956.0, 1366.0] as [CGFloat] {
            let estimate = KeyboardMetrics.estimatedOverlap(forScreenHeight: height)
            XCTAssertGreaterThanOrEqual(estimate, 280, "screen height \(height)")
            XCTAssertLessThanOrEqual(estimate, 460, "screen height \(height)")
            XCTAssertLessThan(estimate, height * 0.85, "an estimate that eats the screen is worse than none")
        }
    }

    // MARK: Riding the keyboard's own animation

    /// Content has to move on the keyboard's duration and curve. Reading either
    /// one wrong is what made the document correct itself a beat *after* the
    /// keyboard had already landed instead of moving with it.
    func testAnimationUsesTheCurveAndDurationFromTheNotification() {
        let note = keyboardNotification(duration: 0.35, curve: 7)
        let (duration, options) = KeyboardMetrics.animation(from: note)

        XCTAssertEqual(duration, 0.35, accuracy: 0.0001)
        XCTAssertTrue(
            options.contains(UIView.AnimationOptions(rawValue: 7 << 16)),
            "the keyboard's private curve (7) must be passed through, not remapped to an easing constant"
        )
        XCTAssertTrue(
            options.contains(.beginFromCurrentState),
            "a second keyboard change mid-flight must retarget, not restart from the old position"
        )
    }

    /// A malformed/absent payload must still animate rather than snapping, and
    /// must never produce a zero duration (UIView treats that as "no animation",
    /// which is the instant jump this whole mechanism exists to remove).
    func testAnimationFallsBackToASaneDuration() {
        let (duration, _) = KeyboardMetrics.animation(from: Notification(name: UIResponder.keyboardWillChangeFrameNotification))
        XCTAssertGreaterThan(duration, 0)
        XCTAssertLessThanOrEqual(duration, 0.5)

        let (clamped, _) = KeyboardMetrics.animation(from: keyboardNotification(duration: 0, curve: 7))
        XCTAssertGreaterThan(clamped, 0, "a zero duration from the system must still be animated")
    }

    // MARK: Google Calendar status copy

    /// Settings was rendering the core's raw failure straight into the form:
    /// five lines of JSON with braces and quoted keys, mid-page.
    func testStatusDropsTheSerializedPayload() {
        let raw = """
        mbhat@ucsd.edu: Google OAuth HTTP 400: {
          "error": "invalid_request",
          "error_description": "Missing required parameter: refresh_token"
        }
        """
        let shown = GoogleCalendarStatusText.readable(raw)

        XCTAssertEqual(shown, "mbhat@ucsd.edu: Google OAuth HTTP 400")
        XCTAssertFalse(shown!.contains("{"), "no JSON may reach the UI")
        XCTAssertFalse(shown!.contains("\n"), "the status is a single footnote line")
    }

    func testOrdinaryStatusIsLeftAlone() {
        XCTAssertEqual(
            GoogleCalendarStatusText.readable("Imported 2 calendars."),
            "Imported 2 calendars.",
            "a normal, already-localized message must pass through untouched"
        )
    }

    func testStatusIsCappedRatherThanFloodingTheForm() {
        let long = String(repeating: "a", count: 400)
        let shown = GoogleCalendarStatusText.readable(long)

        XCTAssertEqual(shown?.count, 160)
        XCTAssertEqual(shown?.last, "…")
    }

    func testNothingToShowStaysHidden() {
        XCTAssertNil(GoogleCalendarStatusText.readable(nil))
        XCTAssertNil(GoogleCalendarStatusText.readable(""))
        XCTAssertNil(GoogleCalendarStatusText.readable("   \n  "))
        XCTAssertNil(
            GoogleCalendarStatusText.readable("{\"error\":\"x\"}"),
            "a message that is nothing but payload leaves an empty row, so show none"
        )
    }

    // MARK: Upcoming display preferences

    func testUpcomingDisplayAppliesVisibilityDeduplicationAndLimitInOrder() {
        let completedOverdue = occurrence(id: "completed", done: true)
        let openOverdue = occurrence(id: "overdue")
        let upcoming = occurrence(id: "upcoming")

        let visible = MobileUpcomingDisplay.visibleOccurrences(
            overdue: [completedOverdue, openOverdue],
            upcoming: [openOverdue, upcoming],
            maximumItems: 2,
            showOverdue: true,
            showCompleted: false
        )

        XCTAssertEqual(visible.map(\.itemId), ["overdue", "upcoming"])
    }

    func testUpcomingDisplayCanHideTheEntireOverdueBucket() {
        let visible = MobileUpcomingDisplay.visibleOccurrences(
            overdue: [occurrence(id: "overdue")],
            upcoming: [occurrence(id: "upcoming")],
            maximumItems: 14,
            showOverdue: false,
            showCompleted: true
        )

        XCTAssertEqual(visible.map(\.itemId), ["upcoming"])
    }

    // MARK: Helpers

    private func occurrence(id: String, done: Bool = false) -> MobileOccurrence {
        MobileOccurrence(
            schemeId: "scheme",
            itemId: id,
            occurrenceJson: "{\"Single\":null}",
            occurrenceIndex: 0,
            isRecurring: false,
            canDeleteFuture: false,
            schemeName: "Scheme",
            colorIndex: 0,
            isReadOnly: false,
            title: id,
            kind: "assignment",
            done: done,
            start: nil,
            end: "2026-08-10T12:00:00Z",
            notificationOffsetSecs: nil,
            localDate: "2026-08-10",
            repeatRule: nil
        )
    }

    private var sampleHit: EditorTableCellHit {
        EditorTableCellHit(
            itemID: "item",
            tableIndex: 0,
            row: 0,
            column: 0,
            text: "cell",
            frame: CGRect(x: 0, y: 0, width: 100, height: 24)
        )
    }

    /// A screen transition that finishes when the test says so.
    @MainActor
    private final class SpyTransition: EditorFocusTransition {
        var accepts = true
        private var completion: (@MainActor () -> Void)?

        func runAfterTransition(_ completion: @escaping @MainActor () -> Void) -> Bool {
            guard accepts else { return false }
            self.completion = completion
            return true
        }

        func finish() {
            completion?()
            completion = nil
        }
    }

    private func keyboardNotification(duration: Double, curve: UInt) -> Notification {
        Notification(
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
            userInfo: [
                UIResponder.keyboardAnimationDurationUserInfoKey: NSNumber(value: duration),
                UIResponder.keyboardAnimationCurveUserInfoKey: NSNumber(value: curve),
            ]
        )
    }
}
