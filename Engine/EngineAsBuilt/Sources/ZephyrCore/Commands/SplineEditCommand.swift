import Foundation
import CSDL3
import ImGui
import SwiftSDL

// =========================================================================
// MARK: - SplineEditCommand
// =========================================================================

/// Interactive command to edit splines (Convert to Polyline, Close, Reverse, etc.).
@MainActor
public final class SplineEditCommand: FeatureCommand {

    private enum State {
        case selecting
        case menuOpen
        case insertingKnot
        case promptingPrecision
        case selectingSecondForJoin
        case finished
    }

    private var state: State = .selecting
    private var targetHandle: UUID?
    private var splineIndex: Int = 0

    // Join state
    private var firstJoinTarget: SplineJoinTarget? = nil

    // UI state
    private var openMenuNextFrame = false
    private var openPromptNextFrame = false
    private var precisionSegments: Int32 = 12
    private var popupScreenX: Float = 0
    private var popupScreenY: Float = 0

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        print("[SplineEditCommand] start called")
        state = .selecting
        targetHandle = nil
        processor.commandPrompt = "Select a spline to edit (Esc to cancel)."
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        print("[SplineEditCommand] cancel called")
        engine.cadSelection.clearSelection()
        state = .finished
    }

    public func getDrawingSnapPoints() -> [Vector3] { [] }
    public var isSnappingEnabled: Bool { return state == .selecting }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        if state == .selecting {
            let hitHandle = engine.cadSelection.hitTest(
                worldX: worldX, worldY: worldY,
                document: engine.document,
                threshold: 12.0 / engine.camera.zoom
            )
            
            if let handle = hitHandle,
               let entity = engine.document.entity(for: handle) {
                // Check if it has a spline primitive
                let hasSpline = entity.localGeometry?.contains { prim in
                    if case .spline = prim { return true }
                    return false
                } ?? false
                
                if hasSpline {
                    targetHandle = handle
                    engine.cadSelection.select(handle)
                    state = .menuOpen
                    openMenuNextFrame = true
                    
                    let screenPos = EngineCameraManager.worldToScreen(worldX: worldX, worldY: worldY, cam: engine.camera.currentTransform(windowWidth: engine.windowWidth, windowHeight: engine.windowHeight))
                    popupScreenX = Float(screenPos.x)
                    popupScreenY = Float(screenPos.y)
                    
                    processor.commandPrompt = "Spline selected. Choose an option."
                    return .continue
                }
            }
        }

        if state == .insertingKnot {
            guard let handle = targetHandle,
                  let entity = engine.document.entity(for: handle),
                  let geometry = entity.localGeometry,
                  splineIndex < geometry.count,
                  case let .spline(cps, knots, degree, weights, color) = geometry[splineIndex]
            else {
                state = .finished
                return .continue
            }

            let w = weights ?? Array(repeating: 1.0, count: cps.count)
            let invTransform = entity.transform.inverse()
            let localClick = invTransform.transformPoint(Vector3(x: worldX, y: worldY, z: 0))

            // Find the closest parameter t on the spline to the click
            let t = NURBSEvaluator.findClosestParameter(
                degree: degree,
                knots: knots,
                controlPoints: cps,
                weights: w,
                to: localClick,
                segments: 48
            )

            // Attempt single knot insertion
            if let inserted = NURBSEvaluator.insertKnot(
                degree: degree,
                knots: knots,
                controlPoints: cps,
                weights: w,
                at: t
            ) {
                var newGeom = geometry
                newGeom[splineIndex] = .spline(
                    controlPoints: inserted.controlPoints,
                    knots: inserted.knots,
                    degree: degree,
                    weights: inserted.weights,
                    color: color
                )
                engine.document.updateEntityGeometry(for: handle, geometry: newGeom)
                engine.tabManager.markActiveDirty()
                processor.commandPrompt = "Control point inserted. Click again or Esc/Enter to finish."
            } else {
                processor.commandPrompt = "Cannot insert knot at this location — try a different spot."
            }

            return .continue
        }
        
        if state == .selectingSecondForJoin {
            guard let first = firstJoinTarget else {
                processor.commandPrompt = "Join target lost. Start Join again."
                state = .finished
                return .finished
            }

            guard let handle = hitTestSplineExcluding(
                worldX: worldX,
                worldY: worldY,
                excluding: first.handle,
                engine: engine
            ) else {
                processor.commandPrompt = "Select second spline to join to."
                return .continue
            }

            let (secondTarget, secondError) = SplineJoiner.extractSingleSplineTarget(engine: engine, handle: handle)
            guard let second = secondTarget else {
                processor.commandPrompt = secondError ?? "Cannot join this spline."
                return .continue
            }

            guard first.curve.degree == second.curve.degree else {
                processor.commandPrompt =
                    "Cannot join splines with different degrees (\(first.curve.degree) vs \(second.curve.degree))."
                return .continue
            }

            if applyJoin(engine: engine, first: first, second: second) {
                state = .finished
                return .finished
            }

            return .continue
        }

        if state == .finished {
            return .finished
        }
        
        return .continue
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {}

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        if scancode == SDL_SCANCODE_ESCAPE {
            if state == .insertingKnot {
                processor.commandPrompt = "Knot insertion complete."
            }
            if state == .selectingSecondForJoin {
                processor.commandPrompt = "Join cancelled."
                firstJoinTarget = nil
            }
            engine.cadSelection.clearSelection()
            state = .finished
            return .finished
        }
        if scancode == SDL_SCANCODE_RETURN || scancode == SDL_SCANCODE_KP_ENTER {
            if state == .insertingKnot {
                processor.commandPrompt = "Knot insertion complete."
                engine.cadSelection.clearSelection()
                state = .finished
                return .finished
            }
            if state == .selectingSecondForJoin {
                processor.commandPrompt = "Join cancelled."
                firstJoinTarget = nil
                engine.cadSelection.clearSelection()
                state = .finished
                return .finished
            }
        }
        return state == .finished ? .finished : .continue
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    public func renderImGui(engine: PhrostEngine) {
        if state == .finished { return }

        if openMenuNextFrame {
            ImGuiSetNextWindowPos(ImVec2(x: popupScreenX, y: popupScreenY), Int32(ImGuiCond_Appearing.rawValue), ImVec2(x: 0, y: 0))
            ImGuiOpenPopup("SplineEditMenu", Int32(ImGuiPopupFlags_None.rawValue))
            openMenuNextFrame = false
        }

        if ImGuiBeginPopup("SplineEditMenu", Int32(ImGuiPopupFlags_None.rawValue)) {
            ImGuiTextV("SplineEdit Options")
            ImGuiSeparator()
            
            if ImGuiButton("Close/Open", ImVec2(x: 150, y: 0)) {
                // Stub for now
                ImGuiCloseCurrentPopup()
                engine.cadSelection.clearSelection()
                state = .finished
            }
            if ImGuiButton("Join", ImVec2(x: 150, y: 0)) {
                if let handle = targetHandle {
                    let (target, error) = SplineJoiner.extractSingleSplineTarget(engine: engine, handle: handle)
                    if let t = target {
                        firstJoinTarget = t
                        ImGuiCloseCurrentPopup()
                        state = .selectingSecondForJoin
                        engine.commandProcessor.commandPrompt = "Select second spline to join to (Esc to cancel)."
                    } else {
                        engine.commandProcessor.commandPrompt = error ?? "Cannot join this spline."
                        ImGuiCloseCurrentPopup()
                        state = .finished
                    }
                }
            }
            if ImGuiButton("Fit Data (Stub)", ImVec2(x: 150, y: 0)) {
                ImGuiCloseCurrentPopup()
                engine.cadSelection.clearSelection()
                state = .finished
            }
            if ImGuiButton("Edit Vertex (Stub)", ImVec2(x: 150, y: 0)) {
                ImGuiCloseCurrentPopup()
                engine.cadSelection.clearSelection()
                state = .finished
            }
            if ImGuiButton("Insert Knot", ImVec2(x: 150, y: 0)) {
                // Find the spline primitive index for later replacement
                if let handle = targetHandle,
                   let entity = engine.document.entity(for: handle),
                   let geom = entity.localGeometry {
                    for (idx, prim) in geom.enumerated() {
                        if case .spline = prim {
                            splineIndex = idx
                            break
                        }
                    }
                }
                ImGuiCloseCurrentPopup()
                state = .insertingKnot
                engine.commandProcessor.commandPrompt = "Click on the spline to insert a control point (Esc to finish)."
            }
            if ImGuiButton("Convert to Polyline", ImVec2(x: 150, y: 0)) {
                ImGuiCloseCurrentPopup()
                state = .promptingPrecision
                openPromptNextFrame = true
            }
            if ImGuiButton("Reverse", ImVec2(x: 150, y: 0)) {
                applyReverse(engine: engine)
                ImGuiCloseCurrentPopup()
                engine.cadSelection.clearSelection()
                state = .finished
            }
            ImGuiSeparator()
            if ImGuiButton("Exit", ImVec2(x: 150, y: 0)) {
                ImGuiCloseCurrentPopup()
                engine.cadSelection.clearSelection()
                state = .finished
            }
            ImGuiEndPopup()
        }

        if openPromptNextFrame {
            ImGuiOpenPopup("Convert Spline", Int32(ImGuiPopupFlags_None.rawValue))
            openPromptNextFrame = false
        }

        var p_open = true
        let flags = Int32(ImGuiWindowFlags_AlwaysAutoResize.rawValue)
        if ImGuiBeginPopupModal("Convert Spline", &p_open, flags) {
            ImGuiTextV("Enter precision (number of segments per span):")
            
            ImGuiInputInt("##segments", &precisionSegments, 1, 10, 0)
            if precisionSegments < 1 { precisionSegments = 1 }
            
            if ImGuiButton("Convert", ImVec2(x: 120, y: 0)) {
                applyConvert(engine: engine)
                ImGuiCloseCurrentPopup()
                engine.cadSelection.clearSelection()
                state = .finished
            }
            ImGuiSameLine(0, -1)
            if ImGuiButton("Cancel", ImVec2(x: 120, y: 0)) {
                ImGuiCloseCurrentPopup()
                engine.cadSelection.clearSelection()
                state = .finished
            }
            ImGuiEndPopup()
        }
        
        if state == .finished {
            engine.commandProcessor.finishFeatureCommand(engine: engine)
        }
    }

    // MARK: - Join Spline Helpers

    /// Perform the join using shared `SplineJoiner` helpers.
    /// Returns `true` on success, `false` on failure (error already set on prompt).
    @discardableResult
    private func applyJoin(
        engine: PhrostEngine,
        first: SplineJoinTarget,
        second: SplineJoinTarget
    ) -> Bool {
        let wsA = SplineJoiner.worldSpaceCurve(from: first)
        let wsB = SplineJoiner.worldSpaceCurve(from: second)

        let result = NURBSEvaluator.joinSameDegree(wsA, wsB)
        switch result {
        case .success(let joined):
            let newEntity = SplineJoiner.makeJoinedSplineEntity(from: joined, firstTarget: first)
            let removeSet: Set<UUID> = [first.handle, second.handle]
            engine.document.replaceEntities(remove: removeSet, add: [newEntity])
            engine.cadSelection.clearSelection()
            engine.cadSelection.addToSelection(newEntity.handle)
            engine.tabManager.markActiveDirty()
            engine.commandProcessor.commandPrompt = "Splines joined."
            return true

        case .failure(let error):
            engine.commandProcessor.commandPrompt = error.description
            return false
        }
    }

    /// Hit-test that finds the nearest spline entity under the cursor, **excluding**
    /// the given handle. Used to prevent re-selecting the first spline at a shared
    /// endpoint where both splines overlap.
    private func hitTestSplineExcluding(
        worldX: Double,
        worldY: Double,
        excluding excludedHandle: UUID,
        engine: PhrostEngine
    ) -> UUID? {
        let point = Vector3(x: worldX, y: worldY, z: 0)
        let threshold = 12.0 / engine.camera.zoom
        let t2 = threshold * threshold

        var bestHandle: UUID?
        var bestDrawOrder: Int = .min
        var bestArea: Double = .infinity
        var bestDist: Double = .infinity

        for entity in engine.document.entitiesView {
            guard entity.handle != excludedHandle else { continue }
            guard entity.blockID == nil else { continue }
            guard let layer = engine.document.layer(for: entity.layerID), layer.isVisible else { continue }
            guard let geom = entity.localGeometry else { continue }

            var minDist = Double.infinity
            var hasSpline = false

            for prim in geom {
                guard case .spline = prim else { continue }
                hasSpline = true

                if let d = CADHitTesting.distanceSqToPrimitive(
                    prim,
                    point: point,
                    transform: entity.transform,
                    t2: t2
                ) {
                    minDist = min(minDist, d)
                }
            }

            guard hasSpline, minDist <= t2 else { continue }

            let area = entity.worldBoundingBox?.area ?? 0.0
            let order = entity.drawOrder

            var replace = false
            if order > bestDrawOrder {
                replace = true
            } else if order == bestDrawOrder {
                if area < bestArea - 1e-3 {
                    replace = true
                } else if abs(area - bestArea) <= 1e-3 && minDist < bestDist {
                    replace = true
                }
            }

            if replace {
                bestDrawOrder = order
                bestArea = area
                bestDist = minDist
                bestHandle = entity.handle
            }
        }

        return bestHandle
    }

    // MARK: - Actions

    private func applyReverse(engine: PhrostEngine) {
        guard let handle = targetHandle,
              let entity = engine.document.entity(for: handle) else { return }

        var newGeom = entity.localGeometry ?? []
        for i in 0..<newGeom.count {
            if case let .spline(cps, knots, degree, weights, color) = newGeom[i] {
                // Reverse control points and weights
                let revCPs = Array(cps.reversed())
                let revW = weights.map { Array($0.reversed()) }
                
                // Reverse knots: t_new[i] = max_knot - t[n - i]
                let maxKnot = knots.last ?? 1.0
                let minKnot = knots.first ?? 0.0
                let revKnots = knots.reversed().map { maxKnot - ($0 - minKnot) }
                
                newGeom[i] = .spline(controlPoints: revCPs, knots: revKnots, degree: degree, weights: revW, color: color)
            }
        }
        
        engine.document.updateEntityGeometry(for: handle, geometry: newGeom)
        engine.tabManager.markActiveDirty()
        engine.commandProcessor.commandPrompt = "Spline reversed."
    }

    private func applyConvert(engine: PhrostEngine) {
        guard let handle = targetHandle,
              let entity = engine.document.entity(for: handle) else { return }

        var newGeom = entity.localGeometry ?? []
        var convertedAny = false
        
        for i in 0..<newGeom.count {
            if case let .spline(cps, knots, degree, weights, color) = newGeom[i] {
                let pts = NURBSEvaluator.evaluateByKnotSpans(
                    degree: degree,
                    knots: knots,
                    controlPoints: cps,
                    weights: weights,
                    segmentsPerSpan: Int(precisionSegments)
                )
                
                if pts.count >= 2 {
                    // Replace with line segments
                    var lines: [CADPrimitive] = []
                    for j in 0..<(pts.count - 1) {
                        lines.append(.line(start: pts[j], end: pts[j+1], color: color))
                    }
                    newGeom.remove(at: i)
                    newGeom.insert(contentsOf: lines, at: i)
                    convertedAny = true
                    break // Assumes only 1 spline to convert for simplicity
                }
            }
        }
        
        if convertedAny {
            engine.document.updateEntityGeometry(for: handle, geometry: newGeom)
            engine.tabManager.markActiveDirty()
            engine.commandProcessor.commandPrompt = "Spline converted to polyline."
        }
    }
}
