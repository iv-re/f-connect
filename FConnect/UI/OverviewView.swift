import SwiftUI

public struct OverviewView: View {
    @ObservedObject var controller: BaseDeviceController
    @Binding var selectedPort: Int
    
    public init(controller: BaseDeviceController, selectedPort: Binding<Int>) {
        self.controller = controller
        self._selectedPort = selectedPort
    }
    
    private var visibleGroups: [(index: Int, state: FanGroupState)] {
        controller.visibleGroups
    }
    
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if visibleGroups.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "eye.slash")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("All Fan Groups are Hidden")
                            .font(.headline)
                        Text("Enable groups in Device Settings to monitor them here.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16)], alignment: .leading, spacing: 16) {
                        ForEach(visibleGroups, id: \.index) { item in
                            overviewGroupCard(for: item.index)
                        }
                    }
                }
            }
            .padding(24)
        }
    }
    
    private func overviewGroupCard(for portIndex: Int) -> some View {
        let state = controller.groupStates[portIndex]
        
        return GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(state.name)
                        .font(.headline)
                    Spacer()
                }
                
                HStack(spacing: 8) {
                    ForEach(0..<state.fanCount, id: \.self) { _ in
                        UniFanGraphicView(
                            mode: state.lightingMode,
                            color: Color(red: Double(state.staticColor.red) / 255.0, green: Double(state.staticColor.green) / 255.0, blue: Double(state.staticColor.blue) / 255.0),
                            rpm: state.rpm,
                            isSelected: false,
                            isARGBSync: controller.isMotherboardARGBSync
                        )
                        .frame(width: 60, height: 60)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
                
                HStack {
                    Text("\(state.rpm) RPM")
                        .font(.subheadline.monospacedDigit())
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    if controller.isMotherboardARGBSync {
                        Text("MB ARGB")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                            .foregroundColor(.secondary)
                    }
                    
                    if state.isRPMSync {
                        Text("MB RPM")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                            .foregroundColor(.secondary)
                    } else {
                        Text("\(state.targetDuty)% PWM")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(4)
        }
    }
}
