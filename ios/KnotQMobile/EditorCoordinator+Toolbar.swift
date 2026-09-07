import SwiftUI
import UIKit

extension EditorCoordinator {
    // MARK: Toolbar

    func makeToolbar(for textView: UITextView) -> UIView {
        markerButtons.removeAll()
        let width = UIScreen.main.bounds.width
        let accessoryHeight: CGFloat = UIDevice.current.userInterfaceIdiom == .phone ? 58 : 44
        let bottomGap: CGFloat = UIDevice.current.userInterfaceIdiom == .phone ? 14 : 6
        let container = TransparentInputAccessoryView(frame: CGRect(x: 0, y: 0, width: width, height: accessoryHeight))
        container.autoresizingMask = [.flexibleWidth]
        container.backgroundColor = .clear
        container.isOpaque = false
        let dismissPan = UIPanGestureRecognizer(target: self, action: #selector(handleToolbarPan(_:)))
        dismissPan.cancelsTouchesInView = false
        container.addGestureRecognizer(dismissPan)

        // The bar is the only floating surface (it replaces per-button chip
        // backgrounds). Flat rather than a material — see `AccessoryBarPanel`
        // for why a material here breaks the keyboard's first presentation.
        let backdrop = AccessoryBarPanel(theme: theme)
        container.addSubview(backdrop)

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.backgroundColor = .clear
        // With a hardware keyboard the bar docks at the screen bottom, and the
        // automatic inset would add the home-indicator safe area, shifting the
        // icons up inside the bar. Pin them to the bar's own bounds instead.
        scroll.contentInsetAdjustmentBehavior = .never
        backdrop.addSubview(scroll)

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.layoutMargins = UIEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
        stack.isLayoutMarginsRelativeArrangement = true
        // Without this, a docked hardware-keyboard bar adds the bottom safe
        // area to the stack's margins, pushing the icons up inside the bar.
        stack.insetsLayoutMarginsFromSafeArea = false
        scroll.insetsLayoutMarginsFromSafeArea = false
        scroll.addSubview(stack)

        // Dismiss-keyboard is pinned outside the scroll view (see below), so the
        // scrolling part is the desktop format palette with section dividers
        // between functional groups.
        let blank = markerButton(.blank, systemName: "text.alignleft")
        let checkbox = markerButton(.checkbox, systemName: "checkmark.square")
        let bullet = markerButton(.bullet, systemName: "list.bullet")
        let numbered = markerButton(.numbered, systemName: "list.number")
        [
            blank, checkbox, bullet, numbered,
            separator(),
            toolbarButton("decrease.indent") { [weak self] in self?.view?.shiftCurrentIndent(-1, theme: self?.theme ?? .dark) },
            toolbarButton("increase.indent") { [weak self] in self?.view?.shiftCurrentIndent(1, theme: self?.theme ?? .dark) },
            separator(),
            toolbarButton("calendar.badge.clock") { [weak self] in self?.onDateRequested?() },
            separator(),
            toolbarButton("bold") { [weak self] in self?.view?.toggleWrappedMarkdown("**", theme: self?.theme ?? .dark) },
            toolbarButton("italic") { [weak self] in self?.view?.toggleWrappedMarkdown("_", theme: self?.theme ?? .dark) },
            toolbarButton("textformat.size") { [weak self] in self?.view?.toggleHeading(theme: self?.theme ?? .dark) },
            separator(),
            toolbarButton("photo.badge.plus") { [weak self] in
                guard let self else { return }
                self.controller?.prepareImageUploadTarget()
                self.onImageUploadRequested?()
            },
            toolbarButton("tablecells") { [weak self] in
                self?.onInsertTableRequested?()
            },
        ].forEach(stack.addArrangedSubview)

        // Dismiss-keyboard lives OUTSIDE the scroll view, pinned to the trailing
        // edge: it's the one control a user needs to get unstuck, and inside the
        // scroller it both sat where nobody looks for it (iOS puts "done" on the
        // right — Notes, Signal) and could be scrolled off-screen entirely, which
        // is how the bar ends up feeling like a trap with no way to dismiss it.
        let dismiss = toolbarButton("keyboard.chevron.compact.down") { [weak textView] in
            textView?.resignFirstResponder()
        }
        let dismissDivider = separator()
        dismiss.translatesAutoresizingMaskIntoConstraints = false
        dismissDivider.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(dismissDivider)
        backdrop.addSubview(dismiss)

        var constraints: [NSLayoutConstraint] = [
            // Anchored to the bar's BOTTOM with a fixed height, not stretched
            // between the container's top and bottom, so the panel keeps its
            // shape whatever frame UIKit hands the accessory mid-presentation.
            backdrop.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -bottomGap),
            backdrop.heightAnchor.constraint(equalToConstant: accessoryHeight - 4 - bottomGap),
            backdrop.topAnchor.constraint(greaterThanOrEqualTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: dismissDivider.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: backdrop.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),

            dismiss.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -6),
            dismiss.centerYAnchor.constraint(equalTo: backdrop.centerYAnchor),
            dismissDivider.trailingAnchor.constraint(equalTo: dismiss.leadingAnchor, constant: -2),
            dismissDivider.centerYAnchor.constraint(equalTo: backdrop.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
        ]

        if UIDevice.current.userInterfaceIdiom == .pad {
            // iPad: hug the buttons and center the bar, but cap at the available
            // width so it falls back to a full-width scrolling bar (like iPhone)
            // when the buttons would overflow the screen.
            let hugContent = scroll.frameLayoutGuide.widthAnchor.constraint(equalTo: scroll.contentLayoutGuide.widthAnchor)
            hugContent.priority = .defaultHigh
            constraints += [
                backdrop.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                backdrop.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 8),
                backdrop.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -8),
                hugContent
            ]
        } else {
            constraints += [
                backdrop.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
                backdrop.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8)
            ]
        }
        NSLayoutConstraint.activate(constraints)
        return container
    }

    @objc private func handleToolbarPan(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: recognizer.view)
        guard recognizer.state == .ended || recognizer.state == .changed else { return }
        if translation.y > 22, translation.y > abs(translation.x) * 1.25 {
            _ = view?.resignFirstResponder()
        }
    }

    func markerButton(_ marker: Marker, systemName: String) -> UIButton {
        let button = toolbarButton(systemName) { [weak self] in
            guard let self else { return }
            if marker == .bullet, let view = self.view {
                let alert = UIAlertController(title: "Bullet style", message: nil, preferredStyle: .actionSheet)
                [("Standard", "standard"), ("Discs", "discs"), ("Rings", "rings"), ("Squares", "squares"), ("Dashes", "dashes"), ("Alternating", "alternating")].forEach { label, family in
                    alert.addAction(UIAlertAction(title: label, style: .default) { _ in view.setCurrentMarker(.bullet, theme: self.theme, family: family) })
                }
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                view.window?.rootViewController?.present(alert, animated: true)
            } else {
                self.view?.setCurrentMarker(marker, theme: self.theme)
            }
        }
        markerButtons[marker] = button
        return button
    }

    func toolbarButton(_ systemName: String, _ action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: systemName), for: .normal)
        button.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold),
            forImageIn: .normal
        )
        button.tintColor = UIColor(theme.textDim)
        button.backgroundColor = .clear
        button.widthAnchor.constraint(equalToConstant: 38).isActive = true
        button.heightAnchor.constraint(equalToConstant: 34).isActive = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    func separator() -> UIView {
        let view = UIView()
        view.backgroundColor = UIColor(theme.dividerSoft)
        view.widthAnchor.constraint(equalToConstant: 1).isActive = true
        view.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return view
    }
}
