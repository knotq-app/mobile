import SwiftUI
import UIKit

struct UpcomingSection: View {
    let title: String
    let empty: String
    let occurrences: [MobileOccurrence]
    let theme: KnotQTheme
    let timeFormat: String
    let onToggleOccurrence: (MobileOccurrence) -> Void
    let onOpenOccurrence: (MobileOccurrence) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.textDim)
                .padding(.horizontal, 4)
            if occurrences.isEmpty {
                Text(empty)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            } else {
                ForEach(Array(occurrences.enumerated()), id: \.element.id) { idx, occurrence in
                    OccurrenceCompactRow(
                        occurrence: occurrence,
                        theme: theme,
                        timeFormat: timeFormat,
                        striped: idx % 2 == 1,
                        moreAction: { onOpenOccurrence(occurrence) }
                    ) {
                        onToggleOccurrence(occurrence)
                    }
                }
            }
        }
    }
}

struct OccurrenceCompactRow: View {
    let occurrence: MobileOccurrence
    let theme: KnotQTheme
    let timeFormat: String
    let striped: Bool
    let moreAction: (() -> Void)?
    let action: () -> Void
    let showDayLabel: Bool
    let longPressDuration: Double

    init(
        occurrence: MobileOccurrence,
        theme: KnotQTheme,
        timeFormat: String,
        striped: Bool,
        showDayLabel: Bool = false,
        longPressDuration: Double = 0.25,
        moreAction: (() -> Void)? = nil,
        action: @escaping () -> Void
    ) {
        self.occurrence = occurrence
        self.theme = theme
        self.timeFormat = timeFormat
        self.striped = striped
        self.moreAction = moreAction
        self.action = action
        self.showDayLabel = showDayLabel
        self.longPressDuration = longPressDuration
    }

    var body: some View {
        interactiveRow
            .opacity(occurrence.done ? 0.45 : 1)
    }

    @ViewBuilder
    private var interactiveRow: some View {
        if let moreAction {
            baseRow
                .overlay {
                    FastPressGestureOverlay(
                        longPressDuration: longPressDuration,
                        allowableMovement: 18,
                        tapAction: action,
                        longPressAction: {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            moreAction()
                        }
                    )
                }
        } else {
            baseRow
                .onTapGesture {
                    action()
                }
        }
    }

    private var baseRow: some View {
        rowContent
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }

    private var rowContent: some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(occurrenceSchemeColor(occurrence, dark: theme.isDark))
                .frame(width: 1.5)
                .padding(.vertical, 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(occurrence.schemeName)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(occurrenceSchemeColor(occurrence, dark: theme.isDark))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(MobileDate.occurrenceLabel(occurrence, timeFormat: timeFormat, showDay: showDayLabel))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(occurrenceStatusTimeColor(occurrence, theme: theme))
                        .lineLimit(1)
                }
                Text(occurrence.title.isEmpty ? occurrence.kind.capitalized : occurrence.title)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(2)
                    .strikethrough(occurrence.done)
            }
            .padding(.vertical, 7)
            .padding(.trailing, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(striped ? theme.rowAlt : Color.clear, in: RoundedRectangle(cornerRadius: 3))
    }
}

private struct FastPressGestureOverlay: UIViewRepresentable {
    let longPressDuration: TimeInterval
    let allowableMovement: CGFloat
    let tapAction: () -> Void
    let longPressAction: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(tapAction: tapAction, longPressAction: longPressAction)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear

        let longPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = longPressDuration
        longPress.allowableMovement = allowableMovement
        longPress.cancelsTouchesInView = false
        longPress.delaysTouchesBegan = false
        longPress.delaysTouchesEnded = false
        longPress.delegate = context.coordinator

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.delegate = context.coordinator
        tap.require(toFail: longPress)

        view.addGestureRecognizer(longPress)
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.tapAction = tapAction
        context.coordinator.longPressAction = longPressAction

        for recognizer in view.gestureRecognizers ?? [] {
            if let longPress = recognizer as? UILongPressGestureRecognizer {
                longPress.minimumPressDuration = longPressDuration
                longPress.allowableMovement = allowableMovement
            }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var tapAction: () -> Void
        var longPressAction: () -> Void

        init(tapAction: @escaping () -> Void, longPressAction: @escaping () -> Void) {
            self.tapAction = tapAction
            self.longPressAction = longPressAction
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            tapAction()
        }

        @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began else { return }
            longPressAction()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            otherGestureRecognizer is UIPanGestureRecognizer
        }
    }
}
