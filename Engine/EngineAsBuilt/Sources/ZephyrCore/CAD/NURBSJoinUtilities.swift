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
