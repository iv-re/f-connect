import SwiftUI

public struct UniFanGraphicView: View {
    let mode: FanLightingMode
    let color: Color
    let rpm: Int
    let isSelected: Bool
    let isARGBSync: Bool
    
    @State private var rotationAngle: Double = 0.0
    
    public init(
        mode: FanLightingMode = .rainbow,
        color: Color = .cyan,
        rpm: Int = 0,
        isSelected: Bool = false,
        isARGBSync: Bool = false
    ) {
        self.mode = mode
        self.color = color
        self.rpm = rpm
        self.isSelected = isSelected
        self.isARGBSync = isARGBSync
    }
    
    public var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            
            // Three layers. Only the blades move; the housing and the hub never change while spinning, so each layer is
            // rendered once into a texture (drawingGroup) and rotation is just a transform of that texture. Without this,
            // every gradient and shadow of every fan was recomputed on each animation frame.
            ZStack {
                housing(size: size)
                    .drawingGroup()
                
                blades(size: size)
                    .drawingGroup()
                    .rotationEffect(.degrees(rotationAngle))
                
                hub(size: size)
                    .drawingGroup()
            }
            .frame(width: size, height: size)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
            .shadow(color: isSelected ? Color.accentColor.opacity(0.3) : Color.clear, radius: 4)
        }
        .aspectRatio(1.0, contentMode: .fit)
        .onAppear {
            startSlowRotation()
        }
        .onChange(of: rpm) { _ in
            startSlowRotation()
        }
    }
    
    /// Square casing, the two light diffusers and the dark impeller well.
    private func housing(size: CGFloat) -> some View {
        ZStack {
            // Square Fan Casing (120mm / 140mm computer fan form factor)
            RoundedRectangle(cornerRadius: size * 0.12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(nsColor: .controlBackgroundColor), Color(nsColor: .windowBackgroundColor)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.12, style: .continuous)
                        .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: isSelected ? 2 : 1)
                )
            
            // Top & Bottom ARGB Light Diffusers (Uni Fan SL V2 signature light channels)
            VStack {
                lightingBar
                    .frame(height: max(3, size * 0.055))
                Spacer()
                lightingBar
                    .frame(height: max(3, size * 0.055))
            }
            .padding(.horizontal, size * 0.14)
            .padding(.vertical, size * 0.06)
            
            // Circular Impeller Well (round cut-out for 120mm blades)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.black.opacity(0.85), Color.black.opacity(0.95)],
                        center: .center,
                        startRadius: 0,
                        endRadius: size * 0.42
                    )
                )
                .overlay(Circle().stroke(Color.white.opacity(0.08), lineWidth: 1))
                .padding(size * 0.09)
        }
        .frame(width: size, height: size)
    }
    
    /// 7 aerodynamic curved blades; the only part that rotates.
    private func blades(size: CGFloat) -> some View {
        ZStack {
            ForEach(0..<7) { i in
                BladeShape()
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.22), Color.white.opacity(0.06)],
                            startPoint: .center,
                            endPoint: .trailing
                        )
                    )
                    .rotationEffect(.degrees(Double(i) * (360.0 / 7.0)))
            }
        }
        .padding(size * 0.12)
        .frame(width: size, height: size)
    }
    
    /// Center Infinity Hub (SL V2 mirror center)
    private func hub(size: CGFloat) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [Color.white.opacity(0.35), Color.black.opacity(0.85)],
                    center: .center,
                    startRadius: 0,
                    endRadius: size * 0.16
                )
            )
            .frame(width: size * 0.32, height: size * 0.32)
            .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 1))
            .frame(width: size, height: size)
    }
    
    private func startSlowRotation() {
        guard rpm > 0 else {
            withAnimation(.easeOut(duration: 0.8)) {
                rotationAngle = 0
            }
            return
        }
        guard rotationAngle == 0 else { return }
        withAnimation(.linear(duration: 4.0).repeatForever(autoreverses: false)) {
            rotationAngle = 360
        }
    }
    
    @ViewBuilder
    private var lightingBar: some View {
        if isARGBSync {
            LinearGradient(
                colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple],
                startPoint: .leading,
                endPoint: .trailing
            )
            .clipShape(Capsule())
            .shadow(color: .purple.opacity(0.6), radius: 4)
        } else {
            switch mode {
        case .rainbow, .colorCycle:
            LinearGradient(
                colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple],
                startPoint: .leading,
                endPoint: .trailing
            )
            .clipShape(Capsule())
            .shadow(color: .cyan.opacity(0.6), radius: 3)
        case .staticColor:
            color
                .clipShape(Capsule())
                .shadow(color: color.opacity(0.6), radius: 3)
        case .breathing:
            color.opacity(0.85)
                .clipShape(Capsule())
                .shadow(color: color.opacity(0.5), radius: 4)
        default:
            LinearGradient(
                colors: [color.opacity(0.2), color, color.opacity(0.2)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .clipShape(Capsule())
            .shadow(color: color.opacity(0.5), radius: 3)
            }
        }
    }
}

private struct BladeShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: center)
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.midY - rect.height * 0.2),
            control: CGPoint(x: rect.midX + rect.width * 0.25, y: rect.midY - rect.height * 0.35)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}
