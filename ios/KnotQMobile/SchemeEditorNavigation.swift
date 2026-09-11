import SwiftUI
import UIKit

/// Makes the hosting `UINavigationController`'s bar fully transparent *and*
/// translucent, which is what lets a pane's content extend up underneath it
/// instead of starting below it. Shared by the scheme editor and the daily feed
/// so the two read as the same screen — a daily that keeps the default opaque
/// bar shows a dead strip across the top and clips its first line against it,
/// where the editor's text flows right up past the back button.
///
/// Restores the bar's original appearance on teardown, so screens that *want*
/// a normal bar (settings, archive) are unaffected.
struct TransparentNavigationBar: UIViewControllerRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> HostController {
        let controller = HostController()
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false
        controller.coordinator = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: HostController, context: Context) {
        uiViewController.coordinator = context.coordinator
        context.coordinator.configure(from: uiViewController)
    }

    static func dismantleUIViewController(_ uiViewController: HostController, coordinator: Coordinator) {
        coordinator.restoreIfNeeded()
    }

    final class HostController: UIViewController {
        weak var coordinator: Coordinator?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            coordinator?.configure(from: self)
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.coordinator?.configure(from: self)
            }
        }
    }

    final class Coordinator {
        private weak var navigationBar: UINavigationBar?
        private var standardAppearance: UINavigationBarAppearance?
        private var scrollEdgeAppearance: UINavigationBarAppearance?
        private var compactAppearance: UINavigationBarAppearance?
        private var compactScrollEdgeAppearance: UINavigationBarAppearance?
        private var isTranslucent: Bool?

        @MainActor
        func configure(from controller: UIViewController) {
            guard let navBar = controller.navigationController?.navigationBar else { return }
            if navigationBar !== navBar {
                restoreIfNeeded()
                navigationBar = navBar
                standardAppearance = navBar.standardAppearance
                scrollEdgeAppearance = navBar.scrollEdgeAppearance
                compactAppearance = navBar.compactAppearance
                compactScrollEdgeAppearance = navBar.compactScrollEdgeAppearance
                isTranslucent = navBar.isTranslucent
            }

            let transparent = UINavigationBarAppearance()
            transparent.configureWithTransparentBackground()
            transparent.backgroundColor = .clear
            transparent.backgroundEffect = nil
            transparent.shadowColor = .clear

            navBar.isTranslucent = true
            navBar.standardAppearance = transparent
            navBar.scrollEdgeAppearance = transparent
            navBar.compactAppearance = transparent
            navBar.compactScrollEdgeAppearance = transparent
        }

        @MainActor
        func restoreIfNeeded() {
            guard let navBar = navigationBar else { return }
            if let standardAppearance {
                navBar.standardAppearance = standardAppearance
            }
            navBar.scrollEdgeAppearance = scrollEdgeAppearance
            if let compactAppearance {
                navBar.compactAppearance = compactAppearance
            }
            navBar.compactScrollEdgeAppearance = compactScrollEdgeAppearance
            if let isTranslucent {
                navBar.isTranslucent = isTranslucent
            }
            navigationBar = nil
        }
    }
}

struct SchemeEditorGlassSurface<Content: View>: View {
    let theme: KnotQTheme
    var minWidth: CGFloat?
    var horizontalPadding: CGFloat
    let content: Content

    init(
        theme: KnotQTheme,
        minWidth: CGFloat? = nil,
        horizontalPadding: CGFloat = 0,
        @ViewBuilder content: () -> Content
    ) {
        self.theme = theme
        self.minWidth = minWidth
        self.horizontalPadding = horizontalPadding
        self.content = content()
    }

    var body: some View {
        let shape = Capsule(style: .continuous)
        if #available(iOS 26.0, *), UIDevice.current.userInterfaceIdiom != .pad {
            content
                .padding(.horizontal, horizontalPadding)
                .frame(height: 38)
                .frame(minWidth: minWidth)
                .glassEffect(.regular.tint(glassTint).interactive(), in: shape)
                .overlay {
                    shape.strokeBorder(glassBorder, lineWidth: 0.7)
                }
        } else if UIDevice.current.userInterfaceIdiom == .pad {
            content
                .padding(.horizontal, horizontalPadding)
                .frame(height: 38)
                .frame(minWidth: minWidth)
                .background {
                    shape.fill(padSurface)
                }
                .overlay {
                    shape.strokeBorder(padBorder, lineWidth: 0.7)
                }
        } else {
            content
                .padding(.horizontal, horizontalPadding)
                .frame(height: 38)
                .frame(minWidth: minWidth)
                .background {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(fallbackTint)
                }
                .overlay {
                    shape.strokeBorder(glassBorder, lineWidth: 0.8)
                }
                .shadow(
                    color: .black.opacity(theme.isDark ? 0.24 : 0.08),
                    radius: theme.isDark ? 12 : 5,
                    x: 0,
                    y: theme.isDark ? 5 : 2
                )
        }
    }

    private var glassTint: Color {
        theme.isDark ? Color.white.opacity(0.06) : Color.white.opacity(0.20)
    }

    private var fallbackTint: Color {
        theme.isDark ? Color.white.opacity(0.08) : Color.white.opacity(0.24)
    }

    private var padSurface: Color {
        theme.buttonBg
    }

    private var padBorder: Color {
        theme.isDark ? Color.white.opacity(0.16) : theme.borderOverlay.opacity(0.75)
    }

    private var glassBorder: Color {
        theme.isDark ? Color.white.opacity(0.15) : theme.borderOverlay.opacity(0.72)
    }
}

struct SchemeTopLipIconButton: ButtonStyle {
    let theme: KnotQTheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(theme.textPrimary)
            .frame(width: 38, height: 38)
            // No glass/material fill: a bare, transparent control so the chrome
            // never reads as an opaque lip over the editor. Only a faint press
            // state gives tap feedback.
            .background(
                configuration.isPressed ? theme.rowSelected.opacity(0.5) : Color.clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

struct SchemeToolbarDivider: View {
    let theme: KnotQTheme

    var body: some View {
        Rectangle()
            .fill(theme.dividerSoft)
            .frame(width: 1, height: 20)
    }
}

struct SchemeArchiveButton: View {
    let theme: KnotQTheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "archivebox")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .frame(width: 38, height: 38)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.t("sidebar.context.archive"))
    }
}

struct SchemeColorPickerButton: View {
    @EnvironmentObject private var model: AppModel
    let scheme: MobileScheme
    let theme: KnotQTheme
    let accent: Color
    @State private var showingPicker = false

    private let colorOrder: [Int32] = [0, 1, 5, 2, 3, 4]
    var body: some View {
        Button {
            showingPicker = true
        } label: {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(accent)
                .frame(width: 18, height: 18)
                .overlay {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(theme.borderOverlay, lineWidth: 1)
                }
                .frame(width: 38, height: 38)
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.t("mobile.scheme.color_label"))
        .popover(isPresented: $showingPicker, arrowEdge: .top) {
            SchemeColorPickerPopover(
                scheme: scheme,
                theme: theme,
                colorOrder: colorOrder
            ) { index in
                model.setSchemeColor(id: scheme.id, colorIndex: index)
                showingPicker = false
            }
            .presentationCompactAdaptation(.popover)
            .presentationBackground(theme.bgApp)
            .presentationCornerRadius(12)
        }
    }
}

struct SchemeColorPickerPopover: View {
    let scheme: MobileScheme
    let theme: KnotQTheme
    let colorOrder: [Int32]
    let onSelect: (Int32) -> Void

    private let columns = Array(repeating: GridItem(.fixed(42), spacing: 6), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(colorOrder, id: \.self) { index in
                let selected = index == scheme.colorIndex
                Button {
                    onSelect(index)
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selected ? theme.rowSelected : Color.clear)
                            .frame(width: 42, height: 42)
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(schemeColor(index, dark: theme.isDark))
                            .frame(width: 28, height: 28)
                            .overlay {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(selected ? theme.textPrimary : theme.borderOverlay, lineWidth: selected ? 2 : 0.8)
                            }
                        if selected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(theme.isDark ? Color.black.opacity(0.82) : Color.white)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t("mobile.scheme.color_label"))
            }
        }
        .padding(8)
        .background(theme.bgApp)
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(theme.dividerSoft, lineWidth: 1)
        }
    }
}
