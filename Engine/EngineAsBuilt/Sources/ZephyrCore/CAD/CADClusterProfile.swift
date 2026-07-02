import Foundation

// =========================================================================
// MARK: - ClusterProfileJSON
//
// Lightweight JSON feature profile of an entity cluster, designed to be
// serialized and sent to an LLM for geometric pattern matching.
//
// All array fields are sorted ascending so the LLM can trivially compare
// clusters regardless of the traversal order used during extraction.
// =========================================================================

public struct ClusterProfileJSON: Codable, Sendable {
    /// Unique identifier for this cluster (UUID string).
    public let cluster_id: String

    /// Number of entities in the cluster.
    public let entity_count: Int

    /// Primitive type names present in the cluster (e.g. ["line", "line", "line"]).
    public let types: [String]

    /// Diagonal length of the cluster's world-space bounding box.
    /// Absolute value; scale-dependent.
    public let max_diagonal: Double

    /// Mean segment length across all line-like primitives in the cluster.
    public let average_length: Double

    /// Whether the cluster forms a closed shape (all endpoints connect within gap tolerance).
    public let is_closed_shape: Bool

    /// Distances between unjoined endpoints, in ascending order.
    /// An empty array means all endpoints are joined.
    public let endpoint_gaps: [Double]

    /// Relative interior angles between consecutive line segments, in ascending order.
    /// For non-line primitives (arcs, circles) the angular span is included.
    public let relative_angles: [Double]

    /// Layer names the cluster entities reside on (deduplicated, sorted).
    public let layer_names: [String]

    // MARK: - Scale/Rotation-Invariant Metrics

    /// Scale-invariant spatial distribution: max_diagonal / average_length.
    /// Invariant to uniform scale and arbitrary rotation (unlike aspect_ratio).
    public let spread_factor: Double

    /// Each gap in `endpoint_gaps` divided by `average_length`.
    /// Scale-invariant: a gap of 0.05 on a large object looks identical to 0.005 on a tiny one.
    /// Sorted ascending.
    public let normalized_gaps: [Double]

    // MARK: - Init

    public init(
        cluster_id: String,
        entity_count: Int,
        types: [String],
        max_diagonal: Double,
        average_length: Double,
        is_closed_shape: Bool,
        endpoint_gaps: [Double],
        relative_angles: [Double],
        layer_names: [String],
        spread_factor: Double,
        normalized_gaps: [Double]
    ) {
        self.cluster_id = cluster_id
        self.entity_count = entity_count
        self.types = types
        self.max_diagonal = max_diagonal
        self.average_length = average_length
        self.is_closed_shape = is_closed_shape
        self.endpoint_gaps = endpoint_gaps
        self.relative_angles = relative_angles
        self.layer_names = layer_names
        self.spread_factor = spread_factor
        self.normalized_gaps = normalized_gaps
    }
}
