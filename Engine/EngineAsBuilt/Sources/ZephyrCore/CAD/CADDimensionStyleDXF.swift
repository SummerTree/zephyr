import Foundation

public enum CADDimensionArrowhead: String, Sendable, Hashable, Codable, CaseIterable {
    case closedFilled
    case closedBlank
    case closed
    case dot
    case architecturalTick
    case oblique
    case open
    case originIndicator
    case originIndicator2
    case rightAngle
    case open30
    case dotSmall
    case dotBlank
    case dotSmallBlank
    case box
    case boxFilled
    case datumTriangle
    case datumTriangleFilled
    case integral
    case none
    case userArrow

    public var displayName: String {
        switch self {
        case .closedFilled: return "Closed filled"
        case .closedBlank: return "Closed blank"
        case .closed: return "Closed"
        case .dot: return "Dot"
        case .architecturalTick: return "Architectural tick"
        case .oblique: return "Oblique"
        case .open: return "Open"
        case .originIndicator: return "Origin indicator"
        case .originIndicator2: return "Origin indicator2"
        case .rightAngle: return "Right angle"
        case .open30: return "Open 30"
        case .dotSmall: return "Dot small"
        case .dotBlank: return "Dot blank"
        case .dotSmallBlank: return "Dot small blank"
        case .box: return "Box"
        case .boxFilled: return "Box filled"
        case .datumTriangle: return "Datum triangle"
        case .datumTriangleFilled: return "Datum triangle filled"
        case .integral: return "Integral"
        case .none: return "None"
        case .userArrow: return "User arrow"
        }
    }

    public static func fromDXFBlockName(_ blockName: String?) -> CADDimensionArrowhead {
        guard let blockName else { return .closedFilled }
        let normalized = blockName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
            .lowercased()

        switch normalized {
        case "", "closedfilled": return .closedFilled
        case "closedblank": return .closedBlank
        case "closed": return .closed
        case "dot": return .dot
        case "archtick", "architecturaltick": return .architecturalTick
        case "oblique": return .oblique
        case "open": return .open
        case "origin", "originindicator": return .originIndicator
        case "origin2", "originindicator2": return .originIndicator2
        case "rightangle": return .rightAngle
        case "open30": return .open30
        case "dotsmall": return .dotSmall
        case "dotblank": return .dotBlank
        case "dotsmallblank": return .dotSmallBlank
        case "box", "boxblank": return .box
        case "boxfilled": return .boxFilled
        case "datum", "datumblank", "datumtriangle": return .datumTriangle
        case "datumfilled", "datumtrianglefilled": return .datumTriangleFilled
        case "integral": return .integral
        case "none": return .none
        default: return .userArrow
        }
    }
}

public extension CADDimensionStyle {
    var resolvedFirstArrowhead: CADDimensionArrowhead {
        firstArrowhead ?? (tickSize > 0 ? .architecturalTick : .closedFilled)
    }

    var resolvedSecondArrowhead: CADDimensionArrowhead {
        secondArrowhead ?? (tickSize > 0 ? .architecturalTick : .closedFilled)
    }

    func formatDXFMeasurement(_ value: Double, prefix: String = "", suffix: String = "") -> String {
        let scaled = value * (linearScaleFactor ?? 1.0)
        let body: String
        switch unitsFormat {
        case .scientific:
            body = String(format: "%.*E", max(0, unitsPrecision), scaled)
        case .decimal, .windowsDesktop:
            body = formatDXFDecimal(scaled)
        case .engineering:
            body = formatDXFEngineering(scaled)
        case .architectural:
            body = formatDXFArchitectural(scaled)
        case .fractional:
            body = formatDXFFractional(scaled)
        }
        return prefix + (dimensionPrefix ?? "") + body + (dimensionSuffix ?? "") + suffix
    }

    func formatDXFAngle(_ radians: Double) -> String {
        switch angleFormat {
        case .decimalDegrees:
            return String(format: "%.*f°", max(0, anglePrecision), radians * 180.0 / .pi)
        case .degMinSec:
            let totalDegrees = radians * 180.0 / .pi
            let sign = totalDegrees < 0 ? "-" : ""
            let absolute = abs(totalDegrees)
            let degrees = Int(floor(absolute))
            let totalMinutes = (absolute - Double(degrees)) * 60.0
            let minutes = Int(floor(totalMinutes))
            let seconds = (totalMinutes - Double(minutes)) * 60.0
            return String(format: "%@%d°%02d'%.*f\"", sign, degrees, minutes, max(0, anglePrecision), seconds)
        case .gradians:
            return String(format: "%.*fg", max(0, anglePrecision), radians * 200.0 / .pi)
        case .radians:
            return String(format: "%.*fr", max(0, anglePrecision), radians)
        }
    }

    private func formatDXFDecimal(_ value: Double) -> String {
        var text = String(format: "%.*f", max(0, unitsPrecision), value)
        let suppression = zeroSuppression ?? 0
        if (suppression & 8) != 0, text.contains(".") {
            while text.last == "0" { text.removeLast() }
            if text.last == "." { text.removeLast() }
        }
        if (suppression & 4) != 0 {
            if text.hasPrefix("0.") { text.removeFirst() }
            if text.hasPrefix("-0.") { text.remove(at: text.index(after: text.startIndex)) }
        }
        return text
    }

    private func formatDXFEngineering(_ inches: Double) -> String {
        let sign = inches < 0 ? "-" : ""
        let absolute = abs(inches)
        let feet = Int(floor(absolute / 12.0))
        let remainingInches = absolute - Double(feet * 12)
        return sign + "\(feet)'-" + String(format: "%.*f\"", max(0, unitsPrecision), remainingInches)
    }

    private func formatDXFArchitectural(_ inches: Double) -> String {
        let sign = inches < 0 ? "-" : ""
        let denominator = 1 << min(max(0, unitsPrecision), 10)
        var totalNumerator = Int((abs(inches) * Double(denominator)).rounded())
        let numeratorsPerFoot = 12 * denominator
        let feet = totalNumerator / numeratorsPerFoot
        totalNumerator %= numeratorsPerFoot
        let wholeInches = totalNumerator / denominator
        let numerator = totalNumerator % denominator
        let suppression = zeroSuppression ?? 0
        let showFeet = feet != 0 || (suppression & 1) == 0
        let showInches = wholeInches != 0 || numerator != 0 || (suppression & 2) == 0
        let feetText = showFeet ? "\(feet)'" : ""
        let inchesText = showInches
            ? "\(formatDXFFractionText(whole: wholeInches, numerator: numerator, denominator: denominator))\""
            : ""
        let separator = showFeet && showInches ? "-" : ""
        return sign + feetText + separator + inchesText
    }

    private func formatDXFFractional(_ value: Double) -> String {
        let sign = value < 0 ? "-" : ""
        let denominator = 1 << min(max(0, unitsPrecision), 10)
        let totalNumerator = Int((abs(value) * Double(denominator)).rounded())
        let whole = totalNumerator / denominator
        let numerator = totalNumerator % denominator
        return sign + formatDXFFractionText(whole: whole, numerator: numerator, denominator: denominator)
    }

    private func formatDXFFractionText(whole: Int, numerator: Int, denominator: Int) -> String {
        guard numerator != 0 else { return "\(whole)" }
        let divisor = greatestCommonDivisor(numerator, denominator)
        let reducedNumerator = numerator / divisor
        let reducedDenominator = denominator / divisor
        return whole == 0
            ? "\(reducedNumerator)/\(reducedDenominator)"
            : "\(whole) \(reducedNumerator)/\(reducedDenominator)"
    }

    private func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
        var x = abs(a)
        var y = abs(b)
        while y != 0 {
            let remainder = x % y
            x = y
            y = remainder
        }
        return max(1, x)
    }
}
