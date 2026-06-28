import ZephyrCore
import Foundation
import ImGui

// MARK: - StatusBarUI
//
// Renders the status bar anchored to the bottom of the window.
// Displays two sets of information:
//   Left side: Tab name, dirty marker, active layer, entity count,
//              undo/redo depth, pan mode indicator
//   Right side: FPS counter, primitive count, sprite count, camera zoom
//
// Status text on the left is cached and only recomputed when relevant
// state changes (entity count, undo depth, active layer, etc.) to avoid
// unnecessary string formatting every frame. FPS text on the right uses
// a frame counter to refresh every 15 frames (~4 times/sec at 60fps).

@MainActor
struct StatusBarUI {
    /// Renders the status bar at the bottom edge.
    /// - Parameters:
    ///   - engine: The engine instance.
    ///   - io: ImGui IO pointer for FPS and display metrics.
    ///   - dw: Display width.
    ///   - dh: Display height.
    static func render(
        engine: PhrostEngine, io: UnsafeMutablePointer<ImGuiIO>,
        dw: Float, dh: Float
    ) {
        let doc = engine.document
        let currentEntityCount = doc.entityCount

        // Check for active save state
        let saveState = engine.tabManager.activeSaveState
        let hasSaveState = saveState != nil

        if let ss = saveState {
            // When saving, always rebuild status text to show progress
            let pct = Int(ss.progress * 100)
            if case .failed(let msg) = ss.status {
                engine._cachedStatusLeft = "Save failed: \(msg)"
                // Auto-clear after 3 seconds
                if let failedAt = ss.failedAt, Date().timeIntervalSince(failedAt) > 3 {
                    engine.tabManager.clearSaveError()
                }
            } else {
                engine._cachedStatusLeft = "\(ss.statusText) \(pct)%"
            }
            engine._lastHadSaveState = true
        } else if engine._lastHadSaveState || engine._lastStatusEntityCount != currentEntityCount
            || engine._lastStatusUndo != doc.undoManager.undoDepth
            || engine._lastStatusRedo != doc.undoManager.redoDepth
            || engine._lastStatusLayerID != doc.activeLayerID
            || engine._lastPolarEnabled != engine.snap.polarTrackingEnabled
            || engine._lastOTrackEnabled != engine.snap.objectSnapTrackingEnabled
            || engine._lastExtEnabled != engine.snap.extensionSnapEnabled
            || engine._lastOrthoEnabled != engine.snap.orthoEnabled
        {
            let tabName = engine.tabManager.activeTab?.displayName ?? "Untitled"
            let dirtyMark = engine.tabManager.activeIsDirty ? " *" : ""
            let activeLayerName: String
            if let alid = doc.activeLayerID, let layer = doc.layer(for: alid) {
                activeLayerName = layer.name
            } else {
                activeLayerName = "none"
            }
            // Build snap tracking indicators.
            var trackingParts: [String] = []
            if engine.snap.polarTrackingEnabled {
                trackingParts.append("POLAR(\(Int(engine.snap.polarAngleIncrement))°)")
            }
            if engine.snap.objectSnapTrackingEnabled {
                let tpCount = engine.snap.snapTrackingEngine.trackingPoints.count
                trackingParts.append(tpCount > 0 ? "OTRACK(\(tpCount))" : "OTRACK")
            }
            if engine.snap.extensionSnapEnabled {
                trackingParts.append("EXT")
            }
            if engine.snap.orthoEnabled {
                trackingParts.append("ORTHO")
            }
            let trackingStr = trackingParts.isEmpty ? "" : "  ·  " + trackingParts.joined(separator: "  ·  ")

            // New mockup format: filename · Layer 0 · Entities: 967 · POLAR(45°)
            engine._cachedStatusLeft =
                "\(tabName)\(dirtyMark)  ·  Layer: \(activeLayerName)  ·  Entities: \(currentEntityCount)\(trackingStr)"

            engine._lastStatusEntityCount = currentEntityCount
            engine._lastStatusUndo = doc.undoManager.undoDepth
            engine._lastStatusRedo = doc.undoManager.redoDepth
            engine._lastStatusLayerID = doc.activeLayerID
            engine._lastPolarEnabled = engine.snap.polarTrackingEnabled
            engine._lastOTrackEnabled = engine.snap.objectSnapTrackingEnabled
            engine._lastExtEnabled = engine.snap.extensionSnapEnabled
            engine._lastOrthoEnabled = engine.snap.orthoEnabled
            engine._lastHadSaveState = false
        }

        let barH = AppLayout.statusBarHeight
        let barY = dh - barH

        ImGuiSetNextWindowPos(
            ImVec2(x: 0, y: barY),
            Int32(ImGuiCond_Always.rawValue),
            ImVec2(x: 0, y: 0))
        ImGuiSetNextWindowSize(
            ImVec2(x: dw, y: barH),
            Int32(ImGuiCond_Always.rawValue))

        ImGuiPushStyleVarX(Int32(ImGuiStyleVar_WindowPadding.rawValue), 16)
        ImGuiPushStyleVarY(Int32(ImGuiStyleVar_WindowPadding.rawValue), 6)
        ImGuiPushStyleColor(Int32(ImGuiCol_WindowBg.rawValue), engine.ui.theme.panelBg) // Navy background
        ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), engine.ui.theme.textDim) // Dim text

        var opened = true
        let flags: Int32 = 1 | 2 | 4 | 8 | 256
        if igBegin("##StatusBar", &opened, flags) {

            ImGuiSetCursorPosX(16)
            ImGuiTextV(engine._cachedStatusLeft)

            // Save failure indicator
            if let ss = saveState, case .failed = ss.status {
                ImGuiSameLine(0, 8)
                let redColor = ImVec4(x: 1, y: 0.3, z: 0.3, w: 1)
                ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), redColor)
                ImGuiTextV("✕")
                ImGuiPopStyleColor(1)
            }

            // Right side: Coordinates
            let mousePos = EngineCameraManager.screenToWorld(screenX: io.pointee.MousePos.x, screenY: io.pointee.MousePos.y, cam: engine.camera.currentTransform(windowWidth: Int32(dw), windowHeight: Int32(dh)))
            let coordText = String(format: "%.3f, %.3f", mousePos.0, mousePos.1)
            let textSize = ImGuiCalcTextSize(coordText, nil, false, -1)
            
            let rx = dw - textSize.x - 16
            if rx > 0 { ImGuiSetCursorPosX(rx) }
            ImGuiTextV(coordText)
        }
        igEnd()

        ImGuiPopStyleColor(2)
        ImGuiPopStyleVar(2)
    }
}
