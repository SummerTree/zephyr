import ZephyrCore
import Foundation
import ImGui

@MainActor
struct DataTableRibbonUI {
    static func renderIfNeeded(engine: PhrostEngine, displayWidth: Float) {
        guard engine.commandProcessor.activeFeatureCommand == nil,
              engine.cadSelection.selectedCount == 1,
              let handle = engine.cadSelection.lastSelectedHandle,
              let entity = engine.document.entity(for: handle),
              let table = DataTableEditor.payload(in: entity) else {
            if engine.interaction.selectedTableHandle != nil {
                if engine.interaction.tableCellEditorActive {
                    DataTableEditor.commitCellEditing(engine: engine)
                }
                engine.interaction.clearDataTableEditingState()
            }
            return
        }

        if engine.interaction.selectedTableHandle != handle {
            if engine.interaction.tableCellEditorActive {
                DataTableEditor.commitCellEditing(engine: engine)
            }
            engine.interaction.selectTable(handle: handle)
        }

        renderSelectionOverlay(entity: entity, table: table, engine: engine)
        renderRibbon(handle: handle, table: table, engine: engine, displayWidth: displayWidth)

        if engine.interaction.tableCellEditorActive && !engine.ui.dataTablePanelVisible {
            renderCanvasCellEditor(entity: entity, table: table, engine: engine)
        }
    }

    private static func renderRibbon(
        handle: UUID,
        table: DataTableEntityPayload,
        engine: PhrostEngine,
        displayWidth: Float
    ) {
        let range = engine.interaction.tableSelectionRange
        let cellMode = engine.interaction.tableEditingMode == .cell && range != nil
        let title = cellMode ? "TABLE CELL" : "TABLE"
        let ribbonWidth = min(displayWidth - 32, cellMode ? 1240 : 1080)
        let y = AppLayout.topChromeHeight + AppLayout.tabBarHeight + 8

        ImGuiSetNextWindowPos(
            ImVec2(x: (displayWidth - ribbonWidth) * 0.5, y: y),
            Int32(ImGuiCond_Always.rawValue),
            ImVec2(x: 0, y: 0))
        ImGuiSetNextWindowSize(ImVec2(x: ribbonWidth, y: 0), Int32(ImGuiCond_Always.rawValue))
        ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowRounding.rawValue), 10.0)
        ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowPadding.rawValue), ImVec2(x: 12, y: 10))
        ImGuiPushStyleColor(Int32(ImGuiCol_WindowBg.rawValue), engine.ui.theme.panelBg)

        let flags = Int32(ImGuiWindowFlags_NoTitleBar.rawValue)
            | Int32(ImGuiWindowFlags_NoResize.rawValue)
            | Int32(ImGuiWindowFlags_NoMove.rawValue)
            | Int32(ImGuiWindowFlags_NoScrollbar.rawValue)
            | Int32(ImGuiWindowFlags_NoSavedSettings.rawValue)
            | Int32(ImGuiWindowFlags_AlwaysAutoResize.rawValue)

        if igBegin("##DataTableRibbon", nil, flags) {
            if let bold = engine.ui.boldFont { ImGuiPushFont(bold, 0) }
            ImGuiTextV(title)
            if engine.ui.boldFont != nil { ImGuiPopFont() }
            ImGuiSameLine(0, 14)

            if ribbonButton("Insert Row Below", enabled: true) {
                let index = min(table.data.rows.count, (range?.maxRow ?? table.data.rows.count - 1) + 1)
                DataTableEditor.insertRow(handle: handle, at: index, engine: engine)
                selectAfterStructureChange(handle: handle, row: index, column: range?.minColumn ?? 0, engine: engine)
            }
            ImGuiSameLine(0, 4)
            if ribbonButton("Insert Column Right", enabled: true) {
                let index = min(table.data.columns.count, (range?.maxColumn ?? table.data.columns.count - 1) + 1)
                DataTableEditor.insertColumn(handle: handle, at: index, engine: engine)
                selectAfterStructureChange(handle: handle, row: range?.minRow ?? 0, column: index, engine: engine)
            }

            ImGuiSameLine(0, 10)
            verticalDivider()
            ImGuiSameLine(0, 10)

            if ribbonButton("Delete Row", enabled: cellMode && table.data.rows.count > 1), let range {
                DataTableEditor.deleteRows(handle: handle, range: range.minRow...range.maxRow, engine: engine)
                selectNearestCell(handle: handle, row: range.minRow, column: range.minColumn, engine: engine)
            }
            ImGuiSameLine(0, 4)
            if ribbonButton("Delete Column", enabled: cellMode && table.data.columns.count > 1), let range {
                DataTableEditor.deleteColumns(handle: handle, range: range.minColumn...range.maxColumn, engine: engine)
                selectNearestCell(handle: handle, row: range.minRow, column: range.minColumn, engine: engine)
            }

            ImGuiSameLine(0, 10)
            verticalDivider()
            ImGuiSameLine(0, 10)

            if ribbonButton("Equal Rows", enabled: !table.data.rows.isEmpty) {
                let rows = range.map { $0.minRow...$0.maxRow }
                DataTableEditor.sizeRowsEqually(handle: handle, range: rows, engine: engine)
            }
            ImGuiSameLine(0, 4)
            if ribbonButton("Equal Columns", enabled: !table.data.columns.isEmpty) {
                let columns = range.map { $0.minColumn...$0.maxColumn }
                DataTableEditor.sizeColumnsEqually(handle: handle, range: columns, engine: engine)
            }

            if cellMode {
                ImGuiSameLine(0, 10)
                verticalDivider()
                ImGuiSameLine(0, 10)

                if ribbonButton("Merge", enabled: range?.isSingleCell == false), let range {
                    DataTableEditor.mergeCells(handle: handle, range: range, engine: engine)
                }
                ImGuiSameLine(0, 4)
                if ribbonButton("Split", enabled: isMergedSelection(table: table.data, range: range)), let address = range?.focus {
                    DataTableEditor.splitCell(handle: handle, address: address, engine: engine)
                }

                ImGuiSameLine(0, 10)
                verticalDivider()
                ImGuiSameLine(0, 10)

                let columnRange = range.map { $0.minColumn...$0.maxColumn }
                if ribbonButton("Align Left", enabled: true) {
                    DataTableEditor.setAlignment(handle: handle, range: columnRange, alignment: .left, engine: engine)
                }
                ImGuiSameLine(0, 4)
                if ribbonButton("Center", enabled: true) {
                    DataTableEditor.setAlignment(handle: handle, range: columnRange, alignment: .center, engine: engine)
                }
                ImGuiSameLine(0, 4)
                if ribbonButton("Align Right", enabled: true) {
                    DataTableEditor.setAlignment(handle: handle, range: columnRange, alignment: .right, engine: engine)
                }
            }

            ImGuiSameLine(0, 10)
            verticalDivider()
            ImGuiSameLine(0, 10)

            ImGuiTextV("Style")
            ImGuiSameLine(0, 4)
            ImGuiSetNextItemWidth(110)
            let currentStyle = DataTableEditor.currentStylePreset(data: table.data)
            if ImGuiBeginCombo("##TableStylePreset", currentStyle.rawValue, 0) {
                for preset in DataTableStylePreset.allCases {
                    let selected = preset == currentStyle
                    if ImGuiSelectable(preset.rawValue, selected, 0, ImVec2(x: 0, y: 0)) {
                        DataTableEditor.applyStylePreset(handle: handle, preset: preset, engine: engine)
                    }
                    if selected { ImGuiSetItemDefaultFocus() }
                }
                ImGuiEndCombo()
            }

            ImGuiSameLine(0, 10)
            verticalDivider()
            ImGuiSameLine(0, 10)

            if ribbonButton("Edit Data", enabled: true) {
                engine.ui.dataTablePanelVisible = true
            }
            ImGuiSameLine(0, 4)
            if ribbonButton("Done", enabled: true) {
                if engine.interaction.tableCellEditorActive {
                    DataTableEditor.commitCellEditing(engine: engine)
                }
                engine.cadSelection.clearSelection()
                engine.interaction.clearDataTableEditingState()
            }
        }
        ImGuiEnd()
        ImGuiPopStyleColor(1)
        ImGuiPopStyleVar(2)
    }

    private static func renderSelectionOverlay(
        entity: CADEntity,
        table: DataTableEntityPayload,
        engine: PhrostEngine
    ) {
        let layout = DataTableTessellator.layout(data: table.data, origin: table.origin)
        let selectedRect: DataTableCellRect
        if let range = engine.interaction.tableSelectionRange,
           let rect = DataTableTessellator.rangeRect(data: table.data, layout: layout, range: range) {
            selectedRect = rect
        } else {
            selectedRect = layout.tableRect
        }

        let corners = screenCorners(rect: selectedRect, entity: entity, engine: engine)
        guard corners.count == 4 else { return }
        let drawList = igGetForegroundDrawList_ViewportPtr(nil)
        let accent = igGetColorU32_Vec4(engine.ui.theme.brandGold)
        let fill = (accent & 0x00FFFFFF) | 0x30000000
        ImDrawListAddQuadFilled(drawList, corners[0], corners[1], corners[2], corners[3], fill)
        ImDrawListAddQuad(drawList, corners[0], corners[1], corners[2], corners[3], accent, 2.0)

        if let boundary = engine.interaction.hoveredTableBoundary {
            let line: (Vector3, Vector3)?
            switch boundary {
            case .column(let index):
                let edge = index + 1
                if edge >= 0, edge < layout.columnEdges.count {
                    line = (
                        Vector3(x: layout.columnEdges[edge], y: layout.dataTop, z: table.origin.z),
                        Vector3(x: layout.columnEdges[edge], y: layout.origin.y + layout.totalHeight, z: table.origin.z))
                } else {
                    line = nil
                }
            case .row(let index):
                let edge = index + 1
                if edge >= 0, edge < layout.rowEdges.count {
                    line = (
                        Vector3(x: layout.origin.x, y: layout.rowEdges[edge], z: table.origin.z),
                        Vector3(x: layout.origin.x + layout.totalWidth, y: layout.rowEdges[edge], z: table.origin.z))
                } else {
                    line = nil
                }
            }
            if let line {
                let start = screenPoint(entity.transform.transformPoint(line.0), engine: engine)
                let end = screenPoint(entity.transform.transformPoint(line.1), engine: engine)
                ImDrawListAddLine(drawList, start, end, accent, 4.0)
            }
        }
    }

    private static func renderCanvasCellEditor(
        entity: CADEntity,
        table: DataTableEntityPayload,
        engine: PhrostEngine
    ) {
        guard let address = engine.interaction.tableSelectionRange?.focus else { return }
        let layout = DataTableTessellator.layout(data: table.data, origin: table.origin)
        guard let rect = DataTableTessellator.cellRect(
            data: table.data,
            layout: layout,
            row: address.row,
            column: address.column,
            expandMerged: true) else { return }
        let corners = screenCorners(rect: rect, entity: entity, engine: engine)
        guard corners.count == 4 else { return }

        let minX = corners.map(\.x).min() ?? 0
        let minY = corners.map(\.y).min() ?? 0
        let maxX = corners.map(\.x).max() ?? minX + 120
        let maxY = corners.map(\.y).max() ?? minY + 30
        let width = max(150, maxX - minX)
        let height = max(38, maxY - minY)

        ImGuiSetNextWindowPos(ImVec2(x: minX, y: minY), Int32(ImGuiCond_Always.rawValue), ImVec2(x: 0, y: 0))
        ImGuiSetNextWindowSize(ImVec2(x: width, y: height), Int32(ImGuiCond_Always.rawValue))
        ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowPadding.rawValue), ImVec2(x: 4, y: 4))
        ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowRounding.rawValue), 2.0)
        ImGuiPushStyleColor(Int32(ImGuiCol_WindowBg.rawValue), engine.ui.theme.panelBg)
        ImGuiPushStyleColor(Int32(ImGuiCol_Border.rawValue), engine.ui.theme.brandGold)

        let flags = Int32(ImGuiWindowFlags_NoTitleBar.rawValue)
            | Int32(ImGuiWindowFlags_NoResize.rawValue)
            | Int32(ImGuiWindowFlags_NoMove.rawValue)
            | Int32(ImGuiWindowFlags_NoSavedSettings.rawValue)
        if igBegin("##CanvasTableCellEditor", nil, flags) {
            if engine.interaction.tableCellEditNeedsFocus {
                igSetKeyboardFocusHere(0)
                engine.interaction.tableCellEditNeedsFocus = false
            }
            ImGuiPushItemWidth(-1)
            let submitted = igInputText(
                "##TableCellValue",
                &engine.interaction.tableCellEditBuffer,
                4096,
                Int32(ImGuiInputTextFlags_EnterReturnsTrue.rawValue),
                nil,
                nil)
            ImGuiPopItemWidth()

            let tabPressed = ImGuiIsKeyPressed(ImGuiKey_Tab, false)
            let escapePressed = ImGuiIsKeyPressed(ImGuiKey_Escape, false)
            if escapePressed {
                DataTableEditor.cancelCellEditing(engine: engine)
            } else if submitted || tabPressed {
                let oldAddress = address
                let forward = !(ImGuiGetIO()?.pointee.KeyShift ?? false)
                DataTableEditor.commitCellEditing(engine: engine)
                if let updated = DataTableEditor.payload(handle: entity.handle, document: engine.document) {
                    let next = DataTableEditor.advanceAddress(
                        oldAddress,
                        data: updated.data,
                        forward: forward,
                        vertical: submitted)
                    DataTableEditor.beginCellEditing(handle: entity.handle, address: next, engine: engine)
                }
            }
        }
        ImGuiEnd()
        ImGuiPopStyleColor(2)
        ImGuiPopStyleVar(2)
    }

    private static func selectAfterStructureChange(
        handle: UUID,
        row: Int,
        column: Int,
        engine: PhrostEngine
    ) {
        selectNearestCell(handle: handle, row: row, column: column, engine: engine)
    }

    private static func selectNearestCell(
        handle: UUID,
        row: Int,
        column: Int,
        engine: PhrostEngine
    ) {
        guard let data = DataTableEditor.payload(handle: handle, document: engine.document)?.data,
              !data.rows.isEmpty,
              !data.columns.isEmpty else {
            engine.interaction.selectTable(handle: handle)
            return
        }
        let address = DataTableCellAddress(
            row: max(0, min(row, data.rows.count - 1)),
            column: max(0, min(column, data.columns.count - 1)))
        engine.interaction.selectTableCell(handle: handle, address: address, extending: false)
    }

    private static func isMergedSelection(
        table: DataTableData,
        range: DataTableCellRange?
    ) -> Bool {
        guard let address = range?.focus,
              address.row >= 0,
              address.row < table.rows.count,
              address.column >= 0,
              address.column < table.columns.count else { return false }
        let anchor = DataTableTessellator.mergeAnchor(
            data: table,
            row: address.row,
            column: address.column)
        let columnID = table.columns[anchor.column].id
        guard let cell = table.rows[anchor.row].cells.first(where: { $0.columnID == columnID }) else { return false }
        return cell.rowSpan > 1 || cell.colSpan > 1 || cell.coveredByMerge
    }

    private static func ribbonButton(_ label: String, enabled: Bool) -> Bool {
        if !enabled { ImGuiBeginDisabled(true) }
        let clicked = igButton(label, ImVec2(x: 0, y: 0))
        if !enabled { ImGuiEndDisabled() }
        return clicked
    }

    private static func verticalDivider() {
        let position = igGetCursorScreenPos()
        let drawList = igGetWindowDrawList()
        let color: UInt32 = 0x40FFFFFF
        ImDrawListAddLine(
            drawList,
            ImVec2(x: position.x, y: position.y),
            ImVec2(x: position.x, y: position.y + ImGuiGetFrameHeight()),
            color,
            1.0)
        ImGuiDummy(ImVec2(x: 1, y: ImGuiGetFrameHeight()))
    }

    private static func screenCorners(
        rect: DataTableCellRect,
        entity: CADEntity,
        engine: PhrostEngine
    ) -> [ImVec2] {
        let local = [
            Vector3(x: rect.minX, y: rect.minY, z: 0),
            Vector3(x: rect.maxX, y: rect.minY, z: 0),
            Vector3(x: rect.maxX, y: rect.maxY, z: 0),
            Vector3(x: rect.minX, y: rect.maxY, z: 0),
        ]
        return local.map { screenPoint(entity.transform.transformPoint($0), engine: engine) }
    }

    private static func screenPoint(_ world: Vector3, engine: PhrostEngine) -> ImVec2 {
        let camera = engine.camera.currentTransform(
            windowWidth: engine.windowWidth,
            windowHeight: engine.windowHeight)
        let point = EngineCameraManager.worldToScreen(worldX: world.x, worldY: world.y, cam: camera)
        return ImVec2(x: point.x, y: point.y)
    }
}
