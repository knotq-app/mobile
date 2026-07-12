import SwiftUI
import UIKit

struct SwipeActionRow<Content: View, ActionLabel: View>: View {
    let actionWidth: CGFloat
    let actionTint: Color
    let allowsFullSwipe: Bool
    private let openThreshold: CGFloat = 0.38
    let action: () -> Void
    let actionLabel: () -> ActionLabel
    let content: () -> Content

    @State private var restingOffset: CGFloat = 0
    @GestureState private var dragOffset: CGFloat = 0

    init(
        actionWidth: CGFloat = 88,
        actionTint: Color,
        allowsFullSwipe: Bool = true,
        action: @escaping () -> Void,
        @ViewBuilder actionLabel: @escaping () -> ActionLabel,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.actionWidth = actionWidth
        self.actionTint = actionTint
        self.allowsFullSwipe = allowsFullSwipe
        self.action = action
        self.actionLabel = actionLabel
        self.content = content
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: performAction) {
                actionLabel()
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.white)
                    .labelStyle(.iconOnly)
                    .frame(width: actionWidth)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(actionTint)
            .opacity(currentOffset < -1 ? 1 : 0)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.clear)
                .offset(x: currentOffset)
        }
        .clipped()
        .contentShape(Rectangle())
        .simultaneousGesture(rowDragGesture)
        .animation(.interactiveSpring(response: 0.24, dampingFraction: 0.88, blendDuration: 0.17), value: restingOffset)
    }

    private var currentOffset: CGFloat {
        let raw = restingOffset + dragOffset
        if raw <= -actionWidth {
            // Give a tiny overscroll feel after reveal instead of a hard stop.
            let overdraw = raw + actionWidth
            return -actionWidth + overdraw * 0.28
        }
        return max(-actionWidth * 1.2, min(0, raw))
    }

    private var rowDragGesture: some Gesture {
        DragGesture(minimumDistance: 14, coordinateSpace: .local)
            .updating($dragOffset) { value, state, _ in
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > abs(dy) * 1.25 else { return }
                let raw = restingOffset + dx
                if raw <= -actionWidth {
                    state = -actionWidth + (raw + actionWidth) * 0.28 - restingOffset
                } else {
                    state = dx
                }
            }
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > abs(dy) * 1.25 else { return }
                let projected = restingOffset + value.predictedEndTranslation.width
                let velocity = value.velocity.width
                if allowsFullSwipe && (
                    projected < -actionWidth * 1.35
                    || (velocity < -1100 && projected < -actionWidth * 0.55)
                ) {
                    performAction()
                    return
                }
                withAnimation(.interactiveSpring(response: 0.27, dampingFraction: 0.9, blendDuration: 0.16)) {
                    if projected < -actionWidth * openThreshold {
                        restingOffset = -actionWidth
                    } else {
                        restingOffset = 0
                    }
                }
            }
    }

    private func performAction() {
        withAnimation(.interactiveSpring(response: 0.2, dampingFraction: 0.86, blendDuration: 0.16)) {
            restingOffset = 0
        }
        action()
    }
}

struct HomeGlassSurface: ViewModifier {
    let theme: KnotQTheme
    let cornerRadius: CGFloat
    let shadow: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                ZStack {
                    shape.fill(theme.isDark ? AnyShapeStyle(theme.bgModal.opacity(0.94)) : AnyShapeStyle(theme.bgModal))
                    shape.fill(theme.isDark ? Color.black.opacity(0.08) : Color.clear)
                }
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(theme.isDark ? 0.13 : 0.16),
                            theme.borderOverlay.opacity(theme.isDark ? 0.48 : 0.85)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
            }
            .shadow(color: .black.opacity(shadow ? (theme.isDark ? 0.20 : 0.018) : 0), radius: shadow ? (theme.isDark ? 12 : 4) : 0, x: 0, y: shadow ? (theme.isDark ? 5 : 1) : 0)
    }
}

extension View {
    func homeGlassSurface(theme: KnotQTheme, cornerRadius: CGFloat = 8, shadow: Bool = true) -> some View {
        modifier(HomeGlassSurface(theme: theme, cornerRadius: cornerRadius, shadow: shadow))
    }
}

struct HomeQuickActions: View {
    let theme: KnotQTheme
    let onOpenDaily: () -> Void

    var body: some View {
        glassButton(L10n.t("menu.daily"), "checklist", action: onOpenDaily)
    }

    private func glassButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.accent)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(AnyShapeStyle(theme.buttonBg), in: Capsule())
            .overlay { Capsule().stroke(theme.borderOverlay, lineWidth: 0.7) }
            .shadow(color: .black.opacity(theme.isDark ? 0.20 : 0.035), radius: theme.isDark ? 10 : 5, x: 0, y: theme.isDark ? 4 : 2)
        }
        .buttonStyle(.plain)
    }
}

struct HomeQuickWriteButtons: View {
    let theme: KnotQTheme
    let onNewScheme: () -> Void
    let onOpenDaily: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            quickButton(icon: "checklist", label: L10n.t("menu.daily"), action: onOpenDaily)
            quickButton(icon: "pencil", label: L10n.t("mobile.home.new_scheme"), action: onNewScheme)
        }
    }

    private func quickButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .frame(width: 56, height: 56)
                .background(AnyShapeStyle(theme.bgToolbar), in: Circle())
                .overlay {
                    Circle().strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(theme.isDark ? 0.14 : 0.16),
                                theme.borderOverlay.opacity(theme.isDark ? 0.50 : 0.90)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.9
                    )
                }
                .shadow(color: .black.opacity(theme.isDark ? 0.28 : 0.06), radius: theme.isDark ? 14 : 7, x: 0, y: theme.isDark ? 6 : 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

struct HomeDailyPreview: View {
    let entry: MobileDailyEntry?
    let selectedDate: Date
    let theme: KnotQTheme
    let timeFormat: String
    let onOpenDaily: () -> Void

    var body: some View {
        Button(action: onOpenDaily) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(dailyQueueColor(dark: theme.isDark))
                        .frame(width: 12, height: 12)
                    Text(L10n.t("menu.daily"))
                        .font(.system(size: 15, weight: .semibold))
                    Text(AppModel.displayDate(entry?.date ?? AppModel.dateOnly(selectedDate)))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.textSoft)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(theme.textMuted)
                }

                if previewItems.isEmpty {
                    Text(L10n.t("mobile.home.no_open_daily_items"))
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textMuted)
                        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                } else {
                    HomeDailyPreviewRenderedList(rows: previewRows, theme: theme, timeFormat: timeFormat)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.rowAlt.opacity(theme.isDark ? 0.82 : 0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(theme.borderOverlay.opacity(theme.isDark ? 0.85 : 0.65), lineWidth: 0.7)
            }
        }
        .buttonStyle(.plain)
    }

    private var previewRows: [HomeDailyPreviewRenderedRow] {
        guard let entry else { return [] }
        return previewItems.prefix(3).map { item in
            HomeDailyPreviewRenderedRow(item: item, ordinal: numberedOrdinal(for: item, in: entry.scheme.items))
        }
    }

    private var previewItems: [MobileItem] {
        guard let entry else { return [] }
        return entry.scheme.items.filter { item in
            !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !item.done
        }
    }

    private func numberedOrdinal(for item: MobileItem, in items: [MobileItem]) -> Int {
        guard item.marker == "numbered",
              let index = items.firstIndex(where: { $0.id == item.id }) else { return 1 }
        guard index > items.startIndex else { return 1 }
        let indent = Int(item.indent)
        var ordinal = 1
        var cursor = items.index(before: index)
        while cursor >= items.startIndex {
            let previous = items[cursor]
            let previousIndent = Int(previous.indent)
            if previousIndent > indent {
                if cursor == items.startIndex { break }
                cursor = items.index(before: cursor)
                continue
            }
            if previousIndent < indent || previous.marker != "numbered" {
                break
            }
            ordinal += 1
            if cursor == items.startIndex { break }
            cursor = items.index(before: cursor)
        }
        return ordinal
    }
}

struct HomeDailyPreviewRenderedRow: Identifiable {
    let item: MobileItem
    let ordinal: Int
    var id: String { item.id }
}

struct HomeDailyPreviewRenderedList: UIViewRepresentable {
    let rows: [HomeDailyPreviewRenderedRow]
    let theme: KnotQTheme
    let timeFormat: String

    func makeUIView(context: Context) -> HomeDailyPreviewRendererView {
        let view = HomeDailyPreviewRendererView()
        view.configure(rows: rows, theme: theme, timeFormat: timeFormat)
        return view
    }

    func updateUIView(_ uiView: HomeDailyPreviewRendererView, context: Context) {
        uiView.configure(rows: rows, theme: theme, timeFormat: timeFormat)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: HomeDailyPreviewRendererView, context: Context) -> CGSize? {
        let width = max(1, proposal.width ?? UIScreen.main.bounds.width - 52)
        return CGSize(width: width, height: uiView.height(for: width))
    }
}

final class HomeDailyPreviewRendererView: UIView {
    private enum Metrics {
        static let baseX: CGFloat = 18
        static let markerSlot: CGFloat = 21
        static let indentWidth: CGFloat = 15
        static let checkboxSize: CGFloat = 14
        static let textFontSize: CGFloat = 16
        static let textLineHeight: CGFloat = 22
        static let annotationFontSize: CGFloat = 11
        static let annotationHeight: CGFloat = 14
        static let annotationBarGap: CGFloat = 8
        static let annotationTextGap: CGFloat = 7
        static let indentGuideXShift: CGFloat = 2
        static let rowGap: CGFloat = 2
        static let trailingInset: CGFloat = 2
        static let maxTextLines: CGFloat = 2
    }

    private struct LayoutRow {
        let row: HomeDailyPreviewRenderedRow
        let annotation: String?
        let textHeight: CGFloat
        let rowHeight: CGFloat
        let y: CGFloat
    }

    private var rows: [HomeDailyPreviewRenderedRow] = []
    private var theme: KnotQTheme = .dark
    private var timeFormat = "twelve_hour"

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(rows: [HomeDailyPreviewRenderedRow], theme: KnotQTheme, timeFormat: String) {
        self.rows = rows
        self.theme = theme
        self.timeFormat = timeFormat
        invalidateIntrinsicContentSize()
        setNeedsDisplay()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: height(for: bounds.width > 1 ? bounds.width : UIScreen.main.bounds.width - 52))
    }

    func height(for width: CGFloat) -> CGFloat {
        layoutRows(width: width).last.map { $0.y + $0.rowHeight } ?? 0
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), bounds.width > 1 else { return }
        let layout = layoutRows(width: bounds.width)
        let items = rows.map(\.item)
        for index in layout.indices {
            let row = layout[index]
            let item = row.row.item
            let previous = index > 0 ? items[index - 1] : nil
            let next = index + 1 < items.count ? items[index + 1] : nil
            drawIndentGuides(item: item, previous: previous, next: next, row: row, context: context)
            drawMarker(row.row, y: row.y, context: context)
            drawText(row, width: bounds.width)
            if let annotation = row.annotation {
                let previousAnnotated = index > 0 && layout[index - 1].annotation != nil
                let nextAnnotated = index + 1 < layout.count && layout[index + 1].annotation != nil
                drawAnnotationBar(item: item, row: row, connectsToPrevious: previousAnnotated, connectsToNext: nextAnnotated, context: context)
                drawAnnotation(annotation, item: item, row: row)
            }
        }
    }

    private func layoutRows(width: CGFloat) -> [LayoutRow] {
        var result: [LayoutRow] = []
        var y: CGFloat = 0
        for row in rows {
            let annotation = annotationText(for: row.item)
            let measured = textHeight(for: row.item, width: width)
            let rowHeight = measured + (annotation == nil ? 0 : Metrics.annotationHeight)
            result.append(LayoutRow(row: row, annotation: annotation, textHeight: measured, rowHeight: rowHeight, y: y))
            y += rowHeight + Metrics.rowGap
        }
        return result
    }

    private func textHeight(for item: MobileItem, width: CGFloat) -> CGFloat {
        let availableWidth = max(1, width - Metrics.trailingInset)
        let bounds = displayAttributedText(for: item).boundingRect(
            with: CGSize(width: availableWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        let lines = min(Metrics.maxTextLines, max(1, ceil(bounds.height / Metrics.textLineHeight)))
        return lines * Metrics.textLineHeight
    }

    private func textAttributes(for item: MobileItem) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        let indent = CGFloat(item.indent) * Metrics.indentWidth + Metrics.baseX
        let markerOffset = item.marker == "blank" ? CGFloat(0) : Metrics.markerSlot
        paragraph.firstLineHeadIndent = indent + markerOffset
        paragraph.headIndent = indent
        paragraph.minimumLineHeight = Metrics.textLineHeight
        paragraph.maximumLineHeight = Metrics.textLineHeight
        paragraph.lineBreakMode = .byTruncatingTail
        var attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: Metrics.textFontSize),
            .foregroundColor: UIColor(item.done ? theme.textMuted : theme.textPrimary),
            .paragraphStyle: paragraph
        ]
        if item.done {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        return attrs
    }

    /// The item body styled like the editor's collapsed (no-caret) preview:
    /// `**bold**`/`*italic*`/`==highlight==` rendered, with the markers removed.
    private func displayAttributedText(for item: MobileItem) -> NSAttributedString {
        let text = item.text.isEmpty ? item.kind.capitalized : item.text
        let result = NSMutableAttributedString(string: text, attributes: textAttributes(for: item))
        applyInlineMarkdownStyling(
            body: text,
            bodyRange: NSRange(location: 0, length: (text as NSString).length),
            in: result,
            enlargeHeadings: false
        )
        var markers: [NSRange] = []
        result.enumerateAttribute(.knotqMarker, in: NSRange(location: 0, length: result.length)) { value, range, _ in
            if value != nil { markers.append(range) }
        }
        // Delete from the back so earlier ranges keep their offsets.
        for range in markers.sorted(by: { $0.location > $1.location }) {
            result.deleteCharacters(in: range)
        }
        return result
    }

    private func drawText(_ row: LayoutRow, width: CGFloat) {
        let rect = CGRect(x: 0, y: row.y, width: max(1, width - Metrics.trailingInset), height: row.textHeight)
        displayAttributedText(for: row.row.item).draw(
            with: rect,
            options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine],
            context: nil
        )
    }

    private func drawIndentGuides(item: MobileItem, previous: MobileItem?, next: MobileItem?, row: LayoutRow, context: CGContext) {
        let indent = min(Int(item.indent), 8)
        guard indent > 0 else { return }
        context.setFillColor(UIColor(theme.dividerSoft).cgColor)
        let marker = markerRect(for: item, y: row.y)
        let ownBarX = marker.minX - (Metrics.annotationBarGap + Metrics.indentGuideXShift)
        let guideMargin: CGFloat = 3
        for guideIndent in 1...indent {
            let previousHasGuide = min(Int(previous?.indent ?? 0), 8) >= guideIndent
            let nextHasGuide = min(Int(next?.indent ?? 0), 8) >= guideIndent
            let topMargin = previousHasGuide ? CGFloat(0) : guideMargin
            let bottomMargin = nextHasGuide ? CGFloat(0) : guideMargin
            let levelOffset = CGFloat(indent - guideIndent) * Metrics.indentWidth
            context.fill(CGRect(
                x: ownBarX - levelOffset,
                y: row.y + topMargin,
                width: 1,
                height: max(1, row.rowHeight - topMargin - bottomMargin)
            ))
        }
    }

    private func drawMarker(_ row: HomeDailyPreviewRenderedRow, y: CGFloat, context: CGContext) {
        let item = row.item
        let rect = markerRect(for: item, y: y)
        let chrome = chromeColor
        switch item.marker {
        case "bullet":
            context.setFillColor(chrome.cgColor)
            context.fillEllipse(in: rect.insetBy(dx: 4.5, dy: 4.5))
        case "numbered":
            let label = "\(row.ordinal)." as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: chrome
            ]
            let size = label.size(withAttributes: attrs)
            label.draw(at: CGPoint(x: rect.maxX - size.width, y: rect.minY + (rect.height - size.height) / 2), withAttributes: attrs)
        case "checkbox":
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 3)
            (item.done ? chrome : UIColor(theme.buttonBg)).setFill()
            path.fill()
            chrome.setStroke()
            path.lineWidth = 1
            path.stroke()
            if item.done {
                let check = UIBezierPath()
                check.move(to: CGPoint(x: rect.minX + 3.2, y: rect.minY + 7.2))
                check.addLine(to: CGPoint(x: rect.minX + 5.8, y: rect.minY + 9.7))
                check.addLine(to: CGPoint(x: rect.maxX - 3.0, y: rect.minY + 4.3))
                UIColor(theme.bgApp).setStroke()
                check.lineWidth = 1.8
                check.stroke()
            }
        default:
            return
        }
    }

    private func drawAnnotationBar(item: MobileItem, row: LayoutRow, connectsToPrevious: Bool, connectsToNext: Bool, context: CGContext) {
        let marker = markerRect(for: item, y: row.y)
        let x = annotationGuideX(marker: marker)
        let top = connectsToPrevious ? row.y : marker.minY
        let bottom = row.y + row.rowHeight - (connectsToNext ? 0 : 3)
        context.setFillColor(chromeColor.cgColor)
        context.fill(CGRect(x: x, y: top, width: 1, height: max(1, bottom - top)))
    }

    private func drawAnnotation(_ annotation: String, item: MobileItem, row: LayoutRow) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: Metrics.annotationFontSize, weight: .medium),
            .foregroundColor: chromeColor
        ]
        let marker = markerRect(for: item, y: row.y)
        let x = annotationGuideX(marker: marker) + Metrics.annotationTextGap
        let y = row.y + row.textHeight - 1
        (annotation as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attrs)
    }

    private func markerRect(for item: MobileItem, y: CGFloat) -> CGRect {
        CGRect(
            x: Metrics.baseX + CGFloat(item.indent) * Metrics.indentWidth,
            y: y + (Metrics.textLineHeight - Metrics.checkboxSize) / 2,
            width: Metrics.checkboxSize,
            height: Metrics.checkboxSize
        )
    }

    private func annotationGuideX(marker: CGRect) -> CGFloat {
        marker.minX - (Metrics.annotationBarGap + Metrics.indentGuideXShift)
    }

    private func annotationText(for item: MobileItem) -> String? {
        MobileDate.annotationText(start: item.start, end: item.end, timeFormat: timeFormat)
    }

    private var chromeColor: UIColor {
        UIColor(theme.isDark ? Color(hex: 0xb8c9e8) : Color(hex: 0x536a8f))
    }
}

