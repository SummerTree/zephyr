import Foundation
import ImGui
import SwiftSDL

// =========================================================================
// MARK: - JoinCommand
// =========================================================================

/// JOIN — Merge connected entities into polyline or spline entities.
///
/// **Workflow (AutoCAD-style):**
///   1. Select entities.
///   2. Type `JOIN` (or `J`).
///   3. The command executes immediately — no interactive steps.
///
/// **Dispatch:**
///   - If ALL selected entities are single-spline, single-line, or single-arc
///     entities → spline join path (lines/arcs convert on-the-fly to NURBS).
///   - If ALL selected are lines/open polylines → line/polyline join path.
///   - Mixed selection (splines/arcs + polylines/unsupported) → rejected.
///
/// **Spline join algorithm:**
///   - Collects all selected spline targets via `SplineJoiner`.
///   - Repeatedly finds endpoint-matching pairs (greedy) and joins them
///     into a single spline until no more pairs match.
///   - Unmatched splines are kept as-is.
///   - Uses `SplineJoiner` shared helpers for extraction/join/entity creation.
///
/// **Line/polyline algorithm (unchanged):**
///   - Collects world-space line segments from selected `.line` and open
///     `.polyline` primitives.
///   - Groups segment endpoints by spatial proximity into clusters (tolerance
///     = 0.001 world units).
///   - Builds an adjacency graph and walks to extract maximal non-branching
///     chains.
///   - Creates one `CADEntity` per chain (identity transform, world-space
///     geometry), deletes all original entities, and selects the new ones.
///
/// **Undo:** `start()` calls `document.replaceEntities(remove:add:)` which
/// pushes a single undo snapshot before mutating the entity registry.
/// Reverting restores all original entities and removes the joined ones
/// in one undo step.
@MainActor
public final class JoinCommand: FeatureCommand {

    /// Endpoints closer than this distance (world units) are merged into the
    /// same cluster. 0.001 is tight enough to avoid accidental merges and
    /// wide enough to absorb single-precision rounding from DXF import.
    private static let endpointTolerance: Double = 0.001

    // MARK: - FeatureCommand conformance

    public init() {}

    /// Does all the work immediately. The command finishes on return.
    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        let selected = engine.cadSelection.selectedHandles

        guard !selected.isEmpty else {
            processor.commandPrompt = "Select objects to join, then run JOIN."
            processor.finishFeatureCommand(engine: engine)
            return
        }

        // ── Classify selection ──
        let targets = selected.compactMap { handle -> SplineJoinTarget? in
            guard let entity = engine.document.entity(for: handle) else { return nil }
            return SplineJoiner.extractOrConvertTarget(entity: entity, handle: handle)
        }

        let hasAnySplineConvertible = !targets.isEmpty
        let allSplineConvertible = targets.count == selected.count

        if allSplineConvertible {
            joinSelectedSplines(engine: engine, processor: processor, targets: targets)
            processor.finishFeatureCommand(engine: engine)
            return
        }

        if hasAnySplineConvertible {
            processor.commandPrompt = "JOIN selection includes unsupported or invalid objects."
            processor.finishFeatureCommand(engine: engine)
            return
        }

        // No spline-convertible entities — fall through to line/polyline join
        joinSelectedLinesAndPolylines(engine: engine, processor: processor)
        processor.finishFeatureCommand(engine: engine)
    }

    // MARK: - Spline Join

    private func joinSelectedSplines(
        engine: PhrostEngine,
        processor: CADCommandProcessor,
        targets: [SplineJoinTarget]
    ) {
        guard targets.count >= 2 else {
            processor.commandPrompt = "Select at least 2 splines to join."
            return
        }

        let originalHandles = Set(targets.map { $0.handle })
        var pending = targets
        var removedHandles = Set<UUID>()
        var changed = true

        while changed {
            changed = false

            outer: for i in pending.indices {
                for j in pending.indices where i != j {
                    let wsA = SplineJoiner.worldSpaceCurve(from: pending[i])
                    let wsB = SplineJoiner.worldSpaceCurve(from: pending[j])

                    if case .success(let joined) = NURBSEvaluator.joinSameDegree(
                        wsA, wsB, matchTolerance: Self.endpointTolerance
                    ) {
                        let newEntity = SplineJoiner.makeJoinedSplineEntity(
                            from: joined, firstTarget: pending[i]
                        )
                        let syntheticTarget = SplineJoinTarget(
                            entity: newEntity, handle: newEntity.handle,
                            curve: NURBSCurveComponents(
                                controlPoints: joined.controlPoints,
                                knots: joined.knots,
                                degree: joined.degree,
                                weights: joined.weights,
                                isRational: joined.isRational
                            ),
                            color: pending[i].color
                        )

                        removedHandles.insert(pending[i].handle)
                        removedHandles.insert(pending[j].handle)

                        let high = max(i, j)
                        let low  = min(i, j)
                        pending.remove(at: high)
                        pending.remove(at: low)
                        pending.append(syntheticTarget)
                        changed = true
                        break outer
                    }
                }
            }
        }

        // ── No-op guard: if nothing was joined, don't mutate the document ──
        guard !removedHandles.isEmpty else {
            processor.commandPrompt = "No matching endpoints found."
            return
        }

        // ── Build final result entities ──
        // Only add entities whose handles are NOT in the original set.
        // Original unmatched splines stay in the document untouched.
        var newEntities: [CADEntity] = []
        for target in pending {
            if !originalHandles.contains(target.handle) {
                newEntities.append(target.entity)
            }
        }

        // ── Atomic replace ──
        engine.document.replaceEntities(remove: removedHandles, add: newEntities)

        engine.cadSelection.clearSelection()
        for entity in newEntities {
            engine.cadSelection.addToSelection(entity.handle)
        }
        engine.tabManager.markActiveDirty()

        let msg = "Joined \(removedHandles.count) splines into \(newEntities.count) spline(s)."
        print("[JOIN] \(msg)")
        processor.commandPrompt = msg
    }

    // MARK: - Line / Polyline Join (unchanged logic, extracted from start())

    private func joinSelectedLinesAndPolylines(
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) {
        let doc = engine.document
        let selection = engine.cadSelection

        // ---- Step 1: Collect world-space line segments from selected entities ----

        struct WorldLineSegment {
            let entityHandle: UUID
            let layerID: UUID
            let start: Vector3
            let end: Vector3
            let color: ColorRGBA?
            let xdata: [String: XDataValue]
        }

        var segments: [WorldLineSegment] = []
        var skippedBlockRefs = 0
        var skippedNonLine = 0
        var skippedEmpty = 0

        for handle in selection.selectedHandles {
            guard let entity = doc.entity(for: handle) else { continue }

            if entity.blockID != nil {
                skippedBlockRefs += 1
                continue
            }

            guard let geometry = entity.localGeometry, !geometry.isEmpty else {
                skippedEmpty += 1
                continue
            }

            let hasUnsupportedPrimitive = geometry.contains { prim in
                switch prim {
                case .line, .polyline:
                    return false
                default:
                    return true
                }
            }
            if hasUnsupportedPrimitive {
                skippedNonLine += 1
                continue
            }

            let t = entity.transform
            for prim in geometry {
                switch prim {
                case .line(let start, let end, let color):
                    segments.append(WorldLineSegment(
                        entityHandle: handle,
                        layerID: entity.layerID,
                        start: t.transformPoint(start),
                        end: t.transformPoint(end),
                        color: color,
                        xdata: entity.xdata
                    ))
                case .polyline(let path, let color):
                    let points = path.tessellatedPoints()
                    guard points.count >= 2 else { continue }
                    for i in 0..<(points.count - 1) {
                        segments.append(WorldLineSegment(
                            entityHandle: handle,
                            layerID: entity.layerID,
                            start: t.transformPoint(points[i]),
                            end: t.transformPoint(points[i + 1]),
                            color: color,
                            xdata: entity.xdata
                        ))
                    }
                default:
                    break
                }
            }
        }

        guard !segments.isEmpty else {
            let reason: String
            if skippedNonLine > 0 {
                reason = "No joinable line or open-polyline geometry selected."
            } else if skippedBlockRefs > 0 {
                reason = "Selected entities are block references. Explode them first."
            } else if skippedEmpty > 0 {
                reason = "Selected entities have no geometry."
            } else {
                reason = "No line entities selected."
            }
            processor.commandPrompt = reason
            return
        }

        // ---- Step 2: Cluster endpoints by proximity ----

        var endpointClusters: [Vector3] = []

        func findOrCreateCluster(for point: Vector3) -> Int {
            for (i, cluster) in endpointClusters.enumerated() {
                if point.distance(to: cluster) < Self.endpointTolerance {
                    return i
                }
            }
            endpointClusters.append(point)
            return endpointClusters.count - 1
        }

        var segClusters: [(s: Int, e: Int)] = []
        segClusters.reserveCapacity(segments.count)

        for seg in segments {
            let si = findOrCreateCluster(for: seg.start)
            let ei = findOrCreateCluster(for: seg.end)
            segClusters.append((si, ei))
        }

        // ---- Step 3: Build adjacency graph ----

        var clusterSegments: [[Int]] = Array(repeating: [], count: endpointClusters.count)
        for (segIdx, (si, ei)) in segClusters.enumerated() {
            clusterSegments[si].append(segIdx)
            if si != ei {
                clusterSegments[ei].append(segIdx)
            }
        }

        // ---- Step 4: Extract maximal non-branching chains ----

        var usedSegments = Set<Int>()
        var chains: [[Int]] = []

        func followChain(from cluster: Int, firstSeg: Int) -> [Int] {
            var chain: [Int] = [firstSeg]
            usedSegments.insert(firstSeg)

            var cur = cluster
            var seg = firstSeg

            while true {
                let (si, ei) = segClusters[seg]
                cur = (si == cur) ? ei : si

                let candidates = clusterSegments[cur].filter { !usedSegments.contains($0) }
                if candidates.isEmpty { break }
                if candidates.count > 1 { break }

                seg = candidates[0]
                chain.append(seg)
                usedSegments.insert(seg)
            }
            return chain
        }

        for clusterIdx in 0..<endpointClusters.count {
            let candidates = clusterSegments[clusterIdx].filter { !usedSegments.contains($0) }
            guard candidates.count == 1 else { continue }
            let chain = followChain(from: clusterIdx, firstSeg: candidates[0])
            if !chain.isEmpty { chains.append(chain) }
        }

        for segIdx in 0..<segments.count {
            guard !usedSegments.contains(segIdx) else { continue }
            let (si, _) = segClusters[segIdx]
            let chain = followChain(from: si, firstSeg: segIdx)
            if !chain.isEmpty { chains.append(chain) }
        }

        // ---- Step 5: Order each chain's segments and produce polyline geometry ----

        func orderPoints(chain: Set<Int>) -> [Vector3] {
            guard !chain.isEmpty else { return [] }
            if chain.count == 1 {
                let segIdx = chain.first!
                let (si, ei) = segClusters[segIdx]
                return [endpointClusters[si], endpointClusters[ei]]
            }

            var clusterToSegs: [Int: [Int]] = [:]
            for segIdx in chain {
                let (si, ei) = segClusters[segIdx]
                clusterToSegs[si, default: []].append(segIdx)
                clusterToSegs[ei, default: []].append(segIdx)
            }

            let degree1 = clusterToSegs.filter { $0.value.count == 1 }
            var cur: Int
            if let first = degree1.first {
                cur = first.key
            } else {
                cur = clusterToSegs.keys.first!
            }

            var ordered: [Vector3] = [endpointClusters[cur]]
            var usedLocal = Set<Int>()

            while usedLocal.count < chain.count {
                let candidates = (clusterToSegs[cur] ?? []).filter { !usedLocal.contains($0) }
                guard let nextSeg = candidates.first else { break }
                usedLocal.insert(nextSeg)

                let (si, ei) = segClusters[nextSeg]
                cur = (si == cur) ? ei : si
                ordered.append(endpointClusters[cur])
            }

            return ordered
        }

        // ---- Step 6: Create new polyline entities ----

        var removedHandles = Set<UUID>()
        var newEntities: [CADEntity] = []

        var mergedChains: [[Int]] = []
        var isolatedChains: [[Int]] = []

        for chain in chains {
            if chain.count >= 2 {
                mergedChains.append(chain)
                for segIdx in chain {
                    removedHandles.insert(segments[segIdx].entityHandle)
                }
            } else {
                isolatedChains.append(chain)
            }
        }

        var chainsToProcess = mergedChains
        for chain in isolatedChains {
            let segIdx = chain[0]
            if removedHandles.contains(segments[segIdx].entityHandle) {
                chainsToProcess.append(chain)
            }
        }

        for chain in chainsToProcess {
            let chainSet = Set(chain)
            let rawPoints = orderPoints(chain: chainSet)

            var deduped: [Vector3] = []
            for pt in rawPoints {
                if let last = deduped.last, last.distance(to: pt) < Self.endpointTolerance {
                    continue
                }
                deduped.append(pt)
            }
            guard deduped.count >= 2 else { continue }

            let isClosed = deduped.count >= 3
                && deduped.first!.distance(to: deduped.last!) < Self.endpointTolerance

            let primitives: [CADPrimitive]
            let color = segments[chain[0]].color
            if isClosed {
                var closedPoints = deduped
                closedPoints.removeLast()
                primitives = [.polygon(points: closedPoints, color: color)]
            } else {
                primitives = [.polyline(points: deduped, color: color)]
            }

            let firstSegIdx = chain[0]
            let layerID = segments[firstSegIdx].layerID

            var entity = CADEntity(
                layerID: layerID,
                localGeometry: primitives,
                transform: .identity
            )

            if isClosed {
                entity.xdata["dxf.closed"] = .bool(true)
            }

            let xd = segments[firstSegIdx].xdata
            if let v = xd["dxf.lineType"]   { entity.xdata["dxf.lineType"]   = v }
            if let v = xd["dxf.color"]      { entity.xdata["dxf.color"]      = v }
            if let v = xd["dxf.lineWeight"] { entity.xdata["dxf.lineWeight"] = v }
            entity.drawOrder = doc.entity(for: segments[firstSegIdx].entityHandle)?.drawOrder ?? Int.max

            newEntities.append(entity)

            for segIdx in chain {
                removedHandles.insert(segments[segIdx].entityHandle)
            }
        }

        // ---- Step 7: Atomic replace ----

        doc.replaceEntities(remove: removedHandles, add: newEntities)

        selection.clearSelection()
        for entity in newEntities {
            selection.addToSelection(entity.handle)
        }

        engine.tabManager.markActiveDirty()

        var closedCount = 0
        for entity in newEntities {
            if let e = doc.entity(for: entity.handle),
               e.xdata["dxf.closed"] == .bool(true) {
                closedCount += 1
            }
        }

        let msg = "Joined \(removedHandles.count) entities into \(newEntities.count) polyline(s)"
            + (closedCount > 0 ? " (\(closedCount) closed)" : "")
            + "."
        print("[JOIN] \(msg)")
        processor.commandPrompt = msg
    }

    // MARK: - Remaining FeatureCommand conformance

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {}

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        return .finished
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
    }

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        return .finished
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
    }
}
