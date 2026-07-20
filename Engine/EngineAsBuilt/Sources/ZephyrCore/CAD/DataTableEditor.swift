import Foundation

public struct DataTableEntityPayload: Sendable {
    public var primitiveIndex: Int
    public var data: DataTableData
    public var origin: Vector3
    public var color: ColorRGBA?

    public init(primitiveIndex: Int, data: DataTableData, origin: Vector3, color: ColorRGBA?) {
        self.primitiveIndex = primitiveIndex
        self.data = data
        self.origin = origin
        self.color = color
    }
}

@MainActor
public enum DataTableEditor {
    public static func payload(in entity: CADEntity) -> DataTableEntityPayload? {
        guard let geometry = entity.localGeometry else { return nil }
        for (index, primitive) in geometry.enumerated() {
            if case .table(let data, let origin, let color) = primitive {
                return DataTableEntityPayload(
                    primitiveIndex: index,
                    data: data,
                    origin: origin,
                    color: color)
            }
        }
        return nil
    }

    public static func payload(handle: UUID, document: CADDocument) -> DataTableEntityPayload? {
        guard let entity = document.entity(for: handle) else { return nil }
        return payload(in: entity)
    }

    public static func makeData(configuration: DataTableInsertConfiguration) -> DataTableData {
        let columnCount = max(1, min(configuration.columnCount, 256))
        let dataRowCount = max(1, min(configuration.dataRowCount, 100_000))
        let headerCount = max(0, min(configuration.headerRowCount, 1_000))
        let rowCount = min(100_000, dataRowCount + headerCount)
        let columns = (0..<columnCount).map {
            DataTableColumn(
                name: spreadsheetColumnName($0),
                width: max(0.25, configuration.defaultColumnWidth),
                alignment: .left)
        }
        let rows = (0..<rowCount).map { _ in
            DataTableRow(cells: columns.map {
                DataTableCell(columnID: $0.id, value: .empty)
            })
        }
        var data = DataTableData(
            columns: columns,
            rows: rows,
            title: configuration.includeTitle ? configuration.title : nil,
            rowHeights: Array(repeating: max(0.25, configuration.defaultRowHeight), count: rowCount),
            defaultRowHeight: max(0.25, configuration.defaultRowHeight),
            defaultColumnWidth: max(0.25, configuration.defaultColumnWidth),
            headerRowCount: headerCount,
            cellMargin: 0.25,
            textHeight: max(0.1, configuration.textHeight),
            cellAlignment: .left)
        applyStylePreset(configuration.stylePreset, to: &data)
        return data
    }

    public static func cellText(data: DataTableData, address: DataTableCellAddress) -> String {
        guard let cell = cell(data: data, address: address) else { return "" }
        if let cached = cell.cachedDisplayText, !cached.isEmpty { return cached }
        switch cell.value {
        case .string(let value): return value
        case .number(let value): return String(format: "%g", value)
        case .integer(let value): return String(value)
        case .boolean(let value): return value ? "true" : "false"
        case .empty: return ""
        }
    }

    public static func cellHit(
        handle: UUID,
        worldPoint: Vector3,
        document: CADDocument
    ) -> DataTableCellHit? {
        guard let entity = document.entity(for: handle),
              let table = payload(in: entity) else { return nil }
        let localPoint = entity.transform.inverse().transformPoint(worldPoint)
        return DataTableTessellator.hitTestCell(
            data: table.data,
            origin: table.origin,
            localPoint: localPoint)
    }

    public static func beginCellEditing(
        handle: UUID,
        address: DataTableCellAddress,
        engine: PhrostEngine
    ) {
        guard let table = payload(handle: handle, document: engine.document) else { return }
        let anchor = DataTableTessellator.mergeAnchor(
            data: table.data,
            row: address.row,
            column: address.column)
        engine.interaction.selectedTableHandle = handle
        engine.interaction.tableSelectionRange = DataTableCellRange(anchor)
        engine.interaction.tableEditingMode = .cell
        engine.interaction.tableCellEditorActive = true
        engine.interaction.tableCellEditBuffer = cellText(data: table.data, address: anchor)
        engine.interaction.tableCellEditNeedsFocus = true
    }

    public static func commitCellEditing(engine: PhrostEngine) {
        guard engine.interaction.tableCellEditorActive,
              let handle = engine.interaction.selectedTableHandle,
              let address = engine.interaction.tableSelectionRange?.focus else { return }
        setCellText(
            handle: handle,
            address: address,
            text: engine.interaction.tableCellEditBuffer,
            engine: engine)
        engine.interaction.tableCellEditorActive = false
        engine.interaction.tableCellEditNeedsFocus = false
    }

    public static func cancelCellEditing(engine: PhrostEngine) {
        engine.interaction.tableCellEditorActive = false
        engine.interaction.tableCellEditNeedsFocus = false
        engine.interaction.tableCellEditBuffer = ""
    }

    public static func setCellText(
        handle: UUID,
        address: DataTableCellAddress,
        text: String,
        engine: PhrostEngine
    ) {
        mutateTable(handle: handle, engine: engine) { data in
            normalizeRows(&data)
            let anchor = DataTableTessellator.mergeAnchor(
                data: data,
                row: address.row,
                column: address.column)
            guard anchor.row >= 0, anchor.row < data.rows.count,
                  anchor.column >= 0, anchor.column < data.columns.count else { return }
            let columnID = data.columns[anchor.column].id
            guard let cellIndex = data.rows[anchor.row].cells.firstIndex(where: { $0.columnID == columnID }) else { return }
            data.rows[anchor.row].cells[cellIndex].value = text.isEmpty ? .empty : .string(text)
            data.rows[anchor.row].cells[cellIndex].cachedDisplayText = nil
            data.rows[anchor.row].cells[cellIndex].formulaExpression = nil
        }
    }

    public static func setTitle(
        handle: UUID,
        title: String,
        engine: PhrostEngine
    ) {
        mutateTable(handle: handle, engine: engine) { data in
            data.title = title.isEmpty ? nil : title
        }
    }

    public static func setColumnName(
        handle: UUID,
        column: Int,
        name: String,
        engine: PhrostEngine
    ) {
        mutateTable(handle: handle, engine: engine) { data in
            guard column >= 0, column < data.columns.count else { return }
            data.columns[column].name = name.isEmpty ? spreadsheetColumnName(column) : name
        }
    }

    public static func clearCells(
        handle: UUID,
        range: DataTableCellRange,
        engine: PhrostEngine
    ) {
        mutateTable(handle: handle, engine: engine) { data in
            normalizeRows(&data)
            let clamped = clamp(range: range, data: data)
            for row in clamped.minRow...clamped.maxRow {
                for column in clamped.minColumn...clamped.maxColumn {
                    let columnID = data.columns[column].id
                    guard let cellIndex = data.rows[row].cells.firstIndex(where: { $0.columnID == columnID }) else { continue }
                    data.rows[row].cells[cellIndex].value = .empty
                    data.rows[row].cells[cellIndex].formulaExpression = nil
                    data.rows[row].cells[cellIndex].cachedDisplayText = nil
                }
            }
        }
    }

    public static func insertRow(
        handle: UUID,
        at index: Int,
        engine: PhrostEngine
    ) {
        mutateTable(handle: handle, engine: engine) { data in
            normalizeRows(&data)
            var merges = captureMergeRegions(data)
            resetMerges(&data)
            ensureRowHeights(&data)
            let insertionIndex = max(0, min(index, data.rows.count))
            let height = insertionIndex > 0 && insertionIndex - 1 < data.rowHeights.count
                ? data.rowHeights[insertionIndex - 1]
                : data.defaultRowHeight
            let row = DataTableRow(cells: data.columns.map {
                DataTableCell(columnID: $0.id, value: .empty)
            })
            data.rows.insert(row, at: insertionIndex)
            data.rowHeights.insert(max(0.25, height), at: min(insertionIndex, data.rowHeights.count))
            if insertionIndex < data.headerRowCount {
                data.headerRowCount += 1
            }
            for mergeIndex in merges.indices {
                if insertionIndex <= merges[mergeIndex].row {
                    merges[mergeIndex].row += 1
                } else if insertionIndex < merges[mergeIndex].row + merges[mergeIndex].rowSpan {
                    merges[mergeIndex].rowSpan += 1
                }
            }
            applyMergeRegions(merges, to: &data)
        }
    }

    public static func deleteRows(
        handle: UUID,
        range: ClosedRange<Int>,
        engine: PhrostEngine
    ) {
        mutateTable(handle: handle, engine: engine) { data in
            guard data.rows.count > 1 else { return }
            normalizeRows(&data)
            let originalMerges = captureMergeRegions(data)
            resetMerges(&data)
            ensureRowHeights(&data)
            let lower = max(0, min(range.lowerBound, data.rows.count - 1))
            let upper = max(lower, min(range.upperBound, data.rows.count - 1))
            let maximumRemoval = data.rows.count - 1
            let removalCount = min(upper - lower + 1, maximumRemoval)
            guard removalCount > 0 else { return }
            let removedUpper = lower + removalCount - 1
            let merges = originalMerges.compactMap {
                deletingRows(from: $0, lower: lower, upper: removedUpper, count: removalCount)
            }
            data.rows.removeSubrange(lower..<(lower + removalCount))
            if lower < data.rowHeights.count {
                let end = min(data.rowHeights.count, lower + removalCount)
                data.rowHeights.removeSubrange(lower..<end)
            }
            let removedHeaderRows = max(0, min(lower + removalCount, data.headerRowCount) - min(lower, data.headerRowCount))
            data.headerRowCount = max(0, data.headerRowCount - removedHeaderRows)
            applyMergeRegions(merges, to: &data)
        }
    }

    public static func insertColumn(
        handle: UUID,
        at index: Int,
        engine: PhrostEngine
    ) {
        mutateTable(handle: handle, engine: engine) { data in
            normalizeRows(&data)
            var merges = captureMergeRegions(data)
            resetMerges(&data)
            let insertionIndex = max(0, min(index, data.columns.count))
            let width: Double
            if insertionIndex > 0 {
                let previous = data.columns[insertionIndex - 1]
                width = previous.width > 0 ? previous.width : data.defaultColumnWidth
            } else {
                width = data.defaultColumnWidth
            }
            let column = DataTableColumn(
                name: nextAvailableColumnName(in: data),
                width: max(0.25, width),
                alignment: data.cellAlignment)
            data.columns.insert(column, at: insertionIndex)
            for rowIndex in data.rows.indices {
                data.rows[rowIndex].cells.insert(
                    DataTableCell(columnID: column.id, value: .empty),
                    at: min(insertionIndex, data.rows[rowIndex].cells.count))
            }
            for mergeIndex in merges.indices {
                if insertionIndex <= merges[mergeIndex].column {
                    merges[mergeIndex].column += 1
                } else if insertionIndex < merges[mergeIndex].column + merges[mergeIndex].colSpan {
                    merges[mergeIndex].colSpan += 1
                }
            }
            applyMergeRegions(merges, to: &data)
        }
    }

    public static func deleteColumns(
        handle: UUID,
        range: ClosedRange<Int>,
        engine: PhrostEngine
    ) {
        mutateTable(handle: handle, engine: engine) { data in
            guard data.columns.count > 1 else { return }
            normalizeRows(&data)
            let originalMerges = captureMergeRegions(data)
            resetMerges(&data)
            let lower = max(0, min(range.lowerBound, data.columns.count - 1))
            let upper = max(lower, min(range.upperBound, data.columns.count - 1))
            let maximumRemoval = data.columns.count - 1
            let removalCount = min(upper - lower + 1, maximumRemoval)
            guard removalCount > 0 else { return }
            let removedUpper = lower + removalCount - 1
            let merges = originalMerges.compactMap {
                deletingColumns(from: $0, lower: lower, upper: removedUpper, count: removalCount)
            }
            let removedIDs = Set(data.columns[lower..<(lower + removalCount)].map(\.id))
            data.columns.removeSubrange(lower..<(lower + removalCount))
            for rowIndex in data.rows.indices {
                data.rows[rowIndex].cells.removeAll { removedIDs.contains($0.columnID) }
            }
            applyMergeRegions(merges, to: &data)
        }
    }

    public static func mergeCells(
        handle: UUID,
        range: DataTableCellRange,
        engine: PhrostEngine
    ) {
        mutateTable(handle: handle, engine: engine) { data in
            guard !data.rows.isEmpty, !data.columns.isEmpty else { return }
            normalizeRows(&data)
            let selected = clamp(range: range, data: data)
            guard selected.rowCount > 1 || selected.columnCount > 1 else { return }
            let existingMerges = captureMergeRegions(data)
            for merge in existingMerges where merge.intersects(selected) {
                resetMergeRegion(merge, in: &data)
            }
            let anchorColumnID = data.columns[selected.minColumn].id
            guard let anchorCellIndex = data.rows[selected.minRow].cells.firstIndex(where: { $0.columnID == anchorColumnID }) else { return }
            data.rows[selected.minRow].cells[anchorCellIndex].rowSpan = selected.rowCount
            data.rows[selected.minRow].cells[anchorCellIndex].colSpan = selected.columnCount
            data.rows[selected.minRow].cells[anchorCellIndex].coveredByMerge = false

            for row in selected.minRow...selected.maxRow {
                for column in selected.minColumn...selected.maxColumn {
                    if row == selected.minRow && column == selected.minColumn { continue }
                    let columnID = data.columns[column].id
                    guard let cellIndex = data.rows[row].cells.firstIndex(where: { $0.columnID == columnID }) else { continue }
                    data.rows[row].cells[cellIndex].rowSpan = 1
                    data.rows[row].cells[cellIndex].colSpan = 1
                    data.rows[row].cells[cellIndex].coveredByMerge = true
                }
            }
        }
        if let data = payload(handle: handle, document: engine.document)?.data {
            let anchor = DataTableCellAddress(
                row: min(range.minRow, max(0, data.rows.count - 1)),
                column: min(range.minColumn, max(0, data.columns.count - 1)))
            engine.interaction.tableSelectionRange = DataTableCellRange(anchor)
        }
    }

    public static func splitCell(
        handle: UUID,
        address: DataTableCellAddress,
        engine: PhrostEngine
    ) {
        mutateTable(handle: handle, engine: engine) { data in
            normalizeRows(&data)
            let anchor = DataTableTessellator.mergeAnchor(
                data: data,
                row: address.row,
                column: address.column)
            guard let anchorCell = cell(data: data, address: anchor) else { return }
            let rowSpan = max(1, anchorCell.rowSpan)
            let colSpan = max(1, anchorCell.colSpan)
            for row in anchor.row..<min(data.rows.count, anchor.row + rowSpan) {
                for column in anchor.column..<min(data.columns.count, anchor.column + colSpan) {
                    let columnID = data.columns[column].id
                    guard let cellIndex = data.rows[row].cells.firstIndex(where: { $0.columnID == columnID }) else { continue }
                    data.rows[row].cells[cellIndex].rowSpan = 1
                    data.rows[row].cells[cellIndex].colSpan = 1
                    data.rows[row].cells[cellIndex].coveredByMerge = false
                }
            }
        }
    }

    public static func sizeRowsEqually(
        handle: UUID,
        range: ClosedRange<Int>?,
        engine: PhrostEngine
    ) {
        mutateTable(handle: handle, engine: engine) { data in
            guard !data.rows.isEmpty else { return }
            ensureRowHeights(&data)
            let lower = max(0, min(range?.lowerBound ?? 0, data.rows.count - 1))
            let upper = max(lower, min(range?.upperBound ?? data.rows.count - 1, data.rows.count - 1))
            let values = data.rowHeights[lower...upper]
            let average = max(0.25, values.reduce(0, +) / Double(values.count))
            for row in lower...upper { data.rowHeights[row] = average }
        }
    }

    public static func sizeColumnsEqually(
        handle: UUID,
        range: ClosedRange<Int>?,
        engine: PhrostEngine
    ) {
        mutateTable(handle: handle, engine: engine) { data in
            guard !data.columns.isEmpty else { return }
            let lower = max(0, min(range?.lowerBound ?? 0, data.columns.count - 1))
            let upper = max(lower, min(range?.upperBound ?? data.columns.count - 1, data.columns.count - 1))
            let widths = (lower...upper).map {
                data.columns[$0].width > 0 ? data.columns[$0].width : data.defaultColumnWidth
            }
            let average = max(0.25, widths.reduce(0, +) / Double(widths.count))
            for column in lower...upper { data.columns[column].width = average }
        }
    }

    public static func currentStylePreset(data: DataTableData) -> DataTableStylePreset {
        if data.gridColor == ColorRGBA(r: 190, g: 190, b: 190, a: 255),
           data.headerFillColor == ColorRGBA(r: 230, g: 230, b: 230, a: 255) {
            return .light
        }
        if data.gridColor?.a == 0 {
            return .minimal
        }
        if data.backgroundFillColor == ColorRGBA(r: 24, g: 32, b: 44, a: 255) {
            return .alternating
        }
        return .standard
    }

    public static func applyStylePreset(
        handle: UUID,
        preset: DataTableStylePreset,
        engine: PhrostEngine
    ) {
        mutateTable(handle: handle, engine: engine) { data in
            applyStylePreset(preset, to: &data)
        }
    }

    public static func setAlignment(
        handle: UUID,
        range: ClosedRange<Int>?,
        alignment: DataTableCellAlignment,
        engine: PhrostEngine
    ) {
        mutateTable(handle: handle, engine: engine) { data in
            guard !data.columns.isEmpty else { return }
            let lower = max(0, min(range?.lowerBound ?? 0, data.columns.count - 1))
            let upper = max(lower, min(range?.upperBound ?? data.columns.count - 1, data.columns.count - 1))
            let columnIDs = Set(data.columns[lower...upper].map(\.id))
            for column in lower...upper { data.columns[column].alignment = alignment }
            for rowIndex in data.rows.indices {
                for cellIndex in data.rows[rowIndex].cells.indices
                where columnIDs.contains(data.rows[rowIndex].cells[cellIndex].columnID) {
                    data.rows[rowIndex].cells[cellIndex].horizontalAlignment = alignment
                }
            }
            data.cellAlignment = alignment
        }
    }

    public static func applyBoundaryResize(
        handle: UUID,
        boundary: DataTableBoundaryHit,
        originalData: DataTableData,
        deltaLocal: Vector3,
        engine: PhrostEngine,
        live: Bool
    ) {
        var data = originalData
        switch boundary {
        case .column(let index):
            guard index >= 0, index < data.columns.count else { return }
            let originalWidth = data.columns[index].width > 0
                ? data.columns[index].width
                : data.defaultColumnWidth
            data.columns[index].width = max(0.25, originalWidth + deltaLocal.x)
        case .row(let index):
            guard index >= 0, index < data.rows.count else { return }
            ensureRowHeights(&data)
            data.rowHeights[index] = max(0.25, data.rowHeights[index] + deltaLocal.y)
        }
        replaceTableData(handle: handle, data: data, engine: engine, live: live)
    }

    public static func replaceTableData(
        handle: UUID,
        data: DataTableData,
        engine: PhrostEngine,
        live: Bool
    ) {
        guard var entity = engine.document.entity(for: handle),
              var geometry = entity.localGeometry,
              let table = payload(in: entity) else { return }
        var updatedData = data
        updatedData.nativeDXFPayload?.isModified = true
        geometry[table.primitiveIndex] = .table(
            data: updatedData,
            origin: table.origin,
            color: table.color)
        entity.localGeometry = geometry
        DataTableTessellator.invalidateCache()
        if live {
            engine.document.updateEntityLive(entity)
        } else {
            engine.document.updateEntity(entity)
            engine.tabManager.markActiveDirty()
        }
    }

    public static func advanceAddress(
        _ address: DataTableCellAddress,
        data: DataTableData,
        forward: Bool,
        vertical: Bool
    ) -> DataTableCellAddress {
        guard !data.rows.isEmpty, !data.columns.isEmpty else { return address }
        var row = max(0, min(address.row, data.rows.count - 1))
        var column = max(0, min(address.column, data.columns.count - 1))
        if vertical {
            row += forward ? 1 : -1
            if row >= data.rows.count { row = 0 }
            if row < 0 { row = data.rows.count - 1 }
        } else if forward {
            column += 1
            if column >= data.columns.count {
                column = 0
                row = (row + 1) % data.rows.count
            }
        } else {
            column -= 1
            if column < 0 {
                column = data.columns.count - 1
                row = row == 0 ? data.rows.count - 1 : row - 1
            }
        }
        return DataTableTessellator.mergeAnchor(data: data, row: row, column: column)
    }

    private static func mutateTable(
        handle: UUID,
        engine: PhrostEngine,
        mutation: (inout DataTableData) -> Void
    ) {
        guard var entity = engine.document.entity(for: handle),
              var geometry = entity.localGeometry,
              let table = payload(in: entity) else { return }
        var data = table.data
        mutation(&data)
        data.nativeDXFPayload?.isModified = true
        geometry[table.primitiveIndex] = .table(
            data: data,
            origin: table.origin,
            color: table.color)
        entity.localGeometry = geometry
        DataTableTessellator.invalidateCache()
        engine.document.updateEntity(entity)
        engine.tabManager.markActiveDirty()
    }

    private static func applyStylePreset(
        _ preset: DataTableStylePreset,
        to data: inout DataTableData
    ) {
        switch preset {
        case .standard:
            data.gridColor = ColorRGBA(r: 128, g: 128, b: 128, a: 255)
            data.textColor = ColorRGBA(r: 255, g: 255, b: 255, a: 255)
            data.headerFillColor = ColorRGBA(r: 40, g: 40, b: 60, a: 255)
            data.backgroundFillColor = ColorRGBA(r: 30, g: 30, b: 40, a: 255)
        case .light:
            data.gridColor = ColorRGBA(r: 190, g: 190, b: 190, a: 255)
            data.textColor = ColorRGBA(r: 20, g: 20, b: 20, a: 255)
            data.headerFillColor = ColorRGBA(r: 230, g: 230, b: 230, a: 255)
            data.backgroundFillColor = ColorRGBA(r: 248, g: 248, b: 248, a: 255)
        case .minimal:
            data.gridColor = ColorRGBA(r: 128, g: 128, b: 128, a: 0)
            data.textColor = ColorRGBA(r: 255, g: 255, b: 255, a: 255)
            data.headerFillColor = ColorRGBA(r: 0, g: 0, b: 0, a: 0)
            data.backgroundFillColor = ColorRGBA(r: 0, g: 0, b: 0, a: 0)
        case .alternating:
            data.gridColor = ColorRGBA(r: 110, g: 125, b: 145, a: 255)
            data.textColor = ColorRGBA(r: 245, g: 245, b: 245, a: 255)
            data.headerFillColor = ColorRGBA(r: 49, g: 63, b: 82, a: 255)
            data.backgroundFillColor = ColorRGBA(r: 24, g: 32, b: 44, a: 255)
        }
    }

    private static func normalizeRows(_ data: inout DataTableData) {
        let validIDs = Set(data.columns.map(\.id))
        let columnOrder = Dictionary(uniqueKeysWithValues: data.columns.enumerated().map { ($0.element.id, $0.offset) })
        for rowIndex in data.rows.indices {
            var cells = data.rows[rowIndex].cells.filter { validIDs.contains($0.columnID) }
            for (columnIndex, column) in data.columns.enumerated() {
                if !cells.contains(where: { $0.columnID == column.id }) {
                    cells.insert(
                        DataTableCell(columnID: column.id, value: .empty),
                        at: min(columnIndex, cells.count))
                }
            }
            cells.sort {
                (columnOrder[$0.columnID] ?? Int.max) < (columnOrder[$1.columnID] ?? Int.max)
            }
            data.rows[rowIndex].cells = cells
        }
    }

    private static func ensureRowHeights(_ data: inout DataTableData) {
        if data.rowHeights.count < data.rows.count {
            data.rowHeights.append(contentsOf: Array(
                repeating: max(0.25, data.defaultRowHeight),
                count: data.rows.count - data.rowHeights.count))
        } else if data.rowHeights.count > data.rows.count {
            data.rowHeights.removeLast(data.rowHeights.count - data.rows.count)
        }
        for index in data.rowHeights.indices {
            if data.rowHeights[index] <= 0 { data.rowHeights[index] = max(0.25, data.defaultRowHeight) }
        }
    }

    private struct MergeRegion {
        var row: Int
        var column: Int
        var rowSpan: Int
        var colSpan: Int
        var sourceCell: DataTableCell

        func intersects(_ range: DataTableCellRange) -> Bool {
            let maxRow = row + rowSpan - 1
            let maxColumn = column + colSpan - 1
            return row <= range.maxRow
                && maxRow >= range.minRow
                && column <= range.maxColumn
                && maxColumn >= range.minColumn
        }
    }

    private static func captureMergeRegions(_ data: DataTableData) -> [MergeRegion] {
        var result: [MergeRegion] = []
        for row in data.rows.indices {
            for column in data.columns.indices {
                guard let value = cell(data: data, address: DataTableCellAddress(row: row, column: column)),
                      !value.coveredByMerge,
                      value.rowSpan > 1 || value.colSpan > 1 else { continue }
                result.append(MergeRegion(
                    row: row,
                    column: column,
                    rowSpan: max(1, value.rowSpan),
                    colSpan: max(1, value.colSpan),
                    sourceCell: value))
            }
        }
        return result
    }

    private static func resetMerges(_ data: inout DataTableData) {
        for rowIndex in data.rows.indices {
            for cellIndex in data.rows[rowIndex].cells.indices {
                data.rows[rowIndex].cells[cellIndex].rowSpan = 1
                data.rows[rowIndex].cells[cellIndex].colSpan = 1
                data.rows[rowIndex].cells[cellIndex].coveredByMerge = false
            }
        }
    }

    private static func resetMergeRegion(_ region: MergeRegion, in data: inout DataTableData) {
        let endRow = min(data.rows.count, region.row + region.rowSpan)
        let endColumn = min(data.columns.count, region.column + region.colSpan)
        guard region.row >= 0, region.column >= 0,
              region.row < endRow, region.column < endColumn else { return }
        for row in region.row..<endRow {
            for column in region.column..<endColumn {
                let columnID = data.columns[column].id
                guard let index = data.rows[row].cells.firstIndex(where: { $0.columnID == columnID }) else { continue }
                data.rows[row].cells[index].rowSpan = 1
                data.rows[row].cells[index].colSpan = 1
                data.rows[row].cells[index].coveredByMerge = false
            }
        }
    }

    private static func applyMergeRegions(_ regions: [MergeRegion], to data: inout DataTableData) {
        normalizeRows(&data)
        for region in regions {
            guard region.row >= 0, region.column >= 0,
                  region.row < data.rows.count,
                  region.column < data.columns.count else { continue }
            let rowSpan = min(max(1, region.rowSpan), data.rows.count - region.row)
            let colSpan = min(max(1, region.colSpan), data.columns.count - region.column)

            let anchorColumnID = data.columns[region.column].id
            guard let anchorIndex = data.rows[region.row].cells.firstIndex(where: { $0.columnID == anchorColumnID }) else { continue }
            data.rows[region.row].cells[anchorIndex].value = region.sourceCell.value
            data.rows[region.row].cells[anchorIndex].formulaExpression = region.sourceCell.formulaExpression
            data.rows[region.row].cells[anchorIndex].cachedDisplayText = region.sourceCell.cachedDisplayText
            data.rows[region.row].cells[anchorIndex].rowSpan = rowSpan
            data.rows[region.row].cells[anchorIndex].colSpan = colSpan
            data.rows[region.row].cells[anchorIndex].coveredByMerge = false

            for row in region.row..<(region.row + rowSpan) {
                for column in region.column..<(region.column + colSpan) {
                    if row == region.row && column == region.column { continue }
                    let columnID = data.columns[column].id
                    guard let index = data.rows[row].cells.firstIndex(where: { $0.columnID == columnID }) else { continue }
                    data.rows[row].cells[index].rowSpan = 1
                    data.rows[row].cells[index].colSpan = 1
                    data.rows[row].cells[index].coveredByMerge = true
                }
            }
        }
    }

    private static func deletingRows(
        from region: MergeRegion,
        lower: Int,
        upper: Int,
        count: Int
    ) -> MergeRegion? {
        let end = region.row + region.rowSpan - 1
        if end < lower { return region }
        if region.row > upper {
            var shifted = region
            shifted.row -= count
            return shifted
        }
        let before = max(0, lower - region.row)
        let after = max(0, end - upper)
        guard before + after > 0 else { return nil }
        var adjusted = region
        adjusted.row = before > 0 ? region.row : lower
        adjusted.rowSpan = before + after
        return adjusted
    }

    private static func deletingColumns(
        from region: MergeRegion,
        lower: Int,
        upper: Int,
        count: Int
    ) -> MergeRegion? {
        let end = region.column + region.colSpan - 1
        if end < lower { return region }
        if region.column > upper {
            var shifted = region
            shifted.column -= count
            return shifted
        }
        let before = max(0, lower - region.column)
        let after = max(0, end - upper)
        guard before + after > 0 else { return nil }
        var adjusted = region
        adjusted.column = before > 0 ? region.column : lower
        adjusted.colSpan = before + after
        return adjusted
    }

    private static func cell(data: DataTableData, address: DataTableCellAddress) -> DataTableCell? {
        guard address.row >= 0, address.row < data.rows.count,
              address.column >= 0, address.column < data.columns.count else { return nil }
        let columnID = data.columns[address.column].id
        return data.rows[address.row].cells.first { $0.columnID == columnID }
    }

    private static func clamp(range: DataTableCellRange, data: DataTableData) -> DataTableCellRange {
        let maxRow = max(0, data.rows.count - 1)
        let maxColumn = max(0, data.columns.count - 1)
        return DataTableCellRange(
            anchor: DataTableCellAddress(
                row: max(0, min(range.anchor.row, maxRow)),
                column: max(0, min(range.anchor.column, maxColumn))),
            focus: DataTableCellAddress(
                row: max(0, min(range.focus.row, maxRow)),
                column: max(0, min(range.focus.column, maxColumn))))
    }

    private static func nextAvailableColumnName(in data: DataTableData) -> String {
        let names = Set(data.columns.map { $0.name.uppercased() })
        var index = 0
        while names.contains(spreadsheetColumnName(index)) { index += 1 }
        return spreadsheetColumnName(index)
    }

    private static func spreadsheetColumnName(_ index: Int) -> String {
        var value = max(0, index)
        var result = ""
        repeat {
            let remainder = value % 26
            result.insert(Character(UnicodeScalar(65 + remainder)!), at: result.startIndex)
            value = value / 26 - 1
        } while value >= 0
        return result
    }


}
