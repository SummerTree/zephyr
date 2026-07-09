import Foundation
import SwiftDXFrw

/// Converts SwiftDXFrw entity types into Zephyr CADPrimitive arrays.
/// Replaces the old CDXFRW bridge converter — pure Swift.
public enum DXFEntityConverter {

    public nonisolated(unsafe) static var simplifyPolylines: Bool = false

    /// Convert a SwiftDXFrw DXFEntity to CADPrimitives
    internal static func convertEntityToPrimitives(
        _ e: DXFEntity,
        arrowSize: Double = 1.0,
        bylayerColor: ColorRGBA? = nil
    ) -> [CADPrimitive] {
        let explicitColor: ColorRGBA? = resolveEntityColor(e)
        let primColor: ColorRGBA? = explicitColor ?? (e.color == 256 ? bylayerColor : nil)

        switch e.eType {
        case .pOINT:
            guard let p = e as? DXFPointEntity else { return [] }
            return [.point(position: cadPoint(p.basePoint, extrusion: p.haveExtrusion ? p.extrusion : nil), color: primColor)]
        case .lINE:
            guard let l = e as? DXFLineEntity else { return [] }
            return [.line(start: yflip(l.basePoint), end: yflip(l.secPoint), color: primColor)]
        case .cIRCLE:
            guard let c = e as? DXFCircleEntity else { return [] }
            return [.circle(center: cadPoint(c.basePoint, extrusion: c.haveExtrusion ? c.extrusion : nil), radius: c.radius, color: primColor)]
        case .aRC:
            guard let a = e as? DXFArcEntity else { return [] }
            let center = cadPoint(a.basePoint, extrusion: a.haveExtrusion ? a.extrusion : nil)
            var startAngle = -a.endAngle
            var endAngle = -a.startAngle
            if a.haveExtrusion && a.extrusion.z < 0 {
                startAngle = -a.startAngle
                endAngle = -a.endAngle
            }
            return [.arc(center: center, radius: a.radius,
                        startAngle: startAngle, endAngle: endAngle, color: primColor)]
        case .lWPOLYLINE, .pOLYLINE:
            return convertPolyline(e, color: primColor)
        case .eLLIPSE:
            return convertEllipse(e, color: primColor)
        case .sPLINE:
            return convertSpline(e, color: primColor)
        case .tEXT, .mTEXT:
            return convertText(e, color: primColor)
        case .iNSERT:
            return []
        case .sOLID:
            guard let s = e as? DXFSolidEntity else { return [] }
            let ext = s.haveExtrusion ? s.extrusion : nil
            return [.fillPolygon(points: [cadPoint(s.basePoint, extrusion: ext), cadPoint(s.secPoint, extrusion: ext),
                                         cadPoint(s.thirdPoint, extrusion: ext), cadPoint(s.fourPoint, extrusion: ext)], color: primColor)]
        case .e3DFACE:
            guard let f = e as? DXF3DFaceEntity else { return [] }
            let ext = f.haveExtrusion ? f.extrusion : nil
            return [.polygon(points: [cadPoint(f.basePoint, extrusion: ext), cadPoint(f.secPoint, extrusion: ext),
                                     cadPoint(f.thirdPoint, extrusion: ext), cadPoint(f.fourPoint, extrusion: ext)], color: primColor)]
        case .hATCH:
            return convertHatch(e, color: primColor)
        case .dIMENSION:
            guard let d = e as? DXFDimensionEntity else { return [] }
            let def = yflip(d.defPoint); let txt = yflip(d.textPoint)
            return def != txt ? [.line(start: def, end: txt, color: primColor)] : [.point(position: def, color: primColor)]
        case .lEADER:
            return convertLeader(e, arrowSize: arrowSize, color: primColor)
        case .iMAGE:
            return convertImage(e, color: primColor)
        case .xLINE:
            guard let x = e as? DXFXLineEntity else { return [] }
            let base = yflip(x.basePoint); let dir = yflip(x.secPoint)
            return [.line(start: base, end: Vector3(x: base.x + dir.x, y: base.y + dir.y, z: base.z + dir.z), color: primColor)]
        case .rAY:
            guard let r = e as? DXFRayEntity else { return [] }
            return [.ray(start: yflip(r.basePoint), direction: yflip(r.secPoint), color: primColor)]
        case .tRACE:
            guard let t = e as? DXFTraceEntity else { return [] }
            return [.line(start: yflip(t.basePoint), end: yflip(t.secPoint), color: primColor)]
        case .vIEWPORT, .tABLE, .bLOCK, .uNKNOWN:
            return []
        default:
            return []
        }
    }

    // MARK: - Polyline

    private static func convertPolyline(_ e: DXFEntity, color: ColorRGBA?) -> [CADPrimitive] {
        if let lw = e as? DXFLWPolylineEntity {
            guard !lw.vertices.isEmpty else { return [] }
            if lw.vertices.count == 1 {
                return [.point(position: cadLWPoint(lw.vertices[0], in: lw), color: color)]
            }
            let isClosed = (lw.flags & 0x01) != 0
            let mirrored = !isDefaultExtrusion(lw.extPoint) && lw.extPoint.z < 0
            let path = CADPolyline(
                vertices: lw.vertices.map { v in
                    var bulge = -v.bulge
                    if mirrored { bulge = -bulge }
                    return CADPolylineVertex(position: cadLWPoint(v, in: lw),
                                             bulge: bulge, startWidth: v.startWidth, endWidth: v.endWidth)
                }, isClosed: isClosed, lineTypeGenerationEnabled: (lw.flags & 0x80) != 0)
            return [.polyline(path: simplifyIfNeeded(path), color: color)]
        }
        if let pl = e as? DXFPolylineEntity {
            guard !pl.vertices.isEmpty else { return [] }
            let mirrored = pl.haveExtrusion && pl.extrusion.z < 0
            let path = CADPolyline(
                vertices: pl.vertices.map { v in
                    var bulge = -v.bulge
                    if mirrored { bulge = -bulge }
                    return CADPolylineVertex(position: cadPolylinePoint(v, in: pl),
                                             bulge: bulge, startWidth: v.startWidth, endWidth: v.endWidth)
                },
                isClosed: (pl.flags & 0x01) != 0,
                lineTypeGenerationEnabled: false)
            return [.polyline(path: simplifyIfNeeded(path), color: color)]
        }
        return []
    }

    // MARK: - Ellipse

    private static func convertEllipse(_ e: DXFEntity, color: ColorRGBA?) -> [CADPrimitive] {
        guard let el = e as? DXFEllipseEntity else { return [] }
        let center = yflip(el.basePoint)
        let rawMajor = Vector3(x: el.secPoint.x, y: el.secPoint.y, z: el.secPoint.z)
        let majorLen = rawMajor.magnitude; let minorLen = majorLen * el.ratio
        guard majorLen > 1e-12, minorLen > 1e-12 else { return [.point(position: center, color: color)] }
        let startP = el.startParam; let endP = el.endParam
        let isFull = abs(abs(endP - startP) - .pi * 2) < 1e-5 || abs(endP - startP) < 1e-5
        var sweep = endP - startP; if sweep < 0 && !isFull { sweep += .pi * 2.0 }
        let angle = atan2(rawMajor.y, rawMajor.x); let cosR = cos(angle); let sinR = sin(angle)
        let segs = 64; var pts: [Vector3] = []
        for i in 0...segs {
            let t = Double(i) / Double(segs); let param = startP + sweep * t
            let px = majorLen * cos(param); let py = minorLen * sin(param)
            let rx = px * cosR - py * sinR; let ry = px * sinR + py * cosR
            pts.append(Vector3(x: center.x + rx, y: center.y - ry, z: center.z))
        }
        if isFull { return [.polygon(points: pts, color: color)] }
        return (0..<(pts.count - 1)).map { .line(start: pts[$0], end: pts[$0 + 1], color: color) }
    }

    // MARK: - Spline

    private static func convertSpline(_ e: DXFEntity, color: ColorRGBA?) -> [CADPrimitive] {
        guard let sp = e as? DXFSplineEntity else { return [] }
        let degree = sp.degree > 0 ? sp.degree : 3
        if sp.nControl > 0, sp.nKnots > 0 {
            let cps = sp.controlPoints.map { yflip($0) }
            let weights = sp.weights.isEmpty ? Array(repeating: 1.0, count: cps.count) : sp.weights
            return [.spline(controlPoints: cps, knots: sp.knots, degree: degree,
                           weights: weights.contains { abs($0 - 1.0) > 1e-9 } ? weights : nil, color: color)]
        }
        if sp.nFit > 0 {
            let fpts = sp.fitPoints.map { yflip($0) }
            guard fpts.count > 1 else { return [] }
            return (0..<(fpts.count - 1)).map { .line(start: fpts[$0], end: fpts[$0 + 1], color: color) }
        }
        return []
    }

    // MARK: - Text

    private static func convertText(_ e: DXFEntity, color: ColorRGBA?) -> [CADPrimitive] {
        guard let tx = e as? DXFTextEntity else { return [] }
        let cleaned = cleanMTextFormatting(tx.text)
        let height = tx.height > 0 ? tx.height : 2.5
        let isText = e.eType == .tEXT
        let useSec = isText && (tx.alignH == 1 || tx.alignH == 2 || tx.alignH == 4 || tx.alignV != 0)
        let ref = useSec ? tx.secPoint : tx.basePoint
        var pos = yflip(ref)
        var angle = -tx.angle_p * .pi / 180.0
        if isText, abs(tx.extrusion.x) < 0.015625, abs(tx.extrusion.y) < 0.015625, tx.extrusion.z < 0 {
            pos = Vector3(x: -pos.x, y: pos.y, z: pos.z)
            angle = tx.angle_p * .pi / 180.0 - .pi
        }
        let isMText = e.eType == .mTEXT
        return [.text(position: pos, text: cleaned, height: height, rotation: angle,
                      style: tx.style, alignH: tx.alignH, alignV: tx.alignV,
                      mtextWidth: isMText && tx.widthScale > 0 ? tx.widthScale : nil, color: color)]
    }

    // MARK: - Hatch

    private static func convertHatch(_ e: DXFEntity, color: ColorRGBA?) -> [CADPrimitive] {
        guard let h = e as? DXFHatchEntity else { return [] }
        let (outerLoop, holes) = extractHatchBoundaries(from: h)
        let holesArr = holes.map { $0 }
        if h.isGradient == 1, !outerLoop.isEmpty {
            var c1 = color ?? .white; var c2 = ColorRGBA(r: UInt8(min(255, Int(c1.r) + 60)), g: UInt8(min(255, Int(c1.g) + 60)), b: UInt8(min(255, Int(c1.b) + 60)))
            if let gc = h.gradientColors.first, gc.rgb >= 0 { c1 = rgbToRGBA(gc.rgb) }
            if h.gradientColors.count > 1, h.gradientColors[1].rgb >= 0 { c2 = rgbToRGBA(h.gradientColors[1].rgb) }
            if c1 == c2 { return [.fillComplexPolygon(outer: outerLoop, holes: holesArr, color: c1)] }
            return [.gradient(outer: outerLoop, holes: holesArr, gradientName: h.gradientName,
                             angle: h.gradientAngle * .pi / 180.0, color1: c1, color2: c2)]
        }
        if h.solid == 1, !outerLoop.isEmpty {
            return [.fillComplexPolygon(outer: outerLoop, holes: holesArr, color: color)]
        }
        if !outerLoop.isEmpty {
            let background = h.bgColor >= 0 ? DXFColorTable.aciToRGBA(h.bgColor, color24: -1) : nil
            return [.hatch(boundary: outerLoop, pattern: h.name.isEmpty ? "SOLID" : h.name,
                          scale: h.scale > 0 ? h.scale : 1.0, angle: h.angle_p * .pi / 180.0,
                          color: color, backgroundColor: background)]
        }
        return []
    }

    /// Extract outer boundary and holes from a hatch entity's loops.
    /// Each loop may contain multiple boundary entities (lines, arcs, ellipses, splines, polylines).
    private static func extractHatchBoundaries(from h: DXFHatchEntity) -> (outer: [Vector3], holes: [[Vector3]]) {
        guard !h.loops.isEmpty else { return ([], []) }

        // Build polygon from all entities in a loop. Hatch edge order is not
        // guaranteed, so each edge is tessellated independently and then stitched
        // by matching nearest endpoints.
        func buildLoopPolygon(_ loop: DXFHatchLoop) -> [Vector3] {
            var edges: [[Vector3]] = []
            edges.reserveCapacity(loop.entities.count)

            for ent in loop.entities {
                var edge: [Vector3] = []
                if let lw = ent as? DXFLWPolylineEntity {
                    edge = hatchLWPolylineToPoints(lw)
                } else if let pl = ent as? DXFPolylineEntity {
                    edge = hatchPolylineToPoints(pl)
                } else if let line = ent as? DXFLineEntity {
                    edge = [yflip(line.basePoint), yflip(line.secPoint)]
                } else if let arc = ent as? DXFArcEntity {
                    edge = arcToPolyline(arc)
                } else if let ellipse = ent as? DXFEllipseEntity {
                    edge = ellipseToPolyline(ellipse)
                } else if let spline = ent as? DXFSplineEntity {
                    edge = splineToPolyline(spline)
                }

                edge = cleanAdjacentPoints(edge)
                if edge.count >= 2 { edges.append(edge) }
            }

            return cleanAdjacentPoints(stitchHatchEdges(edges))
        }

        let loops = h.loops.map { buildLoopPolygon($0) }.filter { $0.count >= 3 }
        guard !loops.isEmpty else { return ([], []) }

        // First non-empty loop is the outer boundary; rest are holes
        let outer = loops[0]
        let holes = Array(loops.dropFirst())
        return (outer, holes)
    }


    private static func hatchLWPolylineToPoints(_ polyline: DXFLWPolylineEntity) -> [Vector3] {
        guard !polyline.vertices.isEmpty else { return [] }
        let vertices = polyline.vertices.map {
            var bulge = -$0.bulge
            if !isDefaultExtrusion(polyline.extPoint) && polyline.extPoint.z < 0 { bulge = -bulge }
            return CADPolylineVertex(position: cadLWPoint($0, in: polyline),
                              bulge: bulge,
                              startWidth: $0.startWidth,
                              endWidth: $0.endWidth)
        }
        let path = CADPolyline(vertices: vertices, isClosed: (polyline.flags & 1) != 0)
        return path.hasBulges ? path.tessellatedPoints() : path.points
    }

    private static func hatchPolylineToPoints(_ polyline: DXFPolylineEntity) -> [Vector3] {
        guard !polyline.vertices.isEmpty else { return [] }
        let vertices = polyline.vertices.map {
            var bulge = -$0.bulge
            if polyline.haveExtrusion && polyline.extrusion.z < 0 { bulge = -bulge }
            return CADPolylineVertex(position: cadPolylinePoint($0, in: polyline),
                              bulge: bulge,
                              startWidth: $0.startWidth,
                              endWidth: $0.endWidth)
        }
        let path = CADPolyline(vertices: vertices, isClosed: (polyline.flags & 1) != 0)
        return path.hasBulges ? path.tessellatedPoints() : path.points
    }

    private static func stitchHatchEdges(_ edges: [[Vector3]]) -> [Vector3] {
        guard !edges.isEmpty else { return [] }
        var used = Array(repeating: false, count: edges.count)
        var out = edges[0]
        used[0] = true
        var usedCount = 1

        func distSq(_ a: Vector3, _ b: Vector3) -> Double {
            let dx = a.x - b.x
            let dy = a.y - b.y
            let dz = a.z - b.z
            return dx * dx + dy * dy + dz * dz
        }

        func appendEdge(_ edge: [Vector3]) {
            guard !edge.isEmpty else { return }
            if let tail = out.last, let first = edge.first, distSq(tail, first) < 1e-10 {
                out.append(contentsOf: edge.dropFirst())
            } else {
                out.append(contentsOf: edge)
            }
        }

        while usedCount < edges.count {
            guard let tail = out.last else { break }
            var bestIndex: Int?
            var reverse = false
            var bestDistance = Double.infinity

            for index in edges.indices where !used[index] && !edges[index].isEmpty {
                let edge = edges[index]
                let startDistance = distSq(tail, edge[0])
                if startDistance < bestDistance {
                    bestDistance = startDistance
                    bestIndex = index
                    reverse = false
                }
                if let end = edge.last {
                    let endDistance = distSq(tail, end)
                    if endDistance < bestDistance {
                        bestDistance = endDistance
                        bestIndex = index
                        reverse = true
                    }
                }
            }

            guard let index = bestIndex else { break }
            used[index] = true
            usedCount += 1
            if reverse {
                appendEdge(Array(edges[index].reversed()))
            } else {
                appendEdge(edges[index])
            }
        }

        return out
    }

    private static func cleanAdjacentPoints(_ points: [Vector3], toleranceSquared: Double = 1e-10) -> [Vector3] {
        var out: [Vector3] = []
        out.reserveCapacity(points.count)
        for point in points {
            if let last = out.last, nearlySamePoint(last, point, toleranceSquared: toleranceSquared) {
                continue
            }
            out.append(point)
        }
        if out.count > 1,
           let first = out.first,
           let last = out.last,
           nearlySamePoint(first, last, toleranceSquared: toleranceSquared) {
            out.removeLast()
        }
        return out
    }

    // MARK: - Boundary entity → polyline converters

    /// Convert an arc to a polyline approximation
    private static func arcToPolyline(_ arc: DXFArcEntity, segments: Int = 64) -> [Vector3] {
        guard arc.radius > 1e-12 else { return [] }
        let center = yflip(arc.basePoint)
        // Angles are in radians; CADPrimitive uses -endAngle/-startAngle convention
        let startAngle = -arc.endAngle
        let endAngle = -arc.startAngle
        var sweep = endAngle - startAngle
        if sweep < 0 { sweep += .pi * 2.0 }
        let n = max(segments, 3)
        var pts: [Vector3] = []
        for i in 0...n {
            let t = Double(i) / Double(n)
            let angle = startAngle + sweep * t
            pts.append(Vector3(x: center.x + arc.radius * cos(angle),
                              y: center.y + arc.radius * sin(angle), z: 0))
        }
        return pts
    }

    /// Convert an ellipse to a polyline approximation
    private static func ellipseToPolyline(_ ellipse: DXFEllipseEntity, segments: Int = 64) -> [Vector3] {
        let center = yflip(ellipse.basePoint)
        let rawMajor = Vector3(x: ellipse.secPoint.x, y: ellipse.secPoint.y, z: ellipse.secPoint.z)
        let majorLen = rawMajor.magnitude
        let minorLen = majorLen * ellipse.ratio
        guard majorLen > 1e-12, minorLen > 1e-12 else { return [] }
        let startP = ellipse.startParam
        let endP = ellipse.endParam
        let isFull = abs(abs(endP - startP) - .pi * 2) < 1e-5 || abs(endP - startP) < 1e-5
        var sweep = endP - startP
        if sweep < 0 && !isFull { sweep += .pi * 2.0 }
        let angle = atan2(rawMajor.y, rawMajor.x)
        let cosR = cos(angle)
        let sinR = sin(angle)
        let n = max(segments, 3)
        var pts: [Vector3] = []
        for i in 0...n {
            let t = Double(i) / Double(n)
            let param = startP + sweep * t
            let px = majorLen * cos(param)
            let py = minorLen * sin(param)
            let rx = px * cosR - py * sinR
            let ry = px * sinR + py * cosR
            pts.append(Vector3(x: center.x + rx, y: center.y - ry, z: center.z))
        }
        return pts
    }

    /// Convert a spline to a polyline approximation using control points
    private static func splineToPolyline(_ spline: DXFSplineEntity, segments: Int = 64) -> [Vector3] {
        let degree = spline.degree > 0 ? spline.degree : 3
        let knots = spline.knots
        var cps: [Vector3]

        if spline.nControl > 0, !spline.controlPoints.isEmpty {
            cps = spline.controlPoints.map { yflip($0) }
        } else if spline.nFit > 0, !spline.fitPoints.isEmpty {
            return spline.fitPoints.map { yflip($0) }
        } else {
            return []
        }

        var weights = normalizedSplineWeights(spline.weights, controlCount: cps.count)
        let expectedControlCount = knots.count - degree - 1
        if expectedControlCount > cps.count, !cps.isEmpty {
            let baseCPs = cps
            let baseWeights = weights
            for i in 0..<(expectedControlCount - cps.count) {
                cps.append(baseCPs[i % baseCPs.count])
                weights.append(baseWeights[i % baseWeights.count])
            }
        }

        guard degree >= 1, cps.count > degree, knots.count == cps.count + degree + 1 else {
            return cps.count > 1 ? cps : []
        }

        var pts = NURBSEvaluator.evaluateAdaptiveByKnotSpans(
            degree: degree,
            knots: knots,
            controlPoints: cps,
            weights: weights,
            chordTolerance: 0.01,
            maxDepth: 10,
            maxSegments: max(512, segments * 16)
        )

        if pts.count < 2 {
            pts = NURBSEvaluator.evaluateByKnotSpans(
                degree: degree,
                knots: knots,
                controlPoints: cps,
                weights: weights,
                segmentsPerSpan: 12
            )
        }

        if ((spline.flags & 1) != 0 || (spline.flags & 2) != 0),
           let first = pts.first, let last = pts.last,
           !nearlySamePoint(first, last) {
            pts.append(first)
        }

        return pts
    }

    private static func normalizedSplineWeights(_ raw: [Double], controlCount: Int) -> [Double] {
        guard controlCount > 0 else { return [] }
        if raw.count == controlCount {
            return raw.map { $0.isFinite && $0 > 0 ? $0 : 1.0 }
        }
        if raw.isEmpty {
            return Array(repeating: 1.0, count: controlCount)
        }
        var out = raw.prefix(controlCount).map { $0.isFinite && $0 > 0 ? $0 : 1.0 }
        while out.count < controlCount { out.append(1.0) }
        return out
    }

    private static func nearlySamePoint(_ a: Vector3, _ b: Vector3, toleranceSquared: Double = 1e-12) -> Bool {
        (a - b).magnitudeSquared <= toleranceSquared
    }

    // MARK: - Leader

    private static func convertLeader(_ e: DXFEntity, arrowSize: Double, color: ColorRGBA?) -> [CADPrimitive] {
        guard let ld = e as? DXFLeaderEntity, ld.vertices.count >= 2 else { return [] }
        let pts = ld.vertices.map { yflip($0) }
        var prims: [CADPrimitive] = []
        if ld.arrow != 0 {
            let v0 = pts[0]; let v1 = pts[1]
            let dir = (v1 - v0).normalized; let len = min(arrowSize, v0.distance(to: v1) * 0.5)
            let perp = Vector3(x: -dir.y, y: dir.x, z: 0); let wing = len * 0.25
            let tip = v0 + dir * len
            prims.append(.fillPolygon(points: [v0, tip + perp * wing, tip - perp * wing], color: color))
            prims.append(.line(start: tip, end: v1, color: color))
        }
        for i in (ld.arrow != 0 ? 1 : 0)..<(pts.count - 1) {
            prims.append(.line(start: pts[i], end: pts[i + 1], color: color))
        }
        return prims
    }

    // MARK: - Image

    private static func convertImage(_ e: DXFEntity, color: ColorRGBA?) -> [CADPrimitive] {
        guard let img = e as? DXFImageEntity else { return [] }
        let ins = yflip(img.basePoint)
        let u = yflip(img.secPoint) * (img.sizeU > 0 ? img.sizeU : 1.0)
        let v = yflip(img.vVector) * (img.sizeV > 0 ? img.sizeV : 1.0)
        return [.image(insertion: ins, uAxis: u, vAxis: v,
                      imageName: String(format: "%X", img.ref), clipBoundary: nil, tint: nil)]
    }

    // MARK: - Helpers

    private static func resolveEntityColor(_ e: DXFEntity) -> ColorRGBA? {
        if e.color24 >= 0 || (e.color > 0 && e.color < 256) {
            return DXFColorTable.aciToRGBA(e.color, color24: e.color24)
        }
        return nil
    }

    public static func cleanMTextFormatting(_ text: String) -> String {
        var clean = ""; var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]; let nextI = text.index(after: i)
            guard nextI < text.endIndex else { clean.append(c); break }
            let next = text[nextI]
            if c == "\\" || c == "¥" {
                switch next {
                case "P": clean.append("\n"); i = text.index(after: nextI)
                case "L", "l": clean.append("%%u"); i = text.index(after: nextI)
                case "O", "o": i = text.index(after: nextI)
                case "\\", "¥", "{", "}": clean.append(String(next)); i = text.index(after: nextI)
                default:
                    if Set("fFcChHsStTwWaAqQp").contains(next) {
                        var j = text.index(after: nextI)
                        while j < text.endIndex, text[j] != ";" { j = text.index(after: j) }
                        i = j < text.endIndex ? text.index(after: j) : text.endIndex
                    } else { i = nextI }
                }
            } else if c == "{" || c == "}" { i = nextI }
            else { clean.append(c); i = nextI }
        }
        return clean
    }

    private static func simplifyIfNeeded(_ path: CADPolyline) -> CADPolyline {
        guard simplifyPolylines, !path.hasBulges, path.vertices.count > 200 else { return path }
        let bb = BoundingBox3D(from: path.points)
        let diag = max(bb.size.x, bb.size.y); let tol = max(diag * 0.002, 0.01)
        var simplified = rdp(path.points, tolerance: tol)
        let minPts = path.isClosed ? 3 : 2
        if simplified.count < minPts {
            simplified = path.isClosed ? [bb.min, Vector3(x: bb.max.x, y: bb.min.y), bb.max, Vector3(x: bb.min.x, y: bb.max.y)]
                                       : [path.points.first!, path.points.last!]
        }
        return CADPolyline(points: simplified, isClosed: path.isClosed, lineTypeGenerationEnabled: path.lineTypeGenerationEnabled)
    }

    internal static func rdp(_ pts: [Vector3], tolerance: Double) -> [Vector3] {
        guard pts.count > 2 else { return pts }
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true; keep[pts.count - 1] = true
        func perpDist(_ p: Vector3, _ a: Vector3, _ b: Vector3) -> Double {
            let ab = b - a; let ap = p - a
            let len2 = ab.x * ab.x + ab.y * ab.y
            guard len2 > 1e-12 else { return p.distance(to: a) }
            let t = max(0, min(1, (ap.x * ab.x + ap.y * ab.y) / len2))
            return p.distance(to: a + ab * t)
        }
        func simplify(_ start: Int, _ end: Int) {
            guard end > start + 1 else { return }
            var maxDist = 0.0; var maxIdx = start
            for i in (start + 1)..<end {
                let d = perpDist(pts[i], pts[start], pts[end])
                if d > maxDist { maxDist = d; maxIdx = i }
            }
            if maxDist > tolerance { keep[maxIdx] = true; simplify(start, maxIdx); simplify(maxIdx, end) }
        }
        simplify(0, pts.count - 1)
        return pts.enumerated().compactMap { keep[$0.offset] ? $0.element : nil }
    }

    private static func cadLWPoint(_ vertex: DXFVertex2D, in polyline: DXFLWPolylineEntity) -> Vector3 {
        let raw = SwiftDXFrw.Vector3(x: vertex.x, y: vertex.y, z: polyline.elevation)
        let extrusion = isDefaultExtrusion(polyline.extPoint) ? nil : polyline.extPoint
        return cadPoint(raw, extrusion: extrusion)
    }

    private static func cadPolylinePoint(_ vertex: DXFVertexEntity, in polyline: DXFPolylineEntity) -> Vector3 {
        cadPoint(vertex.basePoint, extrusion: polyline.haveExtrusion ? polyline.extrusion : nil)
    }

    private static func cadPoint(_ point: SwiftDXFrw.Vector3, extrusion: SwiftDXFrw.Vector3?) -> Vector3 {
        guard let extrusion, !isDefaultExtrusion(extrusion) else { return yflip(point) }
        return yflip(ocsToWcs(point, extrusion: extrusion))
    }

    private static func isDefaultExtrusion(_ n: SwiftDXFrw.Vector3) -> Bool {
        abs(n.x) < 1e-12 && abs(n.y) < 1e-12 && abs(n.z - 1.0) < 1e-12
    }

    private static func ocsToWcs(_ point: SwiftDXFrw.Vector3, extrusion n: SwiftDXFrw.Vector3) -> SwiftDXFrw.Vector3 {
        var az = n
        var mag = sqrt(az.x * az.x + az.y * az.y + az.z * az.z)
        if mag < 1e-12 {
            az = SwiftDXFrw.Vector3(x: 0, y: 0, z: 1)
            mag = 1.0
        }
        az.x /= mag; az.y /= mag; az.z /= mag

        var ax: SwiftDXFrw.Vector3
        if abs(az.x) < 0.015625 && abs(az.y) < 0.015625 {
            ax = SwiftDXFrw.Vector3(x: az.z, y: 0, z: -az.x)
        } else {
            ax = SwiftDXFrw.Vector3(x: -az.y, y: az.x, z: 0)
        }
        mag = sqrt(ax.x * ax.x + ax.y * ax.y + ax.z * ax.z)
        if mag > 1e-12 { ax.x /= mag; ax.y /= mag; ax.z /= mag }

        var ay = SwiftDXFrw.Vector3(
            x: az.y * ax.z - az.z * ax.y,
            y: az.z * ax.x - az.x * ax.z,
            z: az.x * ax.y - az.y * ax.x)
        mag = sqrt(ay.x * ay.x + ay.y * ay.y + ay.z * ay.z)
        if mag > 1e-12 { ay.x /= mag; ay.y /= mag; ay.z /= mag }

        return SwiftDXFrw.Vector3(
            x: ax.x * point.x + ay.x * point.y + az.x * point.z,
            y: ax.y * point.x + ay.y * point.y + az.y * point.z,
            z: ax.z * point.x + ay.z * point.y + az.z * point.z)
    }

    /// Convert SwiftDXFrw.Vector3 → ZephyrCore.Vector3 with Y-flip
    private static func yflip(_ v: SwiftDXFrw.Vector3) -> Vector3 {
        Vector3(x: v.x, y: -v.y, z: v.z)
    }

    private static func rgbToRGBA(_ rgb: Int32) -> ColorRGBA {
        ColorRGBA(r: UInt8((rgb >> 16) & 0xFF), g: UInt8((rgb >> 8) & 0xFF), b: UInt8(rgb & 0xFF))
    }
}