import Foundation
import SwiftDXFrw

/// Converts Zephyr CAD types to DXF format using pure Swift DXFWriter.
public enum DXFWriterBridge {

    /// Export a full CADDocument to DXF (convenience)
    public static func export(document: CADDocument, to url: URL) throws {
        try exportToDXF(layers: document.allLayers, blocks: document.allBlocks,
                       entities: document.allEntities, filePath: url.path)
    }

    public static func exportToDXF(
        layers: [Layer], blocks: [CADBlock], entities: [CADEntity],
        filePath: String, dxfVersion: DXFVersion = .r2000
    ) throws {
        let writer = DXFWriter(); writer.version = dxfVersion

        for layer in layers {
            let dl = DXFLayerEntry()
            dl.name = layer.name; dl.lineType = layer.lineType; dl.plotFlag = layer.isVisible
            dl.color = DXFColorTable.rgbaToACI(layer.color)
            dl.color24 = DXFColorTable.rgbaToTrueColor(layer.color) ?? -1
            writer.addLayer(dl)
        }

        for entity in entities {
            guard let primitives = entity.localGeometry else { continue }
            let layerName = layers.first(where: { $0.handle == entity.layerID })?.name ?? "0"
            for prim in primitives {
                if var dxfEnt = primitiveToEntity(prim) {
                    dxfEnt.layer = layerName
                    applyTransform(entity.transform, to: &dxfEnt)
                    writer.addEntity(dxfEnt)
                }
            }
        }

        try writer.write(to: filePath)
    }

    // MARK: - Primitive → DXFEntity (ZephyrCore.Vector3 → SwiftDXFrw.Vector3)

    private static func primitiveToEntity(_ p: CADPrimitive) -> DXFEntity? {
        switch p {
        case .point(let pos, _):
            return DXFPointEntity().with { $0.basePoint = toDXF(pos) }
        case .line(let s1, let e1, _):
            return DXFLineEntity().with { $0.basePoint = toDXF(s1); $0.secPoint = toDXF(e1) }
        case .circle(let c, let r, _):
            return DXFCircleEntity().with { $0.basePoint = toDXF(c); $0.radius = r }
        case .arc(let c, let r, let sa, let ea, _):
            return DXFArcEntity().with { $0.basePoint = toDXF(c); $0.radius = r; $0.startAngle = sa; $0.endAngle = ea }
        case .polygon(let pts, _):
            let lw = DXFLWPolylineEntity(); lw.flags = 1
            for pt in pts { let v = DXFVertex2D(); v.x = pt.x; v.y = pt.y; lw.vertices.append(v) }
            return lw
        case .polyline(let path, _):
            let lw = DXFLWPolylineEntity()
            for v in path.vertices {
                let dv = DXFVertex2D(); dv.x = v.position.x; dv.y = v.position.y
                dv.bulge = v.bulge; dv.startWidth = v.startWidth; dv.endWidth = v.endWidth
                lw.vertices.append(dv)
            }
            lw.flags = path.isClosed ? 1 : 0; return lw
        case .text(let pos, let txt, let ht, let rot, let st, let ah, let av, _, _):
            let t = DXFTextEntity()
            t.basePoint = toDXF(pos); t.text = txt; t.height = ht; t.angle_p = rot * 180.0 / .pi
            t.style = st ?? "STANDARD"; t.alignH = ah; t.alignV = av; return t
        case .spline(let cps, let knots, let deg, let weights, _):
            let sp = DXFSplineEntity()
            sp.controlPoints = cps.map { toDXF($0) }; sp.knots = knots; sp.degree = deg
            sp.weights = weights ?? []; sp.nControl = Int32(cps.count); sp.nKnots = Int32(knots.count)
            return sp
        case .ellipse(let c, let maj, let ratio, _):
            let el = DXFEllipseEntity(); el.basePoint = toDXF(c); el.secPoint = toDXF(maj); el.ratio = ratio; return el
        case .ray(let s1, let d, _):
            let r = DXFRayEntity(); r.basePoint = toDXF(s1); r.secPoint = toDXF(d); return r
        case .hatch(let boundary, let pattern, let scale, let angle, _, _):
            let h = DXFHatchEntity(); h.name = pattern; h.scale = scale; h.angle_p = angle
            h.solid = pattern.uppercased() == "SOLID" ? 1 : 0
            let loop = DXFHatchLoop(type: 0); let pl = DXFLWPolylineEntity()
            for pt in boundary { let v = DXFVertex2D(); v.x = pt.x; v.y = pt.y; pl.vertices.append(v) }
            loop.entities.append(pl); h.loops.append(loop); return h
        case .hatchPath(let boundary, _, let pattern, let scale, let angle, _, _):
            let h = DXFHatchEntity(); h.name = pattern; h.scale = scale; h.angle_p = angle
            h.solid = pattern.uppercased() == "SOLID" ? 1 : 0
            let loop = DXFHatchLoop(type: 0); let pl = DXFLWPolylineEntity()
            for vertex in boundary.vertices {
                let v = DXFVertex2D(); v.x = vertex.position.x; v.y = vertex.position.y; v.bulge = vertex.bulge; pl.vertices.append(v)
            }
            pl.flags = boundary.isClosed ? 1 : 0
            loop.entities.append(pl); h.loops.append(loop); return h
        case .fillPolygon(let pts, _):
            let s = DXFSolidEntity()
            if pts.count >= 1 { s.basePoint = toDXF(pts[0]) }
            if pts.count >= 2 { s.secPoint = toDXF(pts[1]) }
            if pts.count >= 3 { s.thirdPoint = toDXF(pts[2]) }
            if pts.count >= 4 { s.fourPoint = toDXF(pts[3]) }
            return s
        case .fillComplexPolygon(let outer, _, _):
            let h = DXFHatchEntity(); h.name = "SOLID"; h.solid = 1
            let loop = DXFHatchLoop(type: 1); let pl = DXFLWPolylineEntity()
            for pt in outer { let v = DXFVertex2D(); v.x = pt.x; v.y = pt.y; pl.vertices.append(v) }
            loop.entities.append(pl); h.loops.append(loop); return h
        default: return nil
        }
    }

    /// Convert ZephyrCore.Vector3 → SwiftDXFrw.Vector3
    private static func toDXF(_ v: Vector3) -> SwiftDXFrw.Vector3 {
        SwiftDXFrw.Vector3(x: v.x, y: v.y, z: v.z)
    }

    private static func applyTransform(_ t: Transform3D, to e: inout DXFEntity) {
        if let pt = e as? DXFPointEntity { pt.basePoint = toDXF(t.transformPoint(z(pt.basePoint))) }
        if let ln = e as? DXFLineEntity {
            ln.basePoint = toDXF(t.transformPoint(z(ln.basePoint)))
            ln.secPoint = toDXF(t.transformPoint(z(ln.secPoint)))
        }
        if let ci = e as? DXFCircleEntity { ci.basePoint = toDXF(t.transformPoint(z(ci.basePoint))) }
        if let a = e as? DXFArcEntity { a.basePoint = toDXF(t.transformPoint(z(a.basePoint))) }
        if let lw = e as? DXFLWPolylineEntity {
            for v in lw.vertices {
                let p = t.transformPoint(Vector3(x: v.x, y: v.y, z: 0))
                v.x = p.x; v.y = p.y
            }
        }
        if let tx = e as? DXFTextEntity { tx.basePoint = toDXF(t.transformPoint(z(tx.basePoint))) }
        if let sp = e as? DXFSplineEntity {
            sp.controlPoints = sp.controlPoints.map { toDXF(t.transformPoint(z($0))) }
            sp.fitPoints = sp.fitPoints.map { toDXF(t.transformPoint(z($0))) }
        }
        if let el = e as? DXFEllipseEntity { el.basePoint = toDXF(t.transformPoint(z(el.basePoint))) }
        if let ry = e as? DXFRayEntity { ry.basePoint = toDXF(t.transformPoint(z(ry.basePoint))) }
    }

    /// Convert SwiftDXFrw.Vector3 → ZephyrCore.Vector3
    private static func z(_ v: SwiftDXFrw.Vector3) -> Vector3 {
        Vector3(x: v.x, y: v.y, z: v.z)
    }
}

// MARK: - Helper: configurable entity
private protocol With {}
extension DXFEntity: With {}
extension With where Self: DXFEntity {
    func with(_ configure: (inout Self) -> Void) -> Self {
        var copy = self; configure(&copy); return copy
    }
}