import Foundation

// =========================================================================
// MARK: - EntityCluster
//
// A group of CAD entity handles that are spatially adjacent, forming a
// "shape" for the purpose of geometric feature extraction and LLM-based
// pattern matching.
// =========================================================================

public struct EntityCluster: Sendable {
    /// Unique identifier for this cluster.
    public let id: UUID

    /// Handles of the entities belonging to this cluster.
    public var entities: [UUID]

    /// Number of entities in the cluster.
    public var entityCount: Int { entities.count }

    public init(id: UUID = UUID(), entities: [UUID] = []) {
        self.id = id
        self.entities = entities
    }
}

// =========================================================================
// MARK: - EntityClustering
//
// DBSCAN-light proximity clustering + geometric feature extraction for
// 2D CAD entities. Groups disconnected primitives into "shapes" based on
// bounding-box proximity and exports lightweight JSON feature profiles
// suitable for LLM-based pattern classification.
// =========================================================================

public enum EntityClustering {

    // MARK: - Clustering

    /// Groups the given entity handles into spatially-adjacent clusters.
    ///
    /// Algorithm (DBSCAN-light):
    ///   1. Collect the world-space bounding box of every entity, expanded by `gapTolerance`.
    ///   2. For every pair of entities whose expanded boxes intersect, union their sets.
    ///   3. Return each connected component as an `EntityCluster`.
    ///
    /// - Parameters:
    ///   - handles: The entity handles to cluster.
    ///   - document: The CAD document to resolve entities from.
    ///   - gapTolerance: Maximum world-space distance between entities that should
    ///     be considered part of the same shape (default 0.05).
    /// - Returns: Array of clusters, each containing a list of handle UUIDs.
    public static func clusterEntities(
        _ handles: Set<UUID>,
        in document: CADDocument,
        gapTolerance: Double = 0.05
    ) -> [EntityCluster] {
        guard !handles.isEmpty else { return [] }

        let handleList = Array(handles)

        // Pre-extract world-space segments for narrow-phase true-distance checks.
        var entitySegments: [UUID: [Segment]] = [:]

        struct Node {
            let handle: UUID
            let bbox: BoundingBox3D
        }

        var nodes: [Node] = []
        nodes.reserveCapacity(handleList.count)

        for h in handleList {
            guard let entity = document.entity(for: h),
                  let bb = entity.worldBoundingBox else { continue }

            nodes.append(Node(handle: h, bbox: bb.expanded(by: gapTolerance)))

            let geom = document.resolvedGeometry(for: entity) ?? entity.localGeometry ?? []
            var segs: [Segment] = []
            let t = entity.transform
            for prim in geom {
                let localSegs = extractSegments(from: prim)
                for s in localSegs {
                    segs.append(Segment(start: t.transformPoint(s.start),
                                        end: t.transformPoint(s.end)))
                }
            }
            entitySegments[h] = segs
        }

        guard !nodes.isEmpty else { return [] }

        var parent = Array(0..<nodes.count)
        var rank = Array(repeating: 0, count: nodes.count)

        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }

        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            guard ra != rb else { return }
            if rank[ra] < rank[rb] { parent[ra] = rb }
            else if rank[ra] > rank[rb] { parent[rb] = ra }
            else { parent[rb] = ra; rank[ra] += 1 }
        }

        for i in 0..<nodes.count {
            let bi = nodes[i].bbox
            let segsI = entitySegments[nodes[i].handle] ?? []
            for j in (i + 1)..<nodes.count {
                // Broad-phase AABB check.
                if bi.intersects(nodes[j].bbox) {
                    let segsJ = entitySegments[nodes[j].handle] ?? []
                    // Narrow-phase true geometric proximity check.
                    if segmentsTouch(segsI, segsJ, tolerance: gapTolerance) {
                        union(i, j)
                    }
                }
            }
        }

        var groups: [Int: [UUID]] = [:]
        for i in 0..<nodes.count {
            let root = find(i)
            groups[root, default: []].append(nodes[i].handle)
        }

        return groups.values.map { EntityCluster(entities: $0) }
    }

    // MARK: - Narrow-Phase Proximity Helpers

    /// Returns true if any endpoint of a segment in `a` is within `tolerance`
    /// of any endpoint of a segment in `b`, or if a segment endpoint lies within
    /// `tolerance` of the other segment's interior.
    fileprivate static func segmentsTouch(_ a: [Segment], _ b: [Segment], tolerance: Double) -> Bool {
        let tolSq = tolerance * tolerance
        for sa in a {
            for sb in b {
                if distSq(sa.start, sb.start) <= tolSq { return true }
                if distSq(sa.start, sb.end)   <= tolSq { return true }
                if distSq(sa.end,   sb.start) <= tolSq { return true }
                if distSq(sa.end,   sb.end)   <= tolSq { return true }

                if pointToSegDistSq(sa.start, sb.start, sb.end) <= tolSq { return true }
                if pointToSegDistSq(sa.end,   sb.start, sb.end) <= tolSq { return true }
                if pointToSegDistSq(sb.start, sa.start, sa.end) <= tolSq { return true }
                if pointToSegDistSq(sb.end,   sa.start, sa.end) <= tolSq { return true }
            }
        }
        return false
    }

    fileprivate static func distSq(_ a: Vector3, _ b: Vector3) -> Double {
        let dx = a.x - b.x; let dy = a.y - b.y; return dx * dx + dy * dy
    }

    fileprivate static func pointToSegDistSq(_ p: Vector3, _ a: Vector3, _ b: Vector3) -> Double {
        let dx = b.x - a.x; let dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        if lenSq < 1e-12 { return distSq(p, a) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq
        t = max(0, min(1, t))
        let projX = a.x + t * dx; let projY = a.y + t * dy
        let px = p.x - projX; let py = p.y - projY
        return px * px + py * py
    }

    // MARK: - Segment (internal representation)

    /// A straight line segment in world space, used during feature extraction.
    fileprivate struct Segment {
        let start: Vector3
        let end: Vector3
    }

    // MARK: - Feature Extraction

    /// Extracts a JSON-serializable feature profile from a cluster.
    ///
    /// All array fields (`endpoint_gaps`, `relative_angles`, `normalized_gaps`) are
    /// sorted ascending so the LLM can perform deterministic comparisons regardless
    /// of the traversal order used during extraction.
    ///
    /// - Parameters:
    ///   - cluster: The cluster to profile.
    ///   - document: The CAD document to resolve entities and geometry from.
    /// - Returns: A `ClusterProfileJSON` value, or `nil` if the cluster is empty.
    public static func extractProfile(
        from cluster: EntityCluster,
        in document: CADDocument
    ) -> ClusterProfileJSON? {
        guard !cluster.entities.isEmpty else { return nil }

        // --- Gather all line segments (in world space) ---
        var segments: [Segment] = []
        var allTypes: Set<String> = []
        var layerNames: Set<String> = []
        var totalLength: Double = 0
        var segmentCount: Int = 0
        var minX = Double.infinity, maxX = -Double.infinity
        var minY = Double.infinity, maxY = -Double.infinity

        for handle in cluster.entities {
            guard let entity = document.entity(for: handle) else { continue }
            guard let geometry = document.resolvedGeometry(for: entity) else { continue }

            if let bb = entity.worldBoundingBox {
                if bb.min.x < minX { minX = bb.min.x }; if bb.max.x > maxX { maxX = bb.max.x }
                if bb.min.y < minY { minY = bb.min.y }; if bb.max.y > maxY { maxY = bb.max.y }
            }

            if let layer = document.layer(for: entity.layerID) {
                layerNames.insert(layer.name)
            }

            let transform = entity.transform
            for prim in geometry {
                allTypes.insert(primitiveTypeName(prim))
                let segs = extractSegments(from: prim)
                for s in segs {
                    // Transform from local to world space.
                    let wsStart = transform.transformPoint(s.start)
                    let wsEnd   = transform.transformPoint(s.end)
                    let wsSegment = Segment(start: wsStart, end: wsEnd)
                    let dx = wsEnd.x - wsStart.x
                    let dy = wsEnd.y - wsStart.y
                    let len = hypot(dx, dy)
                    totalLength += len
                    segmentCount += 1
                    segments.append(wsSegment)
                }
            }
        }

        let averageLength = segmentCount > 0 ? totalLength / Double(segmentCount) : 0
        let bbWidth = maxX - minX
        let bbHeight = maxY - minY
        let maxDiagonal = hypot(bbWidth, bbHeight)
        let spreadFactor = averageLength > 1e-12 ? maxDiagonal / averageLength : 1.0

        // --- Endpoint gaps ---
        let endpointGaps = computeEndpointGaps(segments: segments)

        // --- Relative angles ---
        let relativeAngles = computeRelativeAngles(segments: segments)

        // --- Closed shape detection ---
        // Relaxed threshold: gap must be < 15% of average segment length.
        let isClosedShape = segments.count >= 3
            && endpointGaps.allSatisfy { $0 < (averageLength * 0.15) }
            && segments.count > 0

        // --- Normalized gaps ---
        let normalizedGaps: [Double]
        if averageLength > 1e-12 {
            normalizedGaps = endpointGaps.map { $0 / averageLength }.sorted()
        } else {
            normalizedGaps = endpointGaps.map { _ in 0.0 }
        }

        return ClusterProfileJSON(
            cluster_id: cluster.id.uuidString,
            entity_count: cluster.entities.count,
            types: allTypes.sorted(),
            max_diagonal: maxDiagonal,
            average_length: averageLength,
            is_closed_shape: isClosedShape,
            endpoint_gaps: endpointGaps.sorted(),
            relative_angles: relativeAngles.sorted(),
            layer_names: layerNames.sorted(),
            spread_factor: spreadFactor,
            normalized_gaps: normalizedGaps
        )
    }

    /// Extracts profiles for multiple clusters at once.
    public static func extractProfiles(
        from clusters: [EntityCluster],
        in document: CADDocument
    ) -> [ClusterProfileJSON] {
        clusters.compactMap { extractProfile(from: $0, in: document) }
    }

    // MARK: - Private Helpers

    /// Returns a short type name for a CADPrimitive.
    private static func primitiveTypeName(_ prim: CADPrimitive) -> String {
        switch prim {
        case .point:        return "point"
        case .line:         return "line"
        case .rect:         return "rect"
        case .fillRect:     return "fillRect"
        case .polygon:      return "polygon"
        case .polyline:     return "polyline"
        case .fillPolygon:  return "fillPolygon"
        case .fillComplexPolygon: return "fillComplexPolygon"
        case .gradient:     return "gradient"
        case .circle:       return "circle"
        case .arc:          return "arc"
        case .spline:       return "spline"
        case .text:         return "text"
        case .ellipse:      return "ellipse"
        case .hatch:        return "hatch"
        case .ray:          return "ray"
        case .image:        return "image"
        }
    }

    /// Extracts straight-line segments from a primitive.
    /// - For `.line`: one segment.
    /// - For `.polyline`, `.polygon`: tessellates bulges, returns chord segments.
    /// - For `.rect`, `.fillRect`: four edges.
    /// - For `.arc`: chord from start to end.
    /// - For `.circle`: two perpendicular diameters (approximate).
    /// - For `.spline`: chord segments between tessellated points.
    /// - Everything else: empty.
    private static func extractSegments(from prim: CADPrimitive) -> [Segment] {
        switch prim {
        case .line(let start, let end, _):
            return [Segment(start: start, end: end)]

        case .polyline(let path, _):
            let pts = path.points
            guard pts.count >= 2 else { return [] }
            var out: [Segment] = []
            out.reserveCapacity(path.segmentCount)
            // Tessellate bulged segments.
            let tessellated = path.tessellatedPoints()
            for i in 0..<(tessellated.count - 1) {
                out.append(Segment(start: tessellated[i], end: tessellated[i + 1]))
            }
            if path.isClosed && tessellated.count >= 2 {
                out.append(Segment(start: tessellated.last!, end: tessellated.first!))
            }
            return out

        case .polygon(let pts, _):
            guard pts.count >= 2 else { return [] }
            var out: [Segment] = []
            for i in 0..<(pts.count - 1) {
                out.append(Segment(start: pts[i], end: pts[i + 1]))
            }
            out.append(Segment(start: pts.last!, end: pts.first!))
            return out

        case .fillPolygon(let pts, _):
            guard pts.count >= 2 else { return [] }
            var out: [Segment] = []
            for i in 0..<(pts.count - 1) {
                out.append(Segment(start: pts[i], end: pts[i + 1]))
            }
            out.append(Segment(start: pts.last!, end: pts.first!))
            return out

        case .rect(let origin, let size, _):
            let x0 = origin.x, y0 = origin.y
            let x1 = x0 + size.x, y1 = y0 + size.y
            return [
                Segment(start: Vector3(x: x0, y: y0), end: Vector3(x: x1, y: y0)),
                Segment(start: Vector3(x: x1, y: y0), end: Vector3(x: x1, y: y1)),
                Segment(start: Vector3(x: x1, y: y1), end: Vector3(x: x0, y: y1)),
                Segment(start: Vector3(x: x0, y: y1), end: Vector3(x: x0, y: y0)),
            ]

        case .fillRect(let origin, let size, _):
            let x0 = origin.x, y0 = origin.y
            let x1 = x0 + size.x, y1 = y0 + size.y
            return [
                Segment(start: Vector3(x: x0, y: y0), end: Vector3(x: x1, y: y0)),
                Segment(start: Vector3(x: x1, y: y0), end: Vector3(x: x1, y: y1)),
                Segment(start: Vector3(x: x1, y: y1), end: Vector3(x: x0, y: y1)),
                Segment(start: Vector3(x: x0, y: y1), end: Vector3(x: x0, y: y0)),
            ]

        case .arc(let center, let radius, let startAngle, let endAngle, _):
            let sx = center.x + cos(startAngle) * radius
            let sy = center.y + sin(startAngle) * radius
            let ex = center.x + cos(endAngle) * radius
            let ey = center.y + sin(endAngle) * radius
            return [Segment(start: Vector3(x: sx, y: sy), end: Vector3(x: ex, y: ey))]

        case .circle(let center, let radius, _):
            // Two perpendicular diameters — enough to represent the circle's extent.
            return [
                Segment(start: Vector3(x: center.x - radius, y: center.y),
                        end: Vector3(x: center.x + radius, y: center.y)),
                Segment(start: Vector3(x: center.x, y: center.y - radius),
                        end: Vector3(x: center.x, y: center.y + radius)),
            ]

        case .spline(let controlPoints, _, _, _, _):
            guard controlPoints.count >= 2 else { return [] }
            var out: [Segment] = []
            for i in 0..<(controlPoints.count - 1) {
                out.append(Segment(start: controlPoints[i], end: controlPoints[i + 1]))
            }
            return out

        case .ellipse(let center, let majorAxis, let minorRatio, _):
            let majLen = hypot(majorAxis.x, majorAxis.y)
            guard majLen > 1e-12 else { return [] }
            let minLen = majLen * minorRatio
            return [
                Segment(start: Vector3(x: center.x - majLen, y: center.y),
                        end: Vector3(x: center.x + majLen, y: center.y)),
                Segment(start: Vector3(x: center.x, y: center.y - minLen),
                        end: Vector3(x: center.x, y: center.y + minLen)),
            ]

        default:
            return []
        }
    }

    /// Computes the smallest distances between unjoined endpoints.
    /// For each endpoint of every segment, finds the closest endpoint of any *other*
    /// segment, and returns those distances (capped so we don't include huge gaps
    /// that are clearly intentional separations).
    private static func computeEndpointGaps(segments: [Segment]) -> [Double] {
        guard segments.count > 1 else { return [] }

        // Collect all unique endpoints.
        var endpoints: [Vector3] = []
        endpoints.reserveCapacity(segments.count * 2)
        for s in segments {
            endpoints.append(s.start)
            endpoints.append(s.end)
        }

        var gaps: [Double] = []
        // For each endpoint, find the closest *other* endpoint.
        for i in 0..<endpoints.count {
            var best = Double.infinity
            for j in 0..<endpoints.count where j != i {
                let dx = endpoints[i].x - endpoints[j].x
                let dy = endpoints[i].y - endpoints[j].y
                let d = hypot(dx, dy)
                if d < best { best = d }
            }
            // Only include gaps < 0.5 (beyond that is clearly not a near-closure).
            if best < 0.5 {
                gaps.append(best)
            }
        }

        return gaps
    }

    /// Computes relative interior angles for a set of line segments.
    ///
    /// Uses the consecutive-delta method: compute absolute world angle for each
    /// segment direction, sort them, then take the absolute difference between
    /// consecutive sorted angles (including wrap-around). This produces exactly
    /// N angles for N segments and is fully rotation-invariant.
    private static func computeRelativeAngles(segments: [Segment]) -> [Double] {
        guard segments.count >= 2 else { return [] }

        // Compute absolute world angle [0, 360) for each segment.
        var worldAngles: [Double] = []
        worldAngles.reserveCapacity(segments.count)
        for s in segments {
            let dx = s.end.x - s.start.x
            let dy = s.end.y - s.start.y
            guard hypot(dx, dy) > 1e-12 else { continue }
            var angle = atan2(dy, dx) * 180.0 / Double.pi
            if angle < 0 { angle += 360.0 }
            worldAngles.append(angle)
        }
        guard worldAngles.count >= 2 else { return [] }

        // Sort ascending.
        worldAngles.sort()

        // Consecutive deltas (including wrap-around from last to first).
        var deltas: [Double] = []
        deltas.reserveCapacity(worldAngles.count)
        for i in 0..<worldAngles.count {
            let a = worldAngles[i]
            let b = worldAngles[(i + 1) % worldAngles.count]
            var delta: Double
            if i == worldAngles.count - 1 {
                // Wrap-around: b is the first angle (plus 360).
                delta = (b + 360.0) - a
            } else {
                delta = b - a
            }
            // Normalize to [0, 180].
            if delta > 180 { delta = 360 - delta }
            deltas.append(delta)
        }

        return deltas
    }
}
