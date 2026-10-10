import SwiftUI

public struct ContentView: View {
    @ObservedObject private var deviceManager = DeviceManager.shared
    
    public init() {}
    
    public var body: some View {
        Group {
            if let controller = deviceManager.selectedController {
                MainDashboardView(
                    deviceManager: deviceManager,
                    controller: controller
                )
            } else {
                noDeviceView
            }
        }
        .frame(minWidth: 880, minHeight: 640)
        .onAppear {
            deviceManager.start()
        }
    }
    
    private var noDeviceView: some View {
        VStack(spacing: 14) {
            Image(systemName: "cable.connector.slash")
                .font(.system(size: 54))
                .foregroundColor(.secondary)
            Text("No Lian Li Controllers Detected")
                .font(.title2)
                .fontWeight(.bold)
            if let problem = deviceManager.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            } else {
                Text("Ensure the controller's USB cable is connected.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Button {
                deviceManager.scanDevices()
            } label: {
                Label("Scan USB Devices", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
