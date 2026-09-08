import Foundation
import Focus

struct HomeFocusSnapshot {
    struct Row {
        let item: HomeRow.ItemID?
        let column: Int
        let offset: Double
    }
    let selectedRow: HomeRow.ID?
    let rowIndex: Int
    let verticalOffset: Double
    let rows: [HomeRow.ID: Row]
}

extension LibraryModel {
    func captureHomeFocus(in rows: [HomeRow]) -> HomeFocusSnapshot {
        var memory: [HomeRow.ID: HomeFocusSnapshot.Row] = [:]
        for (index, row) in rows.enumerated() {
            let column = homeColumns[index, default: 0]
            memory[row.id] = .init(item: row.itemID(at: column), column: column,
                                   offset: homeRowOffsets[index, default: 0])
        }
        return .init(selectedRow: rows[safe: homeRow]?.id, rowIndex: homeRow,
                     verticalOffset: homeScrollOffset, rows: memory)
    }

    /// Keep each row's child and viewport attached to its identity through metadata refresh,
    /// download completion, collection edits and changes in the set of visible Home rows.
    func restoreHomeFocus(_ snapshot: HomeFocusSnapshot) {
        let current = rows
        var columns: [Int: Int] = [:], offsets: [Int: Double] = [:]
        for (index, row) in current.enumerated() {
            let memory = snapshot.rows[row.id]
            let column: Int
            switch memory?.item {
            case .game(let id):
                column = row.games.firstIndex { $0.id == id } ?? min(memory?.column ?? 0, max(0, row.itemCount - 1))
            case .library where row.showsLibraryCard: column = row.games.count
            default: column = min(memory?.column ?? 0, max(0, row.itemCount - 1))
            }
            columns[index] = column
            let left = 24 + Double(column) * 233
            offsets[index] = FocusViewport.reveal(offset: memory?.offset ?? 0, itemMin: left,
                itemMax: left + 213, viewport: 1752, content: 48 + Double(row.itemCount) * 233)
        }
        let matchingRow = current.firstIndex { $0.id == snapshot.selectedRow }
        let selected = matchingRow ?? min(snapshot.rowIndex, max(0, current.count - 1))
        isReconcilingHomeFocus = true
        homeColumns = columns
        homeRowOffsets = offsets
        homeRow = selected
        // Preserve the row's vertical position when rows above it appear or disappear.
        homeScrollOffset = max(0, snapshot.verticalOffset + (matchingRow == nil ? 0 : Double(selected - snapshot.rowIndex) * 456))
        isReconcilingHomeFocus = false
        revealHomeFocus()
    }
}
