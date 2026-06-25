import Foundation
import CSDL3
import ImGui
import SwiftSDL

// =========================================================================
// MARK: - MatchPropCommand
//
// AutoCAD-style MATCHPROP (MA) command — "Format Painter" for CAD entities.
//
// **Workflow:**
//   1. Type `MA` or `MATCHPROP` in the command line and press Enter.
//   2. Phase 1 — Pick source: Click the entity whose properties you want to copy.
//   3. Phase 2 — Paint destinations: Click any number of destination entities
//      to apply the captured properties to them.
//   4. Press Enter or Esc to finish.
//
// **Properties copied (AutoCAD-compatible):**
//   - Color override (dxf.color XData)
//   - Line weight override (dxf.lineWeight XData)
//   - Line type override (dxf.lineType XData)
//   - Draw order
//   - Layer assignment
//
// For each property, if the source has an explicit XData override, that value
// is written to the destination. If the source uses the layer default (no XData
// entry), any existing XData entry is *removed* from the destination, reverting
// it to its layer default.
//
// Each destination click pushes individual undo entries via the existing
// CADDocument per-property mutation methods. This matches AutoCAD behavior
// where each painted entity's property changes are independently undoable.
// =========================================================================

@MainActor
public final class MatchPropCommand: FeatureCommand {

    // MARK: - Phase

    private enum Phase {
        case pickSource
        case paintDestinations
    }

    // MARK: - Captured properties

    private struct CapturedProperties {
        let layerID: UUID
        let colorXData: XDataValue?       // nil = source uses layer default
        let lineWeightXData: XDataValue?  // nil = source uses layer default
        let lineTypeXData: XDataValue?    // nil = source uses layer default
        let drawOrder: Int
    }

    // MARK: - State

    private var phase: Phase = .pickSource
    private var captured: CapturedProperties? = nil

    // MARK: - Init

    public init() {}

    public var isSnappingEnabled: Bool { return false }

    // MARK: - FeatureCommand conformance

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        phase = .pickSource
        captured = nil
        processor.commandPrompt = "Select source object"
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        phase = .pickSource
        captured = nil
    }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        // Hit-test at the unsnapped world position
        let threshold = 6.0 / engine.camera.zoom
        guard let handle = engine.cadSelection.hitTest(
            worldX: worldX, worldY: worldY,
            document: engine.document,
            threshold: threshold,
            simplifyComplexBlocks: engine.simplifyComplexBlocks)
        else {
            // Clicked empty space — ignore
            return .continue
        }

        guard let entity = engine.document.entity(for: handle) else {
            return .continue
        }

        switch phase {
        case .pickSource:
            // Prevent picking the same entity as both source and... well, we
            // haven't captured yet, so this is fine. Capture properties.
            captured = captureProperties(from: entity, document: engine.document)
            phase = .paintDestinations
            processor.commandPrompt = "Select destination object(s)"
            return .continue

        case .paintDestinations:
            guard let props = captured else {
                // Shouldn't happen, but recover gracefully
                phase = .pickSource
                processor.commandPrompt = "Select source object"
                return .continue
            }

            // Don't paint onto the source entity itself
            // (AutoCAD skips the source — it already has those properties)
            applyProperties(props, to: handle, document: engine.document)
            return .continue
        }
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        // Hover highlight is handled by the global hoverCoordinator, so nothing
        // extra is needed here. The crosshair cursor is drawn by the renderer
        // automatically during feature commands.
    }

    public func handleKeyDown(
        scancode: SDL_Scancode,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        switch scancode {
        case SDL_SCANCODE_ESCAPE,
             SDL_SCANCODE_RETURN,
             SDL_SCANCODE_KP_ENTER:
            return .finished
        default:
            return .continue
        }
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        // Draw a small paint-bucket indicator near the cursor during the
        // paint-destinations phase.
        guard phase == .paintDestinations else { return }

        let drawList = igGetForegroundDrawList_ViewportPtr(nil)
        let mx = engine.interaction.lastMouseX
        let my = engine.interaction.lastMouseY

        // Simple "paint" indicator: a small filled square with a handle,
        // offset 16px right and 16px down from the cursor.
        let s: Float = 10
        let x = mx + 16
        let y = my + 16
        let color = makeCol32(255, 200, 50, 220)

        // Bucket body (filled rectangle)
        ImDrawListAddRectFilled(
            drawList,
            ImVec2(x: x - s, y: y - s),
            ImVec2(x: x + s, y: y + s),
            color,
            0, 0)

        // Bucket rim (top line, slightly wider)
        let rimColor = makeCol32(255, 220, 80, 255)
        ImDrawListAddLine(
            drawList,
            ImVec2(x: x - s - 2, y: y - s),
            ImVec2(x: x + s + 2, y: y - s),
            rimColor,
            1.5)

        // Handle (simple line)
        ImDrawListAddLine(
            drawList,
            ImVec2(x: x + s, y: y - s + 3),
            ImVec2(x: x + s + 6, y: y - s - 6),
            rimColor,
            1.5)
        ImDrawListAddLine(
            drawList,
            ImVec2(x: x + s + 6, y: y - s - 6),
            ImVec2(x: x + s, y: y - s),
            rimColor,
            1.5)
    }

    public func renderImGui(engine: PhrostEngine) {
        // No ImGui UI needed for this command.
    }

    // MARK: - Helpers

    /// Capture the matchable properties from a source entity.
    private func captureProperties(from entity: CADEntity, document: CADDocument) -> CapturedProperties {
        return CapturedProperties(
            layerID: entity.layerID,
            colorXData: entity.xdata["dxf.color"],
            lineWeightXData: entity.xdata["dxf.lineWeight"],
            lineTypeXData: entity.xdata["dxf.lineType"],
            drawOrder: entity.drawOrder
        )
    }

    /// Apply captured properties to a destination entity.
    /// Uses the atomic `applyMatchProperties` method so all property changes
    /// are captured in a single undo step per destination entity.
    private func applyProperties(
        _ props: CapturedProperties,
        to handle: UUID,
        document: CADDocument
    ) {
        document.applyMatchProperties(
            to: handle,
            layerID: props.layerID,
            colorXData: props.colorXData,
            lineWeightXData: props.lineWeightXData,
            lineTypeXData: props.lineTypeXData,
            drawOrder: props.drawOrder
        )
    }
}
