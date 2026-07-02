import Foundation

public struct AIDrawingClient {
    private struct Message: Codable {
        let role: String
        let content: String?
    }

    private struct ChatRequest: Codable {
        let model: String
        let messages: [Message]
        let temperature: Double
        let stream: Bool
        let max_tokens: Int

        enum CodingKeys: String, CodingKey {
            case model, messages, temperature, stream
            case max_tokens
        }
    }

    private struct ChatResponse: Codable {
        struct Choice: Codable {
            struct ResponseMessage: Codable {
                let role: String
                let content: String?
            }
            let message: ResponseMessage
            let finish_reason: String?
        }
        let choices: [Choice]
    }

    public struct DrawingContextJSON: Codable, Sendable {
        public var units: String
        public var origin: [Double]
        public var viewport: [Double]
        public var activeLayer: String?
        public var availableLayers: [String]

        public init(units: String, origin: [Double], viewport: [Double], activeLayer: String?, availableLayers: [String]) {
            self.units = units
            self.origin = origin
            self.viewport = viewport
            self.activeLayer = activeLayer
            self.availableLayers = availableLayers
        }
    }

    public struct DrawingPlanJSON: Codable, Sendable {
        public var intent: String?
        public var coordinateMode: String?
        public var defaultLayer: String?
        public var operations: [DrawingOperationJSON]

        public init(intent: String? = nil, coordinateMode: String? = nil, defaultLayer: String? = nil, operations: [DrawingOperationJSON] = []) {
            self.intent = intent
            self.coordinateMode = coordinateMode
            self.defaultLayer = defaultLayer
            self.operations = operations
        }
    }

    public struct DrawingOperationJSON: Codable, Sendable, Identifiable {
        public var id: String?
        public var type: String
        public var layer: String?
        public var color: String?
        public var lineType: String?
        public var lineWeight: Double?
        public var start: [Double]?
        public var end: [Double]?
        public var points: [[Double]]?
        public var closed: Bool?
        public var origin: [Double]?
        public var center: [Double]?
        public var size: [Double]?
        public var radius: Double?
        public var startAngleDegrees: Double?
        public var endAngleDegrees: Double?
        public var text: String?
        public var height: Double?
        public var rotationDegrees: Double?
        public var pattern: String?
        public var scale: Double?
        public var angleDegrees: Double?

        public var stableID: String { id ?? UUID().uuidString }

        public init(
            id: String? = nil,
            type: String,
            layer: String? = nil,
            color: String? = nil,
            lineType: String? = nil,
            lineWeight: Double? = nil,
            start: [Double]? = nil,
            end: [Double]? = nil,
            points: [[Double]]? = nil,
            closed: Bool? = nil,
            origin: [Double]? = nil,
            center: [Double]? = nil,
            size: [Double]? = nil,
            radius: Double? = nil,
            startAngleDegrees: Double? = nil,
            endAngleDegrees: Double? = nil,
            text: String? = nil,
            height: Double? = nil,
            rotationDegrees: Double? = nil,
            pattern: String? = nil,
            scale: Double? = nil,
            angleDegrees: Double? = nil
        ) {
            self.id = id
            self.type = type
            self.layer = layer
            self.color = color
            self.lineType = lineType
            self.lineWeight = lineWeight
            self.start = start
            self.end = end
            self.points = points
            self.closed = closed
            self.origin = origin
            self.center = center
            self.size = size
            self.radius = radius
            self.startAngleDegrees = startAngleDegrees
            self.endAngleDegrees = endAngleDegrees
            self.text = text
            self.height = height
            self.rotationDegrees = rotationDegrees
            self.pattern = pattern
            self.scale = scale
            self.angleDegrees = angleDegrees
        }
    }

    public enum AIDrawingError: Error, LocalizedError {
        case noResponse
        case invalidResponse
        case httpError(status: Int, body: String)
        case truncatedResponse
        case invalidPlan

        public var errorDescription: String? {
            switch self {
            case .noResponse: return "The AI drawing model returned no response."
            case .invalidResponse: return "Received an invalid HTTP response from the AI drawing model."
            case .httpError(let status, let body): return "HTTP \(status): \(body)"
            case .truncatedResponse: return "The AI drawing model ran out of output tokens before returning a drawing plan."
            case .invalidPlan: return "The AI drawing model did not return a valid drawing plan."
            }
        }
    }

    private let baseURL: String
    private let apiKey: String?
    private let model: String
    private let timeout: TimeInterval
    private let urlSession: URLSession

    public init(baseURL: String, apiKey: String? = nil, model: String = "", timeout: TimeInterval = 60.0) {
        var normalized = baseURL
        if normalized.hasSuffix("/") { normalized = String(normalized.dropLast()) }
        self.baseURL = normalized
        self.apiKey = apiKey
        self.model = model
        self.timeout = timeout
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        self.urlSession = URLSession(configuration: config)
    }

    public func generateDrawingPlan(prompt: String, context: DrawingContextJSON) async throws -> DrawingPlanJSON {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let contextJSON = String(data: try encoder.encode(context), encoding: .utf8) ?? "{}"

        let userPrompt = """
Return JSON only. Do not explain. Do not use markdown.
Return one complete, parseable JSON object. Do not omit the final closing ] or }.

Convert the user's CAD drawing request into a safe drawing plan. The CAD engine will validate and preview the plan before applying it.
Use coordinates relative to context.origin unless the user explicitly asks for absolute coordinates.
Keep the operation count intentional, but do not oversimplify named CAD objects into plain boxes/circles.
For fixtures, appliances, doors, windows, and cabinets, prefer semantic symbol operations when they fit the request. The CAD engine expands those symbols into multi-primitive drafting geometry.
Use primitive operations for walls/outlines/construction geometry, and semantic symbol operations for objects like sinks, stoves, refrigerators, doors, windows, cabinets, counters, tubs, toilets, and furniture.
Use the current drawing units. Do not invent huge coordinates.
Use defaultLayer "AI_Generated" unless the user clearly asks for an existing layer.

Primitive operations:
- line: {"type":"line","start":[x,y],"end":[x,y],"layer":"AI_Generated","color":"#RRGGBBAA"}
- polyline: {"type":"polyline","points":[[x,y],[x,y]],"closed":false}
- rectangle: {"type":"rectangle","origin":[x,y],"size":[width,height]}
- circle: {"type":"circle","center":[x,y],"radius":r}
- arc: {"type":"arc","center":[x,y],"radius":r,"startAngleDegrees":0,"endAngleDegrees":90}
- text: {"type":"text","text":"LABEL","origin":[x,y],"height":h,"rotationDegrees":0}
- hatch: {"type":"hatch","points":[[x,y],[x,y],[x,y]],"pattern":"SOLID","scale":1,"angleDegrees":0}

Semantic symbol operations. Prefer these instead of drawing a single rectangle/circle for named objects:
- kitchen_sink / sink / double_sink: {"type":"kitchen_sink","origin":[x,y],"size":[width,height],"rotationDegrees":0}
- stove / range / cooktop: {"type":"stove","origin":[x,y],"size":[width,height],"rotationDegrees":0}
- refrigerator / fridge: {"type":"refrigerator","origin":[x,y],"size":[width,height],"rotationDegrees":0}
- base_cabinet / cabinet: {"type":"base_cabinet","origin":[x,y],"size":[width,height],"rotationDegrees":0}
- countertop / counter: {"type":"countertop","origin":[x,y],"size":[width,height],"rotationDegrees":0}
- door: {"type":"door","origin":[x,y],"size":[width,thickness],"rotationDegrees":0}
- window: {"type":"window","origin":[x,y],"size":[width,depth],"rotationDegrees":0}
- toilet: {"type":"toilet","origin":[x,y],"size":[width,height],"rotationDegrees":0}

Guidance:
- A kitchen sink should be a detailed symbol with basin(s), divider/drain/faucet details, not one rectangle.
- A stove/range should include the appliance outline, cooktop, burners, knobs/handle details, not one circle.
- A refrigerator should include door split and handles, not one rectangle.
- Use text labels only when requested or when they clarify the generated plan; do not use labels as a substitute for geometry.

Output shape:
{"intent":"short summary","coordinateMode":"relative","defaultLayer":"AI_Generated","operations":[...]}

Context:
\(contextJSON)

User request:
\(prompt)
"""

        let request = ChatRequest(
            model: model,
            messages: [
                Message(role: "system", content: "You are a strict JSON generator for a 2D CAD drawing engine. Return one JSON object only."),
                Message(role: "user", content: userPrompt)
            ],
            temperature: 0.0,
            stream: false,
            max_tokens: 4096
        )

        let response = try await sendChatRequest(request)
        guard let choice = response.choices.first else { throw AIDrawingError.noResponse }
        if choice.finish_reason == "length" { throw AIDrawingError.truncatedResponse }
        guard let content = choice.message.content, !content.isEmpty else { throw AIDrawingError.invalidPlan }
#if DEBUG
        print("[AIDraw] LLM raw response:\n\(content)")
#endif
        if let plan = decodePlan(from: content) { return plan }
        if let json = extractOutermostJSONObject(from: content), let plan = decodePlan(from: json) { return plan }
        if let repaired = repairJSONObject(from: content), let plan = decodePlan(from: repaired) {
#if DEBUG
            print("[AIDraw] Repaired incomplete JSON response before decoding.")
#endif
            return plan
        }
        throw AIDrawingError.invalidPlan
    }

    private func sendChatRequest(_ request: ChatRequest) async throws -> ChatResponse {
        let url = URL(string: "\(baseURL)/chat/completions")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = apiKey, !key.isEmpty {
            urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.httpBody = try JSONEncoder().encode(request)
        let (data, response) = try await urlSession.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else { throw AIDrawingError.invalidResponse }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw AIDrawingError.httpError(status: httpResponse.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(ChatResponse.self, from: data)
    }

    private func decodePlan(from text: String) -> DrawingPlanJSON? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DrawingPlanJSON.self, from: data)
    }

    private func extractOutermostJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start <= end else { return nil }
        return String(text[start...end])
    }

    /// Local LLMs sometimes return a syntactically valid-looking plan but drop
    /// the final closing brace, for example `{..., "operations":[...]`.
    /// This repair pass extracts from the first `{`, tracks braces/brackets while
    /// respecting quoted strings, and appends any missing closing delimiters.
    /// It only repairs structurally incomplete JSON; semantic validation still
    /// happens through `JSONDecoder` and the AIDraw command's entity builder.
    private func repairJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }

        var out = ""
        var stack: [Character] = []
        var inString = false
        var escaped = false

        for ch in text[start...] {
            out.append(ch)

            if inString {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
                continue
            }

            if ch == "\"" {
                inString = true
                continue
            }

            switch ch {
            case "{":
                stack.append("}")
            case "[":
                stack.append("]")
            case "}", "]":
                guard stack.last == ch else { return nil }
                stack.removeLast()
                if stack.isEmpty {
                    return out
                }
            default:
                continue
            }
        }

        guard !out.isEmpty, !inString else { return nil }
        while let closer = stack.popLast() {
            out.append(closer)
        }
        return out
    }

}