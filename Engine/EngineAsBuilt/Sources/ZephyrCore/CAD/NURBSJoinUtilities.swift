import Foundation

// =========================================================================
// MARK: - SplineJoiner
//
// Shared helpers for extracting, transforming, and joining NURBS spline
// entities. Used by both SplineEditCommand (interactive two-click join) and
// JoinCommand (batch join from selected entities).
// =========================================================================

// MARK: - SplineJoinTarget

/// Pre-validated snapshot of a single-spline entity ready for joining.
public struct SplineJoinTarget: Sendable {
    public let entity: CADEntity
    public let handle: UUID
    public let curve: NURBSCurveComponents
    public let color: ColorRGBA?

    public init(entity: CADEntity, handle: UUID, curve: NURBSCurveComponents, color: ColorRGBA?) {
        self.entity = entity
        self.handle = handle
        self.curve = curve
        self.color = color
    }
}

// MARK: - SplineJoiner

public enum SplineJoiner {

    /// Validate that the entity at `handle` has exactly one `.spline` primitive,
    /// is not a block reference, is not closed, and passes NURBS validation.
    /// Returns the target on success, or nil (caller should set an error prompt).
    public static func extractSingleSplineTarget(
        entity: CADEntity,
        handle: UUID
    ) -> SplineJoinTarget? {
        guard entity.blockID == nil else { return nil }
        guard let geom = entity.localGeometry, geom.count == 1,
              case let .spline(cps, knots, degree, weights, color) = geom[0]
        else { return nil }

        // Check closed
        if let first = cps.first, let last = cps.last, first.distance(to: last) < 1e-9 {
            return nil
        }

        let w = weights ?? Array(repeating: 1.0, count: cps.count)
        let curve = NURBSCurveComponents(
            controlPoints: cps, knots: knots, degree: degree,
            weights: w, isRational: weights != nil
        )
        if NURBSEvaluator.validateCurve(curve) != nil {
            return nil
        }
        return SplineJoinTarget(
            entity: entity, handle: handle,
            curve: curve, color: color
        )
    }

    /// Convenience that looks up the entity from the document, validates it,
    /// and returns a user-facing error string on failure.
    @MainActor
    public static func extractSingleSplineTarget(
        engine: PhrostEngine,
        handle: UUID
    ) -> (target: SplineJoinTarget?, error: String?) {
        guard let entity = engine.document.entity(for: handle) else {
            return (nil, "Entity not found.")
        }
        guard entity.blockID == nil else {
            return (nil, "Cannot join block references. Explode first.")
        }
        guard let geom = entity.localGeometry, geom.count == 1,
              case let .spline(cps, _, _, _, _) = geom[0]
        else {
            return (nil, "Entity must contain exactly one spline primitive.")
        }
        // Check closed before deeper validation
        if let first = cps.first, let last = cps.last, first.distance(to: last) < 1e-9 {
            return (nil, "Cannot join closed splines.")
        }
        if let target = extractSingleSplineTarget(entity: entity, handle: handle) {
            return (target, nil)
        }
        return (nil, "Spline is invalid (check degree, knots, weights).")
    }

    /// Transform a spline target's control points to world space using its entity transform.
    public static func worldSpaceCurve(from target: SplineJoinTarget) -> NURBSCurveComponents {
        let t = target.entity.transform
        let wsCPs = target.curve.controlPoints.map { t.transformPoint($0) }
        return NURBSCurveComponents(
            controlPoints: wsCPs,
            knots: target.curve.knots,
            degree: target.curve.degree,
            weights: target.curve.weights,
            isRational: target.curve.isRational
        )
    }

    // MARK: - Primitive conversion to NURBS

    /// Convert a line segment to a degree-1 NURBS curve.
    /// Returns nil for zero-length lines or if validation fails.
    public static func nurbsFromLine(start: Vector3, end: Vector3) -> NURBSCurveComponents? {
        guard start.distance(to: end) > 1e-12 else { return nil }
        let curve = NURBSCurveComponents(
            controlPoints: [start, end],
            knots: [0.0, 0.0, 1.0, 1.0],
            degree: 1,
            weights: [1.0, 1.0],
            isRational: false
        )
        if NURBSEvaluator.validateCurve(curve) != nil { return nil }
        return curve
    }

    /// Convert a circular arc to a degree-2 rational NURBS curve.
    /// The arc is split into segments of at most 90° (π/2) to avoid the
    /// singularity at 180° where weight = cos(θ/2) becomes zero.
    /// Returns nil for invalid radius, zero sweep, closed/full sweep,
    /// NaN/infinite angles, or if NURBS validation fails.
    public static func nurbsFromArc(
        center: Vector3,
        radius: Double,
        startAngle: Double,
        endAngle: Double
    ) -> NURBSCurveComponents? {
        // ── Input validation ──
        guard radius > 1e-12 else { return nil }
        guard startAngle.isFinite, endAngle.isFinite else { return nil }

        // Normalize sweep to positive CCW in (0, 2π)
        var sweep = endAngle - startAngle
        while sweep < 0 { sweep += 2.0 * Double.pi }
        while sweep >= 2.0 * Double.pi { sweep -= 2.0 * Double.pi }

        // Reject zero sweep and full-circle sweep
        guard sweep > 1e-12 else { return nil }
        guard sweep < 2.0 * Double.pi - 1e-12 else { return nil }

        // ── Split into ≤ 90° segments ──
        let maxSegmentSweep = Double.pi / 2.0
        let segmentCount = max(1, Int(ceil(sweep / maxSegmentSweep)))
        let segmentSweep = sweep / Double(segmentCount)

        // ── Build one NURBS per segment ──
        var segments: [NURBSCurveComponents] = []
        segments.reserveCapacity(segmentCount)

        for i in 0..<segmentCount {
            let segStart = startAngle + Double(i) * segmentSweep
            let segEnd   = startAngle + Double(i + 1) * segmentSweep
            let midAngle = segStart + segmentSweep / 2.0

            let p0 = Vector3(
                x: center.x + cos(segStart) * radius,
                y: center.y + sin(segStart) * radius,
                z: center.z
            )
            let p2 = Vector3(
                x: center.x + cos(segEnd) * radius,
                y: center.y + sin(segEnd) * radius,
                z: center.z
            )
            let w1 = cos(segmentSweep / 2.0)
            let p1 = Vector3(
                x: center.x + cos(midAngle) * (radius / w1),
                y: center.y + sin(midAngle) * (radius / w1),
                z: center.z
            )

            let seg = NURBSCurveComponents(
                controlPoints: [p0, p1, p2],
                knots: [0.0, 0.0, 0.0, 1.0, 1.0, 1.0],
                degree: 2,
                weights: [1.0, w1, 1.0],
                isRational: true
            )
            segments.append(seg)
        }

        // ── Concatenate if multiple segments ──
        if segments.count == 1 {
            let curve = segments[0]
            if NURBSEvaluator.validateCurve(curve) != nil { return nil }
            return curve
        }

        var current = segments[0]
        for i in 1..<segments.count {
            let result = NURBSEvaluator.joinSameDegree(current, segments[i])
            switch result {
            case .success(let joined):
                current = joined
            case .failure:
                return nil
            }
        }

        if NURBSEvaluator.validateCurve(current) != nil { return nil }
        return current
    }

    // MARK: - Unified extraction / conversion

    /// Try to extract a `SplineJoinTarget` from an entity, falling back to
    /// on-the-fly conversion of single `.line` or `.arc` primitives to NURBS.
    /// Returns nil for block refs, polylines, unsupported primitives, or
    /// invalid geometry.
    public static func extractOrConvertTarget(
        entity: CADEntity,
        handle: UUID
    ) -> SplineJoinTarget? {
        guard entity.blockID == nil else { return nil }

        // 1) Try native spline extraction
        if let target = extractSingleSplineTarget(entity: entity, handle: handle) {
            return target
        }

        guard let geom = entity.localGeometry, geom.count == 1 else { return nil }

        // 2) Convert single line to degree-1 NURBS
        if case let .line(start, end, color) = geom[0] {
            guard let curve = nurbsFromLine(start: start, end: end) else { return nil }
            return SplineJoinTarget(
                entity: entity, handle: handle,
                curve: curve, color: color
            )
        }

        // 3) Convert single arc to degree-2 rational NURBS
        if case let .arc(center, radius, startAngle, endAngle, color) = geom[0] {
            guard let curve = nurbsFromArc(
                center: center, radius: radius,
                startAngle: startAngle, endAngle: endAngle
            ) else { return nil }
            return SplineJoinTarget(
                entity: entity, handle: handle,
                curve: curve, color: color
            )
        }

        return nil
    }

    /// Create a new `CADEntity` with identity transform containing the joined spline.
    /// Layer, draw order, color, and non-geometric xdata are inherited from `firstTarget`.
    public static func makeJoinedSplineEntity(
        from joined: NURBSCurveComponents,
        firstTarget: SplineJoinTarget
    ) -> CADEntity {
        let outWeights: [Double]? = joined.isRational ? joined.weights : nil
        let prim: CADPrimitive = .spline(
            controlPoints: joined.controlPoints,
            knots: joined.knots,
            degree: joined.degree,
            weights: outWeights,
            color: firstTarget.color
        )
        var entity = CADEntity(
            layerID: firstTarget.entity.layerID,
            localGeometry: [prim],
            transform: .identity
        )
        entity.drawOrder = firstTarget.entity.drawOrder
        if let v = firstTarget.entity.xdata["dxf.lineType"]   { entity.xdata["dxf.lineType"]   = v }
        if let v = firstTarget.entity.xdata["dxf.color"]      { entity.xdata["dxf.color"]      = v }
        if let v = firstTarget.entity.xdata["dxf.lineWeight"] { entity.xdata["dxf.lineWeight"] = v }
        return entity
    }
}
