import Foundation

// =========================================================================
// MARK: - AISelectionClient
//
// Lightweight async HTTP client for an OpenAI-compatible chat completions API.
// Manages a tool-calling agent loop:
//   1. Send system prompt + tool definitions to the LLM.
//   2. If the LLM responds with a tool call, execute it and send the result back.
//   3. Continue until the LLM calls `submit_matching_clusters`.
//   4. If the LLM responds with text only (no tool call), fall back to regex
//      scanning the raw text for UUID patterns or JSON arrays.
// =========================================================================

public struct AISelectionClient {

    // MARK: - OpenAI API Types

    private struct Message: Codable {
        let role: String           // "system" | "user" | "assistant" | "tool"
        let content: String?       // null when tool_calls is present
        let tool_calls: [ToolCall]?
        let tool_call_id: String?

        init(role: String, content: String? = nil, toolCalls: [ToolCall]? = nil, toolCallID: String? = nil) {
            self.role = role
            self.content = content
            self.tool_calls = toolCalls
            self.tool_call_id = toolCallID
        }
    }

    private struct ToolCall: Codable {
        let id: String
        let type: String          // "function"
        let function: FunctionCall
    }

    private struct FunctionCall: Codable {
        let name: String
        let arguments: String     // JSON string
    }

    private struct Tool: Codable {
        let type: String          // "function"
        let function: FunctionDef
    }

    private struct FunctionDef: Codable {
        let name: String
        let description: String
        let parameters: ParametersDef
    }

    private struct ParametersDef: Codable {
        let type: String          // "object"
        let properties: [String: PropertyDef]
        let required: [String]?
    }

    private struct PropertyDef: Codable {
        let type: String
        let description: String?
        let items: ItemsDef?      // for array properties
    }

    private struct ItemsDef: Codable {
        let type: String
    }

    private struct ChatRequest: Codable {
        let model: String
        let messages: [Message]
        let tools: [Tool]?
        let temperature: Double
        let stream: Bool
        let max_tokens: Int

        enum CodingKeys: String, CodingKey {
            case model, messages, tools, temperature, stream
            case max_tokens
        }
    }

    private struct ChatResponse: Codable {
        struct Choice: Codable {
            struct ResponseMessage: Codable {
                let role: String
                let content: String?
                let tool_calls: [ToolCall]?
            }
            let message: ResponseMessage
            let finish_reason: String?
        }
        let choices: [Choice]
    }


    // MARK: - Rule Generation JSON Types

    public struct AISelectionEntityProfileJSON: Codable, Sendable {
        public var sample_id: String
        public var layer_name: String
        public var layer_line_type: String
        public var layer_line_weight: Double
        public var layer_opacity: Double
        public var effective_color: String
        public var explicit_color: String?
        public var effective_line_type: String
        public var explicit_line_type: String?
        public var effective_line_weight: Double
        public var explicit_line_weight: Double?
        public var plot_style: String?
        public var primitive_signature: String
        public var primitive_types: [String]
        public var primitive_count: Int
        public var segment_count: Int
        public var has_bulged_polyline: Bool
        public var has_arc_like_geometry: Bool
        public var has_hatch: Bool
        public var hatch_patterns: [String]
        public var has_text: Bool
        public var has_fill: Bool
        public var is_closed_shape: Bool
        public var bbox_width: Double
        public var bbox_height: Double
        public var bbox_diagonal: Double
        public var average_segment_length: Double
        public var min_segment_length: Double
        public var max_segment_length: Double
        public var relative_angles: [Double]
        public var normalized_gaps: [Double]
        public var transform_rotation: Double
        public var transform_scale_x: Double
        public var transform_scale_y: Double
        public var draw_order: Int
        public var xdata: [String: String]

        public init(
            sample_id: String,
            layer_name: String,
            layer_line_type: String,
            layer_line_weight: Double,
            layer_opacity: Double,
            effective_color: String,
            explicit_color: String?,
            effective_line_type: String,
            explicit_line_type: String?,
            effective_line_weight: Double,
            explicit_line_weight: Double?,
            plot_style: String?,
            primitive_signature: String,
            primitive_types: [String],
            primitive_count: Int,
            segment_count: Int,
            has_bulged_polyline: Bool,
            has_arc_like_geometry: Bool,
            has_hatch: Bool,
            hatch_patterns: [String],
            has_text: Bool,
            has_fill: Bool,
            is_closed_shape: Bool,
            bbox_width: Double,
            bbox_height: Double,
            bbox_diagonal: Double,
            average_segment_length: Double,
            min_segment_length: Double,
            max_segment_length: Double,
            relative_angles: [Double],
            normalized_gaps: [Double],
            transform_rotation: Double,
            transform_scale_x: Double,
            transform_scale_y: Double,
            draw_order: Int,
            xdata: [String: String]
        ) {
            self.sample_id = sample_id
            self.layer_name = layer_name
            self.layer_line_type = layer_line_type
            self.layer_line_weight = layer_line_weight
            self.layer_opacity = layer_opacity
            self.effective_color = effective_color
            self.explicit_color = explicit_color
            self.effective_line_type = effective_line_type
            self.explicit_line_type = explicit_line_type
            self.effective_line_weight = effective_line_weight
            self.explicit_line_weight = explicit_line_weight
            self.plot_style = plot_style
            self.primitive_signature = primitive_signature
            self.primitive_types = primitive_types
            self.primitive_count = primitive_count
            self.segment_count = segment_count
            self.has_bulged_polyline = has_bulged_polyline
            self.has_arc_like_geometry = has_arc_like_geometry
            self.has_hatch = has_hatch
            self.hatch_patterns = hatch_patterns
            self.has_text = has_text
            self.has_fill = has_fill
            self.is_closed_shape = is_closed_shape
            self.bbox_width = bbox_width
            self.bbox_height = bbox_height
            self.bbox_diagonal = bbox_diagonal
            self.average_segment_length = average_segment_length
            self.min_segment_length = min_segment_length
            self.max_segment_length = max_segment_length
            self.relative_angles = relative_angles
            self.normalized_gaps = normalized_gaps
            self.transform_rotation = transform_rotation
            self.transform_scale_x = transform_scale_x
            self.transform_scale_y = transform_scale_y
            self.draw_order = draw_order
            self.xdata = xdata
        }
    }

    public struct AISelectionRuleJSON: Codable, Sendable {
        public var intent: String?
        public var allowedLayerNames: [String]?
        public var allowedColors: [String]?
        public var allowedLineTypes: [String]?
        public var allowedLineWeights: [Double]?
        public var allowedPrimitiveSignatures: [String]?
        public var allowedPrimitiveTypes: [String]?
        public var allowedClosedShapeValues: [Bool]?
        public var allowedHatchPatterns: [String]?
        public var requireLayerMatch: Bool?
        public var requireColorMatch: Bool?
        public var requireLineTypeMatch: Bool?
        public var requireLineWeightMatch: Bool?
        public var allowBulgedPolylines: Bool?
        public var allowArcLikeGeometry: Bool?
        public var allowHatches: Bool?
        public var allowText: Bool?
        public var allowFilledGeometry: Bool?
        public var rejectIfTouchesLargerGeometry: Bool?
        public var rejectIfBulgeWhenSamplesHaveNone: Bool?
        public var rejectIfArcLikeWhenSamplesHaveNone: Bool?
        public var rejectIfHatchPatternDiffers: Bool?
        public var maxDiagonal: Double?
        public var maxWidth: Double?
        public var maxHeight: Double?
        public var maxAverageSegmentLength: Double?
        public var maxSegmentLength: Double?
        public var maxPrimitiveCount: Int?
        public var maxSegmentCount: Int?
        public var targetDiagonal: Double?
        public var targetAverageSegmentLength: Double?
        public var scoreThreshold: Double?
        public var maxDiagonalMultiplier: Double?
        public var maxWidthMultiplier: Double?
        public var maxHeightMultiplier: Double?
        public var maxAverageSegmentLengthMultiplier: Double?
        public var maxSegmentLengthMultiplier: Double?

        public init(
            intent: String? = nil,
            allowedLayerNames: [String]? = nil,
            allowedColors: [String]? = nil,
            allowedLineTypes: [String]? = nil,
            allowedLineWeights: [Double]? = nil,
            allowedPrimitiveSignatures: [String]? = nil,
            allowedPrimitiveTypes: [String]? = nil,
            allowedClosedShapeValues: [Bool]? = nil,
            allowedHatchPatterns: [String]? = nil,
            requireLayerMatch: Bool? = nil,
            requireColorMatch: Bool? = nil,
            requireLineTypeMatch: Bool? = nil,
            requireLineWeightMatch: Bool? = nil,
            allowBulgedPolylines: Bool? = nil,
            allowArcLikeGeometry: Bool? = nil,
            allowHatches: Bool? = nil,
            allowText: Bool? = nil,
            allowFilledGeometry: Bool? = nil,
            rejectIfTouchesLargerGeometry: Bool? = nil,
            rejectIfBulgeWhenSamplesHaveNone: Bool? = nil,
            rejectIfArcLikeWhenSamplesHaveNone: Bool? = nil,
            rejectIfHatchPatternDiffers: Bool? = nil,
            maxDiagonal: Double? = nil,
            maxWidth: Double? = nil,
            maxHeight: Double? = nil,
            maxAverageSegmentLength: Double? = nil,
            maxSegmentLength: Double? = nil,
            maxPrimitiveCount: Int? = nil,
            maxSegmentCount: Int? = nil,
            targetDiagonal: Double? = nil,
            targetAverageSegmentLength: Double? = nil,
            scoreThreshold: Double? = nil,
            maxDiagonalMultiplier: Double? = nil,
            maxWidthMultiplier: Double? = nil,
            maxHeightMultiplier: Double? = nil,
            maxAverageSegmentLengthMultiplier: Double? = nil,
            maxSegmentLengthMultiplier: Double? = nil
        ) {
            self.intent = intent
            self.allowedLayerNames = allowedLayerNames
            self.allowedColors = allowedColors
            self.allowedLineTypes = allowedLineTypes
            self.allowedLineWeights = allowedLineWeights
            self.allowedPrimitiveSignatures = allowedPrimitiveSignatures
            self.allowedPrimitiveTypes = allowedPrimitiveTypes
            self.allowedClosedShapeValues = allowedClosedShapeValues
            self.allowedHatchPatterns = allowedHatchPatterns
            self.requireLayerMatch = requireLayerMatch
            self.requireColorMatch = requireColorMatch
            self.requireLineTypeMatch = requireLineTypeMatch
            self.requireLineWeightMatch = requireLineWeightMatch
            self.allowBulgedPolylines = allowBulgedPolylines
            self.allowArcLikeGeometry = allowArcLikeGeometry
            self.allowHatches = allowHatches
            self.allowText = allowText
            self.allowFilledGeometry = allowFilledGeometry
            self.rejectIfTouchesLargerGeometry = rejectIfTouchesLargerGeometry
            self.rejectIfBulgeWhenSamplesHaveNone = rejectIfBulgeWhenSamplesHaveNone
            self.rejectIfArcLikeWhenSamplesHaveNone = rejectIfArcLikeWhenSamplesHaveNone
            self.rejectIfHatchPatternDiffers = rejectIfHatchPatternDiffers
            self.maxDiagonal = maxDiagonal
            self.maxWidth = maxWidth
            self.maxHeight = maxHeight
            self.maxAverageSegmentLength = maxAverageSegmentLength
            self.maxSegmentLength = maxSegmentLength
            self.maxPrimitiveCount = maxPrimitiveCount
            self.maxSegmentCount = maxSegmentCount
            self.targetDiagonal = targetDiagonal
            self.targetAverageSegmentLength = targetAverageSegmentLength
            self.scoreThreshold = scoreThreshold
            self.maxDiagonalMultiplier = maxDiagonalMultiplier
            self.maxWidthMultiplier = maxWidthMultiplier
            self.maxHeightMultiplier = maxHeightMultiplier
            self.maxAverageSegmentLengthMultiplier = maxAverageSegmentLengthMultiplier
            self.maxSegmentLengthMultiplier = maxSegmentLengthMultiplier
        }
    }

    // MARK: - Configuration

    private let baseURL: String
    private let apiKey: String?
    private let model: String
    private let timeout: TimeInterval
    private let urlSession: URLSession

    // MARK: - System Prompt

    private static let systemPrompt = """
You are a strict JSON classifier for a 2D CAD cleanup selection tool.
Return exactly one JSON object with this shape:
{"matching_cluster_ids":["cluster-id"]}
Do not explain, do not summarize, and do not include markdown.
Select only true cleanup/debris matches. Reject legitimate CAD geometry such as pipe edges, fixture edges, wall/room outlines, leaders, borders, or connected linework unless it has the same small primitive family, size, and topology as the samples.
"""

    // MARK: - Tool Definitions

    private static let toolDefinitions: [Tool] = [
        Tool(type: "function", function: FunctionDef(
            name: "get_sample_cluster_profiles",
            description: "Returns a list of structural geometric feature profiles that the user selected as positive examples.",
            parameters: ParametersDef(
                type: "object",
                properties: [:],
                required: nil
            )
        )),
        Tool(type: "function", function: FunctionDef(
            name: "evaluate_canvas_window_clusters",
            description: "Returns a list of cluster profiles found within the user's cleanup window. Use this to find matches.",
            parameters: ParametersDef(
                type: "object",
                properties: [:],
                required: nil
            )
        )),
        Tool(type: "function", function: FunctionDef(
            name: "submit_matching_clusters",
            description: "Submits the final IDs of the canvas clusters that match the semantic intent of the sample profiles.",
            parameters: ParametersDef(
                type: "object",
                properties: [
                    "matching_cluster_ids": PropertyDef(
                        type: "array",
                        description: "List of cluster IDs that should be selected for erasure.",
                        items: ItemsDef(type: "string")
                    )
                ],
                required: ["matching_cluster_ids"]
            )
        )),
    ]

    // MARK: - Init

    public init(
        baseURL: String,
        apiKey: String? = nil,
        model: String = "",
        timeout: TimeInterval = 60.0
    ) {
        // Normalize: ensure baseURL doesn't end with a slash.
        var normalized = baseURL
        if normalized.hasSuffix("/") {
            normalized = String(normalized.dropLast())
        }
        self.baseURL = normalized
        self.apiKey = apiKey
        self.model = model
        self.timeout = timeout

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        self.urlSession = URLSession(configuration: config)
    }

    // MARK: - Public API

    /// Runs the full agentic selection loop.
    ///
    /// - Parameters:
    ///   - samples: Feature profiles extracted from the user's example selection.
    ///   - targets: Feature profiles extracted from entities in the search window.
    /// - Returns: Array of cluster ID strings that the LLM selected as matches.
    public func runSelectionAgent(
        samples: [ClusterProfileJSON],
        targets: [ClusterProfileJSON]
    ) async throws -> [String] {
        // Encode samples and targets once.
        let encoder = JSONEncoder()
        let samplesJSON = String(data: try encoder.encode(samples), encoding: .utf8) ?? "[]"
        let targetsJSON = String(data: try encoder.encode(targets), encoding: .utf8) ?? "[]"

        let directPrompt = """
Return JSON only. Do not explain. Do not list the samples. Do not think out loud.

Task: choose target cluster IDs that match the cleanup/debris samples.
Reject CAD drawing geometry, pipe/wall arcs, fixture edges, room outlines, leaders, borders, or connected geometry unless it has the same small primitive family and size as the samples.

Samples:
\(samplesJSON)

Targets:
\(targetsJSON)

Required output shape:
{"matching_cluster_ids":["cluster-id"]}
Use {"matching_cluster_ids":[]} only when none match.
"""

        var messages: [Message] = [
            Message(role: "system", content: Self.systemPrompt),
            Message(role: "user", content: directPrompt),
        ]

        // Maximum iterations to prevent infinite loops.
        for _ in 0..<1000 {
            let request = ChatRequest(
                model: model,
                messages: messages,
                tools: nil,
                temperature: 0.0,
                stream: false,
                max_tokens: 8192
            )

            let response = try await sendChatRequest(request)
            guard let choice = response.choices.first else {
                throw AISelectionError.noResponse
            }

            if choice.finish_reason == "length" {
                throw AISelectionError.truncatedResponse
            }

            let msg = choice.message

            // If the LLM called a tool, execute it.
            if let toolCalls = msg.tool_calls, !toolCalls.isEmpty {
                // Append the assistant's tool-call message.
                messages.append(Message(
                    role: "assistant",
                    content: nil,
                    toolCalls: toolCalls
                ))

                for tc in toolCalls {
                    let result = executeToolCall(tc, samplesJSON: samplesJSON, targetsJSON: targetsJSON)
                    // Check if this is the final submission.
                    if tc.function.name == "submit_matching_clusters" {
                        // Try to parse the result as matching IDs.
                        if let data = result.data(using: .utf8),
                           let ids = try? JSONDecoder().decode(MatchingIDs.self, from: data) {
                            return ids.matching_cluster_ids
                        }
                        // Fallback: try parsing the arguments directly.
                        if let argData = tc.function.arguments.data(using: .utf8),
                           let ids = try? JSONDecoder().decode(MatchingIDs.self, from: argData) {
                            return ids.matching_cluster_ids
                        }
                    }
                    messages.append(Message(
                        role: "tool",
                        content: result,
                        toolCallID: tc.id
                    ))
                }
                continue
            }

            // No tool call — check if there's text content to fallback-parse.
            if let content = msg.content, !content.isEmpty {
#if DEBUG
                print("[AISelect] LLM raw response:\n\(content)")
#endif
                if let fallbackIDs = fallbackParseIDs(from: content, targets: targets) {
                    return fallbackIDs
                }
            }

            if choice.finish_reason == "length" {
                throw AISelectionError.truncatedResponse
            }

            return []
        }


        throw AISelectionError.tooManyIterations
    }

    /// Asks the model to convert a compact sample summary into a rule object.
    /// The CAD engine applies the final merged rule locally to every entity in the user-selected window.
    public func generateSelectionRule(
        samples: [AISelectionEntityProfileJSON]
    ) async throws -> AISelectionRuleJSON {
        let summary = makeSampleSummary(from: samples)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let summaryJSON = String(data: try encoder.encode(summary), encoding: .utf8) ?? "{}"

        let prompt = """
Return JSON only. Do not explain. Do not use markdown.

You are creating a deterministic CAD selection rule from positive examples only.
The CAD engine will apply your rule to every entity inside the user's box selection.
Do not select IDs. Do not ask for target entities.

You are receiving a compact aggregate summary, not every selected entity.
Prefer rules that match visually similar cleanup/debris geometry, not exact clones.
Use hard requirements only for stable drafting properties shared by the samples, such as layer and color.
Treat BYLAYER and the effective layer value as equivalent.
Do not make primitive_signature exact unless the summary shows that exact signature is essential.
For line-like PDF speckles/debris, prefer allowedPrimitiveTypes ["line","polyline","polygon"] over allowedPrimitiveSignatures ["polyline"].
Do not invent tiny exact numeric limits. Prefer multiplier fields. The CAD engine will clamp final limits from the sample stats.
For PDF speckle/debris cleanup, usually reject bulged polylines, arc-like geometry, hatches, text, and filled geometry when samples have none.

Return exactly this flat JSON shape. Omit a field only if it should not constrain selection:
{
  "intent":"short intent label",
  "allowedLayerNames":["layer"],
  "allowedColors":["#RRGGBBAA"],
  "allowedLineTypes":["CONTINUOUS"],
  "allowedLineWeights":[0.25],
  "allowedPrimitiveSignatures":["only-if-exact-signature-is-required"],
  "allowedPrimitiveTypes":["line","polyline","polygon"],
  "allowedClosedShapeValues":[true,false],
  "allowedHatchPatterns":["ANSI31"],
  "requireLayerMatch":true,
  "requireColorMatch":true,
  "requireLineTypeMatch":false,
  "requireLineWeightMatch":false,
  "allowBulgedPolylines":false,
  "allowArcLikeGeometry":false,
  "allowHatches":false,
  "allowText":false,
  "allowFilledGeometry":false,
  "rejectIfTouchesLargerGeometry":false,
  "rejectIfBulgeWhenSamplesHaveNone":true,
  "rejectIfArcLikeWhenSamplesHaveNone":true,
  "rejectIfHatchPatternDiffers":true,
  "maxDiagonalMultiplier":1.75,
  "maxWidthMultiplier":2.0,
  "maxHeightMultiplier":2.0,
  "maxAverageSegmentLengthMultiplier":1.75,
  "maxSegmentLengthMultiplier":1.75,
  "maxPrimitiveCount":3,
  "maxSegmentCount":8,
  "scoreThreshold":0.40
}

SampleSummary:
\(summaryJSON)
"""

        let request = ChatRequest(
            model: model,
            messages: [
                Message(role: "system", content: "You are a strict JSON rule generator for a 2D CAD selection engine. Return one JSON object only."),
                Message(role: "user", content: prompt),
            ],
            tools: nil,
            temperature: 0.0,
            stream: false,
            max_tokens: 2048
        )

        let response = try await sendChatRequest(request)
        guard let choice = response.choices.first else { throw AISelectionError.noResponse }
        if choice.finish_reason == "length" { throw AISelectionError.truncatedResponse }
        guard let content = choice.message.content, !content.isEmpty else { throw AISelectionError.invalidRuleResponse }
#if DEBUG
        print("[AISelect] LLM rule response:\n\(content)")
#endif
        if let rule = decodeSelectionRule(from: content) { return rule }
        if let jsonObject = extractJSONObject(containing: "intent", from: content),
           let rule = decodeSelectionRule(from: jsonObject) { return rule }
        if let jsonObject = extractOutermostJSONObject(from: content),
           let rule = decodeSelectionRule(from: jsonObject) { return rule }
        throw AISelectionError.invalidRuleResponse
    }

    // MARK: - Rule Summary Helpers

    private struct NumericSummaryJSON: Codable {
        let min: Double
        let p50: Double
        let p95: Double
        let max: Double
        let mean: Double
    }

    private struct RuleRepresentativeJSON: Codable {
        let label: String
        let primitive_signature: String
        let primitive_types: [String]
        let primitive_family: String
        let is_closed_shape: Bool
        let bbox_diagonal: Double
        let average_segment_length: Double
        let max_segment_length: Double
        let segment_count: Int
        let has_bulged_polyline: Bool
        let has_arc_like_geometry: Bool
        let has_hatch: Bool
        let has_text: Bool
        let has_fill: Bool
    }

    private struct SampleSummaryJSON: Codable {
        let sample_count: Int
        let layer_names: [String]
        let layer_line_types: [String]
        let effective_colors: [String]
        let explicit_colors: [String]
        let effective_line_types: [String]
        let explicit_line_types: [String]
        let effective_line_weights: [Double]
        let plot_styles: [String]
        let primitive_signatures: [String]
        let primitive_types: [String]
        let primitive_families: [String]
        let closed_shape_values: [Bool]
        let has_bulged_polyline: Bool
        let has_arc_like_geometry: Bool
        let has_hatch: Bool
        let hatch_patterns: [String]
        let has_text: Bool
        let has_fill: Bool
        let bbox_diagonal: NumericSummaryJSON
        let bbox_width: NumericSummaryJSON
        let bbox_height: NumericSummaryJSON
        let average_segment_length: NumericSummaryJSON
        let max_segment_length: NumericSummaryJSON
        let primitive_count: NumericSummaryJSON
        let segment_count: NumericSummaryJSON
        let representatives: [RuleRepresentativeJSON]
    }

    private func makeSampleSummary(from samples: [AISelectionEntityProfileJSON]) -> SampleSummaryJSON {
        SampleSummaryJSON(
            sample_count: samples.count,
            layer_names: uniqueStrings(samples.map(\.layer_name)),
            layer_line_types: uniqueStrings(samples.map(\.layer_line_type)),
            effective_colors: uniqueStrings(samples.map(\.effective_color)),
            explicit_colors: uniqueStrings(samples.compactMap { $0.explicit_color }),
            effective_line_types: uniqueStrings(samples.map(\.effective_line_type)),
            explicit_line_types: uniqueStrings(samples.compactMap { $0.explicit_line_type }),
            effective_line_weights: uniqueRoundedDoubles(samples.map(\.effective_line_weight), places: 4),
            plot_styles: uniqueStrings(samples.compactMap { $0.plot_style }),
            primitive_signatures: uniqueStrings(samples.map(\.primitive_signature)),
            primitive_types: uniqueStrings(samples.flatMap(\.primitive_types)),
            primitive_families: uniqueStrings(samples.map { primitiveFamily(for: $0) }),
            closed_shape_values: uniqueBools(samples.map(\.is_closed_shape)),
            has_bulged_polyline: samples.contains { $0.has_bulged_polyline },
            has_arc_like_geometry: samples.contains { $0.has_arc_like_geometry },
            has_hatch: samples.contains { $0.has_hatch },
            hatch_patterns: uniqueStrings(samples.flatMap(\.hatch_patterns)),
            has_text: samples.contains { $0.has_text },
            has_fill: samples.contains { $0.has_fill },
            bbox_diagonal: numericSummary(samples.map(\.bbox_diagonal)),
            bbox_width: numericSummary(samples.map(\.bbox_width)),
            bbox_height: numericSummary(samples.map(\.bbox_height)),
            average_segment_length: numericSummary(samples.map(\.average_segment_length)),
            max_segment_length: numericSummary(samples.map(\.max_segment_length)),
            primitive_count: numericSummary(samples.map { Double($0.primitive_count) }),
            segment_count: numericSummary(samples.map { Double($0.segment_count) }),
            representatives: representativeSamples(from: samples)
        )
    }

    private func representativeSamples(from samples: [AISelectionEntityProfileJSON]) -> [RuleRepresentativeJSON] {
        guard !samples.isEmpty else { return [] }

        var candidates: [(String, AISelectionEntityProfileJSON)] = []
        let sortedByDiagonal = samples.sorted { $0.bbox_diagonal < $1.bbox_diagonal }
        if let first = sortedByDiagonal.first { candidates.append(("smallest", first)) }
        if !sortedByDiagonal.isEmpty { candidates.append(("median", sortedByDiagonal[sortedByDiagonal.count / 2])) }
        if let last = sortedByDiagonal.last { candidates.append(("largest", last)) }
        if let open = samples.first(where: { !$0.is_closed_shape }) { candidates.append(("open", open)) }
        if let closed = samples.first(where: { $0.is_closed_shape }) { candidates.append(("closed", closed)) }
        if let mostSegments = samples.max(by: { $0.segment_count < $1.segment_count }) { candidates.append(("most_segments", mostSegments)) }

        var seen = Set<String>()
        return candidates.compactMap { label, sample in
            let key = sample.sample_id
            guard seen.insert(key).inserted else { return nil }
            return RuleRepresentativeJSON(
                label: label,
                primitive_signature: sample.primitive_signature,
                primitive_types: sample.primitive_types,
                primitive_family: primitiveFamily(for: sample),
                is_closed_shape: sample.is_closed_shape,
                bbox_diagonal: sample.bbox_diagonal,
                average_segment_length: sample.average_segment_length,
                max_segment_length: sample.max_segment_length,
                segment_count: sample.segment_count,
                has_bulged_polyline: sample.has_bulged_polyline,
                has_arc_like_geometry: sample.has_arc_like_geometry,
                has_hatch: sample.has_hatch,
                has_text: sample.has_text,
                has_fill: sample.has_fill
            )
        }
    }

    private func primitiveFamily(for sample: AISelectionEntityProfileJSON) -> String {
        if sample.has_hatch { return "hatch" }
        if sample.has_text { return "text" }
        if sample.has_fill { return "filled" }
        if sample.has_arc_like_geometry { return "arc_like" }
        let types = Set(sample.primitive_types)
        if types.isSubset(of: Set(["line", "polyline", "polygon"])) {
            return "line_like"
        }
        if types.count == 1, let only = types.first {
            return only
        }
        return "mixed"
    }

    private func numericSummary(_ values: [Double]) -> NumericSummaryJSON {
        let filtered = values.filter { $0.isFinite }.sorted()
        guard !filtered.isEmpty else {
            return NumericSummaryJSON(min: 0, p50: 0, p95: 0, max: 0, mean: 0)
        }
        let mean = filtered.reduce(0, +) / Double(filtered.count)
        return NumericSummaryJSON(
            min: filtered.first ?? 0,
            p50: percentile(sorted: filtered, fraction: 0.50),
            p95: percentile(sorted: filtered, fraction: 0.95),
            max: filtered.last ?? 0,
            mean: mean
        )
    }

    private func percentile(sorted values: [Double], fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        if values.count == 1 { return values[0] }
        let clamped = max(0, min(1, fraction))
        let index = clamped * Double(values.count - 1)
        let lower = Int(floor(index))
        let upper = Int(ceil(index))
        if lower == upper { return values[lower] }
        let t = index - Double(lower)
        return values[lower] * (1 - t) + values[upper] * t
    }

    private func uniqueStrings(_ values: [String]) -> [String] {
        Array(Set(values.filter { !$0.isEmpty })).sorted()
    }

    private func uniqueBools(_ values: [Bool]) -> [Bool] {
        Array(Set(values)).sorted { !$0 && $1 }
    }

    private func uniqueRoundedDoubles(_ values: [Double], places: Int) -> [Double] {
        let factor = pow(10.0, Double(places))
        return Array(Set(values.filter { $0.isFinite }.map { ($0 * factor).rounded() / factor })).sorted()
    }

    // MARK: - HTTP

    private func sendChatRequest(_ request: ChatRequest) async throws -> ChatResponse {
        let url = URL(string: "\(baseURL)/chat/completions")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = apiKey, !key.isEmpty {
            urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let body = try JSONEncoder().encode(request)
        urlRequest.httpBody = body

        let (data, response) = try await urlSession.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AISelectionError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw AISelectionError.httpError(status: httpResponse.statusCode, body: bodyStr)
        }

        return try JSONDecoder().decode(ChatResponse.self, from: data)
    }

    // MARK: - Tool Execution

    private struct MatchingIDs: Codable {
        let matching_cluster_ids: [String]
    }

    private func executeToolCall(
        _ call: ToolCall,
        samplesJSON: String,
        targetsJSON: String
    ) -> String {
        switch call.function.name {
        case "get_sample_cluster_profiles":
            return samplesJSON
        case "evaluate_canvas_window_clusters":
            return targetsJSON
        case "submit_matching_clusters":
            // Return the arguments as-is so the caller can parse them.
            return call.function.arguments
        default:
            return "{\"error\": \"Unknown tool: \(call.function.name)\"}"
        }
    }

    // MARK: - Fallback Parsing

    /// If the LLM didn't emit a tool call but instead output raw text, try to
    /// extract matching cluster IDs via regex. This handles local models (Qwen,
    /// Gemma, etc.) that sometimes output markdown instead of strict tool calls.
    private func fallbackParseIDs(
        from text: String,
        targets: [ClusterProfileJSON]
    ) -> [String]? {
        let targetIDs = Set(targets.map { $0.cluster_id })

        if let ids = decodeMatchingIDs(from: text) {
            let valid = ids.filter { targetIDs.contains($0) }
            return valid
        }

        if let jsonObject = extractJSONObject(containing: "matching_cluster_ids", from: text),
           let ids = decodeMatchingIDs(from: jsonObject) {
            let valid = ids.filter { targetIDs.contains($0) }
            return valid
        }

        // Strategy 1: Try to find a JSON array of strings (cluster IDs).
        // Look for ["uuid1", "uuid2", ...] patterns.
        if let matches = extractUUIDsFromJSONArray(in: text) {
            let valid = matches.filter { targetIDs.contains($0) }
            if !valid.isEmpty { return valid }
        }

        // Strategy 2: Find all standalone UUID patterns in the text.
        if let matches = extractUUIDStrings(in: text) {
            let valid = matches.filter { targetIDs.contains($0) }
            if !valid.isEmpty { return valid }
        }

        return nil
    }

    private func decodeMatchingIDs(from text: String) -> [String]? {
        guard let data = text.data(using: .utf8),
              let ids = try? JSONDecoder().decode(MatchingIDs.self, from: data)
        else { return nil }
        return ids.matching_cluster_ids
    }

    private func decodeSelectionRule(from text: String) -> AISelectionRuleJSON? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AISelectionRuleJSON.self, from: data)
    }

    private func extractOutermostJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start <= end else { return nil }
        return String(text[start...end])
    }

    private func extractJSONObject(containing key: String, from text: String) -> String? {
        guard let keyRange = text.range(of: key) else { return nil }
        guard let start = text[..<keyRange.lowerBound].lastIndex(of: "{") else { return nil }
        guard let end = text[keyRange.upperBound...].firstIndex(of: "}") else { return nil }
        return String(text[start...end])
    }

    /// Extracts UUID strings from a JSON array of strings in the given text.
    private func extractUUIDsFromJSONArray(in text: String) -> [String]? {
        let pattern = #""([a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12})""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        let ids = matches.compactMap { match -> String? in
            guard match.numberOfRanges >= 2,
                  let r = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
        return ids.isEmpty ? nil : ids
    }

    /// Extracts standalone UUID strings from arbitrary text.
    private func extractUUIDStrings(in text: String) -> [String]? {
        let pattern = #"[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        let ids = matches.compactMap { match -> String? in
            guard let r = Range(match.range, in: text) else { return nil }
            return String(text[r])
        }
        return ids.isEmpty ? nil : ids
    }
}

// =========================================================================
// MARK: - AISelectionError
// =========================================================================

public enum AISelectionError: Error, LocalizedError {
    case noResponse
    case invalidResponse
    case httpError(status: Int, body: String)
    case truncatedResponse
    case invalidRuleResponse
    case tooManyIterations

    public var errorDescription: String? {
        switch self {
        case .noResponse:
            return "The LLM returned no response."
        case .invalidResponse:
            return "Received an invalid HTTP response."
        case .httpError(let status, let body):
            return "HTTP \(status): \(body)"
        case .truncatedResponse:
            return "The LLM ran out of output tokens before returning matching IDs."
        case .invalidRuleResponse:
            return "The LLM did not return a valid CAD selection rule."
        case .tooManyIterations:
            return "Agent loop exceeded maximum iterations."
        }
    }
}
