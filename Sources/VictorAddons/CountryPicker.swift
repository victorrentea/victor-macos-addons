import AppKit

/// A small **searchable** dropdown for choosing the Break timer's country.
///
/// A stock `NSMenu` only offers prefix type-select that jumps to a single item per
/// keystroke. Here, typing FILTERS the list to every country whose name *contains*
/// the query (case-insensitive) — so "arg" leaves just Argentina, "land" leaves
/// Ireland / Netherlands / New Zealand … The list shrinks to fit as you type.
///
/// Keyboard: type to filter, ↑/↓ move the highlight, ⏎ or a click selects, Esc or
/// clicking away closes. The app is an accessory (no Dock icon), so we activate it
/// while the picker is up so the search field actually receives keystrokes.
final class CountryPicker: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {

    /// Borderless panel that may become key, so the embedded search field can type.
    private final class PickerPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
        var onResignKey: (() -> Void)?
        override func resignKey() { super.resignKey(); onResignKey?() }
    }

    /// A row is either a pickable country or the divider under the pinned Romania.
    private enum Row { case country(BreakCountry); case separator }

    private var panel: PickerPanel?
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scroll = NSScrollView()
    private var rows: [Row] = []
    private var onSelect: ((BreakCountry) -> Void)?

    private let df: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()
    private var now = Date()

    private let width: CGFloat = 320
    private let rowH: CGFloat = 26
    private let sepH: CGFloat = 11
    private let pad: CGFloat = 8
    private let fieldH: CGFloat = 26
    private let gap: CGFloat = 6
    private let maxVisibleRows = 12

    // MARK: Present / dismiss

    /// Show anchored just below `flagScreenRect` (screen coords), preselecting the
    /// row whose timezone is `selectedTZ`.
    func present(below flagScreenRect: NSRect, selectedTZ: String, onSelect: @escaping (BreakCountry) -> Void) {
        close()
        self.onSelect = onSelect
        self.now = Date()
        searchField.stringValue = ""        // fresh & unfiltered on each open
        rebuildRows()

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(white: 0.13, alpha: 1).cgColor
        content.layer?.cornerRadius = 8
        content.layer?.masksToBounds = true

        searchField.placeholderString = "Type a country…"
        searchField.delegate = self
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 13)
        searchField.sendsSearchStringImmediately = true
        content.addSubview(searchField)

        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false

        if tableView.tableColumns.isEmpty {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("country"))
            tableView.addTableColumn(col)
        }
        tableView.tableColumns.first?.width = width - 2 * pad
        tableView.headerView = nil
        tableView.rowHeight = rowH
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        scroll.documentView = tableView
        content.addSubview(scroll)

        let panel = PickerPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 100),
                                styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        panel.contentView = content
        panel.onResignKey = { [weak self] in self?.close() }
        self.panel = panel

        tableView.reloadData()   // populate rows before layout forces a table pass
        layout(below: flagScreenRect)
        selectRow(rowIndexForTZ(selectedTZ))

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
    }

    func close() {
        panel?.onResignKey = nil
        panel?.orderOut(nil)
        panel = nil
    }

    /// Size the panel to the current row count (capped) and pin its TOP just under
    /// the flag, so it grows/shrinks downward as the list filters.
    private func layout(below flagRect: NSRect) {
        guard let panel else { return }
        let h = contentHeight()
        var origin = NSPoint(x: flagRect.minX, y: flagRect.minY - 4 - h)   // top edge under the flag
        if let scr = NSScreen.screens.first(where: { $0.frame.intersects(flagRect) }) ?? NSScreen.main {
            let vis = scr.visibleFrame
            origin.x = min(max(vis.minX + 4, origin.x), vis.maxX - width - 4)
            if origin.y < vis.minY + 4 { origin.y = flagRect.maxY + 4 }     // flip below→above if no room
        }
        applyFrame(top: origin.y + h, x: origin.x, height: h)
    }

    private func height(of row: Row) -> CGFloat {
        if case .separator = row { return sepH }
        return rowH
    }

    /// List height = sum of the row heights, capped so it scrolls past ~12 rows.
    private func listHeight() -> CGFloat {
        let total = rows.reduce(0) { $0 + height(of: $1) }
        return max(rowH, min(total, rowH * CGFloat(maxVisibleRows)))
    }

    private func contentHeight() -> CGFloat {
        pad + fieldH + gap + listHeight() + pad
    }

    /// Place the panel with its TOP edge fixed, laying out the field + list inside.
    private func applyFrame(top: CGFloat, x: CGFloat, height h: CGFloat) {
        guard let panel else { return }
        panel.setFrame(NSRect(x: x, y: top - h, width: width, height: h), display: true)
        panel.contentView!.frame = NSRect(x: 0, y: 0, width: width, height: h)
        searchField.frame = NSRect(x: pad, y: h - pad - fieldH, width: width - 2 * pad, height: fieldH)
        scroll.frame = NSRect(x: pad, y: pad, width: width - 2 * pad, height: h - 2 * pad - fieldH - gap)
    }

    // MARK: Filtering

    func controlTextDidChange(_ obj: Notification) { refilter() }

    /// Rebuild `rows` from the search text. With no query, Romania is pinned at the
    /// top with a divider, then the rest of the list alphabetically — a one-click
    /// "back to Romania". While filtering, only the contains-matches are shown.
    private func rebuildRows() {
        let q = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            rows = [.country(.romania), .separator]
                + BreakCountry.all.filter { $0.tz != BreakCountry.romania.tz }.map { Row.country($0) }
        } else {
            rows = BreakCountry.all
                .filter { $0.name.localizedCaseInsensitiveContains(q) }
                .map { Row.country($0) }
        }
    }

    /// Re-run the filter, resize the panel to fit, and highlight the first match.
    private func refilter() {
        rebuildRows()
        tableView.reloadData()   // sync the row count to `rows` BEFORE any layout-forcing resize
        if let panel { applyFrame(top: panel.frame.maxY, x: panel.frame.minX, height: contentHeight()) }
        selectRow(firstSelectableRow())
    }

    /// Headless test hook: type `q` into the search field and apply the filter.
    func applyQuery(_ q: String) {
        searchField.stringValue = q
        refilter()
    }

    /// Route arrow/return/escape from the search field so focus stays in the field
    /// (the list is driven manually) — this is what makes typing keep filtering.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)):    moveSelection(+1); return true
        case #selector(NSResponder.moveUp(_:)):      moveSelection(-1); return true
        case #selector(NSResponder.insertNewline(_:)): confirm(tableView.selectedRow); return true
        case #selector(NSResponder.cancelOperation(_:)): close(); return true
        default: return false
        }
    }

    // MARK: Selection (separators are never selectable)

    private func country(at row: Int) -> BreakCountry? {
        guard row >= 0, row < rows.count, case .country(let c) = rows[row] else { return nil }
        return c
    }

    /// Indices of the country rows (skips the separator), in order.
    private var selectableRows: [Int] {
        rows.indices.filter { if case .country = rows[$0] { return true }; return false }
    }

    private func firstSelectableRow() -> Int { selectableRows.first ?? -1 }

    private func rowIndexForTZ(_ tz: String) -> Int {
        rows.firstIndex { if case .country(let c) = $0 { return c.tz == tz }; return false } ?? firstSelectableRow()
    }

    private func selectRow(_ row: Int) {
        guard country(at: row) != nil else { tableView.deselectAll(nil); return }
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    private func moveSelection(_ delta: Int) {
        let sel = selectableRows
        guard !sel.isEmpty else { return }
        let pos = sel.firstIndex(of: tableView.selectedRow) ?? (delta > 0 ? -1 : sel.count)
        let next = min(max(0, pos + delta), sel.count - 1)
        selectRow(sel[next])
    }

    @objc private func rowClicked() {
        confirm(tableView.clickedRow)
    }

    private func confirm(_ row: Int) {
        guard let c = country(at: row) else { return }
        close()
        onSelect?(c)
    }

    // MARK: Table data

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row >= 0, row < rows.count else { return rowH }
        return height(of: rows[row])
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        country(at: row) != nil
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < rows.count else { return nil }   // defend against stale layout rows
        if case .separator = rows[row] { return separatorView() }
        guard case .country(let c) = rows[row] else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell")
        let tf = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? {
            let f = NSTextField(labelWithString: "")
            f.identifier = id
            f.font = .systemFont(ofSize: 13)
            f.lineBreakMode = .byTruncatingTail
            f.cell?.usesSingleLineMode = true
            f.drawsBackground = false
            return f
        }()
        df.timeZone = c.timeZone
        tf.stringValue = "\(c.flag)  \(c.name) — \(df.string(from: now))"
        tf.textColor = .white
        return tf
    }

    /// A thin horizontal divider under the pinned Romania row.
    private func separatorView() -> NSView {
        let id = NSUserInterfaceItemIdentifier("sep")
        if let v = tableView.makeView(withIdentifier: id, owner: self) { return v }
        let box = NSBox()
        box.identifier = id
        box.boxType = .separator
        return box
    }
}
