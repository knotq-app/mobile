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

        // Liquid glass background (iOS 26+). Falls back to an ultra-thin
        // material so older OSes still render something readable above the
        // keyboard. The glass replaces per-button chip backgrounds; the bar
        // itself is the only floating surface.
        let backdrop: UIVisualEffectView
        if #available(iOS 26.0, *) {
            backdrop = UIVisualEffectView(effect: UIGlassEffect())
        } else {
            backdrop = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
        }
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.backgroundColor = .clear
        backdrop.isOpaque = false
        backdrop.contentView.backgroundColor = .clear
        backdrop.layer.cornerRadius = 10
        backdrop.layer.cornerCurve = .continuous
        backdrop.clipsToBounds = true
        backdrop.layer.borderWidth = 1
        backdrop.layer.borderColor = UIColor(theme.borderOverlay).cgColor
        container.addSubview(backdrop)

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.backgroundColor = .clear
        // With a hardware keyboard the bar docks at the screen bottom, and the
        // automatic inset would add the home-indicator safe area, shifting the
        // icons up inside the glass. Pin them to the bar's own bounds instead.
        scroll.contentInsetAdjustmentBehavior = .never
        backdrop.contentView.addSubview(scroll)

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.layoutMargins = UIEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
        stack.isLayoutMarginsRelativeArrangement = true
        // Without this, a docked hardware-keyboard bar adds the bottom safe
        // area to the stack's margins, pushing the icons up inside the glass.
        stack.insetsLayoutMarginsFromSafeArea = false
        scroll.insetsLayoutMarginsFromSafeArea = false
        scroll.addSubview(stack)

        // Desktop format-palette order, with dismiss-keyboard as the leftmost
        // glyph and section dividers between functional groups.
        let blank = markerButton(.blank, systemName: "text.alignleft")
        let checkbox = markerButton(.checkbox, systemName: "checkmark.square")
        let bullet = markerButton(.bullet, systemName: "list.bullet")
        let numbered = markerButton(.numbered, systemName: "list.number")
        [
            toolbarButton("keyboard.chevron.compact.down") { [weak textView] in textView?.resignFirstResponder() },
            separator(),
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

        var constraints: [NSLayoutConstraint] = [
            backdrop.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            backdrop.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -bottomGap),
            scroll.leadingAnchor.constraint(equalTo: backdrop.contentView.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: backdrop.contentView.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: backdrop.contentView.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: backdrop.contentView.bottomAnchor),
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
            self.view?.setCurrentMarker(marker, theme: self.theme)
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
