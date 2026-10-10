import SwiftUI
import AppKit

public struct MainDashboardView: View {
    @ObservedObject var deviceManager: DeviceManager
    @ObservedObject var controller: BaseDeviceController
    
    @State private var selectedPort: Int = -1 // -1: All Groups, 0..3: specific group
    @State private var selectedNavSection: NavSection = .overview
    
    enum NavSection: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case lighting = "Lighting"
        case cooling = "Cooling"
        case settings = "Settings"
        
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .overview: return "gauge.medium"
            case .lighting: return "sparkles"
            case .cooling: return "fanblades"
            case .settings: return "slider.horizontal.2.square"
            }
        }
    }
    
    public init(deviceManager: DeviceManager, controller: BaseDeviceController) {
        self.deviceManager = deviceManager
        self.controller = controller
    }
    
    public var body: some View {
        NavigationSplitView {
            // SIDEBAR: Clean, top-level sections separated by subtle dividers
            List(selection: $selectedNavSection) {
                sidebarRow(section: .overview)
                
                Section {
                    if controller.capabilities.contains(.lightingControl) {
                        sidebarRow(section: .lighting)
                    }
                    if controller.capabilities.contains(.coolingControl) {
                        sidebarRow(section: .cooling)
                    }
                }
                
                Section {
                    sidebarRow(section: .settings)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            VStack(spacing: 0) {
                if let issue = controller.connectionIssue {
                    Label(issue, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.orange.opacity(0.25))
                }
                detailContentView
            }
                .navigationTitle(selectedNavSection.rawValue)
                .background(Color(nsColor: .windowBackgroundColor))
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        // Identity, not name: two identical hubs share a name and must stay selectable.
                        Picker("", selection: Binding(
                            get: { deviceManager.selectedController.map { ObjectIdentifier($0) } },
                            set: { id in
                                if let match = deviceManager.connectedControllers.first(where: { ObjectIdentifier($0) == id }) {
                                    deviceManager.selectedController = match
                                }
                            }
                        )) {
                            ForEach(Array(deviceManager.connectedControllers.enumerated()), id: \.offset) { index, dev in
                                Text(controllerTitle(dev, index: index)).tag(Optional(ObjectIdentifier(dev)))
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
        }
    }
    
    /// Device name, numbered when several connected controllers share it.
    private func controllerTitle(_ controller: BaseDeviceController, index: Int) -> String {
        let sameName = deviceManager.connectedControllers.filter { $0.deviceName == controller.deviceName }
        return sameName.count > 1 ? "\(controller.deviceName) #\(index + 1)" : controller.deviceName
    }
    
    @ViewBuilder
    private var detailContentView: some View {
        switch selectedNavSection {
        case .overview:
            OverviewView(controller: controller, selectedPort: $selectedPort)
        case .lighting:
            LightingControlView(controller: controller, selectedPort: $selectedPort)
        case .cooling:
            CoolingControlView(controller: controller, selectedPort: $selectedPort)
        case .settings:
            DeviceSettingsView(controller: controller)
        }
    }
    
    @ViewBuilder
    private func sidebarRow(section: NavSection) -> some View {
        Label(section.rawValue, systemImage: section.icon)
            .tag(section)
    }
}
