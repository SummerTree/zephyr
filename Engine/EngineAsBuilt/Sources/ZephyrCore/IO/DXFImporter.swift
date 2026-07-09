import Foundation
import SwiftDXFrw

// =========================================================================
// MARK: - DXFImporter
// Pure Swift DXF import via SwiftDXFrw.
// =========================================================================

public enum DXFDrawingViewKind: Sendable, Equatable { case model, sheet }

public struct DXFDrawingView: Sendable {
    public let name: String; public let kind: DXFDrawingViewKind; public let entities: [CADEntity]
    public init(name: String, kind: DXFDrawingViewKind, entities: [CADEntity]) {
        self.name = name; self.kind = kind; self.entities = entities
    }
}

public struct DXFImportResult: Sendable {
    public let layers: [Layer]; public let blocks: [CADBlock]; public let entities: [CADEntity]
    public let textStyleFonts: [String: String]; public let linetypePatterns: [String: [Double]]
    public let views: [DXFDrawingView]
    public init(layers: [Layer], blocks: [CADBlock], entities: [CADEntity],
                textStyleFonts: [String: String], linetypePatterns: [String: [Double]],
                views: [DXFDrawingView]) {
        self.layers = layers; self.blocks = blocks; self.entities = entities
        self.textStyleFonts = textStyleFonts; self.linetypePatterns = linetypePatterns
        self.views = views
    }
}

public enum DXFImporter {

    public static func importDXF(filePath: String) throws -> (layers: [Layer], blocks: [CADBlock], entities: [CADEntity], textStyleFonts: [String: String], linetypePatterns: [String: [Double]]) {
        let result = try importDXFViews(filePath: filePath)
        return (result.layers, result.blocks, result.entities, result.textStyleFonts, result.linetypePatterns)
    }

    public static func importDXFViews(filePath: String) throws -> DXFImportResult {
        let reader = DXFReader()
        _ = try reader.readFile(at: filePath)
        return convertDXFToCAD(reader: reader)
    }

    private static func convertDXFToCAD(reader: DXFReader) -> DXFImportResult {
        var layers: [Layer] = []; var layerNameToID: [String: UUID] = [:]; var layerStyleByName: [String: Layer] = [:]

        for table in reader.layers {
            let handle = UUID(); let name = table.name
            layerNameToID[name] = handle
            let color = DXFColorTable.aciToRGBA(table.color, color24: table.color24)
            layers.append(Layer(handle: handle, name: name, isVisible: true,
                               lineWeight: 0.25, color: color, lineType: table.lineType, opacity: 1.0))
            layerStyleByName[name] = layers.last!
        }
        if layerNameToID["0"] == nil {
            let h = UUID(); layerNameToID["0"] = h
            let l0 = Layer(handle: h, name: "0", isVisible: true, lineWeight: 0.25, color: .white)
            layers.append(l0); layerStyleByName["0"] = l0
        }

        var blocks: [CADBlock] = []
        for block in reader.blocks {
            let handle = UUID()
            blocks.append(CADBlock(handle: handle, name: block.name, geometry: []))
        }

        var looseEntities: [CADEntity] = []
        for (i, entity) in reader.entities.enumerated() {
            let layerName = entity.layer.isEmpty ? "0" : entity.layer
            let layerID = layerNameToID[layerName] ?? layerNameToID["0"]!
            let prims = DXFEntityConverter.convertEntityToPrimitives(entity)
            var cadEnt = CADEntity(handle: UUID(), layerID: layerID, blockID: nil,
                                   localGeometry: prims, transform: .identity)
            cadEnt.drawOrder = i
            looseEntities.append(cadEnt)
        }

        return DXFImportResult(layers: layers, blocks: blocks, entities: looseEntities,
                              textStyleFonts: [:], linetypePatterns: [:],
                              views: [DXFDrawingView(name: "Model", kind: .model, entities: looseEntities)])
    }
}
