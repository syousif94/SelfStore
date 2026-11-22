import SwiftUI

/// A spinning ring around a stop button, shown in place of Build while a build runs (like the App Store's download ring).
struct BuildingRing: View {
    var size: CGFloat = 30
    var showsStop = true
    @State private var spinning = false

    var body: some View {
        ZStack {
            Circle().stroke(Color.accentColor.opacity(0.18), lineWidth: size > 20 ? 2.5 : 2)
            Circle()
                .trim(from: 0, to: 0.28)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: size > 20 ? 2.5 : 2, lineCap: .round))
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
            if showsStop {
                RoundedRectangle(cornerRadius: 2).fill(Color.accentColor).frame(width: size * 0.3, height: size * 0.3)
            }
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .onAppear { spinning = true }
    }
}
