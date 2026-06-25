import Foundation

// =========================================================================
// MARK: - CADClipboard
//
// Internal clipboard for CAD entity copy/paste operations. Mimics AutoCAD's
// Windows clipboard behavior but stays entirely in-process — no OS clipboard
// serialization of CAD geometry is required.
//
//   - COPYCLIP  → snapshots selected entities + block defs into `entry`
//   - COPYBASE  → same, but also stores a basePoint for aligned pasting
//   - PASTECLIP → duplicates entities from entry, places at viewport center
//   - PASTEORIG → duplicates entities, keeps original world coordinates
//   - PASTEBLOCK→ pastes entities bundled into a new block definition
// =========================================================================

// MARK: - CADClipboardEntry

/// A single clipboard entry: copied entities, their block definitions,
/// and an optional base point for alignment.
public struct CADClipboardEntry: Sendable {
    /// Deep-copied entities captured at COPYCLIP/COPYBASE time.
    /// Each entity still has its original UUID handle — these are regenerated
    /// at paste time by `CADDocument.duplicateEntities`.
    public let entities: [CADEntity]

    /// Block definitions referenced by the copied entities.
    /// Keyed by original block UUID — remapped at paste time.
    public let blocks: [UUID: CADBlock]

    /// Optional base point. Set by COPYBASE; nil for COPYCLIP.
    /// When non-nil, pasted entities are offset so this point lands at the
    /// paste insertion point.
    public let basePoint: Vector3?

    public init(
        entities: [CADEntity],
        blocks: [UUID: CADBlock],
        basePoint: Vector3? = nil
    ) {
        self.entities = entities
        self.blocks = blocks
        self.basePoint = basePoint
    }
}

// MARK: - CADClipboard

/// Holds at most one clipboard entry at a time (AutoCAD-style single-entry clipboard).
public struct CADClipboard: Sendable {
    /// The current clipboard entry, or nil if nothing has been copied.
    public var entry: CADClipboardEntry?

    /// Whether the clipboard holds entity data that can be pasted.
    public var hasEntities: Bool { entry != nil }

    public init() {}
}
