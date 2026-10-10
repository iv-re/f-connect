import SwiftUI
import ServiceManagement

public struct DeviceSettingsView: View {
    @ObservedObject var controller: BaseDeviceController
    @State private var loginItemStatus: SMAppService.Status = SMAppService.mainApp.status
    @State private var loginItemError: String?
    @State private var diagnosticsCopied = false
    
    public init(controller: BaseDeviceController) {
        self.controller = controller
    }
    
    /// "Registered" includes the case where macOS still waits for the user to approve it in System Settings.
    private var launchAtLogin: Bool {
        loginItemStatus == .enabled || loginItemStatus == .requiresApproval
    }
    
    public var body: some View {
        Form {
            Section("Hardware Information") {
                HStack {
                    Text("Controller Type").foregroundColor(.secondary)
                    Spacer()
                    Text(controller.deviceType.rawValue).font(.subheadline)
                }
                HStack {
                    Text("Firmware Version").foregroundColor(.secondary)
                    Spacer()
                    Text(controller.firmwareVersion).font(.subheadline.monospaced())
                }
                HStack {
                    Text("Status").foregroundColor(.secondary)
                    Spacer()
                    if let issue = controller.connectionIssue {
                        Label(issue, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundColor(.orange)
                            .multilineTextAlignment(.trailing)
                    } else {
                        Text("Connected").font(.subheadline)
                    }
                }
                HStack {
                    Text("Protocol").foregroundColor(.secondary)
                    Spacer()
                    Text("ENE USB HID (Report 0xE0)").font(.subheadline.monospaced())
                }
            }
            
            Section("Application") {
                Toggle("Start at Login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { updateLaunchAtLogin($0) }
                ))
                .toggleStyle(.switch)
                
                if loginItemStatus == .requiresApproval {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("macOS needs your approval: allow F-Connect under General > Login Items.")
                            .font(.callout)
                            .foregroundColor(.secondary)
                        Button("Open Login Items Settings") {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                        .controlSize(.small)
                    }
                }
                if let error = loginItemError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundColor(.orange)
                }
            }
            
            Section("Diagnostics") {
                HStack {
                    Button("Copy Diagnostics") { copyDiagnostics() }
                    if diagnosticsCopied {
                        Label("Copied", systemImage: "checkmark")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                Text("Copies device, firmware and sensor information plus the recent events. It contains no personal data. Paste it into a bug report.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            loginItemStatus = SMAppService.mainApp.status
        }
    }
    
    private func copyDiagnostics() {
        let text = DiagnosticsCollector.collect().render()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        diagnosticsCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { diagnosticsCopied = false }
    }
    
    private func updateLaunchAtLogin(_ enable: Bool) {
        loginItemError = nil
        do {
            if enable {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Typically: the app is not in /Applications, or is not signed. Say so instead of silently flipping the switch back.
            loginItemError = "Could not change the login item: \(error.localizedDescription)"
        }
        loginItemStatus = SMAppService.mainApp.status
    }
}
