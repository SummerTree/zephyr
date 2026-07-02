import Foundation
import ImGui
import SwiftSDL

// =========================================================================
// MARK: - AISelectCommand
//
// AI-powered pattern-matching selection command.
//
// **Workflow:**
//   1. Pre-select example entities that represent the pattern you want to find.
//   2. Type `AISELECT` (or `AIS` / `AIFIND`).
//   3. Click first corner, then second corner to define the search window.
//   4. The engine clusters and profiles both your examples and the entities in
//      the window, sends the profiles to an LLM, and selects matching clusters.
//   5. Review the selection, Shift-deselect keepers, then ERASE.
//
// **Architecture:** Swift handles clustering and feature extraction (the heavy
// math); an OpenAI-compatible LLM acts as the intelligent classifier.
@MainActor
public final class AISelectCommand: FeatureCommand {

    // MARK: - State Machine

    private enum State {
        /// Inspecting the current selection to learn positive examples.
        case learningFromExamples
        /// Waiting for the user to click the first corner of the search window.
        case waitingForFirstCorner
        /// First corner stored; tracking mouse for live preview; waiting for second corner.
        case waitingForSecondCorner(firstX: Double, firstY: Double)
        /// AI call is in-flight. All input is blocked.
        case aiProcessing
    }

    private var state: State = .learningFromExamples

    /// Feature profiles of the user's example selection (positive samples).
    private var sampleProfiles: [ClusterProfileJSON] = []

    /// Live mouse position (world-space), updated by `handleMouseMotion`.
    private var currentMouseWorldX: Double = 0
    private var currentMouseWorldY: Double = 0

    private var sampleColors: Set<ColorRGBA> = []
    private var maxSpeckleDiagonal: Double = 0
    private var canUseSpeckleFastPath = false
    private var samplePrimitiveSignatures: Set<String> = []
    private var maxDiagonalByPrimitiveSignature: [String: Double] = [:]
    private var sampleRuleProfiles: [AISelectionClient.AISelectionEntityProfileJSON] = []

    private struct RankedCanvasCluster {
        let cluster: EntityCluster
        let profile: ClusterProfileJSON
        let score: Double
    }

    // MARK: - Init

    public init() {}

    // MARK: - FeatureCommand Conformance

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        state = .learningFromExamples
        sampleProfiles.removeAll()
        sampleColors.removeAll()
        maxSpeckleDiagonal = 0
        canUseSpeckleFastPath = false
        samplePrimitiveSignatures.removeAll()
        maxDiagonalByPrimitiveSignature.removeAll()
        sampleRuleProfiles.removeAll()
        currentMouseWorldX = 0
        currentMouseWorldY = 0

        let selection = engine.cadSelection
        let doc = engine.document
        let config = engine.aiSelectConfig

        guard selection.hasSelection else {
            processor.commandPrompt = "Select example entities first, then run AISELECT again."
            processor.finishFeatureCommand(engine: engine)
            return
        }

        let selectedHandles = selection.selectedHandles
        sampleRuleProfiles = selectedHandles.compactMap { handle in
            guard let entity = doc.entity(for: handle) else { return nil }
            return Self.makeRuleProfile(for: entity, in: doc)
        }

        var speckleCompatibleExamples = 0
        var allExamplesAreSpeckleCompatible = true

        for handle in selectedHandles {
            guard let entity = doc.entity(for: handle) else {
                allExamplesAreSpeckleCompatible = false
                continue
            }

            guard let geometry = doc.resolvedGeometry(for: entity),
                  geometry.count < 10,
                  geometry.allSatisfy(CleanSpecklesCommand.isSpecklePrimitive(_:))
            else {
                allExamplesAreSpeckleCompatible = false
                continue
            }

            let signature = Self.primitiveSignature(for: geometry)
            samplePrimitiveSignatures.insert(signature)
            sampleColors.insert(CleanSpecklesCommand.resolveColor(for: entity, in: doc))

            if let bb = entity.worldBoundingBox {
                let diag = hypot(bb.max.x - bb.min.x, bb.max.y - bb.min.y)
                if diag > maxSpeckleDiagonal { maxSpeckleDiagonal = diag }
                let existing = maxDiagonalByPrimitiveSignature[signature] ?? 0
                if diag > existing { maxDiagonalByPrimitiveSignature[signature] = diag }
            }

            speckleCompatibleExamples += 1
        }

        maxSpeckleDiagonal *= 1.3
        if maxSpeckleDiagonal <= 0 { maxSpeckleDiagonal = 0.05 }
        canUseSpeckleFastPath = speckleCompatibleExamples > 0 && allExamplesAreSpeckleCompatible

        let clusters = EntityClustering.clusterEntities(
            selectedHandles,
            in: doc,
            gapTolerance: config.gapTolerance
        )
        let clusteredProfiles = EntityClustering.extractProfiles(from: clusters, in: doc)

        if clusteredProfiles.count == 1,
           selectedHandles.count > 1,
           (clusteredProfiles.first?.entity_count ?? 0) > 12 {
            let entityProfiles = EntityClustering.extractProfiles(
                from: selectedHandles.map { EntityCluster(entities: [$0]) },
                in: doc
            )
            sampleProfiles = Self.compactProfiles(entityProfiles, maxCount: 16)
            print("[AISelect] Sample selection formed one large cluster; learning \(sampleProfiles.count) independent example profile(s) instead.")
        } else {
            sampleProfiles = clusteredProfiles
        }

        guard !sampleProfiles.isEmpty else {
            processor.commandPrompt = "No profiles could be extracted from the selection."
            processor.finishFeatureCommand(engine: engine)
            return
        }

        print("[AISelect] Learned \(sampleProfiles.count) sample cluster profile(s) from selection.")
        state = .waitingForFirstCorner
        processor.commandPrompt = "Click first corner of search window (Esc to cancel)."
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        state = .learningFromExamples
        sampleProfiles.removeAll()
        sampleColors.removeAll()
        maxSpeckleDiagonal = 0
        canUseSpeckleFastPath = false
        samplePrimitiveSignatures.removeAll()
        maxDiagonalByPrimitiveSignature.removeAll()
        sampleRuleProfiles.removeAll()
    }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        switch state {
        case .learningFromExamples:
            return .finished

        case .aiProcessing:
            // Block all input while the LLM is processing.
            return .continue

        case .waitingForFirstCorner:
            state = .waitingForSecondCorner(firstX: worldX, firstY: worldY)
            currentMouseWorldX = worldX
            currentMouseWorldY = worldY
            processor.commandPrompt = "Click opposite corner (Esc to cancel)."
            return .continue

        case .waitingForSecondCorner(let firstX, let firstY):
            state = .aiProcessing
            processor.commandPrompt = "AI is analyzing geometric structures..."

            let doc = engine.document
            let config = engine.aiSelectConfig

            // Build world-space search rectangle.
            let minWX = min(firstX, worldX)
            let maxWX = max(firstX, worldX)
            let minWY = min(firstY, worldY)
            let maxWY = max(firstY, worldY)
            let searchMin = Vector3(x: minWX, y: minWY)
            let searchMax = Vector3(x: maxWX, y: maxWY)

            // Capture profiles and config for the async task.
            let samples = self.sampleProfiles
            let useSpeckleCandidateMode = self.canUseSpeckleFastPath
            let speckleSampleColors = self.sampleColors
            let speckleMaxDiagonal = self.maxSpeckleDiagonal
            let specklePrimitiveSignatures = self.samplePrimitiveSignatures
            let speckleMaxDiagonalBySignature = self.maxDiagonalByPrimitiveSignature
            let ruleSamples = self.sampleRuleProfiles
            let baseURL = config.baseURL
            let apiKey = config.apiKey
            let model = config.model
            let gapTolerance = config.gapTolerance
            let maxClusters = config.maxClustersToEvaluate
            let timeout = config.requestTimeout

            Task {
                var selectedHandles = Set<UUID>()
                var usedFallbackRule = false

                do {
                    let fallbackRule = Self.makeFallbackSelectionRule(from: ruleSamples)
                    let client = AISelectionClient(
                        baseURL: baseURL,
                        apiKey: apiKey,
                        model: model,
                        timeout: timeout
                    )

                    let aiRule: AISelectionClient.AISelectionRuleJSON
                    do {
                        aiRule = try await client.generateSelectionRule(samples: ruleSamples)
                        print("[AISelect] LLM generated selection rule: \(aiRule.intent ?? "unnamed").")
                    } catch {
                        aiRule = fallbackRule
                        usedFallbackRule = true
                        print("[AISelect] Rule generation failed: \(error.localizedDescription). Using local sample-derived rule.")
                    }

                    let rule = Self.mergeSelectionRule(aiRule, fallback: fallbackRule)
                    selectedHandles = Self.selectHandlesByRule(
                        firstX: firstX,
                        firstY: firstY,
                        secondX: worldX,
                        secondY: worldY,
                        rule: rule,
                        sampleProfiles: ruleSamples,
                        engine: engine
                    )

                    print("[AISelect] Rule selected \(selectedHandles.count) entity/entities\(usedFallbackRule ? " using fallback rule" : "").")
                } catch {
                    print("[AISelect] Rule selection failed: \(error.localizedDescription)")
                }

                await MainActor.run { [selectedHandles] in
                    engine.cadSelection.clearSelection()
                    for handle in selectedHandles {
                        engine.cadSelection.addToSelection(handle)
                    }

                    let count = selectedHandles.count
                    if count > 0 {
                        processor.commandPrompt = "AI rule selected \(count) entity/entities matching your examples. Review, then ERASE."
                    } else {
                        processor.commandPrompt = "No matching patterns found in the window."
                    }

                    processor.finishFeatureCommand(engine: engine)
                }
            }

            return .continue
        }
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        // Block input while AI is processing.
        if case .aiProcessing = state { return }
        currentMouseWorldX = worldX
        currentMouseWorldY = worldY
    }

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        // Block input while AI is processing.
        if case .aiProcessing = state { return .continue }
        return .continue
    }


    // MARK: - AI Rule-Based Selection

    private struct RuleSegment {
        let start: Vector3
        let end: Vector3
    }

    private struct RuleCandidate {
        let entity: CADEntity
        let profile: AISelectionClient.AISelectionEntityProfileJSON
        let segments: [RuleSegment]
        let bbox: BoundingBox3D
        let score: Double
    }

    private struct MotifConfig {
        let hasDashMotif: Bool
        let hasTriangleMotif: Bool
        let dashMaxDiagonal: Double
        let triangleMaxDiagonal: Double
        let proximityTolerance: Double
        let maxTriangleSegmentCount: Int
    }

    private struct EndpointGraphStats {
        let nodeCount: Int
        let leafCount: Int
        let maxDegree: Int
    }

    private static func makeFallbackSelectionRule(
        from samples: [AISelectionClient.AISelectionEntityProfileJSON]
    ) -> AISelectionClient.AISelectionRuleJSON {
        let lineLikeSamples = samplesAreLineLikeCleanup(samples)
        let diagonalBase = robustUpperBound(samples.map(\.bbox_diagonal))
        let widthBase = robustUpperBound(samples.map(\.bbox_width))
        let heightBase = robustUpperBound(samples.map(\.bbox_height))
        let averageSegmentBase = robustUpperBound(samples.map(\.average_segment_length))
        let segmentBase = robustUpperBound(samples.map(\.max_segment_length))
        let targetDiagonal = median(samples.map(\.bbox_diagonal))
        let targetAverageSegmentLength = median(samples.map(\.average_segment_length))
        let lineWeights = uniqueRounded(samples.map(\.effective_line_weight), places: 4)

        let primitiveSignatures: [String]? = lineLikeSamples ? nil : unique(samples.map(\.primitive_signature))
        let primitiveTypes: [String] = lineLikeSamples
            ? ["line", "polygon", "polyline"]
            : unique(samples.flatMap(\.primitive_types))

        return AISelectionClient.AISelectionRuleJSON(
            intent: lineLikeSamples ? "sample_derived_line_like_cleanup_rule" : "sample_derived_cad_rule",
            allowedLayerNames: unique(samples.map(\.layer_name)),
            allowedColors: unique(samples.map(\.effective_color)),
            allowedLineTypes: unique(samples.flatMap { [$0.effective_line_type, $0.layer_line_type, $0.explicit_line_type].compactMap { $0 } }),
            allowedLineWeights: lineWeights,
            allowedPrimitiveSignatures: primitiveSignatures,
            allowedPrimitiveTypes: primitiveTypes,
            allowedClosedShapeValues: unique(samples.map(\.is_closed_shape)),
            allowedHatchPatterns: unique(samples.flatMap(\.hatch_patterns)),
            requireLayerMatch: true,
            requireColorMatch: true,
            requireLineTypeMatch: false,
            requireLineWeightMatch: false,
            allowBulgedPolylines: samples.contains { $0.has_bulged_polyline },
            allowArcLikeGeometry: samples.contains { $0.has_arc_like_geometry },
            allowHatches: samples.contains { $0.has_hatch },
            allowText: samples.contains { $0.has_text },
            allowFilledGeometry: samples.contains { $0.has_fill },
            rejectIfTouchesLargerGeometry: false,
            rejectIfBulgeWhenSamplesHaveNone: true,
            rejectIfArcLikeWhenSamplesHaveNone: true,
            rejectIfHatchPatternDiffers: true,
            maxDiagonal: max(diagonalBase * 1.75, 1e-9),
            maxWidth: max(widthBase * 2.0, 1e-9),
            maxHeight: max(heightBase * 2.0, 1e-9),
            maxAverageSegmentLength: max(averageSegmentBase * 1.75, 1e-9),
            maxSegmentLength: max(segmentBase * 1.75, 1e-9),
            maxPrimitiveCount: max((samples.map(\.primitive_count).max() ?? 1) + (lineLikeSamples ? 1 : 0), 1),
            maxSegmentCount: max((samples.map(\.segment_count).max() ?? 1) + (lineLikeSamples ? 2 : 0), 1),
            targetDiagonal: targetDiagonal,
            targetAverageSegmentLength: targetAverageSegmentLength,
            scoreThreshold: lineLikeSamples ? 0.40 : 0.50,
            maxDiagonalMultiplier: 1.75,
            maxWidthMultiplier: 2.0,
            maxHeightMultiplier: 2.0,
            maxAverageSegmentLengthMultiplier: 1.75,
            maxSegmentLengthMultiplier: 1.75
        )
    }

    private static func mergeSelectionRule(
        _ aiRule: AISelectionClient.AISelectionRuleJSON,
        fallback: AISelectionClient.AISelectionRuleJSON
    ) -> AISelectionClient.AISelectionRuleJSON {
        func nonEmpty(_ value: [String]?, _ fallbackValue: [String]?) -> [String]? {
            guard let value, !value.isEmpty else { return fallbackValue }
            return value
        }
        func nonEmptyBool(_ value: [Bool]?, _ fallbackValue: [Bool]?) -> [Bool]? {
            guard let value, !value.isEmpty else { return fallbackValue }
            return value
        }
        func nonEmptyDouble(_ value: [Double]?, _ fallbackValue: [Double]?) -> [Double]? {
            guard let value, !value.isEmpty else { return fallbackValue }
            return value
        }
        func multiplierLimit(base: Double?, multiplier: Double?, fallbackValue: Double?) -> Double? {
            guard let base else { return fallbackValue }
            let m = max(multiplier ?? 1.0, 1.0)
            return max(base * m, fallbackValue ?? 0)
        }
        func relaxedMax(_ value: Double?, _ fallbackValue: Double?, multiplier: Double? = nil) -> Double? {
            guard let fallbackValue else { return value }
            let multiplied = multiplierLimit(base: fallbackValue / 1.75, multiplier: multiplier, fallbackValue: fallbackValue) ?? fallbackValue
            let lowerBound = max(fallbackValue, multiplied)
            guard let value else { return lowerBound }
            return min(max(value, lowerBound), lowerBound * 2.0)
        }
        func mergedThreshold(_ ai: Double?, _ fallbackValue: Double?) -> Double? {
            guard let fallbackValue else { return ai }
            guard let ai else { return fallbackValue }
            return min(max(ai, 0.25), fallbackValue)
        }
        func mergedCount(_ ai: Int?, _ fallbackValue: Int?) -> Int? {
            guard let fallbackValue else { return ai }
            guard let ai else { return fallbackValue }
            return min(max(ai, fallbackValue), max(fallbackValue * 3, fallbackValue))
        }

        let fallbackIsLineLike = fallback.allowedPrimitiveSignatures == nil
            && Set(fallback.allowedPrimitiveTypes ?? []).isSuperset(of: Set(["line", "polyline", "polygon"]))

        let allowedTypes: [String]?
        if fallbackIsLineLike {
            allowedTypes = unique((aiRule.allowedPrimitiveTypes ?? []) + (fallback.allowedPrimitiveTypes ?? []))
        } else {
            allowedTypes = nonEmpty(aiRule.allowedPrimitiveTypes, fallback.allowedPrimitiveTypes)
        }

        return AISelectionClient.AISelectionRuleJSON(
            intent: aiRule.intent ?? fallback.intent,
            allowedLayerNames: nonEmpty(aiRule.allowedLayerNames, fallback.allowedLayerNames),
            allowedColors: nonEmpty(aiRule.allowedColors, fallback.allowedColors),
            allowedLineTypes: unique((aiRule.allowedLineTypes ?? []) + (fallback.allowedLineTypes ?? [])),
            allowedLineWeights: nonEmptyDouble(aiRule.allowedLineWeights, fallback.allowedLineWeights),
            allowedPrimitiveSignatures: fallbackIsLineLike ? nil : nonEmpty(aiRule.allowedPrimitiveSignatures, fallback.allowedPrimitiveSignatures),
            allowedPrimitiveTypes: allowedTypes,
            allowedClosedShapeValues: nonEmptyBool(aiRule.allowedClosedShapeValues, fallback.allowedClosedShapeValues),
            allowedHatchPatterns: nonEmpty(aiRule.allowedHatchPatterns, fallback.allowedHatchPatterns),
            requireLayerMatch: aiRule.requireLayerMatch ?? fallback.requireLayerMatch,
            requireColorMatch: aiRule.requireColorMatch ?? fallback.requireColorMatch,
            requireLineTypeMatch: (fallback.requireLineTypeMatch ?? false) && (aiRule.requireLineTypeMatch ?? false),
            requireLineWeightMatch: (fallback.requireLineWeightMatch ?? false) && (aiRule.requireLineWeightMatch ?? false),
            allowBulgedPolylines: aiRule.allowBulgedPolylines ?? fallback.allowBulgedPolylines,
            allowArcLikeGeometry: aiRule.allowArcLikeGeometry ?? fallback.allowArcLikeGeometry,
            allowHatches: aiRule.allowHatches ?? fallback.allowHatches,
            allowText: aiRule.allowText ?? fallback.allowText,
            allowFilledGeometry: aiRule.allowFilledGeometry ?? fallback.allowFilledGeometry,
            rejectIfTouchesLargerGeometry: aiRule.rejectIfTouchesLargerGeometry ?? fallback.rejectIfTouchesLargerGeometry,
            rejectIfBulgeWhenSamplesHaveNone: aiRule.rejectIfBulgeWhenSamplesHaveNone ?? fallback.rejectIfBulgeWhenSamplesHaveNone,
            rejectIfArcLikeWhenSamplesHaveNone: aiRule.rejectIfArcLikeWhenSamplesHaveNone ?? fallback.rejectIfArcLikeWhenSamplesHaveNone,
            rejectIfHatchPatternDiffers: aiRule.rejectIfHatchPatternDiffers ?? fallback.rejectIfHatchPatternDiffers,
            maxDiagonal: relaxedMax(aiRule.maxDiagonal, fallback.maxDiagonal, multiplier: aiRule.maxDiagonalMultiplier),
            maxWidth: relaxedMax(aiRule.maxWidth, fallback.maxWidth, multiplier: aiRule.maxWidthMultiplier),
            maxHeight: relaxedMax(aiRule.maxHeight, fallback.maxHeight, multiplier: aiRule.maxHeightMultiplier),
            maxAverageSegmentLength: relaxedMax(aiRule.maxAverageSegmentLength, fallback.maxAverageSegmentLength, multiplier: aiRule.maxAverageSegmentLengthMultiplier),
            maxSegmentLength: relaxedMax(aiRule.maxSegmentLength, fallback.maxSegmentLength, multiplier: aiRule.maxSegmentLengthMultiplier),
            maxPrimitiveCount: mergedCount(aiRule.maxPrimitiveCount, fallback.maxPrimitiveCount),
            maxSegmentCount: mergedCount(aiRule.maxSegmentCount, fallback.maxSegmentCount),
            targetDiagonal: fallback.targetDiagonal,
            targetAverageSegmentLength: fallback.targetAverageSegmentLength,
            scoreThreshold: mergedThreshold(aiRule.scoreThreshold, fallback.scoreThreshold),
            maxDiagonalMultiplier: aiRule.maxDiagonalMultiplier ?? fallback.maxDiagonalMultiplier,
            maxWidthMultiplier: aiRule.maxWidthMultiplier ?? fallback.maxWidthMultiplier,
            maxHeightMultiplier: aiRule.maxHeightMultiplier ?? fallback.maxHeightMultiplier,
            maxAverageSegmentLengthMultiplier: aiRule.maxAverageSegmentLengthMultiplier ?? fallback.maxAverageSegmentLengthMultiplier,
            maxSegmentLengthMultiplier: aiRule.maxSegmentLengthMultiplier ?? fallback.maxSegmentLengthMultiplier
        )
    }

    private static func selectHandlesByRule(
        firstX: Double,
        firstY: Double,
        secondX: Double,
        secondY: Double,
        rule: AISelectionClient.AISelectionRuleJSON,
        sampleProfiles: [AISelectionClient.AISelectionEntityProfileJSON],
        engine: PhrostEngine
    ) -> Set<UUID> {
        let cam = engine.camera.currentTransform(
            windowWidth: engine.windowWidth,
            windowHeight: engine.windowHeight
        )
        let p1 = EngineCameraManager.worldToScreen(worldX: firstX, worldY: firstY, cam: cam)
        let p3 = EngineCameraManager.worldToScreen(worldX: secondX, worldY: secondY, cam: cam)
        let minSX = min(p1.x, p3.x)
        let maxSX = max(p1.x, p3.x)
        let minSY = min(p1.y, p3.y)
        let maxSY = max(p1.y, p3.y)

        let doc = engine.document
        var candidates: [RuleCandidate] = []
        candidates.reserveCapacity(512)

        for entity in doc.entitiesView {
            guard let layer = doc.layer(for: entity.layerID), layer.isVisible else { continue }
            guard let bb = entity.worldBoundingBox else { continue }
            guard entityBoundingBoxIsInsideScreenWindow(bb, minSX: minSX, maxSX: maxSX, minSY: minSY, maxSY: maxSY, cam: cam) else { continue }
            guard let profile = makeRuleProfile(for: entity, in: doc) else { continue }
            guard let scoreValue = score(profile: profile, entity: entity, rule: rule, in: doc), scoreValue >= (rule.scoreThreshold ?? 0.55) else { continue }
            candidates.append(RuleCandidate(
                entity: entity,
                profile: profile,
                segments: transformedRuleSegments(for: entity, in: doc),
                bbox: bb,
                score: scoreValue
            ))
        }

        if shouldUseMotifSelection(rule: rule, samples: sampleProfiles) {
            let selected = selectHandlesByMotif(
                candidates: candidates,
                sampleProfiles: sampleProfiles,
                rule: rule,
                document: doc
            )
            print("[AISelect] Motif pass reduced \(candidates.count) rule candidate(s) to \(selected.count) entity/entities.")
            return selected
        }

        return Set(candidates.map { $0.entity.handle })
    }

    private static func shouldUseMotifSelection(
        rule: AISelectionClient.AISelectionRuleJSON,
        samples: [AISelectionClient.AISelectionEntityProfileJSON]
    ) -> Bool {
        guard samplesAreLineLikeCleanup(samples) else { return false }
        if rule.allowArcLikeGeometry ?? false { return false }
        if rule.allowHatches ?? false { return false }
        if rule.allowText ?? false { return false }
        if rule.allowFilledGeometry ?? false { return false }
        return true
    }

    private static func selectHandlesByMotif(
        candidates: [RuleCandidate],
        sampleProfiles: [AISelectionClient.AISelectionEntityProfileJSON],
        rule: AISelectionClient.AISelectionRuleJSON,
        document: CADDocument
    ) -> Set<UUID> {
        guard !candidates.isEmpty else { return [] }
        let config = makeMotifConfig(from: sampleProfiles, rule: rule)
        let clusters = clusterRuleCandidates(candidates, tolerance: config.proximityTolerance)
        var selected = Set<UUID>()

        for cluster in clusters {
            if isIsolatedDashMotif(cluster, config: config) || isTriangleLikeMotif(cluster, config: config) {
                for candidate in cluster {
                    selected.insert(candidate.entity.handle)
                }
            }
        }

        return selected
    }

    private static func makeMotifConfig(
        from samples: [AISelectionClient.AISelectionEntityProfileJSON],
        rule: AISelectionClient.AISelectionRuleJSON
    ) -> MotifConfig {
        let lineSamples = samples.filter(isLineLikeSample(_:))
        let usableSamples = lineSamples.isEmpty ? samples : lineSamples
        let dashSamples = usableSamples.filter { sample in
            sample.segment_count <= 2
                && sample.bbox_diagonal > 0
                && !sample.is_closed_shape
                && !isTriangleLikeSample(sample)
        }
        let triangleSamples = usableSamples.filter(isTriangleLikeSample(_:))

        let sampleDiagonalBase = robustUpperBound(usableSamples.map(\.bbox_diagonal))
        let sampleSegmentBase = robustUpperBound(usableSamples.map(\.max_segment_length))
        let dashBase = robustUpperBound(dashSamples.map(\.bbox_diagonal))
        let triangleBase = robustUpperBound((triangleSamples.isEmpty ? usableSamples : triangleSamples).map(\.bbox_diagonal))

        let dashMax = max(
            dashBase > 0 ? dashBase * 1.35 : 0,
            min(sampleDiagonalBase * 0.70, sampleSegmentBase * 1.85),
            1e-8
        )
        let triangleMax = max(
            rule.maxDiagonal ?? 0,
            triangleBase * 1.60,
            sampleDiagonalBase * 1.35,
            dashMax * 2.25,
            1e-8
        )
        let tolerance = max(
            median(usableSamples.map(\.max_segment_length)) * 0.28,
            triangleMax * 0.045,
            1e-6
        )
        let maxSeg = max(
            rule.maxSegmentCount ?? 0,
            (triangleSamples.map(\.segment_count).max() ?? 0) + 3,
            6
        )

        return MotifConfig(
            hasDashMotif: !dashSamples.isEmpty || triangleSamples.isEmpty,
            hasTriangleMotif: !triangleSamples.isEmpty || usableSamples.contains { $0.segment_count >= 3 || $0.is_closed_shape },
            dashMaxDiagonal: dashMax,
            triangleMaxDiagonal: triangleMax,
            proximityTolerance: tolerance,
            maxTriangleSegmentCount: maxSeg
        )
    }

    private static func isLineLikeSample(_ sample: AISelectionClient.AISelectionEntityProfileJSON) -> Bool {
        !sample.has_bulged_polyline
            && !sample.has_arc_like_geometry
            && !sample.has_hatch
            && !sample.has_text
            && !sample.has_fill
            && Set(sample.primitive_types).isSubset(of: Set(["line", "polyline", "polygon"]))
    }

    private static func isTriangleLikeSample(_ sample: AISelectionClient.AISelectionEntityProfileJSON) -> Bool {
        guard isLineLikeSample(sample) else { return false }
        guard sample.segment_count >= 3 && sample.segment_count <= 8 else { return false }
        guard sample.bbox_diagonal > 1e-12 else { return false }
        let compactness = min(sample.bbox_width, sample.bbox_height) / max(sample.bbox_diagonal, 1e-12)
        if sample.is_closed_shape { return compactness >= 0.12 }
        if sample.relative_angles.count >= 2 { return compactness >= 0.12 }
        return compactness >= 0.18
    }

    private static func isIsolatedDashMotif(_ cluster: [RuleCandidate], config: MotifConfig) -> Bool {
        guard config.hasDashMotif, cluster.count == 1, let candidate = cluster.first else { return false }
        let extent = clusterExtent(cluster)
        guard extent.diagonal > 0 && extent.diagonal <= config.dashMaxDiagonal else { return false }
        guard candidate.profile.segment_count <= 2 else { return false }
        if candidate.profile.is_closed_shape { return false }
        let compactness = min(extent.width, extent.height) / max(extent.diagonal, 1e-12)
        return compactness <= 0.35 || extent.diagonal <= config.dashMaxDiagonal * 0.65
    }

    private static func isTriangleLikeMotif(_ cluster: [RuleCandidate], config: MotifConfig) -> Bool {
        guard config.hasTriangleMotif else { return false }
        let segments = cluster.flatMap { $0.segments }.filter { segmentLength($0) > 1e-12 }
        guard segments.count >= 3 && segments.count <= max(config.maxTriangleSegmentCount, 6) else { return false }

        let extent = clusterExtent(cluster)
        guard extent.diagonal > 0 && extent.diagonal <= config.triangleMaxDiagonal else { return false }
        let compactness = min(extent.width, extent.height) / max(extent.diagonal, 1e-12)
        guard compactness >= 0.16 else { return false }

        let orientationCount = orientationGroupCount(segments, toleranceDegrees: 18.0)
        guard orientationCount >= 3 else { return false }

        let graph = endpointGraphStats(segments, tolerance: max(config.proximityTolerance * 1.75, extent.diagonal * 0.10))
        guard graph.nodeCount >= 3 && graph.nodeCount <= 8 else { return false }
        guard graph.leafCount <= 4 else { return false }
        return true
    }

    private static func clusterRuleCandidates(_ candidates: [RuleCandidate], tolerance: Double) -> [[RuleCandidate]] {
        guard !candidates.isEmpty else { return [] }
        var parent = Array(0..<candidates.count)
        var rank = Array(repeating: 0, count: candidates.count)

        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }

        func union(_ a: Int, _ b: Int) {
            let ra = find(a)
            let rb = find(b)
            guard ra != rb else { return }
            if rank[ra] < rank[rb] { parent[ra] = rb }
            else if rank[ra] > rank[rb] { parent[rb] = ra }
            else { parent[rb] = ra; rank[ra] += 1 }
        }

        for i in 0..<candidates.count {
            let expanded = candidates[i].bbox.expanded(by: tolerance)
            for j in (i + 1)..<candidates.count {
                guard expanded.intersects(candidates[j].bbox.expanded(by: tolerance)) else { continue }
                if candidatesTouch(candidates[i], candidates[j], tolerance: tolerance) {
                    union(i, j)
                }
            }
        }

        var groups: [Int: [RuleCandidate]] = [:]
        for i in 0..<candidates.count {
            groups[find(i), default: []].append(candidates[i])
        }
        return Array(groups.values)
    }

    private static func candidatesTouch(_ a: RuleCandidate, _ b: RuleCandidate, tolerance: Double) -> Bool {
        if a.segments.isEmpty || b.segments.isEmpty { return true }
        return segmentsTouch(a.segments, b.segments, tolerance: tolerance)
    }

    private static func segmentsTouch(_ a: [RuleSegment], _ b: [RuleSegment], tolerance: Double) -> Bool {
        let tolSq = tolerance * tolerance
        for sa in a {
            for sb in b {
                if distSq(sa.start, sb.start) <= tolSq { return true }
                if distSq(sa.start, sb.end) <= tolSq { return true }
                if distSq(sa.end, sb.start) <= tolSq { return true }
                if distSq(sa.end, sb.end) <= tolSq { return true }
                if pointToSegmentDistSq(sa.start, sb.start, sb.end) <= tolSq { return true }
                if pointToSegmentDistSq(sa.end, sb.start, sb.end) <= tolSq { return true }
                if pointToSegmentDistSq(sb.start, sa.start, sa.end) <= tolSq { return true }
                if pointToSegmentDistSq(sb.end, sa.start, sa.end) <= tolSq { return true }
            }
        }
        return false
    }

    private static func clusterExtent(_ cluster: [RuleCandidate]) -> (width: Double, height: Double, diagonal: Double) {
        var minX = Double.infinity
        var minY = Double.infinity
        var maxX = -Double.infinity
        var maxY = -Double.infinity
        for candidate in cluster {
            minX = min(minX, candidate.bbox.min.x)
            minY = min(minY, candidate.bbox.min.y)
            maxX = max(maxX, candidate.bbox.max.x)
            maxY = max(maxY, candidate.bbox.max.y)
        }
        guard minX.isFinite, minY.isFinite, maxX.isFinite, maxY.isFinite else { return (0, 0, 0) }
        let width = maxX - minX
        let height = maxY - minY
        return (width, height, hypot(width, height))
    }

    private static func endpointGraphStats(_ segments: [RuleSegment], tolerance: Double) -> EndpointGraphStats {
        var nodes: [Vector3] = []
        var degrees: [Int] = []

        func nodeIndex(for point: Vector3) -> Int {
            let tolSq = tolerance * tolerance
            for i in 0..<nodes.count where distSq(nodes[i], point) <= tolSq {
                return i
            }
            nodes.append(point)
            degrees.append(0)
            return nodes.count - 1
        }

        for segment in segments {
            let a = nodeIndex(for: segment.start)
            let b = nodeIndex(for: segment.end)
            degrees[a] += 1
            degrees[b] += 1
        }

        return EndpointGraphStats(
            nodeCount: nodes.count,
            leafCount: degrees.filter { $0 == 1 }.count,
            maxDegree: degrees.max() ?? 0
        )
    }

    private static func orientationGroupCount(_ segments: [RuleSegment], toleranceDegrees: Double) -> Int {
        var angles = segments.compactMap { segment -> Double? in
            let dx = segment.end.x - segment.start.x
            let dy = segment.end.y - segment.start.y
            guard hypot(dx, dy) > 1e-12 else { return nil }
            var angle = atan2(dy, dx) * 180.0 / Double.pi
            while angle < 0 { angle += 180.0 }
            while angle >= 180.0 { angle -= 180.0 }
            return angle
        }.sorted()
        guard !angles.isEmpty else { return 0 }

        var groups: [Double] = []
        for angle in angles {
            if let last = groups.last, abs(angle - last) <= toleranceDegrees {
                groups[groups.count - 1] = (last + angle) * 0.5
            } else {
                groups.append(angle)
            }
        }
        if groups.count > 1,
           let first = groups.first,
           let last = groups.last,
           abs((first + 180.0) - last) <= toleranceDegrees {
            groups.removeLast()
        }
        return groups.count
    }

    private static func transformedRuleSegments(for entity: CADEntity, in document: CADDocument) -> [RuleSegment] {
        guard let geometry = document.resolvedGeometry(for: entity) else { return [] }
        let transform = entity.transform
        return geometry.flatMap { primitive in
            ruleSegments(from: primitive).map { segment in
                RuleSegment(
                    start: transform.transformPoint(segment.start),
                    end: transform.transformPoint(segment.end)
                )
            }
        }
    }

    private static func segmentLength(_ segment: RuleSegment) -> Double {
        hypot(segment.end.x - segment.start.x, segment.end.y - segment.start.y)
    }

    private static func distSq(_ a: Vector3, _ b: Vector3) -> Double {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return dx * dx + dy * dy
    }

    private static func pointToSegmentDistSq(_ p: Vector3, _ a: Vector3, _ b: Vector3) -> Double {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        if lenSq < 1e-12 { return distSq(p, a) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq
        t = max(0, min(1, t))
        let px = a.x + t * dx
        let py = a.y + t * dy
        let ex = p.x - px
        let ey = p.y - py
        return ex * ex + ey * ey
    }

    private static func score(
        profile: AISelectionClient.AISelectionEntityProfileJSON,
        entity: CADEntity,
        rule: AISelectionClient.AISelectionRuleJSON,
        in document: CADDocument
    ) -> Double? {
        if rule.requireLayerMatch ?? false {
            guard contains(rule.allowedLayerNames, profile.layer_name) else { return nil }
        }
        if rule.requireColorMatch ?? false {
            guard contains(rule.allowedColors, profile.effective_color) else { return nil }
        }
        if rule.requireLineTypeMatch ?? false {
            guard lineTypeMatches(rule.allowedLineTypes, profile: profile) else { return nil }
        }
        if rule.requireLineWeightMatch ?? false, let allowed = rule.allowedLineWeights, !allowed.isEmpty {
            let matched = allowed.contains { abs($0 - profile.effective_line_weight) <= 0.0001 }
            guard matched else { return nil }
        }
        if let allowed = rule.allowedPrimitiveSignatures, !allowed.isEmpty {
            guard primitiveSignatureMatches(allowed, profile: profile) else { return nil }
        }
        if let allowed = rule.allowedPrimitiveTypes, !allowed.isEmpty {
            let allowedSet = Set(allowed)
            guard Set(profile.primitive_types).isSubset(of: allowedSet) else { return nil }
        }
        if let allowed = rule.allowedClosedShapeValues, !allowed.isEmpty {
            guard allowed.contains(profile.is_closed_shape) else { return nil }
        }
        if profile.has_bulged_polyline && !(rule.allowBulgedPolylines ?? false) { return nil }
        if profile.has_bulged_polyline && (rule.rejectIfBulgeWhenSamplesHaveNone ?? true) && !(rule.allowBulgedPolylines ?? false) { return nil }
        if profile.has_arc_like_geometry && !(rule.allowArcLikeGeometry ?? false) { return nil }
        if profile.has_arc_like_geometry && (rule.rejectIfArcLikeWhenSamplesHaveNone ?? true) && !(rule.allowArcLikeGeometry ?? false) { return nil }
        if profile.has_hatch && !(rule.allowHatches ?? false) { return nil }
        if profile.has_text && !(rule.allowText ?? false) { return nil }
        if profile.has_fill && !(rule.allowFilledGeometry ?? false) { return nil }
        if (rule.rejectIfHatchPatternDiffers ?? true), let allowed = rule.allowedHatchPatterns, !allowed.isEmpty, profile.has_hatch {
            guard Set(profile.hatch_patterns).isSubset(of: Set(allowed)) else { return nil }
        }
        if let max = rule.maxDiagonal, profile.bbox_diagonal > max { return nil }
        if let max = rule.maxWidth, profile.bbox_width > max { return nil }
        if let max = rule.maxHeight, profile.bbox_height > max { return nil }
        if let max = rule.maxAverageSegmentLength, profile.average_segment_length > max { return nil }
        if let max = rule.maxSegmentLength, profile.max_segment_length > max { return nil }
        if let max = rule.maxPrimitiveCount, profile.primitive_count > max { return nil }
        if let max = rule.maxSegmentCount, profile.segment_count > max { return nil }
        if (rule.rejectIfTouchesLargerGeometry ?? false), touchesLargerGeometry(entity, profile: profile, rule: rule, in: document) {
            return nil
        }

        var score = 1.0
        if let target = rule.targetDiagonal, target > 1e-12, profile.bbox_diagonal > 1e-12 {
            score -= min(abs(log(profile.bbox_diagonal / target)) * 0.12, 0.30)
        }
        if let target = rule.targetAverageSegmentLength, target > 1e-12, profile.average_segment_length > 1e-12 {
            score -= min(abs(log(profile.average_segment_length / target)) * 0.10, 0.25)
        }
        return max(0.0, min(1.0, score))
    }

    private static func makeRuleProfile(
        for entity: CADEntity,
        in document: CADDocument
    ) -> AISelectionClient.AISelectionEntityProfileJSON? {
        guard let geometry = document.resolvedGeometry(for: entity), !geometry.isEmpty else { return nil }
        let layer = document.layer(for: entity.layerID)
        let bb = entity.worldBoundingBox
        let size = bb?.size ?? .zero
        let diagonal = hypot(size.x, size.y)
        let primitiveTypes = geometry.map { primitiveTypeName($0) }
        let signature = primitiveTypes.sorted().joined(separator: "+")
        let segments = geometry.flatMap { ruleSegments(from: $0) }
        let segmentLengths = segments.map { hypot($0.end.x - $0.start.x, $0.end.y - $0.start.y) }.filter { $0 > 1e-12 }
        let avgSegment = average(segmentLengths)
        let minSegment = segmentLengths.min() ?? 0
        let maxSegment = segmentLengths.max() ?? 0
        let clusterProfile = EntityClustering.extractProfile(from: EntityCluster(entities: [entity.handle]), in: document)
        let scale = entity.transform.scale
        let xdata = xdataStrings(entity.xdata)
        let explicitColor = xdata["dxf.color"]
        let explicitLineType = xdata["dxf.lineType"]
        let explicitLineWeight = explicitLineWeightValue(entity.xdata)
        let lineType = explicitLineType ?? layer?.lineType ?? "CONTINUOUS"
        let lineWeight = explicitLineWeight ?? layer?.lineWeight ?? 0.25

        return AISelectionClient.AISelectionEntityProfileJSON(
            sample_id: entity.handle.uuidString,
            layer_name: layer?.name ?? "<missing>",
            layer_line_type: layer?.lineType ?? "CONTINUOUS",
            layer_line_weight: layer?.lineWeight ?? 0.25,
            layer_opacity: layer?.opacity ?? 1.0,
            effective_color: colorHex(CleanSpecklesCommand.resolveColor(for: entity, in: document)),
            explicit_color: explicitColor,
            effective_line_type: lineType,
            explicit_line_type: explicitLineType,
            effective_line_weight: lineWeight,
            explicit_line_weight: explicitLineWeight,
            plot_style: firstXDataString(entity.xdata, keys: ["dxf.plotStyle", "dxf.plot_style", "plotStyle", "plot_style", "plotstyle"]),
            primitive_signature: signature,
            primitive_types: primitiveTypes.sorted(),
            primitive_count: geometry.count,
            segment_count: segments.count,
            has_bulged_polyline: geometry.contains { if case .polyline(let path, _) = $0 { return path.hasBulges } else { return false } },
            has_arc_like_geometry: geometry.contains(where: isArcLikePrimitive(_:)),
            has_hatch: geometry.contains { if case .hatch = $0 { return true } else { return false } },
            hatch_patterns: geometry.compactMap { if case .hatch(_, let pattern, _, _, _, _) = $0 { return pattern } else { return nil } }.sorted(),
            has_text: geometry.contains { if case .text = $0 { return true } else { return false } },
            has_fill: geometry.contains(where: isFilledPrimitive(_:)),
            is_closed_shape: clusterProfile?.is_closed_shape ?? geometry.contains(where: isClosedPrimitive(_:)),
            bbox_width: abs(size.x),
            bbox_height: abs(size.y),
            bbox_diagonal: diagonal,
            average_segment_length: avgSegment,
            min_segment_length: minSegment,
            max_segment_length: maxSegment,
            relative_angles: clusterProfile?.relative_angles ?? [],
            normalized_gaps: clusterProfile?.normalized_gaps ?? [],
            transform_rotation: entity.transform.rotation,
            transform_scale_x: scale.x,
            transform_scale_y: scale.y,
            draw_order: entity.drawOrder,
            xdata: xdata
        )
    }

    private static func entityBoundingBoxIsInsideScreenWindow(
        _ bb: BoundingBox3D,
        minSX: Float,
        maxSX: Float,
        minSY: Float,
        maxSY: Float,
        cam: CameraTransform
    ) -> Bool {
        let c1 = EngineCameraManager.worldToScreen(worldX: bb.min.x, worldY: bb.min.y, cam: cam)
        let c2 = EngineCameraManager.worldToScreen(worldX: bb.max.x, worldY: bb.min.y, cam: cam)
        let c3 = EngineCameraManager.worldToScreen(worldX: bb.max.x, worldY: bb.max.y, cam: cam)
        let c4 = EngineCameraManager.worldToScreen(worldX: bb.min.x, worldY: bb.max.y, cam: cam)
        let eMinSX = min(c1.x, c2.x, c3.x, c4.x)
        let eMaxSX = max(c1.x, c2.x, c3.x, c4.x)
        let eMinSY = min(c1.y, c2.y, c3.y, c4.y)
        let eMaxSY = max(c1.y, c2.y, c3.y, c4.y)
        return eMinSX >= minSX && eMaxSX <= maxSX && eMinSY >= minSY && eMaxSY <= maxSY
    }

    private static func touchesLargerGeometry(
        _ entity: CADEntity,
        profile: AISelectionClient.AISelectionEntityProfileJSON,
        rule: AISelectionClient.AISelectionRuleJSON,
        in document: CADDocument
    ) -> Bool {
        guard let bb = entity.worldBoundingBox else { return false }
        let probe = bb.expanded(by: max(profile.bbox_diagonal * 0.15, 1e-6))
        let largeThreshold = max(rule.maxDiagonal ?? profile.bbox_diagonal, profile.bbox_diagonal * 2.0)
        for other in document.entitiesView where other.handle != entity.handle {
            guard let layer = document.layer(for: other.layerID), layer.isVisible else { continue }
            guard let otherBB = other.worldBoundingBox, probe.intersects(otherBB) else { continue }
            let s = otherBB.size
            if hypot(s.x, s.y) > largeThreshold { return true }
        }
        return false
    }

    private static func ruleSegments(from prim: CADPrimitive) -> [RuleSegment] {
        switch prim {
        case .line(let start, let end, _):
            return [RuleSegment(start: start, end: end)]
        case .polyline(let path, _):
            let points = path.tessellatedPoints()
            guard points.count >= 2 else { return [] }
            var out: [RuleSegment] = []
            for i in 0..<(points.count - 1) { out.append(RuleSegment(start: points[i], end: points[i + 1])) }
            if path.isClosed, let first = points.first, let last = points.last { out.append(RuleSegment(start: last, end: first)) }
            return out
        case .polygon(let points, _), .fillPolygon(let points, _):
            return chainSegments(points: points, closed: true)
        case .rect(let origin, let size, _), .fillRect(let origin, let size, _):
            let p0 = origin
            let p1 = Vector3(x: origin.x + size.x, y: origin.y, z: origin.z)
            let p2 = Vector3(x: origin.x + size.x, y: origin.y + size.y, z: origin.z)
            let p3 = Vector3(x: origin.x, y: origin.y + size.y, z: origin.z)
            return chainSegments(points: [p0, p1, p2, p3], closed: true)
        case .arc(let center, let radius, let startAngle, let endAngle, _):
            let start = Vector3(x: center.x + cos(startAngle) * radius, y: center.y + sin(startAngle) * radius, z: center.z)
            let end = Vector3(x: center.x + cos(endAngle) * radius, y: center.y + sin(endAngle) * radius, z: center.z)
            return [RuleSegment(start: start, end: end)]
        case .circle(let center, let radius, _):
            return [
                RuleSegment(start: Vector3(x: center.x - radius, y: center.y, z: center.z), end: Vector3(x: center.x + radius, y: center.y, z: center.z)),
                RuleSegment(start: Vector3(x: center.x, y: center.y - radius, z: center.z), end: Vector3(x: center.x, y: center.y + radius, z: center.z)),
            ]
        case .ellipse(let center, let majorAxis, let minorRatio, _):
            let major = hypot(majorAxis.x, majorAxis.y)
            let minor = major * minorRatio
            return [
                RuleSegment(start: Vector3(x: center.x - major, y: center.y, z: center.z), end: Vector3(x: center.x + major, y: center.y, z: center.z)),
                RuleSegment(start: Vector3(x: center.x, y: center.y - minor, z: center.z), end: Vector3(x: center.x, y: center.y + minor, z: center.z)),
            ]
        case .spline(let controlPoints, _, _, _, _):
            return chainSegments(points: controlPoints, closed: false)
        case .hatch(let boundary, _, _, _, _, _):
            return chainSegments(points: boundary, closed: true)
        case .fillComplexPolygon(let outer, let holes, _):
            return chainSegments(points: outer, closed: true) + holes.flatMap { chainSegments(points: $0, closed: true) }
        default:
            return []
        }
    }

    private static func chainSegments(points: [Vector3], closed: Bool) -> [RuleSegment] {
        guard points.count >= 2 else { return [] }
        var out: [RuleSegment] = []
        for i in 0..<(points.count - 1) { out.append(RuleSegment(start: points[i], end: points[i + 1])) }
        if closed, let first = points.first, let last = points.last { out.append(RuleSegment(start: last, end: first)) }
        return out
    }

    private static func isArcLikePrimitive(_ prim: CADPrimitive) -> Bool {
        switch prim {
        case .arc, .circle, .ellipse:
            return true
        case .polyline(let path, _):
            return path.hasBulges
        default:
            return false
        }
    }

    private static func isClosedPrimitive(_ prim: CADPrimitive) -> Bool {
        switch prim {
        case .rect, .fillRect, .polygon, .fillPolygon, .fillComplexPolygon, .gradient, .circle, .ellipse, .hatch:
            return true
        case .polyline(let path, _):
            return path.isClosed
        default:
            return false
        }
    }

    private static func isFilledPrimitive(_ prim: CADPrimitive) -> Bool {
        switch prim {
        case .fillRect, .fillPolygon, .fillComplexPolygon, .gradient, .hatch:
            return true
        default:
            return false
        }
    }

    private static func colorHex(_ color: ColorRGBA) -> String {
        String(format: "#%02X%02X%02X%02X", Int(color.r), Int(color.g), Int(color.b), Int(color.a))
    }

    private static func xdataStrings(_ xdata: [String: XDataValue]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: xdata.map { entry in (entry.key, xdataString(entry.value)) })
    }

    private static func xdataString(_ value: XDataValue) -> String {
        switch value {
        case .string(let s): return s
        case .double(let d): return String(d)
        case .int(let i): return String(i)
        case .bool(let b): return b ? "true" : "false"
        case .date(let d): return ISO8601DateFormatter().string(from: d)
        }
    }

    private static func firstXDataString(_ xdata: [String: XDataValue], keys: [String]) -> String? {
        for key in keys {
            if let value = xdata[key] { return xdataString(value) }
        }
        return nil
    }

    private static func explicitLineWeightValue(_ xdata: [String: XDataValue]) -> Double? {
        guard let value = xdata["dxf.lineWeight"] else { return nil }
        switch value {
        case .double(let d): return d
        case .int(let i): return Double(i)
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    private static func contains(_ values: [String]?, _ value: String) -> Bool {
        guard let values, !values.isEmpty else { return true }
        return values.contains(value)
    }

    private static func lineTypeMatches(
        _ allowed: [String]?,
        profile: AISelectionClient.AISelectionEntityProfileJSON
    ) -> Bool {
        guard let allowed, !allowed.isEmpty else { return true }
        let candidateValues = [
            profile.effective_line_type,
            profile.explicit_line_type,
            profile.layer_line_type,
            normalizedLineType(profile.effective_line_type),
            normalizedLineType(profile.explicit_line_type),
            normalizedLineType(profile.layer_line_type),
        ].compactMap { $0 }

        var allowedValues = Set<String>()
        for value in allowed {
            allowedValues.insert(value)
            if let normalized = normalizedLineType(value) {
                allowedValues.insert(normalized)
            }
        }
        return candidateValues.contains { allowedValues.contains($0) }
    }

    private static func normalizedLineType(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let upper = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if upper == "BYLAYER" || upper == "CONTINUOUS" || upper == "CONTINUE" {
            return "CONTINUOUS"
        }
        return upper
    }

    private static func primitiveSignatureMatches(
        _ allowed: [String],
        profile: AISelectionClient.AISelectionEntityProfileJSON
    ) -> Bool {
        if allowed.contains(profile.primitive_signature) { return true }

        let allowedSet = Set(allowed)
        let lineLikeAliases: Set<String> = ["line", "polyline", "polygon", "line+polyline", "polyline+polygon", "line+polygon"]
        if !allowedSet.intersection(lineLikeAliases).isEmpty,
           !profile.has_bulged_polyline,
           !profile.has_arc_like_geometry,
           !profile.has_hatch,
           !profile.has_text,
           !profile.has_fill,
           Set(profile.primitive_types).isSubset(of: Set(["line", "polyline", "polygon"])) {
            return true
        }

        return false
    }

    private static func samplesAreLineLikeCleanup(_ samples: [AISelectionClient.AISelectionEntityProfileJSON]) -> Bool {
        guard !samples.isEmpty else { return false }
        return samples.allSatisfy { sample in
            !sample.has_bulged_polyline
            && !sample.has_arc_like_geometry
            && !sample.has_hatch
            && !sample.has_text
            && !sample.has_fill
            && Set(sample.primitive_types).isSubset(of: Set(["line", "polyline", "polygon"]))
        }
    }

    private static func robustUpperBound(_ values: [Double]) -> Double {
        let filtered = values.filter { $0.isFinite && $0 > 0 }.sorted()
        guard !filtered.isEmpty else { return 0.05 }
        let p95 = percentile(filtered, fraction: 0.95)
        let maxValue = filtered.last ?? p95
        return max(p95, maxValue * 0.85)
    }

    private static func median(_ values: [Double]) -> Double {
        percentile(values.filter { $0.isFinite && $0 > 0 }.sorted(), fraction: 0.50)
    }

    private static func percentile(_ sortedValues: [Double], fraction: Double) -> Double {
        guard !sortedValues.isEmpty else { return 0 }
        if sortedValues.count == 1 { return sortedValues[0] }
        let clamped = max(0, min(1, fraction))
        let index = clamped * Double(sortedValues.count - 1)
        let lower = Int(floor(index))
        let upper = Int(ceil(index))
        if lower == upper { return sortedValues[lower] }
        let t = index - Double(lower)
        return sortedValues[lower] * (1 - t) + sortedValues[upper] * t
    }

    private static func unique<T: Hashable>(_ values: [T]) -> [T] {
        Array(Set(values)).sorted { String(describing: $0) < String(describing: $1) }
    }

    private static func uniqueRounded(_ values: [Double], places: Int) -> [Double] {
        let factor = pow(10.0, Double(places))
        return unique(values.map { ($0 * factor).rounded() / factor })
    }

    private static func average(_ values: [Double]) -> Double {
        let filtered = values.filter { $0.isFinite && $0 > 0 }
        guard !filtered.isEmpty else { return 0 }
        return filtered.reduce(0, +) / Double(filtered.count)
    }

    // MARK: - AI Speckle Candidate Gatekeeper

    private static func makeSpeckleAICandidates(
        firstX: Double,
        firstY: Double,
        secondX: Double,
        secondY: Double,
        sampleColors: Set<ColorRGBA>,
        maxDiagonal: Double,
        samplePrimitiveSignatures: Set<String>,
        maxDiagonalByPrimitiveSignature: [String: Double],
        samples: [ClusterProfileJSON],
        engine: PhrostEngine
    ) -> [RankedCanvasCluster] {
        let cam = engine.camera.currentTransform(
            windowWidth: engine.windowWidth,
            windowHeight: engine.windowHeight
        )
        let p1 = EngineCameraManager.worldToScreen(worldX: firstX, worldY: firstY, cam: cam)
        let p3 = EngineCameraManager.worldToScreen(worldX: secondX, worldY: secondY, cam: cam)

        let minSX = min(p1.x, p3.x)
        let maxSX = max(p1.x, p3.x)
        let minSY = min(p1.y, p3.y)
        let maxSY = max(p1.y, p3.y)

        let doc = engine.document
        var ranked: [RankedCanvasCluster] = []

        for entity in doc.entitiesView {
            guard let layer = doc.layer(for: entity.layerID), layer.isVisible else { continue }
            guard sampleColors.contains(CleanSpecklesCommand.resolveColor(for: entity, in: doc)) else { continue }
            guard let bb = entity.worldBoundingBox else { continue }

            let c1 = EngineCameraManager.worldToScreen(worldX: bb.min.x, worldY: bb.min.y, cam: cam)
            let c2 = EngineCameraManager.worldToScreen(worldX: bb.max.x, worldY: bb.min.y, cam: cam)
            let c3 = EngineCameraManager.worldToScreen(worldX: bb.max.x, worldY: bb.max.y, cam: cam)
            let c4 = EngineCameraManager.worldToScreen(worldX: bb.min.x, worldY: bb.max.y, cam: cam)

            let eMinSX = min(c1.x, c2.x, c3.x, c4.x)
            let eMaxSX = max(c1.x, c2.x, c3.x, c4.x)
            let eMinSY = min(c1.y, c2.y, c3.y, c4.y)
            let eMaxSY = max(c1.y, c2.y, c3.y, c4.y)

            guard eMinSX >= minSX && eMaxSX <= maxSX
                && eMinSY >= minSY && eMaxSY <= maxSY else { continue }

            guard let geometry = doc.resolvedGeometry(for: entity),
                  geometry.count < 10,
                  geometry.allSatisfy(CleanSpecklesCommand.isSpecklePrimitive(_:))
            else { continue }

            let signature = primitiveSignature(for: geometry)
            guard samplePrimitiveSignatures.contains(signature) else { continue }

            let diag = hypot(bb.max.x - bb.min.x, bb.max.y - bb.min.y)
            let signatureMax = maxDiagonalByPrimitiveSignature[signature] ?? maxDiagonal
            guard diag < max(signatureMax * 1.2, 1e-9) else { continue }

            let cluster = EntityCluster(entities: [entity.handle])
            guard let profile = EntityClustering.extractProfile(from: cluster, in: doc) else { continue }

            ranked.append(RankedCanvasCluster(
                cluster: cluster,
                profile: profile,
                score: profileDistance(profile, samples: samples)
            ))
        }

        return ranked.sorted { lhs, rhs in
            if lhs.score == rhs.score { return lhs.profile.max_diagonal < rhs.profile.max_diagonal }
            return lhs.score < rhs.score
        }
    }

    private static func primitiveSignature(for geometry: [CADPrimitive]) -> String {
        geometry.map { primitiveTypeName($0) }.sorted().joined(separator: "+")
    }

    private static func primitiveTypeName(_ prim: CADPrimitive) -> String {
        switch prim {
        case .point: return "point"
        case .line: return "line"
        case .rect: return "rect"
        case .fillRect: return "fillRect"
        case .polygon: return "polygon"
        case .polyline(let path, _): return path.hasBulges ? "polylineBulge" : "polyline"
        case .fillPolygon: return "fillPolygon"
        case .fillComplexPolygon: return "fillComplexPolygon"
        case .gradient: return "gradient"
        case .circle: return "circle"
        case .arc: return "arc"
        case .spline: return "spline"
        case .text: return "text"
        case .ellipse: return "ellipse"
        case .hatch: return "hatch"
        case .ray: return "ray"
        case .image: return "image"
        }
    }

    // MARK: - Local Similarity Ranking

    private static func compactProfiles(_ profiles: [ClusterProfileJSON], maxCount: Int) -> [ClusterProfileJSON] {
        guard profiles.count > maxCount else { return profiles }

        var seen = Set<String>()
        var compacted: [ClusterProfileJSON] = []
        compacted.reserveCapacity(maxCount)

        for profile in profiles.sorted(by: { $0.max_diagonal > $1.max_diagonal }) {
            let key = profileSignature(profile)
            if seen.insert(key).inserted {
                compacted.append(profile)
                if compacted.count >= maxCount { break }
            }
        }

        if compacted.isEmpty {
            return Array(profiles.prefix(maxCount))
        }
        return compacted
    }

    private static func profileSignature(_ profile: ClusterProfileJSON) -> String {
        let typeKey = profile.types.joined(separator: ",")
        let lengthBucket = Int((profile.average_length * 100_000.0).rounded())
        let diagonalBucket = Int((profile.max_diagonal * 100_000.0).rounded())
        let spreadBucket = Int((profile.spread_factor * 100.0).rounded())
        return "\(profile.entity_count)|\(typeKey)|\(profile.is_closed_shape)|\(lengthBucket)|\(diagonalBucket)|\(spreadBucket)"
    }

    private static func profileDistance(_ candidate: ClusterProfileJSON, samples: [ClusterProfileJSON]) -> Double {
        samples.map { profileDistance(candidate, sample: $0) }.min() ?? Double.greatestFiniteMagnitude
    }

    private static func profileDistance(_ candidate: ClusterProfileJSON, sample: ClusterProfileJSON) -> Double {
        var score = 0.0

        let maxEntityCount = max(max(candidate.entity_count, sample.entity_count), 1)
        score += Double(abs(candidate.entity_count - sample.entity_count)) / Double(maxEntityCount) * 3.0

        let candidateTypes = Set(candidate.types)
        let sampleTypes = Set(sample.types)
        if candidateTypes.intersection(sampleTypes).isEmpty {
            score += 5.0
        }

        score += boundedLogRatio(candidate.average_length, sample.average_length) * 1.5
        score += boundedLogRatio(candidate.max_diagonal, sample.max_diagonal) * 1.5
        score += boundedLogRatio(candidate.spread_factor, sample.spread_factor) * 0.75
        score += distributionDistance(candidate.normalized_gaps, sample.normalized_gaps) * 0.75
        score += (distributionDistance(candidate.relative_angles, sample.relative_angles) / 180.0) * 0.75

        if candidate.is_closed_shape != sample.is_closed_shape {
            score += 0.75
        }

        return score
    }

    private static func boundedLogRatio(_ a: Double, _ b: Double) -> Double {
        let epsilon = 1e-9
        let av = max(abs(a), epsilon)
        let bv = max(abs(b), epsilon)
        return min(abs(log(av / bv)), 6.0)
    }

    private static func distributionDistance(_ a: [Double], _ b: [Double]) -> Double {
        if a.isEmpty && b.isEmpty { return 0 }
        if a.isEmpty || b.isEmpty { return 1 }

        let lhs = a.sorted()
        let rhs = b.sorted()
        let count = min(lhs.count, rhs.count)
        guard count > 0 else { return 1 }

        var total = 0.0
        for i in 0..<count {
            let li = count == 1 ? 0 : Int((Double(i) * Double(lhs.count - 1) / Double(count - 1)).rounded())
            let ri = count == 1 ? 0 : Int((Double(i) * Double(rhs.count - 1) / Double(count - 1)).rounded())
            total += abs(lhs[li] - rhs[ri])
        }

        let countPenalty = Double(abs(lhs.count - rhs.count)) / Double(max(lhs.count, rhs.count))
        return (total / Double(count)) + countPenalty
    }

    private static func localFallbackMatches(from rankedClusters: [RankedCanvasCluster]) -> [String] {
        guard let best = rankedClusters.first?.score, best.isFinite, best <= 1.25 else { return [] }
        let cutoff = min(1.5, best + 0.35)
        return rankedClusters
            .filter { $0.score <= cutoff }
            .map { $0.cluster.id.uuidString }
    }

    // MARK: - Render Overlay

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        guard case .waitingForSecondCorner(let firstX, let firstY) = state else { return }

        let drawList = igGetForegroundDrawList_ViewportPtr(nil)
        // Bright green rectangle for AI search area preview (distinct from cyan CleanSpeckles).
        let col = makeCol32(100, 255, 100, 200)

        let p1 = EngineCameraManager.worldToScreen(worldX: firstX, worldY: firstY, cam: cam)
        let p3 = EngineCameraManager.worldToScreen(worldX: currentMouseWorldX, worldY: currentMouseWorldY, cam: cam)

        let minSX = min(p1.x, p3.x)
        let maxSX = max(p1.x, p3.x)
        let minSY = min(p1.y, p3.y)
        let maxSY = max(p1.y, p3.y)

        let p1Draw = ImVec2(x: minSX, y: minSY)
        let p2Draw = ImVec2(x: maxSX, y: minSY)
        let p3Draw = ImVec2(x: maxSX, y: maxSY)
        let p4Draw = ImVec2(x: minSX, y: maxSY)

        ImDrawListAddLine(drawList, p1Draw, p2Draw, col, 1.5)
        ImDrawListAddLine(drawList, p2Draw, p3Draw, col, 1.5)
        ImDrawListAddLine(drawList, p3Draw, p4Draw, col, 1.5)
        ImDrawListAddLine(drawList, p4Draw, p1Draw, col, 1.5)

        // Filled semi-transparent overlay.
        let fillCol = makeCol32(100, 255, 100, 40)
        ImDrawListAddRectFilled(drawList, p1Draw, p3Draw, fillCol, 0.0, 0)
    }

    // MARK: - Helpers

    public var isSnappingEnabled: Bool { false }
}
