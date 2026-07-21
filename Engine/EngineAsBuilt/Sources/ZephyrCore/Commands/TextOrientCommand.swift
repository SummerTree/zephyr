import Foundation
import CSDL3
import ImGui
import SwiftSDL

@MainActor
public final class TextOrientCommand: FeatureCommand {
    private enum State {
        case idle
        case selectObjects
        case askFirstPoint
        case askSecondPoint
        case finished
    }

    private var state: State = .idle
    private var targetHandles: Set<UUID> = []
    private var firstPoint: Vector3?
    private var currentMouseX: Double = 0
    private var currentMouseY: Double = 0
    private var angleBuffer = ""

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        reset()
        refreshTargets(engine: engine)

        if !targetHandles.isEmpty {
            state = .askFirstPoint
            processor.commandPrompt = "New absolute rotation <Most Readable>:"
        } else {
            state = .selectObjects
            processor.commandPrompt = "Select text objects, then press Enter"
        }
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        reset()
    }

    public func handleMouseClick(
        worldX: Double,
        worldY: Double,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        switch state {
        case .idle, .finished:
            return .finished

        case .selectObjects:
            let threshold = 8.0 / max(engine.camera.zoom, 0.001)
            guard let handle = engine.cadSelection.hitTest(
                worldX: worldX,
                worldY: worldY,
                document: engine.document,
                threshold: threshold,
                simplifyComplexBlocks: engine.simplifyComplexBlocks
            ),
            let entity = engine.document.entity(for: handle),
            isTextEntity(entity)
            else {
                processor.commandPrompt = "Select text objects, then press Enter (\(targetHandles.count) selected)"
                return .handled
            }

            let shiftHeld = engine.io?.pointee.KeyShift ?? false
            if shiftHeld {
                engine.cadSelection.removeFromSelection(handle)
            } else {
                engine.cadSelection.addToSelection(handle)
            }
            refreshTargets(engine: engine)
            processor.commandPrompt = "Select text objects, then press Enter (\(targetHandles.count) selected)"
            return .handled

        case .askFirstPoint:
            firstPoint = Vector3(x: worldX, y: worldY, z: 0)
            angleBuffer = ""
            state = .askSecondPoint
            processor.commandPrompt = "Specify second point for text angle"
            return .handled

        case .askSecondPoint:
            guard let firstPoint else { return .handled }
            let dx = worldX - firstPoint.x
            let dy = worldY - firstPoint.y
            guard sqrt(dx * dx + dy * dy) > 1e-12 else {
                processor.commandPrompt = "Second point must differ from first point"
                return .handled
            }
            return applyAbsoluteAngle(
                atan2(dy, dx),
                engine: engine,
                processor: processor)
        }
    }

    public func handleMouseMotion(
        worldX: Double,
        worldY: Double,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) {
        currentMouseX = worldX
        currentMouseY = worldY
    }

    public func handleKeyDown(
        scancode: SDL_Scancode,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        if scancode == SDL_SCANCODE_ESCAPE {
            return .finished
        }

        switch state {
        case .selectObjects:
            if scancode == SDL_SCANCODE_RETURN || scancode == SDL_SCANCODE_KP_ENTER {
                refreshTargets(engine: engine)
                guard !targetHandles.isEmpty else {
                    processor.commandPrompt = "No text entities selected"
                    return .handled
                }
                state = .askFirstPoint
                processor.commandPrompt = "New absolute rotation <Most Readable>:"
                return .handled
            }
            return .continue

        case .askFirstPoint, .askSecondPoint:
            if scancode == SDL_SCANCODE_RETURN || scancode == SDL_SCANCODE_KP_ENTER {
                if angleBuffer.isEmpty {
                    if state == .askFirstPoint {
                        return applyMostReadable(engine: engine, processor: processor)
                    }
                    return .handled
                }
                return commitBufferedAngle(engine: engine, processor: processor)
            }

            if handleAngleBufferKey(scancode) {
                processor.commandPrompt = "New absolute rotation <Most Readable>: \(angleBuffer)"
                return .handled
            }
            return .continue

        case .idle, .finished:
            return .finished
        }
    }

    public func handleCommandText(
        _ text: String,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        guard state == .askFirstPoint || state == .askSecondPoint else {
            return .continue
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return state == .askFirstPoint
                ? applyMostReadable(engine: engine, processor: processor)
                : .handled
        }

        guard let degrees = Double(trimmed) else {
            processor.commandPrompt = "Invalid angle. Enter a value in degrees"
            return .handled
        }

        return applyAbsoluteAngle(
            degrees * .pi / 180.0,
            engine: engine,
            processor: processor)
    }

    public var isSnappingEnabled: Bool {
        state == .askFirstPoint || state == .askSecondPoint
    }

    public func getDrawingSnapPoints() -> [Vector3] {
        firstPoint.map { [$0] } ?? []
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        guard state == .askFirstPoint || state == .askSecondPoint,
              let drawList = igGetForegroundDrawList_ViewportPtr(nil)
        else { return }

        let cursor = EngineCameraManager.worldToScreen(
            worldX: currentMouseX,
            worldY: currentMouseY,
            cam: cam)
        let lineColor = makeCol32(0, 200, 255, 220)
        let pointColor = makeCol32(255, 190, 0, 255)

        if state == .askFirstPoint {
            ImDrawListAddLine(
                drawList,
                ImVec2(x: cursor.x - 6, y: cursor.y),
                ImVec2(x: cursor.x + 6, y: cursor.y),
                pointColor,
                1.5)
            ImDrawListAddLine(
                drawList,
                ImVec2(x: cursor.x, y: cursor.y - 6),
                ImVec2(x: cursor.x, y: cursor.y + 6),
                pointColor,
                1.5)
        } else if let firstPoint {
            let first = EngineCameraManager.worldToScreen(
                worldX: firstPoint.x,
                worldY: firstPoint.y,
                cam: cam)
            ImDrawListAddLine(
                drawList,
                ImVec2(x: first.x, y: first.y),
                ImVec2(x: cursor.x, y: cursor.y),
                lineColor,
                1.5)
            ImDrawListAddCircleFilled(
                drawList,
                ImVec2(x: first.x, y: first.y),
                4.0,
                pointColor,
                16)
        }

        guard !angleBuffer.isEmpty else { return }
        let label = angleBuffer + "°"
        let textSize = ImGuiCalcTextSize(label, nil, false, -1)
        let min = ImVec2(x: cursor.x + 14, y: cursor.y - 34)
        let max = ImVec2(x: min.x + textSize.x + 12, y: min.y + textSize.y + 8)
        ImDrawListAddRectFilled(drawList, min, max, makeCol32(30, 30, 30, 220), 4, 0)
        ImDrawListAddRect(drawList, min, max, makeCol32(120, 120, 120, 220), 4, 1, 0)
        ImDrawListAddText(
            drawList,
            ImVec2(x: min.x + 6, y: min.y + 4),
            makeCol32(255, 255, 255, 255),
            label,
            nil)
    }

    private func commitBufferedAngle(
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        guard let degrees = Double(angleBuffer) else {
            processor.commandPrompt = "Invalid angle. Enter a value in degrees"
            return .handled
        }
        return applyAbsoluteAngle(
            degrees * .pi / 180.0,
            engine: engine,
            processor: processor)
    }

    private func applyMostReadable(
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        refreshTargets(engine: engine)
        let changes = targetHandles.compactMap { handle -> (CADEntity, Double)? in
            guard let entity = engine.document.entity(for: handle),
                  let angle = displayedRotation(of: entity)
            else { return nil }

            let normalized = normalize(angle)
            guard normalized > .pi / 2.0 && normalized <= 3.0 * .pi / 2.0 else {
                return nil
            }
            return (entity, normalize(normalized + .pi))
        }
        return apply(changes, engine: engine, processor: processor)
    }

    private func applyAbsoluteAngle(
        _ angle: Double,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        refreshTargets(engine: engine)
        let desired = normalize(angle)
        let changes = targetHandles.compactMap { handle -> (CADEntity, Double)? in
            guard let entity = engine.document.entity(for: handle),
                  displayedRotation(of: entity) != nil
            else { return nil }
            return (entity, desired)
        }
        return apply(changes, engine: engine, processor: processor)
    }

    private func apply(
        _ changes: [(CADEntity, Double)],
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        guard !changes.isEmpty else {
            processor.commandPrompt = "No text entities required rotation"
            state = .finished
            return .finished
        }

        var updatedEntities: [CADEntity] = []
        updatedEntities.reserveCapacity(changes.count)

        for (entity, desired) in changes {
            guard let current = displayedRotation(of: entity),
                  let pivot = insertionPoint(of: entity)
            else { continue }

            let delta = normalizedDelta(desired - current)
            guard abs(delta) > 1e-12 else { continue }

            var updated = entity
            let toOrigin = Transform3D.translated(by: Vector3(x: -pivot.x, y: -pivot.y, z: -pivot.z))
            let rotation = Transform3D.rotated(by: delta)
            let fromOrigin = Transform3D.translated(by: pivot)
            updated.transform = fromOrigin.multiplying(
                by: rotation.multiplying(
                    by: toOrigin.multiplying(by: entity.transform)))
            updatedEntities.append(updated)
        }

        guard !updatedEntities.isEmpty else {
            processor.commandPrompt = "Text is already at the requested orientation"
            state = .finished
            return .finished
        }

        engine.document.pushUndo()
        for entity in updatedEntities {
            engine.document.updateEntityLive(entity)
        }
        engine.document.invalidateEntityGrid()
        engine.tabManager.markActiveDirty()
        processor.commandPrompt = "Rotated \(updatedEntities.count) text object(s)"
        state = .finished
        return .finished
    }

    private func refreshTargets(engine: PhrostEngine) {
        targetHandles = Set(engine.cadSelection.selectedHandles.filter { handle in
            guard let entity = engine.document.entity(for: handle) else { return false }
            return isTextEntity(entity)
        })
    }

    private func isTextEntity(_ entity: CADEntity) -> Bool {
        guard entity.blockID == nil,
              let first = entity.localGeometry?.first,
              case .text = first
        else { return false }
        return true
    }

    private func insertionPoint(of entity: CADEntity) -> Vector3? {
        if entity.xdata["dxf.text"] != nil {
            return entity.transform.position
        }
        guard let first = entity.localGeometry?.first,
              case .text(let position, _, _, _, _, _, _, _, _) = first
        else { return nil }
        return entity.transform.transformPoint(position)
    }

    private func displayedRotation(of entity: CADEntity) -> Double? {
        guard let first = entity.localGeometry?.first,
              case .text(let position, _, _, let rotation, _, _, _, _, _) = first
        else { return nil }

        if entity.xdata["dxf.text"] != nil {
            let origin = entity.transform.position
            let worldX = entity.transform.transformPoint(Vector3(x: 1, y: 0, z: 0)) - origin
            guard worldX.magnitude > 1e-12 else { return nil }
            return atan2(worldX.y, worldX.x)
        }

        let origin = entity.transform.transformPoint(position)
        let localX = Vector3(x: cos(rotation), y: sin(rotation), z: 0)
        let worldX = entity.transform.transformPoint(position + localX) - origin
        guard worldX.magnitude > 1e-12 else { return nil }
        return atan2(worldX.y, worldX.x)
    }

    private func handleAngleBufferKey(_ scancode: SDL_Scancode) -> Bool {
        let raw = scancode.rawValue

        if raw >= SDL_SCANCODE_1.rawValue && raw <= SDL_SCANCODE_9.rawValue {
            let digit = UInt8(0x31) + UInt8(raw - SDL_SCANCODE_1.rawValue)
            angleBuffer.append(Character(UnicodeScalar(digit)))
            return true
        }
        if scancode == SDL_SCANCODE_0 {
            angleBuffer.append("0")
            return true
        }
        if raw >= SDL_SCANCODE_KP_1.rawValue && raw <= SDL_SCANCODE_KP_9.rawValue {
            let digit = UInt8(0x31) + UInt8(raw - SDL_SCANCODE_KP_1.rawValue)
            angleBuffer.append(Character(UnicodeScalar(digit)))
            return true
        }
        if scancode == SDL_SCANCODE_KP_0 {
            angleBuffer.append("0")
            return true
        }
        if scancode == SDL_SCANCODE_PERIOD || scancode == SDL_SCANCODE_KP_PERIOD {
            if !angleBuffer.contains(".") {
                angleBuffer.append(".")
            }
            return true
        }
        if scancode == SDL_SCANCODE_MINUS || scancode == SDL_SCANCODE_KP_MINUS {
            if angleBuffer.isEmpty {
                angleBuffer.append("-")
            }
            return true
        }
        if scancode == SDL_SCANCODE_BACKSPACE || scancode == SDL_SCANCODE_DELETE {
            if !angleBuffer.isEmpty {
                angleBuffer.removeLast()
            }
            return true
        }
        return false
    }

    private func normalize(_ angle: Double) -> Double {
        let twoPi = 2.0 * Double.pi
        let value = angle.truncatingRemainder(dividingBy: twoPi)
        return value < 0 ? value + twoPi : value
    }

    private func normalizedDelta(_ angle: Double) -> Double {
        let twoPi = 2.0 * Double.pi
        var value = angle.truncatingRemainder(dividingBy: twoPi)
        if value > .pi { value -= twoPi }
        if value <= -.pi { value += twoPi }
        return value
    }

    private func reset() {
        state = .idle
        targetHandles.removeAll()
        firstPoint = nil
        currentMouseX = 0
        currentMouseY = 0
        angleBuffer = ""
    }
}
