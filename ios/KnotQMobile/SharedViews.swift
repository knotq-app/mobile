import SwiftUI
import UIKit


/// Builds the system keyboard once, invisibly, so the *first* real focus does
/// not pay for it.
///
/// The first `becomeFirstResponder` of a process is not like the ones after it:
/// UIKit has to stand up the remote keyboard — attach its host, build its view
/// hierarchy, resolve its material. Making a detached text field first responder
/// and resigning in the same runloop turn does that work with no keyboard ever
/// presented (no animation runs, because the responder is gone before the next
/// turn).
///
/// Measured on iOS 26, tapping into a scheme from the home list, time from tap
/// to everything on screen having stopped moving, three runs each:
/// warm 1.408 / 1.418 / 1.448 s, cold 1.648 / 1.675 / 1.612 s — **~220 ms
/// faster, with no overlap between the two sets**.
///
/// Deliberately *not* on the launch critical path: the cost lands in an idle
/// moment after first content rather than adding to time-to-first-frame.
///
/// Note this does *not* address the grey keyboard on first focus — that was the
/// accessory bar's material, see `AccessoryBarPanel`. Warming alone left the
/// grey exactly as it was.
@MainActor
enum KeyboardWarmup {
    private static var warmed = false

    private static var isWarming = false

    /// True while the warm-up itself holds the responder, in which case every
    /// keyboard notification on the wire is one it provoked and describes no
    /// keyboard the user can see. Observers must ignore all of them.
    ///
    /// Building the very first keyboard of the process blocks the main thread
    /// inside `becomeFirstResponder()` for about a second, and UIKit posts
    /// *three* notifications from in there before returning:
    ///
    ///     0.931  keyboardWillShow  (0, 478, 390, 366)   a real keyboard frame
    ///     0.950  keyboardWillShow  (0, 786, 390,  58)   the accessory bar alone
    ///     1.011  keyboardWillHide
    ///     1.020  resignFirstResponder returns
    ///
    /// Believing any of them corrupts keyboard-visibility state for observers
    /// that only track show/hide: with none suppressed the floating dock was
    /// hidden on **8 of 8** cold launches, and suppressing just the first (this
    /// used to consume exactly one show) left the second show hiding the dock
    /// and the hide bringing it back — a visible ~0.2s flicker about a second
    /// into every launch, 3 of 3 recordings.
    ///
    /// The window is exactly `warmNow()`'s own execution. Since the main thread
    /// is blocked in there, nothing else can be running and no user input can
    /// be processed, so a real keyboard event cannot be caught by this.
    static var isSuppressingKeyboardEvents: Bool { isWarming }

    #if DEBUG
    static func beginWarmingForTesting() { isWarming = true }
    static func endWarmingForTesting() { isWarming = false }
    #endif

    /// Warms after a short delay, once, per process. Safe to call repeatedly.
    static func warmSoon() {
        guard !warmed else { return }
        warmed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { warmNow() }
    }

    private static func warmNow() {
        // A keyboard that is already up means the user beat us to it and the
        // build has already happened — warming now would steal the caret.
        guard !KeyboardMetrics.isVisible,
              let scene = UIApplication.shared.connectedScenes
                  .compactMap({ $0 as? UIWindowScene })
                  .first(where: { $0.activationState == .foregroundActive }),
              let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first,
              window.firstResponderIsTextInput == false
        else { return }

        // 1pt, just off the top edge, fully transparent. It must NOT be hidden
        // and must have a non-zero size: UIKit refuses first responder to a
        // hidden view, which silently turns this whole thing into a no-op.
        let field = UITextField(frame: CGRect(x: 0, y: -1, width: 1, height: 1))
        field.alpha = 0.01
        // Warm the accessory path too, not just the bare keyboard: the editors
        // all focus with an `inputAccessoryView`, and a keyboard-plus-accessory
        // is a different first presentation from a keyboard alone.
        //
        // This only buys build time. It does NOT make the first presentation
        // safe: letting this warm-up present the keyboard for real (0.45 s
        // instead of resigning immediately) still left 10 of 10 cold opens of
        // Daily grey — see `EditorAutoFocus`, where the actual cause lives.
        field.inputAccessoryView = UIView(
            frame: CGRect(x: 0, y: 0, width: window.bounds.width, height: 58)
        )
        window.addSubview(field)
        // Everything between here and `isWarming = false` runs without giving up
        // the main thread, and every keyboard notification the warm-up provokes
        // is posted inside it — see `isSuppressingKeyboardEvents`.
        isWarming = true
        field.becomeFirstResponder()
        // Resign in the SAME runloop turn. Deferring it by even one turn leaves
        // an invisible field holding first responder while the user could be
        // tapping into a real one, and measured no faster.
        field.resignFirstResponder()
        isWarming = false
        field.removeFromSuperview()
    }
}

private extension UIWindow {
    /// True when something in this window is already taking keyboard input, in
    /// which case the keyboard is (or is about to be) up.
    var firstResponderIsTextInput: Bool {
        func search(_ view: UIView) -> Bool {
            if view.isFirstResponder, view is UITextInput { return true }
            return view.subviews.contains(where: search)
        }
        return search(self)
    }
}

/// Starts the first keyboard on the settled source screen, then begins navigation
/// from `keyboardWillShow`. Starting both in the tap transaction still races iOS
/// 26's backdrop resolution; the notification is the first point where UIKit has
/// committed to the keyboard presentation, while its animation is still ahead of
/// us and can run alongside the push.
@MainActor
enum EditorKeyboardHandoff {
    static let navigationTrigger = UIResponder.keyboardWillShowNotification
    private static var field: UITextView?
    private static var observer: NSObjectProtocol?
    private static var timeout: DispatchWorkItem?

    static func shouldPrepare(isKeyboardVisible: Bool, hasTextInput: Bool) -> Bool {
        !isKeyboardVisible && !hasTextInput
    }

    static func prepare(theme: KnotQTheme, then proceed: @escaping @MainActor @Sendable () -> Void) {
        cancel()
        guard let window = UIApplication.shared.connectedScenes
                  .compactMap({ $0 as? UIWindowScene })
                  .first(where: { $0.activationState == .foregroundActive })?
                  .windows.first(where: { $0.isKeyWindow }) else {
            proceed()
            return
        }
        guard shouldPrepare(
            isKeyboardVisible: KeyboardMetrics.isVisible,
            hasTextInput: window.firstResponderIsTextInput
        ) else {
            proceed()
            return
        }

        let owner = EditorCoordinator()
        owner.theme = theme
        let next = UITextView(frame: CGRect(x: 0, y: -1, width: 1, height: 1))
        next.alpha = 0.01
        next.keyboardAppearance = theme.isDark ? .dark : .light
        EditorDocumentInputTraits.apply(to: next)
        next.inputAccessoryView = owner.makeToolbar(for: next)
        window.addSubview(next)
        guard next.becomeFirstResponder() else {
            next.removeFromSuperview()
            proceed()
            return
        }
        field = next

        let finish: @MainActor @Sendable () -> Void = {
            observer.map(NotificationCenter.default.removeObserver)
            observer = nil
            timeout?.cancel()
            timeout = nil
            proceed()
        }
        observer = NotificationCenter.default.addObserver(
            forName: navigationTrigger,
            object: nil,
            queue: .main
        ) { note in
            let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            MainActor.assumeIsolated {
                if let frame {
                    KeyboardMetrics.noteKeyboardFrame(frame)
                }
                finish()
            }
        }
        let work = DispatchWorkItem { MainActor.assumeIsolated { finish() } }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// Hands the raised keyboard to the field this open is actually for. The
    /// title borrows the document's accessory through the responder chain, so
    /// either target keeps the same bar — only the keyboard's own traits (no
    /// autocorrect, a Done return key) change with a title.
    @discardableResult
    static func transfer(to editor: EditorTextView, target: EditorAutoFocus.Target = .document) -> Bool {
        guard let field else { return false }
        editor.inputAccessoryView = editor.inputAccessoryView ?? editor.coordinator?.makeToolbar(for: editor)
        let accepted: Bool
        switch target {
        case .document: accepted = editor.becomeFirstResponder()
        case .title: accepted = editor.focusTitle()
        }
        guard accepted else { return false }
        field.removeFromSuperview()
        self.field = nil
        return true
    }

    /// Drop a proxy whose destination refused the responder, once something else
    /// holds it. Deliberately not `cancel()`: resigning a field that is still the
    /// first responder would dismiss the keyboard the open just raised.
    static func discardIfNotFirstResponder() {
        guard let field, !field.isFirstResponder else { return }
        observer.map(NotificationCenter.default.removeObserver)
        observer = nil
        timeout?.cancel()
        timeout = nil
        field.removeFromSuperview()
        self.field = nil
    }

    static func cancel() {
        observer.map(NotificationCenter.default.removeObserver)
        observer = nil
        timeout?.cancel()
        timeout = nil
        field?.resignFirstResponder()
        field?.removeFromSuperview()
        field = nil
    }
}

/// The source-screen handoff field and the real document must request the same
/// keyboard configuration. If traits change with the responder transfer, iOS
/// rebuilds the prediction row after the push instead of carrying it through
/// the animation.
@MainActor
enum EditorDocumentInputTraits {
    static func apply(to textView: UITextView) {
        textView.autocapitalizationType = .sentences
        textView.autocorrectionType = .default
        textView.spellCheckingType = .default
        textView.smartDashesType = .no
        textView.smartQuotesType = .no
    }
}

/// Remembers how much of the screen the keyboard last covered, so a view that
/// raises the keyboard *as it appears* can lay itself out for the
/// keyboard-visible size on its very first frame.
///
/// Without this the sequence is: the pane pushes in laid out full-height, the
/// keyboard slides up over content that is really there, and a beat later
/// (~300 ms, once UIKit reacts to the keyboard) the document jumps to put the
/// caret back on screen. On a long scheme that jump is most of a screen — it
/// reads as the app glitching rather than as a keyboard opening. Anticipating
/// the height means nothing moves: the keyboard slides into space that was
/// already reserved for it.
///
/// The value is the overlap measured from the *bottom of the screen* to the top
/// of the keyboard, including its input-accessory bar. Callers convert into
/// their own geometry (a view inside the safe area subtracts the bottom safe
/// inset; a view that ignores the keyboard safe area uses it as-is).
@MainActor
enum KeyboardMetrics {
    private static let defaultsKeyPrefix = "knotq.mobile.keyboardOverlap.v1."

    /// True between `keyboardWillShow` and `keyboardWillHide`. A pane appearing
    /// while the keyboard is already up needs no reservation — the layout it is
    /// born into already excludes the keyboard.
    private(set) static var isVisible = false
    private(set) static var keyboardFrameEnd: CGRect?

    private static var cache: [Int: CGFloat] = [:]

    private static let paneDefaultsKeyPrefix = "knotq.mobile.paneKeyboardOverlap.v1."
    private static var paneCache: [Int: CGFloat] = [:]

    static func noteKeyboardVisible(_ visible: Bool) {
        isVisible = visible
        if !visible { keyboardFrameEnd = nil }
    }

    static func noteKeyboardFrame(_ frame: CGRect) {
        guard frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width.isFinite, frame.height.isFinite else { return }
        keyboardFrameEnd = frame
    }

    /// Record a real measurement so the next anticipation is exact.
    static func record(overlap: CGFloat, screenWidth: CGFloat) {
        guard overlap > 0, overlap.isFinite, screenWidth > 0 else { return }
        let key = Int(screenWidth.rounded())
        guard cache[key] != overlap else { return }
        cache[key] = overlap
        UserDefaults.standard.set(Double(overlap), forKey: defaultsKeyPrefix + String(key))
    }

    /// The exact overlap measured on a screen of this width, if one has been.
    /// In-memory first, then the value carried over from earlier launches.
    static func rememberedOverlap(forScreenWidth width: CGFloat) -> CGFloat? {
        let key = Int(width.rounded())
        if let remembered = cache[key] { return remembered }
        let stored = UserDefaults.standard.double(forKey: defaultsKeyPrefix + String(key))
        guard stored > 0 else { return nil }
        cache[key] = CGFloat(stored)
        return CGFloat(stored)
    }

    /// Guess for a screen nothing has been measured on yet. Keyboard plus
    /// accessory bar is close to 42% of the screen on every portrait iPhone;
    /// clamped so an unusual size can't produce a wild one. Being a little off
    /// costs a small correction, where not anticipating at all costs a
    /// full-document jump.
    static func estimatedOverlap(forScreenHeight height: CGFloat) -> CGFloat {
        min(max(height * 0.42, 280), 460)
    }

    /// Best estimate of the overlap a keyboard raised right now would produce.
    static func anticipatedOverlap(in view: UIView?) -> CGFloat {
        let screen = view?.window?.screen.bounds ?? UIScreen.main.bounds
        return rememberedOverlap(forScreenWidth: screen.width)
            ?? estimatedOverlap(forScreenHeight: screen.height)
    }

    /// `anticipatedOverlap` expressed in the geometry of a view that lives
    /// inside the bottom safe area (SwiftUI's keyboard avoidance replaces that
    /// inset rather than adding to it, so the view only loses the difference).
    static func anticipatedInsetInsideSafeArea(for view: UIView?) -> CGFloat {
        guard !isVisible else { return 0 }
        return max(0, anticipatedOverlap(in: view) - bottomSafeInset(for: view))
    }

    // MARK: What a pane itself loses to the keyboard

    /// A pane measures its own overlap as `scrollView.frame.maxY - keyboardTop`,
    /// which is **not** the screen overlap recorded above: the pane stops at the
    /// top of the bottom safe area, and sits in a hierarchy SwiftUI also resizes
    /// when the keyboard arrives, so it loses a different amount. Deriving one
    /// from the other by arithmetic is what kept leaving a visible correction on
    /// open (34pt, then 27pt after a first attempt at the subtraction).
    ///
    /// So don't derive it — remember what the pane actually measured, and the
    /// next open reserves exactly that. Only the very first open on a screen
    /// size falls back to the arithmetic.
    static func recordPaneOverlap(_ overlap: CGFloat, screenWidth: CGFloat) {
        // A hardware keyboard leaves only the accessory bar, which is a real
        // overlap but not the one to plan the next open around.
        guard overlap > 120, overlap.isFinite, screenWidth > 0 else { return }
        let key = Int(screenWidth.rounded())
        guard paneCache[key] != overlap else { return }
        paneCache[key] = overlap
        UserDefaults.standard.set(Double(overlap), forKey: paneDefaultsKeyPrefix + String(key))
    }

    static func rememberedPaneOverlap(forScreenWidth width: CGFloat) -> CGFloat? {
        let key = Int(width.rounded())
        if let remembered = paneCache[key] { return remembered }
        let stored = UserDefaults.standard.double(forKey: paneDefaultsKeyPrefix + String(key))
        guard stored > 0 else { return nil }
        paneCache[key] = CGFloat(stored)
        return CGFloat(stored)
    }

    /// What a pane about to be pushed should reserve at its own bottom.
    static func anticipatedPaneOverlap(in view: UIView?) -> CGFloat {
        guard !isVisible else { return 0 }
        let width = (view?.window?.screen.bounds ?? UIScreen.main.bounds).width
        return rememberedPaneOverlap(forScreenWidth: width)
            ?? anticipatedInsetInsideSafeArea(for: view)
    }

    /// The bottom safe-area inset, resolved from a **window**.
    ///
    /// The callers that need this are laying out a screen that is still being
    /// pushed, and a view that isn't in the window yet reports 0 for its own
    /// insets. Trusting that silently turns the adjustment above into a no-op —
    /// which is exactly how the daily open kept giving back 34pt (one 27pt step
    /// plus a 7pt glide) the moment the real keyboard landed.
    static func bottomSafeInset(for view: UIView?) -> CGFloat {
        if let window = view?.window { return window.safeAreaInsets.bottom }
        return UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?.safeAreaInsets.bottom ?? 0
    }

    /// Duration + curve of the keyboard animation a notification describes, so
    /// content can be moved in lockstep with it instead of correcting after it.
    static func animation(from note: Notification) -> (duration: TimeInterval, options: UIView.AnimationOptions) {
        let info = note.userInfo
        let duration = (info?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        let curve = (info?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue
            ?? UInt(UIView.AnimationCurve.easeInOut.rawValue)
        return (
            max(duration, 0.01),
            UIView.AnimationOptions(rawValue: curve << 16).union(.beginFromCurrentState)
        )
    }
}

struct NameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let placeholder: String
    let initialText: String
    let validator: ((String) -> String?)?
    let onSave: (String) -> Void
    @State private var text: String
    @State private var error: String?

    init(
        title: String,
        placeholder: String,
        initialText: String = "",
        validator: ((String) -> String?)? = nil,
        onSave: @escaping (String) -> Void
    ) {
        self.title = title
        self.placeholder = placeholder
        self.initialText = initialText
        self.validator = validator
        self.onSave = onSave
        _text = State(initialValue: initialText)
        _error = State(initialValue: validator?(initialText))
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(placeholder, text: $text)
                    .onChange(of: text) { _, value in
                        error = validator?(value)
                    }
                if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("common.save")) {
                        let validationError = validator?(text)
                        error = validationError
                        guard validationError == nil else { return }
                        onSave(text)
                        dismiss()
                    }
                    .disabled(error != nil)
                }
            }
        }
    }
}

struct ArchiveTarget: Identifiable, Equatable {
    enum Kind: String {
        case folder
        case scheme

        var label: String {
            switch self {
            case .folder: L10n.t("sidebar.context.folder")
            case .scheme: L10n.t("mobile.archive.kind_scheme")
            }
        }
    }

    let id: String
    let name: String
    let kind: Kind

    static func folder(_ node: MobileNode) -> ArchiveTarget {
        ArchiveTarget(id: node.id, name: node.name, kind: .folder)
    }

    static func scheme(_ node: MobileNode) -> ArchiveTarget {
        ArchiveTarget(id: node.id, name: node.name, kind: .scheme)
    }

    static func scheme(_ scheme: MobileScheme) -> ArchiveTarget {
        ArchiveTarget(id: scheme.id, name: scheme.displayName, kind: .scheme)
    }

    var title: String {
        L10n.t("mobile.archive.move_title")
    }

    var confirmTitle: String {
        L10n.t("mobile.archive.move_confirm")
    }

    var message: String {
        switch kind {
        case .folder:
            return L10n.t("mobile.archive.move_folder_message", ["name": name])
        case .scheme:
            return L10n.t("mobile.archive.move_scheme_message", ["name": name])
        }
    }
}

struct DestructiveConfirmationTarget: Identifiable, Equatable {
    let id: String
    let title: String
    let message: String
    let confirmTitle: String

    static func permanentlyDeleteScheme(_ scheme: MobileScheme) -> DestructiveConfirmationTarget {
        DestructiveConfirmationTarget(
            id: "permanent-\(scheme.id)",
            title: L10n.t("mobile.archive.delete_permanently_title"),
            message: L10n.t("mobile.archive.delete_scheme_permanently_message", ["name": scheme.displayName]),
            confirmTitle: L10n.t("mobile.archive.delete_permanently_title")
        )
    }

    static func permanentlyDeleteArchivedScheme(name: String, id: String) -> DestructiveConfirmationTarget {
        DestructiveConfirmationTarget(
            id: "permanent-\(id)",
            title: L10n.t("mobile.archive.delete_permanently_title"),
            message: L10n.t("mobile.archive.delete_scheme_permanently_message", ["name": name]),
            confirmTitle: L10n.t("mobile.archive.delete_permanently_title")
        )
    }

    static func permanentlyDeleteArchivedFolder(name: String, id: String) -> DestructiveConfirmationTarget {
        DestructiveConfirmationTarget(
            id: "permanent-folder-\(id)",
            title: L10n.t("mobile.archive.delete_folder_permanently_title"),
            message: L10n.t("mobile.archive.delete_folder_permanently_message", ["name": name]),
            confirmTitle: L10n.t("mobile.archive.delete_permanently_title")
        )
    }

    static func emptyArchive(count: Int) -> DestructiveConfirmationTarget {
        DestructiveConfirmationTarget(
            id: "empty-archive",
            title: L10n.t("archive.empty_confirm_button"),
            message: L10n.plural("mobile.archive.empty_confirm_message", count),
            confirmTitle: L10n.t("archive.empty_confirm_button")
        )
    }
}

extension View {
    func archiveConfirmation(
        target selection: Binding<ArchiveTarget?>,
        onConfirm: @escaping (ArchiveTarget) -> Void
    ) -> some View {
        alert(
            selection.wrappedValue?.title ?? "Archive",
            isPresented: Binding(
                get: { selection.wrappedValue != nil },
                set: { isPresented in
                    if !isPresented {
                        selection.wrappedValue = nil
                    }
                }
            ),
            presenting: selection.wrappedValue
        ) { target in
            Button(target.confirmTitle) {
                onConfirm(target)
                selection.wrappedValue = nil
            }
            Button("Cancel", role: .cancel) {
                selection.wrappedValue = nil
            }
        } message: { target in
            Text(target.message)
        }
    }

    func destructiveConfirmation(
        target selection: Binding<DestructiveConfirmationTarget?>,
        onConfirm: @escaping (DestructiveConfirmationTarget) -> Void
    ) -> some View {
        confirmationDialog(
            selection.wrappedValue?.title ?? "Confirm",
            isPresented: Binding(
                get: { selection.wrappedValue != nil },
                set: { isPresented in
                    if !isPresented {
                        selection.wrappedValue = nil
                    }
                }
            ),
            titleVisibility: .visible,
            presenting: selection.wrappedValue
        ) { target in
            Button(target.confirmTitle, role: .destructive) {
                onConfirm(target)
                selection.wrappedValue = nil
            }
            Button("Cancel", role: .cancel) {
                selection.wrappedValue = nil
            }
        } message: { target in
            Text(target.message)
        }
    }
}

enum WorkspaceNameValidation {
    static func schemeError(_ name: String) -> String? {
        nil
    }

    static func schemeError(_ name: String, root: MobileNode?, folderID: String? = nil, excludingID: String? = nil) -> String? {
        return nil
    }

    static func folderError(_ name: String) -> String? {
        nil
    }

    static func folderError(_ name: String, root: MobileNode?, excludingID: String? = nil) -> String? {
        return nil
    }

    static func parentFolderID(containingSchemeID schemeID: String?, root: MobileNode?) -> String? {
        guard let schemeID, let root else { return nil }
        return parentFolderID(containingSchemeID: schemeID, in: root)
    }

    private static func parentFolderID(containingSchemeID schemeID: String, in node: MobileNode) -> String? {
        for child in node.children {
            if child.kind == "scheme", child.id == schemeID {
                return node.id
            }
            if child.kind == "folder", let found = parentFolderID(containingSchemeID: schemeID, in: child) {
                return found
            }
        }
        return nil
    }
}

