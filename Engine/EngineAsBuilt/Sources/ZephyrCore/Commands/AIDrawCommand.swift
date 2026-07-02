import Foundation
import CSDL3
import ImGui
import SwiftSDL

@MainActor
public final class AIDrawCommand: FeatureCommand {
    private enum State {
        case waitingForPrompt
        case processing
        case previewReady
        case finished
    }

    private var state: State = .waitingForPrompt
    private var initialPrompt: String?
    private var promptText: String = ""
    private var plan: AIDrawingClient.DrawingPlanJSON?
    private var previewPrimitives: [CADPrimitive] = []
    private var previewEntities: [CADEntity] = []
    private var errorText: String?

    public init(initialPrompt: String? = nil) {
        self.initialPrompt = initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isSnappingEnabled: Bool { false }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        state = .waitingForPrompt
        plan = nil
        previewPrimitives.removeAll()
        previewEntities.removeAll()
        errorText = nil
        if let initialPrompt, !initialPrompt.isEmpty {
            run(prompt: initialPrompt, engine: engine, processor: processor)
        } else {
            processor.commandPrompt = "AIDRAW: describe what to draw, then press Enter."
        }
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        state = .finished
        plan = nil
        previewPrimitives.removeAll()
        previewEntities.removeAll()
    }

    public func handleMouseClick(worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor) -> CommandResult {
        .handled
    }

    public func handleMouseMotion(worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor) {}

    public func handleKeyDown(scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor) -> CommandResult {
        switch state {
        case .previewReady:
            if scancode == SDL_SCANCODE_RETURN || scancode == SDL_SCANCODE_KP_ENTER {
                commit(engine: engine, processor: processor)
                return .finished
            }
            if scancode == SDL_SCANCODE_ESCAPE {
                processor.commandPrompt = "AIDRAW cancelled."
                return .finished
            }
            return .handled
        case .processing:
            return .handled
        default:
            return .continue
        }
    }

    public func handleCommandText(_ text: String, engine: PhrostEngine, processor: CADCommandProcessor) -> CommandResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch state {
        case .waitingForPrompt:
            guard !trimmed.isEmpty else { return .handled }
            run(prompt: trimmed, engine: engine, processor: processor)
            return .handled
        case .previewReady:
            let upper = trimmed.uppercased()
            if upper == "Y" || upper == "YES" || upper == "APPLY" || upper == "COMMIT" || upper == "OK" {
                commit(engine: engine, processor: processor)
                return .finished
            }
            if upper == "N" || upper == "NO" || upper == "CANCEL" || upper == "DISCARD" {
                processor.commandPrompt = "AIDRAW cancelled."
                return .finished
            }
            processor.commandPrompt = "Type APPLY to create the previewed geometry, or CANCEL to discard."
            return .handled
        case .processing:
            return .handled
        case .finished:
            return .finished
        }
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        guard state == .previewReady else { return }
        let drawList = igGetForegroundDrawList_ViewportPtr(nil)
        let col = makeCol32(0, 220, 255, 220)
        let fillCol = makeCol32(0, 220, 255, 35)
        for prim in previewPrimitives {
            drawPrimitive(prim, cam: cam, drawList: drawList, color: col, fillColor: fillCol)
        }
    }

    public func renderImGui(engine: PhrostEngine) {
        guard state == .processing || state == .previewReady || errorText != nil else { return }
        var open = true
        ImGuiSetNextWindowSize(ImVec2(x: 360, y: 0), Int32(ImGuiCond_FirstUseEver.rawValue))
        if igBegin("AI Draw", &open, Int32(ImGuiWindowFlags_AlwaysAutoResize.rawValue)) {
            switch state {
            case .processing:
                ImGuiTextV("Generating CAD preview...")
            case .previewReady:
                ImGuiTextV("Preview ready")
                ImGuiTextV("Operations: \(plan?.operations.count ?? 0)")
                ImGuiTextV("Type APPLY or press Enter to create geometry.")
                ImGuiTextV("Type CANCEL or press Esc to discard.")
            default:
                break
            }
            if let errorText {
                igSeparator()
                ImGuiTextV("\(errorText)")
            }
        }
        igEnd()
    }

    private func run(prompt: String, engine: PhrostEngine, processor: CADCommandProcessor) {
        promptText = prompt
        state = .processing
        processor.commandPrompt = "AIDRAW: generating preview..."
        let config = engine.aiSelectConfig
        let context = makeContext(engine: engine)
        Task {
            do {
                let client = AIDrawingClient(baseURL: config.baseURL, apiKey: config.apiKey, model: config.model, timeout: config.requestTimeout)
                let generated = try await client.generateDrawingPlan(prompt: prompt, context: context)
                let entities = Self.buildEntities(from: generated, engine: engine, prompt: prompt, commitLayers: false)
                await MainActor.run {
                    self.plan = generated
                    self.previewEntities = entities
                    self.previewPrimitives = entities.flatMap { $0.localGeometry ?? [] }
                    self.state = .previewReady
                    processor.commandPrompt = "AIDRAW preview: type APPLY/YES or press Enter to create; CANCEL/Esc to discard."
                }
            } catch {
                await MainActor.run {
                    self.errorText = error.localizedDescription
                    self.state = .finished
                    processor.commandPrompt = "AIDRAW failed: \(error.localizedDescription)"
                    processor.finishFeatureCommand(engine: engine)
                }
            }
        }
    }

    private func commit(engine: PhrostEngine, processor: CADCommandProcessor) {
        guard let plan else {
            processor.commandPrompt = "No AI drawing preview to apply."
            return
        }
        let entities = Self.buildEntities(from: plan, engine: engine, prompt: promptText, commitLayers: true)
        guard !entities.isEmpty else {
            processor.commandPrompt = "AI drawing plan contained no valid geometry."
            return
        }
        engine.document.addEntities(entities)
        engine.cadSelection.clearSelection()
        for entity in entities { engine.cadSelection.addToSelection(entity.handle) }
        engine.tabManager.markActiveDirty()
        state = .finished
        processor.commandPrompt = "AIDRAW created \(entities.count) entity/entities."
    }

    private func makeContext(engine: PhrostEngine) -> AIDrawingClient.DrawingContextJSON {
        let rect = engine.camera.worldViewportRect(windowWidth: engine.windowWidth, windowHeight: engine.windowHeight)
        let activeLayer = engine.document.activeLayerID.flatMap { engine.document.layer(for: $0)?.name }
        return AIDrawingClient.DrawingContextJSON(
            units: engine.document.unit.description,
            origin: [engine.camera.offset.x, engine.camera.offset.y],
            viewport: [rect.minX, rect.minY, rect.maxX, rect.maxY],
            activeLayer: activeLayer,
            availableLayers: engine.document.allLayers.map(\.name).sorted()
        )
    }

    private static func buildEntities(
        from plan: AIDrawingClient.DrawingPlanJSON,
        engine: PhrostEngine,
        prompt: String,
        commitLayers: Bool
    ) -> [CADEntity] {
        let coordinateMode = (plan.coordinateMode ?? "relative").lowercased()
        let relative = coordinateMode != "absolute"
        let origin = Vector3(x: engine.camera.offset.x, y: engine.camera.offset.y, z: 0)
        let defaultLayer = sanitizedLayerName(plan.defaultLayer) ?? "AI_Generated"
        var entities: [CADEntity] = []
        let maxOperations = min(plan.operations.count, 500)
        for operation in plan.operations.prefix(maxOperations) {
            let primitives = primitives(from: operation, origin: origin, relative: relative)
            guard !primitives.isEmpty else { continue }
            let layerID = layerID(named: sanitizedLayerName(operation.layer) ?? defaultLayer, engine: engine, commit: commitLayers)
            var xdata: [String: XDataValue] = [
                "ai.generated": .bool(true),
                "ai.prompt": .string(prompt),
                "ai.operationType": .string(operation.type)
            ]
            if let lineType = operation.lineType, !lineType.isEmpty { xdata["dxf.lineType"] = .string(lineType) }
            if let lineWeight = operation.lineWeight, lineWeight.isFinite, lineWeight > 0 { xdata["dxf.lineWeight"] = .double(lineWeight) }
            entities.append(CADEntity(layerID: layerID, localGeometry: primitives, xdata: xdata))
        }
        return entities
    }

    private static func primitives(from operation: AIDrawingClient.DrawingOperationJSON, origin: Vector3, relative: Bool) -> [CADPrimitive] {
        let color = operation.color.flatMap(ColorRGBA.init(hex:))
        switch operation.type.lowercased() {
        case "line":
            guard let a = point(operation.start, origin: origin, relative: relative), let b = point(operation.end, origin: origin, relative: relative) else { return [] }
            guard validPoint(a), validPoint(b), distance(a, b) > 1e-9 else { return [] }
            return [.line(start: a, end: b, color: color)]
        case "polyline":
            guard let pts = points(operation.points, origin: origin, relative: relative), pts.count >= 2 else { return [] }
            return [.polyline(path: CADPolyline(points: pts, isClosed: operation.closed ?? false), color: color)]
        case "rectangle":
            guard let o = point(operation.origin ?? operation.start, origin: origin, relative: relative), let size = operation.size, size.count >= 2 else { return [] }
            let w = size[0]
            let h = size[1]
            guard w.isFinite, h.isFinite, abs(w) > 1e-9, abs(h) > 1e-9 else { return [] }
            return [rectPrimitive(origin: o, width: w, height: h, rotation: (operation.rotationDegrees ?? 0) * Double.pi / 180.0, color: color)]
        case "circle":
            guard let c = point(operation.center ?? operation.origin, origin: origin, relative: relative), let r = operation.radius, r.isFinite, r > 1e-9 else { return [] }
            return [.circle(center: c, radius: r, color: color)]
        case "arc":
            guard let c = point(operation.center ?? operation.origin, origin: origin, relative: relative), let r = operation.radius, r.isFinite, r > 1e-9 else { return [] }
            let start = (operation.startAngleDegrees ?? 0) * Double.pi / 180.0
            let end = (operation.endAngleDegrees ?? 90) * Double.pi / 180.0
            return [.arc(center: c, radius: r, startAngle: start, endAngle: end, color: color)]
        case "text", "label":
            guard let text = operation.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return [] }
            guard let p = point(operation.origin ?? operation.center ?? operation.start, origin: origin, relative: relative) else { return [] }
            let height = max(operation.height ?? 2.5, 1e-6)
            let rotation = (operation.rotationDegrees ?? 0) * Double.pi / 180.0
            return [.text(position: p, text: text, height: height, rotation: rotation, style: nil, alignH: 0, alignV: 0, mtextWidth: nil, color: color)]
        case "hatch":
            guard let pts = points(operation.points, origin: origin, relative: relative), pts.count >= 3 else { return [] }
            return [.hatch(boundary: pts, pattern: operation.pattern ?? "SOLID", scale: operation.scale ?? 1, angle: (operation.angleDegrees ?? 0) * Double.pi / 180.0, color: color)]
        case "kitchen_sink", "sink", "double_sink":
            guard let frame = symbolFrame(operation, origin: origin, relative: relative, defaultWidth: 900, defaultHeight: 550) else { return [] }
            return kitchenSinkSymbol(frame: frame, color: color)
        case "stove", "range", "cooktop":
            guard let frame = symbolFrame(operation, origin: origin, relative: relative, defaultWidth: 760, defaultHeight: 760) else { return [] }
            return stoveSymbol(frame: frame, color: color)
        case "refrigerator", "fridge":
            guard let frame = symbolFrame(operation, origin: origin, relative: relative, defaultWidth: 900, defaultHeight: 750) else { return [] }
            return refrigeratorSymbol(frame: frame, color: color)
        case "base_cabinet", "cabinet":
            guard let frame = symbolFrame(operation, origin: origin, relative: relative, defaultWidth: 900, defaultHeight: 600) else { return [] }
            return cabinetSymbol(frame: frame, color: color)
        case "countertop", "counter":
            guard let frame = symbolFrame(operation, origin: origin, relative: relative, defaultWidth: 1800, defaultHeight: 650) else { return [] }
            return countertopSymbol(frame: frame, color: color)
        case "door":
            guard let frame = symbolFrame(operation, origin: origin, relative: relative, defaultWidth: 900, defaultHeight: 120) else { return [] }
            return doorSymbol(frame: frame, color: color)
        case "window":
            guard let frame = symbolFrame(operation, origin: origin, relative: relative, defaultWidth: 1200, defaultHeight: 120) else { return [] }
            return windowSymbol(frame: frame, color: color)
        case "toilet":
            guard let frame = symbolFrame(operation, origin: origin, relative: relative, defaultWidth: 450, defaultHeight: 700) else { return [] }
            return toiletSymbol(frame: frame, color: color)
        default:
            return []
        }
    }


    private struct SymbolFrame {
        let origin: Vector3
        let width: Double
        let height: Double
        let rotation: Double
    }

    private static func symbolFrame(
        _ operation: AIDrawingClient.DrawingOperationJSON,
        origin: Vector3,
        relative: Bool,
        defaultWidth: Double,
        defaultHeight: Double
    ) -> SymbolFrame? {
        let w = operation.size?.first ?? defaultWidth
        let h = (operation.size?.count ?? 0) >= 2 ? operation.size![1] : defaultHeight
        guard w.isFinite, h.isFinite, abs(w) > 1e-9, abs(h) > 1e-9 else { return nil }
        let rotation = (operation.rotationDegrees ?? 0) * Double.pi / 180.0
        if let center = point(operation.center, origin: origin, relative: relative) {
            return SymbolFrame(origin: Vector3(x: center.x - w * 0.5, y: center.y - h * 0.5, z: center.z), width: w, height: h, rotation: rotation)
        }
        guard let o = point(operation.origin ?? operation.start, origin: origin, relative: relative) else { return nil }
        return SymbolFrame(origin: o, width: w, height: h, rotation: rotation)
    }

    private static func localPoint(_ frame: SymbolFrame, _ x: Double, _ y: Double) -> Vector3 {
        let cx = frame.origin.x + frame.width * 0.5
        let cy = frame.origin.y + frame.height * 0.5
        let px = frame.origin.x + x
        let py = frame.origin.y + y
        let dx = px - cx
        let dy = py - cy
        let c = cos(frame.rotation)
        let s = sin(frame.rotation)
        return Vector3(x: cx + dx * c - dy * s, y: cy + dx * s + dy * c, z: frame.origin.z)
    }

    private static func rectPrimitive(origin: Vector3, width: Double, height: Double, rotation: Double, color: ColorRGBA?) -> CADPrimitive {
        let frame = SymbolFrame(origin: origin, width: width, height: height, rotation: rotation)
        return closedPolyline([
            localPoint(frame, 0, 0),
            localPoint(frame, width, 0),
            localPoint(frame, width, height),
            localPoint(frame, 0, height)
        ], color: color)
    }

    private static func rectPrimitive(_ frame: SymbolFrame, x: Double, y: Double, w: Double, h: Double, color: ColorRGBA?) -> CADPrimitive {
        closedPolyline([
            localPoint(frame, x, y),
            localPoint(frame, x + w, y),
            localPoint(frame, x + w, y + h),
            localPoint(frame, x, y + h)
        ], color: color)
    }

    private static func linePrimitive(_ frame: SymbolFrame, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, color: ColorRGBA?) -> CADPrimitive {
        .line(start: localPoint(frame, x1, y1), end: localPoint(frame, x2, y2), color: color)
    }

    private static func closedPolyline(_ pts: [Vector3], color: ColorRGBA?) -> CADPrimitive {
        .polyline(path: CADPolyline(points: pts, isClosed: true), color: color)
    }

    private static func openPolyline(_ pts: [Vector3], color: ColorRGBA?) -> CADPrimitive {
        .polyline(path: CADPolyline(points: pts, isClosed: false), color: color)
    }

    private static func circlePrimitive(_ frame: SymbolFrame, cx: Double, cy: Double, radius: Double, color: ColorRGBA?) -> CADPrimitive {
        .circle(center: localPoint(frame, cx, cy), radius: abs(radius), color: color)
    }

    private static func localArcPrimitive(_ frame: SymbolFrame, cx: Double, cy: Double, radius: Double, start: Double, end: Double, color: ColorRGBA?) -> CADPrimitive {
        .arc(center: localPoint(frame, cx, cy), radius: abs(radius), startAngle: start + frame.rotation, endAngle: end + frame.rotation, color: color)
    }

    private static func roundedRectPrimitive(_ frame: SymbolFrame, x: Double, y: Double, w: Double, h: Double, radius: Double, color: ColorRGBA?) -> CADPrimitive {
        let r = max(0, min(abs(radius), min(abs(w), abs(h)) * 0.5))
        guard r > 1e-9 else { return rectPrimitive(frame, x: x, y: y, w: w, h: h, color: color) }
        var pts: [Vector3] = []
        func appendCorner(cx: Double, cy: Double, start: Double, end: Double) {
            let steps = 5
            for i in 0...steps {
                let t = Double(i) / Double(steps)
                let a = start + (end - start) * t
                pts.append(localPoint(frame, cx + cos(a) * r, cy + sin(a) * r))
            }
        }
        appendCorner(cx: x + w - r, cy: y + h - r, start: 0, end: Double.pi * 0.5)
        appendCorner(cx: x + r, cy: y + h - r, start: Double.pi * 0.5, end: Double.pi)
        appendCorner(cx: x + r, cy: y + r, start: Double.pi, end: Double.pi * 1.5)
        appendCorner(cx: x + w - r, cy: y + r, start: Double.pi * 1.5, end: Double.pi * 2.0)
        return closedPolyline(pts, color: color)
    }

    private static func kitchenSinkSymbol(frame: SymbolFrame, color: ColorRGBA?) -> [CADPrimitive] {
        let w = abs(frame.width), h = abs(frame.height)
        let inset = min(w, h) * 0.08
        let gap = w * 0.04
        let bowlW = (w - inset * 2.0 - gap) * 0.5
        let bowlH = h * 0.64
        let bowlY = h * 0.16
        let r = min(bowlW, bowlH) * 0.12
        return [
            rectPrimitive(frame, x: 0, y: 0, w: w, h: h, color: color),
            roundedRectPrimitive(frame, x: inset, y: bowlY, w: bowlW, h: bowlH, radius: r, color: color),
            roundedRectPrimitive(frame, x: inset + bowlW + gap, y: bowlY, w: bowlW, h: bowlH, radius: r, color: color),
            linePrimitive(frame, w * 0.5, bowlY, w * 0.5, bowlY + bowlH, color: color),
            circlePrimitive(frame, cx: inset + bowlW * 0.5, cy: h * 0.5, radius: min(w, h) * 0.035, color: color),
            circlePrimitive(frame, cx: inset + bowlW + gap + bowlW * 0.5, cy: h * 0.5, radius: min(w, h) * 0.035, color: color),
            localArcPrimitive(frame, cx: w * 0.5, cy: h * 0.83, radius: min(w, h) * 0.13, start: Double.pi, end: 0, color: color),
            linePrimitive(frame, w * 0.5, h * 0.83, w * 0.5, h * 0.70, color: color)
        ]
    }

    private static func stoveSymbol(frame: SymbolFrame, color: ColorRGBA?) -> [CADPrimitive] {
        let w = abs(frame.width), h = abs(frame.height)
        let r = min(w, h) * 0.095
        var prims: [CADPrimitive] = [
            rectPrimitive(frame, x: 0, y: 0, w: w, h: h, color: color),
            rectPrimitive(frame, x: w * 0.08, y: h * 0.08, w: w * 0.84, h: h * 0.84, color: color),
            linePrimitive(frame, w * 0.12, h * 0.22, w * 0.88, h * 0.22, color: color),
            linePrimitive(frame, w * 0.25, h * 0.12, w * 0.75, h * 0.12, color: color)
        ]
        for (x, y) in [(w * 0.32, h * 0.62), (w * 0.68, h * 0.62), (w * 0.32, h * 0.38), (w * 0.68, h * 0.38)] {
            prims.append(circlePrimitive(frame, cx: x, cy: y, radius: r, color: color))
            prims.append(circlePrimitive(frame, cx: x, cy: y, radius: r * 0.45, color: color))
        }
        for i in 0..<4 {
            prims.append(circlePrimitive(frame, cx: w * (0.26 + Double(i) * 0.16), cy: h * 0.90, radius: min(w, h) * 0.025, color: color))
        }
        return prims
    }

    private static func refrigeratorSymbol(frame: SymbolFrame, color: ColorRGBA?) -> [CADPrimitive] {
        let w = abs(frame.width), h = abs(frame.height)
        return [
            rectPrimitive(frame, x: 0, y: 0, w: w, h: h, color: color),
            linePrimitive(frame, w * 0.50, 0, w * 0.50, h, color: color),
            linePrimitive(frame, w * 0.42, h * 0.20, w * 0.42, h * 0.78, color: color),
            linePrimitive(frame, w * 0.58, h * 0.20, w * 0.58, h * 0.78, color: color),
            linePrimitive(frame, w * 0.08, h * 0.12, w * 0.92, h * 0.12, color: color),
            linePrimitive(frame, w * 0.08, h * 0.88, w * 0.92, h * 0.88, color: color)
        ]
    }

    private static func cabinetSymbol(frame: SymbolFrame, color: ColorRGBA?) -> [CADPrimitive] {
        let w = abs(frame.width), h = abs(frame.height)
        return [
            rectPrimitive(frame, x: 0, y: 0, w: w, h: h, color: color),
            linePrimitive(frame, w * 0.5, 0, w * 0.5, h, color: color),
            circlePrimitive(frame, cx: w * 0.44, cy: h * 0.5, radius: min(w, h) * 0.025, color: color),
            circlePrimitive(frame, cx: w * 0.56, cy: h * 0.5, radius: min(w, h) * 0.025, color: color)
        ]
    }

    private static func countertopSymbol(frame: SymbolFrame, color: ColorRGBA?) -> [CADPrimitive] {
        let w = abs(frame.width), h = abs(frame.height)
        return [
            rectPrimitive(frame, x: 0, y: 0, w: w, h: h, color: color),
            linePrimitive(frame, 0, h * 0.18, w, h * 0.18, color: color),
            linePrimitive(frame, 0, h * 0.82, w, h * 0.82, color: color)
        ]
    }

    private static func doorSymbol(frame: SymbolFrame, color: ColorRGBA?) -> [CADPrimitive] {
        let w = abs(frame.width), h = max(abs(frame.height), w * 0.08)
        return [
            linePrimitive(frame, 0, 0, 0, h, color: color),
            linePrimitive(frame, 0, 0, w, 0, color: color),
            localArcPrimitive(frame, cx: 0, cy: 0, radius: w, start: 0, end: Double.pi * 0.5, color: color)
        ]
    }

    private static func windowSymbol(frame: SymbolFrame, color: ColorRGBA?) -> [CADPrimitive] {
        let w = abs(frame.width), h = max(abs(frame.height), w * 0.08)
        return [
            rectPrimitive(frame, x: 0, y: 0, w: w, h: h, color: color),
            linePrimitive(frame, 0, h * 0.5, w, h * 0.5, color: color),
            linePrimitive(frame, w * 0.5, 0, w * 0.5, h, color: color)
        ]
    }

    private static func toiletSymbol(frame: SymbolFrame, color: ColorRGBA?) -> [CADPrimitive] {
        let w = abs(frame.width), h = abs(frame.height)
        return [
            roundedRectPrimitive(frame, x: w * 0.18, y: h * 0.55, w: w * 0.64, h: h * 0.35, radius: min(w, h) * 0.08, color: color),
            roundedRectPrimitive(frame, x: w * 0.22, y: h * 0.10, w: w * 0.56, h: h * 0.52, radius: min(w, h) * 0.22, color: color),
            circlePrimitive(frame, cx: w * 0.5, cy: h * 0.34, radius: min(w, h) * 0.12, color: color),
            linePrimitive(frame, w * 0.35, h * 0.74, w * 0.65, h * 0.74, color: color)
        ]
    }

    private static func point(_ raw: [Double]?, origin: Vector3, relative: Bool) -> Vector3? {
        guard let raw, raw.count >= 2, raw[0].isFinite, raw[1].isFinite else { return nil }
        let p = Vector3(x: raw[0], y: raw[1], z: raw.count >= 3 && raw[2].isFinite ? raw[2] : 0)
        return relative ? Vector3(x: origin.x + p.x, y: origin.y + p.y, z: origin.z + p.z) : p
    }

    private static func points(_ raw: [[Double]]?, origin: Vector3, relative: Bool) -> [Vector3]? {
        guard let raw else { return nil }
        let pts = raw.compactMap { point($0, origin: origin, relative: relative) }
        guard pts.count == raw.count, pts.allSatisfy(validPoint) else { return nil }
        return pts
    }

    private static func validPoint(_ p: Vector3) -> Bool {
        p.x.isFinite && p.y.isFinite && p.z.isFinite && abs(p.x) < 1e9 && abs(p.y) < 1e9 && abs(p.z) < 1e9
    }

    private static func distance(_ a: Vector3, _ b: Vector3) -> Double {
        hypot(a.x - b.x, a.y - b.y)
    }

    private static func sanitizedLayerName(_ raw: String?) -> String? {
        guard let name = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return String(name.prefix(80))
    }

    private static func layerID(named name: String, engine: PhrostEngine, commit: Bool) -> UUID {
        if let layer = engine.document.allLayers.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return layer.handle
        }
        if commit {
            let layer = Layer(name: name, color: ColorRGBA.cyan, lineType: "CONTINUOUS")
            engine.document.addLayer(layer)
            return layer.handle
        }
        return engine.document.activeLayerID ?? engine.document.allLayers.first?.handle ?? UUID()
    }

    private func drawPrimitive(_ prim: CADPrimitive, cam: CameraTransform, drawList: UnsafeMutablePointer<ImDrawList>?, color: UInt32, fillColor: UInt32) {
        switch prim {
        case .line(let a, let b, _):
            drawLine(a, b, cam: cam, drawList: drawList, color: color)
        case .polyline(let path, _):
            drawPolyline(path.points, closed: path.isClosed, cam: cam, drawList: drawList, color: color)
        case .polygon(let pts, _):
            drawPolyline(pts, closed: true, cam: cam, drawList: drawList, color: color)
        case .circle(let c, let r, _):
            drawCircle(center: c, radius: r, cam: cam, drawList: drawList, color: color)
        case .arc(let c, let r, let a0, let a1, _):
            drawArc(center: c, radius: r, start: a0, end: a1, cam: cam, drawList: drawList, color: color)
        case .text(let p, let text, _, _, _, _, _, _, _):
            let sp = EngineCameraManager.worldToScreen(worldX: p.x, worldY: p.y, cam: cam)
            ImDrawListAddText(drawList, ImVec2(x: sp.x, y: sp.y), color, text, nil)
        case .hatch(let boundary, _, _, _, _, _):
            drawPolyline(boundary, closed: true, cam: cam, drawList: drawList, color: color)
            let screenPts = boundary.map { p -> ImVec2 in
                let sp = EngineCameraManager.worldToScreen(worldX: p.x, worldY: p.y, cam: cam)
                return ImVec2(x: sp.x, y: sp.y)
            }
            screenPts.withUnsafeBufferPointer { buf in
                if let base = buf.baseAddress, screenPts.count >= 3 {
                    ImDrawListAddConvexPolyFilled(drawList, base, Int32(screenPts.count), fillColor)
                }
            }
        default:
            break
        }
    }

    private func drawLine(_ a: Vector3, _ b: Vector3, cam: CameraTransform, drawList: UnsafeMutablePointer<ImDrawList>?, color: UInt32) {
        let p1 = EngineCameraManager.worldToScreen(worldX: a.x, worldY: a.y, cam: cam)
        let p2 = EngineCameraManager.worldToScreen(worldX: b.x, worldY: b.y, cam: cam)
        ImDrawListAddLine(drawList, ImVec2(x: p1.x, y: p1.y), ImVec2(x: p2.x, y: p2.y), color, 1.5)
    }

    private func drawPolyline(_ pts: [Vector3], closed: Bool, cam: CameraTransform, drawList: UnsafeMutablePointer<ImDrawList>?, color: UInt32) {
        guard pts.count >= 2 else { return }
        var screenPts = pts.map { p -> ImVec2 in
            let sp = EngineCameraManager.worldToScreen(worldX: p.x, worldY: p.y, cam: cam)
            return ImVec2(x: sp.x, y: sp.y)
        }
        if closed, let first = screenPts.first { screenPts.append(first) }
        screenPts.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress {
                ImDrawListAddPolyline(drawList, base, Int32(screenPts.count), color, 1.5, ImDrawFlags(0))
            }
        }
    }

    private func drawCircle(center: Vector3, radius: Double, cam: CameraTransform, drawList: UnsafeMutablePointer<ImDrawList>?, color: UInt32) {
        var pts: [Vector3] = []
        for i in 0...72 {
            let a = Double(i) * 2.0 * Double.pi / 72.0
            pts.append(Vector3(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius, z: 0))
        }
        drawPolyline(pts, closed: false, cam: cam, drawList: drawList, color: color)
    }

    private func drawArc(center: Vector3, radius: Double, start: Double, end: Double, cam: CameraTransform, drawList: UnsafeMutablePointer<ImDrawList>?, color: UInt32) {
        var pts: [Vector3] = []
        let sweep = end - start
        let segments = max(8, min(96, Int(abs(sweep) / (Double.pi / 36.0))))
        for i in 0...segments {
            let t = Double(i) / Double(segments)
            let a = start + sweep * t
            pts.append(Vector3(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius, z: 0))
        }
        drawPolyline(pts, closed: false, cam: cam, drawList: drawList, color: color)
    }
}
