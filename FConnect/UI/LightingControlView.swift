import SwiftUI
import AppKit

public struct LightingControlView: View {
    @ObservedObject var controller: BaseDeviceController
    @Binding var selectedPort: Int
    
    enum ColorDistributionMode: String, CaseIterable, Identifiable {
        case solid = "Solid"
        case multiZone = "Multi-Zone"
        var id: String { rawValue }
    }
    
    @State private var colorDistribution: ColorDistributionMode = .solid
    @State private var isARGBSync: Bool = false
    @State private var selectedMode: FanLightingMode = .rainbow
    @State private var modeColors: [Color] = [.cyan, .purple, .yellow, .blue]
    @State private var activeColorSlot: Int = 0
    @State private var brightnessPercent: Double = 100
    @State private var speedLevel: Double = 2 // 0..4
    @State private var direction: UInt8 = 0
    
    private let presetColors: [Color] = [
        .cyan, .blue, .indigo, .purple, .pink, .red, .orange, .yellow, .mint, .white
    ]
    
    public init(controller: BaseDeviceController, selectedPort: Binding<Int>) {
        self.controller = controller
        self._selectedPort = selectedPort
        self._isARGBSync = State(initialValue: controller.isMotherboardARGBSync)
    }
    
    private var visibleGroups: [(index: Int, state: FanGroupState)] {
        controller.visibleGroups
    }
    
    /// Modes where users typically want a single unified solid color, but CAN opt into multi-zone
    private var supportsZoneChoice: Bool {
        selectedMode == .staticColor || selectedMode == .breathing
    }
    
    public var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { isARGBSync },
                    set: { newVal in
                        isARGBSync = newVal
                        controller.setARGBSync(newVal)
                    }
                )) {
                    Text("Motherboard ARGB Sync")
                }
                .toggleStyle(.switch)
            }
            
            Section {
                Picker("Target Fan Group", selection: Binding(
                    get: { selectedPort },
                    set: { newPort in
                        selectedPort = newPort
                        syncStateFromPort(newPort)
                    }
                )) {
                    Text("All Groups").tag(-1)
                    ForEach(visibleGroups, id: \.index) { item in
                        Text(item.state.name).tag(item.index)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(isARGBSync)
            }
            
            Section {
                Picker("Effect Pattern", selection: Binding(
                    get: { selectedMode },
                    set: { newMode in
                        selectedMode = newMode
                        activeColorSlot = 0
                        applyLighting()
                    }
                )) {
                    ForEach(controller.supportedLightingModes) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                
                if selectedMode.maxColors > 0 {
                    if supportsZoneChoice {
                        Picker("Color Layout", selection: Binding(
                            get: { colorDistribution },
                            set: { newLayout in
                                colorDistribution = newLayout
                                if newLayout == .solid {
                                    let primaryColor = modeColors.first ?? .cyan
                                    for i in 0..<modeColors.count {
                                        modeColors[i] = primaryColor
                                    }
                                }
                                applyLighting()
                            }
                        )) {
                            ForEach(ColorDistributionMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    
                    let isMultiZone = supportsZoneChoice && colorDistribution == .multiZone
                    let count = isMultiZone ? selectedMode.maxColors : (supportsZoneChoice ? 1 : selectedMode.maxColors)
                    
                    ForEach(0..<count, id: \.self) { slotIndex in
                        HStack {
                            let label: String = {
                                if supportsZoneChoice && colorDistribution == .solid {
                                    return "Color"
                                } else {
                                    return "Zone \(slotIndex + 1)"
                                }
                            }()
                            
                            Text(label)
                                .font(.body)
                            
                            Spacer()
                            
                            ColorSwatchButton(
                                color: slotIndex < modeColors.count ? modeColors[slotIndex] : .cyan,
                                presets: presetColors,
                                onSelect: { chosenColor in
                                    if supportsZoneChoice && colorDistribution == .solid {
                                        for i in 0..<modeColors.count {
                                            modeColors[i] = chosenColor
                                        }
                                    } else {
                                        if slotIndex < modeColors.count {
                                            modeColors[slotIndex] = chosenColor
                                        }
                                    }
                                    applyLighting()
                                }
                            )
                        }
                    }
                }
                
                Picker("Animation Direction", selection: Binding(
                    get: { direction },
                    set: { newVal in
                        direction = newVal
                        applyLighting()
                    }
                )) {
                    // Wire values from the original software: Right = 0 (its default), Left = 1.
                    Text("Right").tag(UInt8(0))
                    Text("Left").tag(UInt8(1))
                }
                .pickerStyle(.radioGroup)
            }
            .disabled(isARGBSync)
            
            Section {
                Slider(
                    value: $brightnessPercent,
                    in: 0...100,
                    step: 25,
                    onEditingChanged: { editing in
                        if !editing { applyLighting() }
                    }
                ) {
                    Text("Brightness")
                }
                
                Slider(
                    value: $speedLevel,
                    in: 0...4,
                    step: 1,
                    onEditingChanged: { editing in
                        if !editing { applyLighting() }
                    }
                ) {
                    Text("Animation Speed")
                }
            }
            .disabled(isARGBSync)
        }
        .formStyle(.grouped)
        .onAppear {
            isARGBSync = controller.isMotherboardARGBSync
            syncStateFromPort(selectedPort)
        }
    }
    
    private func syncStateFromPort(_ port: Int) {
        let targetGroup = (port >= 0 && port < controller.groupStates.count) ? controller.groupStates[port] : controller.groupStates.first
        guard let state = targetGroup else { return }
        // A mode this hardware cannot show is displayed (and was sent) as a static color; keep the picker in step.
        selectedMode = controller.effectiveLightingMode(state.lightingMode)
        brightnessPercent = Double(state.brightnessPercent)
        speedLevel = Double(state.speedIndex)
        direction = state.direction
        
        let saved = state.effectiveLightingColors
        var colors = saved.map { Color(red: Double($0.red) / 255.0, green: Double($0.green) / 255.0, blue: Double($0.blue) / 255.0) }
        while colors.count < 4 { colors.append(colors.first ?? .cyan) }
        modeColors = colors
        colorDistribution = Set(saved).count > 1 ? .multiZone : .solid
        activeColorSlot = 0
    }
    
    private func rgbFromColor(_ c: Color) -> RGBColor {
        let ns = NSColor(c).usingColorSpace(.sRGB) ?? NSColor(c)
        let r = UInt8(max(0, min(255, (ns.redComponent * 255.0).rounded())))
        let g = UInt8(max(0, min(255, (ns.greenComponent * 255.0).rounded())))
        let b = UInt8(max(0, min(255, (ns.blueComponent * 255.0).rounded())))
        return RGBColor(red: r, green: g, blue: b)
    }
    
    private func applyLighting() {
        let activeColors: [RGBColor]
        if supportsZoneChoice && colorDistribution == .solid {
            activeColors = [rgbFromColor(modeColors.first ?? .cyan)]
        } else {
            activeColors = Array(modeColors.prefix(max(1, selectedMode.maxColors)).map { rgbFromColor($0) })
        }
        
        if selectedPort == -1 {
            for i in 0..<controller.groupStates.count {
                controller.setLighting(
                    groupIndex: i,
                    mode: selectedMode,
                    speedIndex: Int(speedLevel),
                    brightnessPercent: Int(brightnessPercent),
                    direction: direction,
                    colors: Array(activeColors)
                )
            }
        } else {
            controller.setLighting(
                groupIndex: selectedPort,
                mode: selectedMode,
                speedIndex: Int(speedLevel),
                brightnessPercent: Int(brightnessPercent),
                direction: direction,
                colors: Array(activeColors)
            )
        }
    }
}

struct ColorSwatchButton: View {
    let color: Color
    let presets: [Color]
    let onSelect: (Color) -> Void
    
    @State private var isPickerPresented: Bool = false
    @State private var currentColor: Color = .cyan
    @State private var hexString: String = "00FFFF"
    
    var body: some View {
        Button {
            currentColor = color
            updateHexFromColor(color)
            isPickerPresented.toggle()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .frame(width: 44, height: 22)
                
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(color)
                    .frame(width: 36, height: 16)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.primary.opacity(0.15), lineWidth: 0.5)
                    )
            }
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(Color.primary.opacity(0.25), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.08), radius: 1, x: 0, y: 0.5)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPickerPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Select Color")
                        .font(.headline)
                    Spacer()
                    ColorPicker("", selection: Binding(
                        get: { currentColor },
                        set: { newColor in
                            currentColor = newColor
                            updateHexFromColor(newColor)
                            onSelect(newColor)
                        }
                    ), supportsOpacity: false)
                }
                
                HStack(spacing: 8) {
                    Text("HEX")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    
                    TextField("#000000", text: $hexString)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 100)
                        .onSubmit {
                            applyHex()
                        }
                    
                    Button("Set") {
                        applyHex()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                
                Text("Palette")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 26), spacing: 8)], spacing: 8) {
                    ForEach(presets, id: \.self) { preset in
                        Circle()
                            .fill(preset)
                            .frame(width: 26, height: 26)
                            .overlay(
                                Circle()
                                    .stroke(Color.primary.opacity(currentColor == preset ? 0.9 : 0.2), lineWidth: currentColor == preset ? 2 : 1)
                            )
                            .onTapGesture {
                                currentColor = preset
                                updateHexFromColor(preset)
                                onSelect(preset)
                            }
                    }
                }
            }
            .padding(14)
            .frame(width: 230)
        }
    }
    
    private func updateHexFromColor(_ col: Color) {
        let ns = NSColor(col).usingColorSpace(.sRGB) ?? NSColor(col)
        let r = Int((ns.redComponent * 255.0).rounded())
        let g = Int((ns.greenComponent * 255.0).rounded())
        let b = Int((ns.blueComponent * 255.0).rounded())
        hexString = String(format: "%02X%02X%02X", r, g, b)
    }
    
    private func applyHex() {
        let clean = hexString.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard clean.count == 6, let rgbInt = UInt32(clean, radix: 16) else { return }
        let r = Double((rgbInt >> 16) & 0xFF) / 255.0
        let g = Double((rgbInt >> 8) & 0xFF) / 255.0
        let b = Double(rgbInt & 0xFF) / 255.0
        let newCol = Color(red: r, green: g, blue: b)
        currentColor = newCol
        onSelect(newCol)
    }
}
