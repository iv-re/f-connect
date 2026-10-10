import SwiftUI

public struct CoolingControlView: View {
    @ObservedObject var controller: BaseDeviceController
    @Binding var selectedPort: Int
    @ObservedObject private var thermalMonitor = SystemThermalMonitor.shared
    
    @State private var selectedPointIndex: Int = 1
    @State private var nameBuffers: [Int: String] = [:]
    
    public init(controller: BaseDeviceController, selectedPort: Binding<Int>) {
        self.controller = controller
        self._selectedPort = selectedPort
    }
    
    private var visibleGroups: [(index: Int, state: FanGroupState)] {
        controller.visibleGroups
    }
    
    /// Target group state or default state for "All Groups"
    private var currentGroupState: FanGroupState {
        if selectedPort >= 0 && selectedPort < controller.groupStates.count {
            return controller.groupStates[selectedPort]
        }
        return controller.groupStates.first ?? FanGroupState(id: 0)
    }
    
    /// Whether Motherboard RPM sync is active for the current target selection
    private var isCurrentRPMSync: Bool {
        if selectedPort == -1 {
            return controller.groupStates.allSatisfy { $0.isRPMSync }
        } else if selectedPort >= 0 && selectedPort < controller.groupStates.count {
            return controller.groupStates[selectedPort].isRPMSync
        }
        return false
    }
    
    private var currentPreset: FanSpeedProfilePreset {
        currentGroupState.profilePreset
    }
    
    private var currentCurvePoints: [CurvePoint] {
        currentGroupState.curvePoints
    }
    
    public var body: some View {
        Form {
            Section {
                Picker("Target Fan Group", selection: $selectedPort) {
                    Text("All Groups").tag(-1)
                    ForEach(visibleGroups, id: \.index) { item in
                        Text(item.state.name).tag(item.index)
                    }
                }
                .pickerStyle(.segmented)
            }
            
            Section {
                Toggle("Motherboard RPM Sync", isOn: Binding(
                    get: { isCurrentRPMSync },
                    set: { newVal in
                        controller.setGroupRPMSync(groupIndex: selectedPort, isSync: newVal)
                    }
                ))
                .toggleStyle(.switch)
            }
            
            Section {
                Picker("Sensor Source", selection: Binding(
                    get: { thermalMonitor.selectedSensorID },
                    set: { newSensor in
                        thermalMonitor.selectedSensorID = newSensor
                        applyCurrentCurveSpeed()
                    }
                )) {
                    ForEach(thermalMonitor.availableSensors) { sensor in
                        Text("\(sensor.name) (\(String(format: "%.1f", sensor.temperature)) °C)")
                            .tag(sensor.id)
                    }
                }
                .pickerStyle(.menu)
                .font(.body.monospacedDigit())
                .disabled(isCurrentRPMSync)
                
                if thermalMonitor.currentTemperature == nil && !isCurrentRPMSync {
                    Label("No valid temperature reading - fans hold their speed, then go to a safe 70% after 15 s.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                
                Picker("Curve Preset", selection: Binding(
                    get: { currentPreset },
                    set: { newPreset in
                        guard !isCurrentRPMSync else { return }
                        updateCurvePreset(newPreset)
                    }
                )) {
                    ForEach(FanSpeedProfilePreset.allCases) { preset in
                        Text(preset.rawValue).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(isCurrentRPMSync)
                
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        // Left Y-axis (Speed %)
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("100%")
                            Spacer()
                            Text("80%")
                            Spacer()
                            Text("60%")
                            Spacer()
                            Text("40%")
                            Spacer()
                            Text("20%")
                            Spacer()
                            Text("0%")
                        }
                        .font(.system(size: 10, weight: .medium, design: .default).monospacedDigit())
                        .foregroundColor(.secondary)
                        .frame(width: 34, height: 160)
                        
                        // Center Graph Area
                        GeometryReader { geo in
                            ZStack {
                                // Background grid
                                Path { path in
                                    for y in [0.2, 0.4, 0.6, 0.8, 1.0] {
                                        let yPos = geo.size.height * (1.0 - y)
                                        path.move(to: CGPoint(x: 0, y: yPos))
                                        path.addLine(to: CGPoint(x: geo.size.width, y: yPos))
                                    }
                                    for x in [0.2, 0.4, 0.6, 0.8] {
                                        let xPos = geo.size.width * x
                                        path.move(to: CGPoint(x: xPos, y: 0))
                                        path.addLine(to: CGPoint(x: xPos, y: geo.size.height))
                                    }
                                }
                                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                                
                                // Temperature indicator line
                                if let currentT = thermalMonitor.currentTemperature {
                                    let tempX = geo.size.width * (CGFloat(max(0, min(100, currentT))) / 100.0)
                                    Path { path in
                                        path.move(to: CGPoint(x: tempX, y: 0))
                                        path.addLine(to: CGPoint(x: tempX, y: geo.size.height))
                                    }
                                    .stroke(Color.green, lineWidth: 2)
                                }
                                
                                // Curve line
                                Path { path in
                                    let sorted = currentCurvePoints.sorted { $0.temp < $1.temp }
                                    for (idx, pt) in sorted.enumerated() {
                                        let ptX = geo.size.width * (CGFloat(pt.temp) / 100.0)
                                        let ptY = geo.size.height * (1.0 - CGFloat(pt.speed) / 100.0)
                                        if idx == 0 {
                                            path.move(to: CGPoint(x: 0, y: ptY))
                                            path.addLine(to: CGPoint(x: ptX, y: ptY))
                                        } else {
                                            path.addLine(to: CGPoint(x: ptX, y: ptY))
                                        }
                                        if idx == sorted.count - 1 {
                                            path.addLine(to: CGPoint(x: geo.size.width, y: ptY))
                                        }
                                    }
                                }
                                .stroke(isCurrentRPMSync ? Color.secondary.opacity(0.4) : Color.accentColor, lineWidth: 2.5)
                                
                                // Drag points
                                ForEach(0..<currentCurvePoints.count, id: \.self) { idx in
                                    let pt = currentCurvePoints[idx]
                                    let ptX = geo.size.width * (CGFloat(pt.temp) / 100.0)
                                    let ptY = geo.size.height * (1.0 - CGFloat(pt.speed) / 100.0)
                                    
                                    Circle()
                                        .fill(selectedPointIndex == idx ? Color.white : (isCurrentRPMSync ? Color.secondary : Color.accentColor))
                                        .frame(width: 14, height: 14)
                                        .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 2))
                                        .position(x: ptX, y: ptY)
                                        .gesture(
                                            DragGesture()
                                                .onChanged { g in
                                                    guard !isCurrentRPMSync else { return }
                                                    selectedPointIndex = idx
                                                    let newT = max(0, min(100, Double((g.location.x / geo.size.width) * 100)))
                                                    let newS = max(0, min(100, Double((1.0 - g.location.y / geo.size.height) * 100)))
                                                    updatePoint(at: idx, temp: newT, speed: newS)
                                                }
                                                .onEnded { _ in
                                                    guard !isCurrentRPMSync else { return }
                                                    controller.savePreferences()   // a dragged curve is a setting: keep it across restarts
                                                    applyCurrentCurveSpeed()
                                                }
                                        )
                                }
                            }
                        }
                        .frame(height: 160)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
                    }
                    
                    // Bottom X-axis (Temperature °C)
                    HStack(spacing: 8) {
                        Spacer().frame(width: 34) // Matches exact left Y-axis width
                        
                        GeometryReader { geo in
                            let temps = [0, 20, 40, 60, 80, 100]
                            ZStack {
                                ForEach(temps, id: \.self) { t in
                                    let posX = geo.size.width * (CGFloat(t) / 100.0)
                                    Text("\(t)°C")
                                        .position(x: max(12, min(geo.size.width - 14, posX)), y: 8)
                                }
                            }
                        }
                        .frame(height: 18)
                    }
                    .font(.system(size: 10, weight: .medium, design: .default).monospacedDigit())
                    .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
            .disabled(isCurrentRPMSync)
            
            Section("Fan Groups") {
                ForEach(0..<min(4, controller.groupStates.count), id: \.self) { portIndex in
                    HStack(spacing: 12) {
                        // Visibility toggle
                        Button {
                            let willHide = !controller.groupStates[portIndex].isHidden
                            controller.setGroupHidden(groupIndex: portIndex, isHidden: willHide)
                        } label: {
                            Image(systemName: controller.groupStates[portIndex].isHidden ? "eye.slash" : "eye")
                                .foregroundColor(controller.groupStates[portIndex].isHidden ? .secondary : .accentColor)
                                .frame(width: 18)
                        }
                        .buttonStyle(.plain)
                        .help(controller.groupStates[portIndex].isHidden ? "Show this fan group" : "Hide this fan group")
                        
                        // Port indicator
                        Text("Port \(portIndex + 1)")
                            .font(.subheadline.monospaced())
                            .foregroundColor(.secondary)
                            .frame(width: 46, alignment: .leading)
                        
                        // Editable group name
                        TextField("", text: Binding(
                            get: { nameBuffers[portIndex] ?? controller.groupStates[portIndex].name },
                            set: { newName in
                                nameBuffers[portIndex] = newName
                                controller.setGroupName(groupIndex: portIndex, name: newName)
                            }
                        ), prompt: Text("Group Name"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 130)
                        
                        // Identify physical cluster button
                        Button {
                            controller.identifyCluster(groupIndex: portIndex)
                        } label: {
                            Label("Identify", systemImage: "flashlight.on.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Blink this fan cluster in white to physically identify it in your PC case")
                        
                        Spacer()
                        
                        // Live RPM telemetry
                        Text("\(controller.groupStates[portIndex].rpm) RPM")
                            .font(.subheadline.monospacedDigit())
                            .foregroundColor(.secondary)
                            .frame(width: 84, alignment: .trailing)
                        
                        Divider()
                            .frame(height: 16)
                            .padding(.horizontal, 4)
                        
                        // Fan count stepper
                        HStack(spacing: 6) {
                            Text("\(controller.groupStates[portIndex].fanCount) \(controller.groupStates[portIndex].fanCount == 1 ? "Fan" : "Fans")")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .frame(width: 44, alignment: .trailing)
                            
                            Stepper("", value: Binding(
                                get: { controller.groupStates[portIndex].fanCount },
                                set: { cnt in controller.setFanCount(groupIndex: portIndex, count: cnt) }
                            ), in: 1...4)
                            .labelsHidden()
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            syncNameBuffers()
        }
    }
    
    // MARK: - State Management & Speed Application
    
    private func updateCurvePreset(_ preset: FanSpeedProfilePreset) {
        if selectedPort == -1 {
            for i in 0..<controller.groupStates.count {
                controller.groupStates[i].profilePreset = preset
                controller.groupStates[i].curvePoints = preset.defaultPoints
            }
        } else if selectedPort >= 0 && selectedPort < controller.groupStates.count {
            controller.groupStates[selectedPort].profilePreset = preset
            controller.groupStates[selectedPort].curvePoints = preset.defaultPoints
        }
        controller.savePreferences()
        applyCurrentCurveSpeed()
    }
    
    private func updatePoint(at index: Int, temp: Double, speed: Double) {
        if selectedPort == -1 {
            for i in 0..<controller.groupStates.count {
                if index < controller.groupStates[i].curvePoints.count {
                    controller.groupStates[i].profilePreset = .manual
                    controller.groupStates[i].curvePoints[index].temp = temp
                    controller.groupStates[i].curvePoints[index].speed = speed
                }
            }
        } else if selectedPort >= 0 && selectedPort < controller.groupStates.count {
            if index < controller.groupStates[selectedPort].curvePoints.count {
                controller.groupStates[selectedPort].profilePreset = .manual
                controller.groupStates[selectedPort].curvePoints[index].temp = temp
                controller.groupStates[selectedPort].curvePoints[index].speed = speed
            }
        }
    }
    
    private func applyCurrentCurveSpeed() {
        guard let temp = thermalMonitor.currentTemperature else { return }
        if selectedPort == -1 {
            applyDynamicCurve(temp: temp)
        } else if selectedPort >= 0 && selectedPort < controller.groupStates.count {
            guard !controller.groupStates[selectedPort].isRPMSync else { return }
            let speed = controller.groupStates[selectedPort].curvePoints.interpolatedSpeed(for: temp)
            controller.setFanSpeed(groupIndex: selectedPort, percent: Int(speed))
        }
    }
    
    private func applyDynamicCurve(temp: Double) {
        for i in 0..<controller.groupStates.count {
            guard !controller.groupStates[i].isRPMSync else { continue }
            let speed = controller.groupStates[i].curvePoints.interpolatedSpeed(for: temp)
            controller.setFanSpeed(groupIndex: i, percent: Int(speed))
        }
    }
    
    private func syncNameBuffers() {
        for (i, grp) in controller.groupStates.enumerated() {
            nameBuffers[i] = grp.customName ?? "Group \(i + 1)"
        }
    }
}
