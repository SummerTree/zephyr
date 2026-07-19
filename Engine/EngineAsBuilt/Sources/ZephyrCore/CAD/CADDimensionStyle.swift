// Sources/ZephyrCore/CAD/CADDimensionStyle.swift

public enum DimUnitsFormat: Int, Sendable, Hashable, Codable {
    case scientific = 1
    case decimal = 2
    case engineering = 3
    case architectural = 4
    case fractional = 5
    case windowsDesktop = 6
}

public enum DimAngleFormat: Int, Sendable, Hashable, Codable {
    case decimalDegrees = 0
    case degMinSec = 1
    case gradians = 2
    case radians = 3
}

public struct CADDimensionStyle: Sendable, Hashable, Codable {
    public var arrowSize: Double = 2.5
    public var textHeight: Double = 2.5
    public var textOffset: Double = 0.625
    public var extensionLineOffset: Double = 0.625
    public var extensionLineExtend: Double = 1.25
    public var dimLineOffset: Double = 5.0
    public var tickSize: Double = 0.0
    public var unitsFormat: DimUnitsFormat = .decimal
    public var unitsPrecision: Int = 2
    public var angleFormat: DimAngleFormat = .decimalDegrees
    public var anglePrecision: Int = 1
    public var textStyle: String? = nil
    public var suppressFirstExtension: Bool = false
    public var suppressSecondExtension: Bool = false
    public var suppressFirstDimLine: Bool = false
    public var suppressSecondDimLine: Bool = false

    public var firstArrowhead: CADDimensionArrowhead? = nil
    public var secondArrowhead: CADDimensionArrowhead? = nil
    public var firstArrowBlockName: String? = nil
    public var secondArrowBlockName: String? = nil
    public var linearScaleFactor: Double? = nil
    public var dimensionPrefix: String? = nil
    public var dimensionSuffix: String? = nil
    public var zeroSuppression: Int? = nil
    public var textBackgroundScale: Double? = nil
    public var textBackgroundColor: ColorRGBA? = nil
    public var textBackgroundUsesViewportColor: Bool = false
    public static let `default` = CADDimensionStyle()
    
    public init() {}
    
    public func formatMeasurement(_ value: Double, prefix: String = "", suffix: String = "") -> String {
        formatDXFMeasurement(value, prefix: prefix, suffix: suffix)
    }
    
    public func formatAngle(_ radians: Double) -> String {
        formatDXFAngle(radians)
    }
}
