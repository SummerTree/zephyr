import Foundation
import CDWG

// =========================================================================
// MARK: - DWGExporter
//
// Exports a Zephyr CAD document to native AutoCAD DWG format
// via LibreDWG's dwg_write_file().
//
// Converts CAD entities to the DWG bridge format, then uses
// the LibreDWG C API to write a binary DWG file.

// =========================================================================
// MARK: - DWGExportError
// =========================================================================

public enum DWGExportError: Error, LocalizedError {
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .writeFailed(let msg): return "DWG write failed: \(msg)"
        }
    }
}

// =========================================================================
// MARK: - DWGExporter
// =========================================================================

public enum DWGExporter {

    /// DWG version codes (see dwg.h DWG_VERSION_*)
    public static let dwgVersionR2000: Int32 = 14   // AC1015
    public static let dwgVersionR2004: Int32 = 18   // AC1018
    public static let dwgVersionR2007: Int32 = 21   // AC1021
    public static let dwgVersionR2010: Int32 = 24   // AC1024

    // MARK: - Public API

    /// Export the document to a native DWG file at the given URL.
    /// - Parameters:
    ///   - document: The CAD document to export.
    ///   - url: Destination file URL (.dwg).
    ///   - version: DWG version code (default: R2000 for maximum compatibility).
    /// - Throws: `DWGExportError` if writing fails.
    public static func export(document: CADDocument, to url: URL,
                               version: Int32 = dwgVersionR2000) throws {

        var bridgeEntities: [DWG_EntityData] = []
        bridgeEntities.reserveCapacity(document.entityCount)

        for entity in document.allEntities {
            var bridge = DWG_EntityData()
            convertToBridge(entity: entity, document: document, into: &bridge)
            bridgeEntities.append(bridge)
        }

        // Write via LibreDWG bridge
        var errorMsg: UnsafeMutablePointer<CChar>? = nil
        let ok = bridgeEntities.withUnsafeMutableBufferPointer { buf in
            dwg_bridge_write(url.path, buf.baseAddress, Int32(buf.count), version, &errorMsg)
        }

        guard ok != 0 else {
            let msg = errorMsg.map { String(cString: $0) } ?? "Unknown error"
            if let em = errorMsg { free(em) }
            throw DWGExportError.writeFailed(msg)
        }
    }

    /// Export from a snapshot.
    public static func export(snapshot: CADDocumentSnapshot, to url: URL,
                               progress: ((Float) -> Void)? = nil,
                               version: Int32 = dwgVersionR2000) throws {
        let tempDoc = CADDocument()
        tempDoc.restore(from: snapshot)
        try export(document: tempDoc, to: url, version: version)
    }

    // MARK: - Entity Conversion

    private static func convertToBridge(entity: CADEntity, document: CADDocument,
                                         into bridge: inout DWG_EntityData) {
        bridge = DWG_EntityData()

        // Layer
        if let layer = document.layer(for: entity.layerID) {
            bridge.layerName = z_strdup(layer.name)
        }

        // Color
        if let colorACI = entity.xdata["dxf.color"], case .int(let aci) = colorACI {
            bridge.color = Int32(aci)
        } else {
            bridge.color = 256  // ByLayer
        }
        bridge.colorRGB = -1

        // Line weight
        if let lw = entity.xdata["dxf.lineWeight"], case .double(let w) = lw {
            bridge.lineWeight = w
        } else {
            bridge.lineWeight = -1  // ByLayer
        }

        // Get geometry
        let primitives: [CADPrimitive]
        if let bid = entity.blockID, let block = document.block(for: bid) {
            primitives = block.geometry
            bridge.blockName = z_strdup(block.name)
            bridge.type = DWG_ET_INSERT
            bridge.basePoint.x = entity.transform.position.x
            bridge.basePoint.y = entity.transform.position.y
            bridge.basePoint.z = entity.transform.position.z
            bridge.xscale = entity.transform.scale.x
            bridge.yscale = entity.transform.scale.y
            bridge.zscale = entity.transform.scale.z
            bridge.insertAngle = entity.transform.rotation
            bridge.colCount = 1
            bridge.rowCount = 1
            bridge.colSpace = 0
            bridge.rowSpace = 0
            return
        } else {
            primitives = entity.localGeometry ?? []
        }

        // Determine type from first primitive
        guard let first = primitives.first else { return }

        switch first {
        case .line(let start, let end, _):
            bridge.type = DWG_ET_LINE
            bridge.basePoint.x = start.x; bridge.basePoint.y = start.y; bridge.basePoint.z = start.z
            bridge.secPoint.x = end.x; bridge.secPoint.y = end.y; bridge.secPoint.z = end.z

        case .circle(let center, let radius, _):
            bridge.type = DWG_ET_CIRCLE
            bridge.basePoint.x = center.x; bridge.basePoint.y = center.y; bridge.basePoint.z = center.z
            bridge.radius = radius

        case .arc(let center, let radius, let startAngle, let endAngle, _):
            bridge.type = DWG_ET_ARC
            bridge.basePoint.x = center.x; bridge.basePoint.y = center.y; bridge.basePoint.z = center.z
            bridge.radius = radius
            bridge.startAngle = startAngle
            bridge.endAngle = endAngle

        case .point(let position, _):
            bridge.type = DWG_ET_POINT
            bridge.basePoint.x = position.x; bridge.basePoint.y = position.y; bridge.basePoint.z = position.z

        case .text(let position, let text, let height, let rotation, let style, let alignH, let alignV, _, _):
            bridge.type = DWG_ET_TEXT
            bridge.basePoint.x = position.x; bridge.basePoint.y = position.y; bridge.basePoint.z = position.z
            bridge.textHeight = height
            bridge.textRotation = rotation
            bridge.textAlignH = Int32(alignH)
            bridge.textAlignV = Int32(alignV)
            bridge.textValue = z_strdup(text)
            if let s = style { bridge.textStyle = z_strdup(s) }

        case .polyline(let path, _):
            bridge.type = DWG_ET_LWPOLYLINE
            bridge.polyFlags = path.isClosed ? 1 : 0
            let count = path.vertices.count
            bridge.vertexCount2D = Int32(count)
            bridge.vertices2D = UnsafeMutablePointer<DWG_Vertex2D>.allocate(capacity: count)
            bridge.vertices2D?.initialize(repeating: DWG_Vertex2D(), count: count)
            for i in 0..<count {
                bridge.vertices2D?[i] = DWG_Vertex2D(
                    x: path.vertices[i].position.x,
                    y: path.vertices[i].position.y,
                    bulge: path.vertices[i].bulge
                )
            }

        case .fillPolygon, .polygon:
            // Convert filled polygon to SOLID (always 4 vertices)
            bridge.type = DWG_ET_SOLID
            let pts = first.points
            if pts.count >= 4 {
                bridge.basePoint.x = pts[0].x; bridge.basePoint.y = pts[0].y; bridge.basePoint.z = pts[0].z
                bridge.secPoint.x = pts[1].x; bridge.secPoint.y = pts[1].y; bridge.secPoint.z = pts[1].z
                bridge.thirdPoint.x = pts[2].x; bridge.thirdPoint.y = pts[2].y; bridge.thirdPoint.z = pts[2].z
                bridge.fourPoint.x = pts[3].x; bridge.fourPoint.y = pts[3].y; bridge.fourPoint.z = pts[3].z
            } else if pts.count >= 3 {
                bridge.basePoint.x = pts[0].x; bridge.basePoint.y = pts[0].y; bridge.basePoint.z = pts[0].z
                bridge.secPoint.x = pts[1].x; bridge.secPoint.y = pts[1].y; bridge.secPoint.z = pts[1].z
                bridge.thirdPoint.x = pts[2].x; bridge.thirdPoint.y = pts[2].y; bridge.thirdPoint.z = pts[2].z
                bridge.fourPoint.x = pts[2].x; bridge.fourPoint.y = pts[2].y; bridge.fourPoint.z = pts[2].z
            }

        default:
            bridge.type = DWG_ET_UNKNOWN
        }

        // Apply entity transform
        applyTransform(entity.transform, to: &bridge)
    }

    private static func applyTransform(_ t: Transform3D, to bridge: inout DWG_EntityData) {
        let pos = t.position
        bridge.basePoint.x += pos.x
        bridge.basePoint.y += pos.y
        bridge.basePoint.z += pos.z

        if bridge.type == DWG_ET_LINE || bridge.type == DWG_ET_ARC || bridge.type == DWG_ET_CIRCLE {
            bridge.secPoint.x += pos.x
            bridge.secPoint.y += pos.y
            bridge.secPoint.z += pos.z
        }
    }
}

// Helper to get points from CADPrimitive
private extension CADPrimitive {
    var points: [Vector3] {
        switch self {
        case .line(let s, let e, _): return [s, e]
        case .point(let p, _): return [p]
        case .fillPolygon(let pts, _): return pts
        case .polygon(let pts, _): return pts
        default: return []
        }
    }
}
