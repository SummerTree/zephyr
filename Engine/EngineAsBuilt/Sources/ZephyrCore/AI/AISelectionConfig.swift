import Foundation

// =========================================================================
// MARK: - AISelectionConfig
//
// User-facing configuration for the AI-powered pattern-matching selection
// tool. Stored on `PhrostEngine` so it can be adjusted at runtime via
// command-line or settings commands.
// =========================================================================

public struct AISelectionConfig: Sendable {
    /// Base URL for the OpenAI-compatible API endpoint.
    /// Default: "http://localhost:1234/v1" (LM Studio default).
    public var baseURL: String

    /// API key for the LLM service. `nil` for local LLMs that don't require one.
    public var apiKey: String?

    /// Model name to request. Empty string means "let the server use its default."
    public var model: String

    /// Maximum world-space gap between entities to still consider them part of
    /// the same cluster. Higher values merge more aggressively.
    public var gapTolerance: Double

    /// Maximum number of canvas clusters to send to the LLM in a single batch.
    /// Caps tool-call payload size for local models with tight context windows.
    public var maxClustersToEvaluate: Int

    /// HTTP request timeout in seconds.
    public var requestTimeout: TimeInterval

    // MARK: - Init

    public init(
        baseURL: String = "http://localhost:1234/v1",
        apiKey: String? = nil,
        model: String = "gemma-4-12b-it-mlx",
        gapTolerance: Double = 0.05,
        maxClustersToEvaluate: Int = 50,
        requestTimeout: TimeInterval = 1800.0  // 30 minutes — local LLMs can be slow on first load
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.gapTolerance = gapTolerance
        self.maxClustersToEvaluate = maxClustersToEvaluate
        self.requestTimeout = requestTimeout
    }
}
