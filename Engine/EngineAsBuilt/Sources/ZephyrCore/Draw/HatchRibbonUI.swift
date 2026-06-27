import Foundation
import ImGui

// MARK: - HatchRibbonUI
//
// Shared floating ribbon for hatch creation and post-selection editing.
// Rendered as a borderless, rounded window at top-center of the canvas.
//
// Two call sites:
//   1. HatchCommand.renderImGui  — creation mode, uses command-local state.
//   2. AppUI.render               — editing mode, reads from selected entity.

@MainActor
public struct HatchRibbonUI {

    /// Settings bundle passed between the ribbon and its owner.
    public struct Settings {
        public var fillType: Int32 = 1       // 0=Pattern, 1=Solid, 2=Gradient
        public var patternName: String = "ANSI31"
        public var scale: Float = 1.0
        public var angle: Float = 0.0
        public var primaryColor: ColorRGBA? = nil
        public var backgroundColor: ColorRGBA? = nil
        public var secondaryColor: ColorRGBA? = nil
        public var selectionMode: Int32 = 0  // 0=PickPoints, 1=SelectBoundary
        public var showModeSection: Bool = true  // hidden during edit mode

        public init(fillType: Int32, patternName: String, scale: Float, angle: Float,
                    primaryColor: ColorRGBA?, backgroundColor: ColorRGBA?,
                    secondaryColor: ColorRGBA?, selectionMode: Int32, showModeSection: Bool) {
            self.fillType = fillType
            self.patternName = patternName
            self.scale = scale
            self.angle = angle
            self.primaryColor = primaryColor
            self.backgroundColor = backgroundColor
            self.secondaryColor = secondaryColor
            self.selectionMode = selectionMode
            self.showModeSection = showModeSection
        }
    }

    /// Color popup state (reused across frames).
    public static var activeColorPopup: Int = 0  // 0=none, 1=primary, 2=background, 3=secondary

    // MARK: - Public render entry point

    /// Render the floating hatch ribbon.
    /// - Parameters:
    ///   - settings: Mutable settings to read/write (inout).
    ///   - engine: The engine (for theme colours).
    public static func render(_ settings: inout Settings, engine: PhrostEngine) {
        let fontSize = ImGuiGetFontSize()
        let pad: Float = 8.0

        let topChromeH: Float = {
            #if os(macOS)
            return 36.0
            #else
            return 50.0
            #endif
        }()
        let windowW = fontSize * 52
        let windowX = max(0, (ImGuiGetIO()!.pointee.DisplaySize.x - windowW) * 0.5)
        let windowY = topChromeH + 16

        ImGuiSetNextWindowPos(
            ImVec2(x: windowX, y: windowY),
            Int32(ImGuiCond_Appearing.rawValue),
            ImVec2(x: 0, y: 0))
        ImGuiSetNextWindowSize(
            ImVec2(x: windowW, y: 0),
            Int32(ImGuiCond_Always.rawValue))

        ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowRounding.rawValue), 8.0)
        ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowPadding.rawValue), ImVec2(x: pad, y: pad))
        ImGuiPushStyleColor(Int32(ImGuiCol_WindowBg.rawValue), engine.ui.theme.panelBg)

        let flags = Int32(ImGuiWindowFlags_NoTitleBar.rawValue
                        | ImGuiWindowFlags_NoResize.rawValue
                        | ImGuiWindowFlags_NoScrollbar.rawValue
                        | ImGuiWindowFlags_NoSavedSettings.rawValue
                        | ImGuiWindowFlags_AlwaysAutoResize.rawValue)

        guard igBegin("##HatchRibbon", nil, flags) else {
            ImGuiEnd()
            ImGuiPopStyleVar(2)
            ImGuiPopStyleColor(1)
            return
        }

        defer {
            ImGuiEnd()
            ImGuiPopStyleVar(2)
            ImGuiPopStyleColor(1)
        }

        let activeBg = engine.ui.theme.activeBg

        // ── Group 1: Icon + Fill Type ──
        igBeginGroup()
        let previewCol: UInt32
        if let pc = settings.primaryColor {
            previewCol = makeCol32(pc.r, pc.g, pc.b, pc.a)
        } else {
            previewCol = makeCol32(128, 128, 128, 200)
        }
        let sp = igGetCursorScreenPos()
        let previewMin = ImVec2(x: sp.x, y: sp.y + 2)
        let previewMax = ImVec2(x: previewMin.x + fontSize - 4, y: previewMin.y + fontSize - 4)
        ImDrawListAddRectFilled(igGetWindowDrawList(), previewMin, previewMax, previewCol, 3.0, 0)
        ImGuiDummy(ImVec2(x: fontSize - 4, y: fontSize - 4))

        ImGuiSameLine(0, pad)

        let fillTypeNames: [String] = ["Pattern", "Solid", "Gradient"]
        for (idx, name) in fillTypeNames.enumerated() {
            if idx > 0 { ImGuiSameLine(0, 2) }
            let selected = settings.fillType == Int32(idx)
            if selected {
                ImGuiPushStyleColor(Int32(ImGuiCol_Button.rawValue), activeBg)
            }
            if igSmallButton(name) {
                settings.fillType = Int32(idx)
            }
            if selected {
                ImGuiPopStyleColor(1)
            }
        }
        igEndGroup()

        ImGuiSameLine(0, pad * 2)

        // ── Group 2: Pattern dropdown (Pattern mode only) ──
        igBeginGroup()
        if settings.fillType == 0 {
            ImGuiTextV("Pattern")
            ImGuiSameLine(0, 4)
            ImGuiPushItemWidth(fontSize * 8)
            let patternNames = DXFHatchGenerator.predefinedPatterns.keys.sorted()
            if ImGuiBeginCombo("##HatchPat", settings.patternName, 0) {
                for pn in patternNames {
                    let selected = pn == settings.patternName
                    if ImGuiSelectable(pn, selected, Int32(ImGuiSelectableFlags_None.rawValue),
                                       ImVec2(x: 0, y: 0)) {
                        settings.patternName = pn
                    }
                    if selected { ImGuiSetItemDefaultFocus() }
                }
                ImGuiEndCombo()
            }
            ImGuiPopItemWidth()
        } else {
            ImGuiDummy(ImVec2(x: 1, y: 1))
        }
        igEndGroup()

        ImGuiSameLine(0, pad * 2)

        // ── Group 3: Colors ──
        igBeginGroup()
        let primaryLabel: String
        switch settings.fillType {
        case 0, 1: primaryLabel = "Color"
        default:   primaryLabel = "Color 1"
        }
        ImGuiTextV(primaryLabel)
        ImGuiSameLine(0, 4)
        renderColorSwatch(id: 1, currentColor: &settings.primaryColor, engine: engine)

        if settings.fillType != 1 {
            ImGuiSameLine(0, pad)
            let bgLabel = settings.fillType == 2 ? "Color 2" : "Background"
            ImGuiTextV(bgLabel)
            ImGuiSameLine(0, 4)
            if settings.fillType == 2 {
                renderColorSwatch(id: 3, currentColor: &settings.secondaryColor, engine: engine)
            } else {
                renderColorSwatch(id: 2, currentColor: &settings.backgroundColor, engine: engine)
            }
        }
        igEndGroup()

        ImGuiSameLine(0, pad * 2)

        // ── Group 4: Angle + Scale ──
        igBeginGroup()
        ImGuiTextV("Angle")
        ImGuiSameLine(0, 4)
        ImGuiPushItemWidth(fontSize * 5)
        ImGuiSliderAngle("##HatchAngle", &settings.angle, -180, 180, "%.0f", ImGuiSliderFlags(0))
        ImGuiPopItemWidth()

        ImGuiSameLine(0, pad)
        ImGuiTextV("Scale")
        ImGuiSameLine(0, 4)
        ImGuiPushItemWidth(fontSize * 4)
        ImGuiInputFloat("##HatchScale", &settings.scale, 0.1, 1.0, "%.2f", 0)
        ImGuiPopItemWidth()
        igEndGroup()

        // ── Group 5: Mode toggles (creation only) ──
        if settings.showModeSection {
            ImGuiSameLine(0, pad * 2)
            igBeginGroup()
            if igSmallButton("Pick Points") {
                settings.selectionMode = 0
            }
            ImGuiSameLine(0, 2)
            if igSmallButton("Select") {
                settings.selectionMode = 1
            }
            let modeStr = settings.selectionMode == 0 ? "Pick Points" : "Select Boundary"
            ImGuiTextV(modeStr)
            igEndGroup()
        }
    }

    // MARK: - Color swatch

    private static func renderColorSwatch(
        id: Int, currentColor: inout ColorRGBA?, engine: PhrostEngine
    ) {
        let fontSize = ImGuiGetFontSize()
        let swatchSize: Float = fontSize - 4
        let screenPos = igGetCursorScreenPos()
        let swatchMin = ImVec2(x: screenPos.x, y: screenPos.y + 2)
        let swatchMax = ImVec2(x: swatchMin.x + swatchSize, y: swatchMin.y + swatchSize)
        let dl = igGetWindowDrawList()

        let swatchCol: UInt32
        if let c = currentColor {
            swatchCol = makeCol32(c.r, c.g, c.b, 255)
        } else {
            swatchCol = makeCol32(128, 128, 128, 150)
        }

        ImDrawListAddRectFilled(dl, swatchMin, swatchMax, swatchCol, 3.0, 0)
        ImDrawListAddRect(dl, swatchMin, swatchMax, makeCol32(255, 255, 255, 80), 3.0, 1.0, 0)

        ImGuiDummy(ImVec2(x: swatchSize, y: swatchSize))

        if ImGuiIsItemClicked(0) {
            activeColorPopup = id
            igOpenPopup_Str("##HatchColorPopup", 0)
        }

        if activeColorPopup == id && igBeginPopup("##HatchColorPopup", 0) {
            let presetColors: [(String, ColorRGBA?)] = [
                ("ByLayer", nil),
                ("Red",    ColorRGBA(r: 255, g: 60,  b: 60)),
                ("Orange", ColorRGBA(r: 255, g: 140, b: 0)),
                ("Yellow", ColorRGBA(r: 255, g: 220, b: 0)),
                ("Green",  ColorRGBA(r: 60,  g: 200, b: 80)),
                ("Cyan",   ColorRGBA(r: 0,   g: 200, b: 220)),
                ("Blue",   ColorRGBA(r: 40,  g: 120, b: 255)),
                ("Magenta",ColorRGBA(r: 220, g: 60,  b: 200)),
                ("White",  ColorRGBA(r: 255, g: 255, b: 255)),
            ]

            for (name, col) in presetColors {
                let isSelected = currentColor == col
                let hex = col.map { String(format: "#%02X%02X%02X", $0.r, $0.g, $0.b) } ?? "\u{2014}"
                if ImGuiSelectable("\(name)  \(hex)", isSelected,
                                   Int32(ImGuiSelectableFlags_None.rawValue),
                                   ImVec2(x: 0, y: 0)) {
                    switch id {
                    case 1:  currentColor = col
                    case 2:  currentColor = col
                    case 3:  currentColor = col
                    default: break
                    }
                    activeColorPopup = 0
                    igCloseCurrentPopup()
                }
                if isSelected { ImGuiSetItemDefaultFocus() }
            }

            igSeparator()

            var col: [Float] = [0.5, 0.5, 0.5, 1.0]
            if let c = currentColor {
                col = [Float(c.r) / 255.0, Float(c.g) / 255.0, Float(c.b) / 255.0, Float(c.a) / 255.0]
            }
            ImGuiTextV("Custom:")
            if igColorEdit4("##CustomColor", &col, 0) {
                let newColor = ColorRGBA(
                    r: UInt8(Swift.max(0, Swift.min(255, col[0] * 255))),
                    g: UInt8(Swift.max(0, Swift.min(255, col[1] * 255))),
                    b: UInt8(Swift.max(0, Swift.min(255, col[2] * 255))),
                    a: UInt8(Swift.max(0, Swift.min(255, col[3] * 255))))
                switch id {
                case 1:  currentColor = newColor
                case 2:  currentColor = newColor
                case 3:  currentColor = newColor
                default: break
                }
            }

            igEndPopup()
        }
    }
}
