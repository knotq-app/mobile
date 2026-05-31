import SwiftUI
import UIKit

struct SchemeNavigatorListView: UIViewRepresentable {
    @EnvironmentObject private var model: AppModel
    let root: MobileNode?
    let selectedSchemeID: String?
    let theme: KnotQTheme
    let compact: Bool
    let onOpenScheme: (String) -> Void

    func makeUIView(context: Context) -> SchemeNavigatorUIKitView {
        SchemeNavigatorUIKitView()
    }

    func updateUIView(_ uiView: SchemeNavigatorUIKitView, context: Context) {
        uiView.configure(
            root: root,
            selectedSchemeID: selectedSchemeID,
            theme: theme,
            compact: compact,
            onOpenScheme: onOpenScheme,
            onMoveNode: { kind, id, folderID, position in
                model.moveNode(kind: kind, id: id, folderID: folderID, position: position)
            },
            onArchiveScheme: { id in
                model.archiveScheme(id: id)
            },
            onArchiveFolder: { id in
                model.archiveFolder(id: id)
            }
        )
    }
}

/// The blue insertion indicator drawn between rows during a navigator drag —
/// a leading dot plus a horizontal line, mirroring the desktop sidebar.
private final class NavigatorDropLine: UIView {
    private let line = UIView()
    private let dot = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        addSubview(line)
        addSubview(dot)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setColor(_ color: UIColor) {
        line.backgroundColor = color
        dot.backgroundColor = color
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let lineHeight: CGFloat = 2
        let dotDiameter: CGFloat = 6
        dot.frame = CGRect(x: 0, y: (bounds.height - dotDiameter) / 2, width: dotDiameter, height: dotDiameter)
        dot.layer.cornerRadius = dotDiameter / 2
        let lineX = dotDiameter - 1
        line.frame = CGRect(x: lineX, y: (bounds.height - lineHeight) / 2, width: max(0, bounds.width - lineX), height: lineHeight)
        line.layer.cornerRadius = lineHeight / 2
    }
}

final class SchemeNavigatorUIKitView: UIView, UITableViewDataSource, UITableViewDelegate {
    private struct Row: Equatable {
        let node: MobileNode
        let depth: Int
        let parentID: String
        let siblingIndex: Int

        var id: String { node.id }
    }

    private struct Placement {
        let folderID: String
        let position: Int
    }

    /// Where the indicator is drawn for a candidate drop: a line at a vertical
    /// position/indent, or a whole-folder highlight when dropping into a folder.
    private enum DropVisual {
        case line(y: CGFloat, depth: Int)
        case into(rowIndex: Int)
    }

    private struct DropTarget {
        let placement: Placement
        let visual: DropVisual
    }

    /// Live state for an in-progress long-press drag. The list itself never
    /// reorders mid-drag; only this floating preview and the indicator move.
    private final class DragSession {
        let id: String
        let node: MobileNode
        let preview: UIView
        let originFrame: CGRect
        let grabOffsetY: CGFloat
        let anchorX: CGFloat
        var target: DropTarget?

        init(id: String, node: MobileNode, preview: UIView, originFrame: CGRect, grabOffsetY: CGFloat, anchorX: CGFloat) {
            self.id = id
            self.node = node
            self.preview = preview
            self.originFrame = originFrame
            self.grabOffsetY = grabOffsetY
            self.anchorX = anchorX
        }
    }

    private let tableView = UITableView(frame: .zero, style: .plain)
    private var root: MobileNode?
    private var rows: [Row] = []
    private var expandedFolderIDs = Set<String>()
    private var knownFolderIDs = Set<String>()
    private var selectedSchemeID: String?
    private var theme: KnotQTheme = .dark
    private var compact = false
    private var onOpenScheme: (String) -> Void = { _ in }
    private var onMoveNode: (String, String, String, Int) -> Void = { _, _, _, _ in }
    private var onArchiveScheme: (String) -> Void = { _ in }
    private var onArchiveFolder: (String) -> Void = { _ in }

    private let dropLine = NavigatorDropLine()
    private let folderHighlight = UIView()
    private var dragSession: DragSession?
    private var autoScrollLink: CADisplayLink?
    private var autoScrollVelocity: CGFloat = 0
    private var lastTouchInSelf: CGPoint = .zero

    private var rowHeight: CGFloat { compact ? 27 : 34 }
    private var navLeftInset: CGFloat { compact ? 6 : 20 }
    private var navRightInset: CGFloat { compact ? 6 : 8 }
    private var indentUnit: CGFloat { compact ? 12 : 14 }

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(tableView)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(SchemeNavigatorCell.self, forCellReuseIdentifier: SchemeNavigatorCell.reuseIdentifier)
        tableView.separatorStyle = .none
        tableView.backgroundColor = .clear
        tableView.showsVerticalScrollIndicator = false
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.keyboardDismissMode = .none
        tableView.alwaysBounceVertical = true
        tableView.delaysContentTouches = false

        dropLine.isHidden = true
        tableView.addSubview(dropLine)
        folderHighlight.isHidden = true
        folderHighlight.isUserInteractionEnabled = false
        folderHighlight.layer.cornerRadius = 5
        folderHighlight.layer.cornerCurve = .continuous
        folderHighlight.layer.borderWidth = 1.5
        tableView.addSubview(folderHighlight)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.3
        tableView.addGestureRecognizer(longPress)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        tableView.frame = bounds
    }

    func configure(
        root: MobileNode?,
        selectedSchemeID: String?,
        theme: KnotQTheme,
        compact: Bool,
        onOpenScheme: @escaping (String) -> Void,
        onMoveNode: @escaping (String, String, String, Int) -> Void,
        onArchiveScheme: @escaping (String) -> Void,
        onArchiveFolder: @escaping (String) -> Void
    ) {
        self.onOpenScheme = onOpenScheme
        self.onMoveNode = onMoveNode
        self.onArchiveScheme = onArchiveScheme
        self.onArchiveFolder = onArchiveFolder
        // Never reshuffle the list out from under an in-progress drag; the
        // reorder applied on release will refresh it.
        if dragSession != nil { return }
        let styleChanged = self.selectedSchemeID != selectedSchemeID || self.compact != compact || self.theme.isDark != theme.isDark
        tableView.contentInset = UIEdgeInsets(top: compact ? 1 : 4, left: 0, bottom: compact ? 4 : 5, right: 0)
        tableView.backgroundColor = .clear
        syncExpandedFolders(root)
        let nextRows = makeRows(root: root)
        let rowsChanged = rows != nextRows
        self.root = root
        self.selectedSchemeID = selectedSchemeID
        self.theme = theme
        self.compact = compact
        rows = nextRows
        if rowsChanged || styleChanged {
            tableView.reloadData()
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        rowHeight
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: SchemeNavigatorCell.reuseIdentifier, for: indexPath) as? SchemeNavigatorCell
            ?? SchemeNavigatorCell(style: .default, reuseIdentifier: SchemeNavigatorCell.reuseIdentifier)
        let row = rows[indexPath.row]
        cell.configure(
            row: row.node,
            depth: row.depth,
            expanded: expandedFolderIDs.contains(row.id),
            selected: selectedSchemeID == row.id,
            theme: theme,
            compact: compact
        )
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let row = rows[indexPath.row]
        if row.node.kind == "folder" {
            toggleFolder(row.id)
        } else {
            onOpenScheme(row.id)
        }
    }

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        true
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        let row = rows[indexPath.row]
        let action = UIContextualAction(style: .normal, title: "Archive") { [weak self] _, _, completion in
            guard let self else {
                completion(false)
                return
            }
            if row.node.kind == "folder" {
                self.onArchiveFolder(row.id)
            } else {
                self.onArchiveScheme(row.id)
            }
            completion(true)
        }
        action.image = UIImage(systemName: "archivebox")
        action.backgroundColor = UIColor(theme.danger)
        let configuration = UISwipeActionsConfiguration(actions: [action])
        configuration.performsFirstActionWithFullSwipe = true
        return configuration
    }

    // MARK: - Long-press drag

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            beginDrag(recognizer)
        case .changed:
            updateDrag(recognizer)
        case .ended:
            let location = recognizer.location(in: tableView)
            finishDrag(commit: dropTarget(at: location) ?? dragSession?.target)
        case .cancelled, .failed:
            finishDrag(commit: nil)
        default:
            break
        }
    }

    private func beginDrag(_ recognizer: UILongPressGestureRecognizer) {
        guard dragSession == nil else { return }
        let locationInTable = recognizer.location(in: tableView)
        let locationInSelf = recognizer.location(in: self)
        guard let indexPath = tableView.indexPathForRow(at: locationInTable),
              rows.indices.contains(indexPath.row),
              let cell = tableView.cellForRow(at: indexPath) as? SchemeNavigatorCell else {
            return
        }
        let row = rows[indexPath.row]
        let frameInSelf = tableView.convert(cell.frame, to: self)

        let preview = UIView(frame: frameInSelf)
        preview.backgroundColor = UIColor(theme.bgModal)
        preview.layer.cornerRadius = 7
        preview.layer.cornerCurve = .continuous
        preview.layer.borderWidth = 1
        preview.layer.borderColor = UIColor(theme.borderOverlay).cgColor
        preview.layer.shadowColor = UIColor.black.cgColor
        preview.layer.shadowOpacity = theme.isDark ? 0.45 : 0.2
        preview.layer.shadowRadius = 10
        preview.layer.shadowOffset = CGSize(width: 0, height: 5)
        if let snapshot = cell.snapshotView(afterScreenUpdates: false) {
            snapshot.frame = preview.bounds
            preview.addSubview(snapshot)
        }
        addSubview(preview)
        cell.contentView.alpha = 0.25

        let session = DragSession(
            id: row.id,
            node: row.node,
            preview: preview,
            originFrame: frameInSelf,
            grabOffsetY: locationInSelf.y - frameInSelf.midY,
            anchorX: frameInSelf.midX
        )
        dragSession = session
        tableView.isScrollEnabled = false
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        UIView.animate(withDuration: 0.16) {
            preview.transform = CGAffineTransform(scaleX: 0.82, y: 0.82)
            preview.alpha = 0.72
        }

        let target = dropTarget(at: locationInTable)
        session.target = target
        updateIndicator(target)
    }

    private func updateDrag(_ recognizer: UILongPressGestureRecognizer) {
        guard let session = dragSession else { return }
        let locationInSelf = recognizer.location(in: self)
        let locationInTable = recognizer.location(in: tableView)
        session.preview.center = CGPoint(x: session.anchorX, y: locationInSelf.y - session.grabOffsetY)
        let target = dropTarget(at: locationInTable)
        session.target = target
        updateIndicator(target)
        updateAutoScroll(locationInSelf: locationInSelf)
    }

    private func finishDrag(commit target: DropTarget?) {
        let session = dragSession
        dragSession = nil
        stopAutoScroll()
        hideIndicators()
        tableView.isScrollEnabled = true
        for case let cell as SchemeNavigatorCell in tableView.visibleCells {
            cell.contentView.alpha = 1
        }

        guard let session else { return }
        if let target, let root, let node = findNode(id: session.id, in: root) {
            UIView.animate(withDuration: 0.16, animations: {
                session.preview.alpha = 0
                session.preview.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
            }, completion: { _ in session.preview.removeFromSuperview() })
            // Dropping into a collapsed folder won't reveal the moved node
            // unless we expand it locally before the model refresh lands.
            if case .into(let rowIndex) = target.visual, rows.indices.contains(rowIndex) {
                expandedFolderIDs.insert(rows[rowIndex].id)
            }
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            onMoveNode(
                node.kind == "folder" ? "folder" : "scheme",
                session.id,
                target.placement.folderID,
                target.placement.position
            )
        } else {
            UIView.animate(withDuration: 0.2, animations: {
                session.preview.frame = session.originFrame
                session.preview.transform = .identity
                session.preview.alpha = 1
            }, completion: { _ in session.preview.removeFromSuperview() })
        }
    }

    // MARK: - Auto-scroll

    private func updateAutoScroll(locationInSelf: CGPoint) {
        lastTouchInSelf = locationInSelf
        let edge: CGFloat = 52
        let height = bounds.height
        var fraction: CGFloat = 0
        if locationInSelf.y < edge {
            fraction = -(edge - locationInSelf.y) / edge
        } else if locationInSelf.y > height - edge {
            fraction = (locationInSelf.y - (height - edge)) / edge
        }
        autoScrollVelocity = max(-1, min(1, fraction)) * 14
        if autoScrollVelocity == 0 {
            stopAutoScroll()
        } else if autoScrollLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(stepAutoScroll))
            link.add(to: .main, forMode: .common)
            autoScrollLink = link
        }
    }

    @objc private func stepAutoScroll() {
        guard dragSession != nil else { stopAutoScroll(); return }
        let minOffset = -tableView.adjustedContentInset.top
        let maxOffset = max(minOffset, tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom)
        let newY = min(max(tableView.contentOffset.y + autoScrollVelocity, minOffset), maxOffset)
        guard newY != tableView.contentOffset.y else { return }
        tableView.contentOffset.y = newY
        let locationInTable = convert(lastTouchInSelf, to: tableView)
        let target = dropTarget(at: locationInTable)
        dragSession?.target = target
        updateIndicator(target)
    }

    private func stopAutoScroll() {
        autoScrollLink?.invalidate()
        autoScrollLink = nil
        autoScrollVelocity = 0
    }

    // MARK: - Drop targeting

    private func dropTarget(at location: CGPoint) -> DropTarget? {
        guard let session = dragSession,
              let root,
              let draggedNode = findNode(id: session.id, in: root),
              let source = findChildPlacement(childID: session.id, in: root),
              let raw = rawDrop(at: location, root: root),
              let placement = adjustedPlacement(
                source: source,
                draggedNode: draggedNode,
                folderID: raw.folderID,
                position: raw.position
              ) else {
            return nil
        }
        return DropTarget(placement: placement, visual: raw.visual)
    }

    private func rawDrop(at location: CGPoint, root: MobileNode) -> (folderID: String, position: Int, visual: DropVisual)? {
        guard let indexPath = tableView.indexPathForRow(at: location), rows.indices.contains(indexPath.row) else {
            return (root.id, root.children.count, .line(y: contentBottomY(), depth: 0))
        }
        let row = rows[indexPath.row]
        let frame = tableView.rectForRow(at: indexPath)
        let fraction = frame.height > 0 ? (location.y - frame.minY) / frame.height : 0.5
        let isFolder = row.node.kind == "folder"

        if isFolder, fraction > 0.32, fraction < 0.68 {
            return (row.id, row.node.children.count, .into(rowIndex: indexPath.row))
        }

        let after = fraction >= 0.5
        if after, isFolder, expandedFolderIDs.contains(row.id) {
            // The visible gap below an expanded folder header is its first child.
            return (row.id, 0, .line(y: frame.maxY, depth: row.depth + 1))
        }
        let position = row.siblingIndex + (after ? 1 : 0)
        let lineY = after ? frame.maxY : frame.minY
        return (row.parentID, position, .line(y: lineY, depth: row.depth))
    }

    private func contentBottomY() -> CGFloat {
        guard !rows.isEmpty else { return 0 }
        return tableView.rectForRow(at: IndexPath(row: rows.count - 1, section: 0)).maxY
    }

    private func updateIndicator(_ target: DropTarget?) {
        guard let target else {
            hideIndicators()
            return
        }
        let accent = UIColor(theme.accent)
        switch target.visual {
        case .line(let y, let depth):
            folderHighlight.isHidden = true
            let indent = navLeftInset + CGFloat(max(0, depth)) * indentUnit
            let width = max(0, tableView.bounds.width - navRightInset - indent)
            dropLine.frame = CGRect(x: indent, y: y - 6, width: width, height: 12)
            dropLine.setColor(accent)
            dropLine.isHidden = false
            dropLine.setNeedsLayout()
            tableView.bringSubviewToFront(dropLine)
        case .into(let rowIndex):
            dropLine.isHidden = true
            guard rows.indices.contains(rowIndex) else {
                folderHighlight.isHidden = true
                return
            }
            let rect = tableView.rectForRow(at: IndexPath(row: rowIndex, section: 0))
            folderHighlight.frame = CGRect(x: 3, y: rect.minY + 2, width: tableView.bounds.width - 6, height: rect.height - 4)
            folderHighlight.layer.borderColor = accent.cgColor
            folderHighlight.backgroundColor = accent.withAlphaComponent(0.14)
            folderHighlight.isHidden = false
            tableView.bringSubviewToFront(folderHighlight)
        }
    }

    private func hideIndicators() {
        dropLine.isHidden = true
        folderHighlight.isHidden = true
    }

    private func toggleFolder(_ id: String) {
        if expandedFolderIDs.contains(id) {
            expandedFolderIDs.remove(id)
        } else {
            expandedFolderIDs.insert(id)
        }
        rows = makeRows(root: root)
        tableView.reloadData()
    }

    private func makeRows(root: MobileNode?) -> [Row] {
        guard let root else { return [] }
        var next: [Row] = []
        appendRows(root.children, parentID: root.id, depth: 0, into: &next)
        return next
    }

    private func appendRows(_ nodes: [MobileNode], parentID: String, depth: Int, into rows: inout [Row]) {
        for (index, node) in nodes.enumerated() {
            rows.append(Row(node: node, depth: depth, parentID: parentID, siblingIndex: index))
            if node.kind == "folder", expandedFolderIDs.contains(node.id) {
                appendRows(node.children, parentID: node.id, depth: depth + 1, into: &rows)
            }
        }
    }

    private func syncExpandedFolders(_ root: MobileNode?) {
        var folderIDs = Set<String>()
        if let root {
            collectFolderIDs(from: root.children, into: &folderIDs)
        }
        if knownFolderIDs.isEmpty {
            expandedFolderIDs = folderIDs
        } else {
            expandedFolderIDs = expandedFolderIDs.intersection(folderIDs)
            expandedFolderIDs.formUnion(folderIDs.subtracting(knownFolderIDs))
        }
        knownFolderIDs = folderIDs
    }

    private func collectFolderIDs(from nodes: [MobileNode], into folderIDs: inout Set<String>) {
        for node in nodes where node.kind == "folder" {
            folderIDs.insert(node.id)
            collectFolderIDs(from: node.children, into: &folderIDs)
        }
    }

    /// Resolves a raw sibling slot into a concrete `Placement`, accounting for
    /// the node first being removed from its current parent, and rejecting
    /// no-op or illegal (folder-into-itself) moves.
    private func adjustedPlacement(
        source: (parentID: String, position: Int),
        draggedNode: MobileNode,
        folderID: String,
        position: Int
    ) -> Placement? {
        guard let root,
              let targetParent = findNode(id: folderID, in: root) else {
            return nil
        }
        if draggedNode.kind == "folder" {
            guard folderID != draggedNode.id && !containsNode(folderID, within: draggedNode) else {
                return nil
            }
        }

        let sameParent = source.parentID == folderID
        var adjustedPosition = position
        if sameParent, source.position < position {
            adjustedPosition = max(0, adjustedPosition - 1)
        }
        let targetCount = targetParent.children.count - (sameParent ? 1 : 0)
        adjustedPosition = max(0, min(adjustedPosition, max(0, targetCount)))
        if sameParent, adjustedPosition == source.position {
            return nil
        }
        return Placement(folderID: folderID, position: adjustedPosition)
    }
}

private final class SchemeNavigatorCell: UITableViewCell {
    static let reuseIdentifier = "SchemeNavigatorCell"

    private let selectedFill = UIView()
    private let iconView = UIImageView()
    private let colorSquare = UIView()
    private let titleLabel = UILabel()
    private let chevronView = UIImageView(image: UIImage(systemName: "chevron.right"))
    private var depth = 0
    private var compact = false
    private var nodeKind = "scheme"

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none
        selectedFill.layer.cornerRadius = 4
        selectedFill.layer.cornerCurve = .continuous
        contentView.addSubview(selectedFill)
        contentView.addSubview(iconView)
        contentView.addSubview(colorSquare)
        contentView.addSubview(titleLabel)
        contentView.addSubview(chevronView)
        colorSquare.layer.cornerRadius = 3
        colorSquare.layer.cornerCurve = .continuous
        titleLabel.lineBreakMode = .byTruncatingTail
        chevronView.contentMode = .scaleAspectFit
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        row node: MobileNode,
        depth: Int,
        expanded: Bool,
        selected: Bool,
        theme: KnotQTheme,
        compact: Bool
    ) {
        self.depth = depth
        self.compact = compact
        self.nodeKind = node.kind

        selectedFill.backgroundColor = selected ? UIColor(theme.rowSelected) : .clear
        titleLabel.text = node.name
        titleLabel.textColor = UIColor(theme.textPrimary)
        titleLabel.font = .systemFont(ofSize: compact ? 13 : 14, weight: node.kind == "folder" ? .semibold : .medium)
        chevronView.tintColor = UIColor(theme.textMuted)
        chevronView.isHidden = node.kind == "folder"

        if node.kind == "folder" {
            iconView.isHidden = false
            colorSquare.isHidden = true
            let config = UIImage.SymbolConfiguration(pointSize: compact ? 12 : 14, weight: .semibold)
            iconView.image = UIImage(systemName: expanded ? "folder" : "folder.fill", withConfiguration: config)
            iconView.tintColor = UIColor(theme.textMuted)
        } else {
            iconView.isHidden = true
            colorSquare.isHidden = false
            colorSquare.backgroundColor = UIColor(schemeColor(node.colorIndex ?? 0, dark: theme.isDark))
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Non-compact (Home) rows align with the "Daily" row beneath the list:
        // 4 (card padding) + 8 (row padding) + 8 (icon gap) = 20.
        let leftInset: CGFloat = compact ? 6 : 20
        let rightInset: CGFloat = compact ? 6 : 8
        let indent = CGFloat(max(0, depth)) * (compact ? 12 : 14)
        let iconSize: CGFloat = compact ? 14 : 17
        let squareSize: CGFloat = compact ? 11 : 12
        let rowY: CGFloat = compact ? 1 : 2
        selectedFill.frame = CGRect(x: 3, y: rowY, width: bounds.width - 6, height: bounds.height - rowY * 2)

        let iconX = leftInset + indent
        let iconY = (bounds.height - iconSize) * 0.5
        iconView.frame = CGRect(x: iconX, y: iconY, width: iconSize, height: iconSize)
        colorSquare.frame = CGRect(
            x: iconX + (iconSize - squareSize) * 0.5,
            y: (bounds.height - squareSize) * 0.5,
            width: squareSize,
            height: squareSize
        )

        let chevronSize: CGFloat = compact ? 12 : 14
        let chevronX = bounds.width - rightInset - chevronSize
        chevronView.frame = CGRect(x: chevronX, y: (bounds.height - chevronSize) * 0.5, width: chevronSize, height: chevronSize)

        let titleX = iconX + iconSize + 8
        let titleRight = nodeKind == "folder" ? bounds.width - rightInset : chevronX - 4
        titleLabel.frame = CGRect(x: titleX, y: 0, width: max(0, titleRight - titleX), height: bounds.height)
    }
}
