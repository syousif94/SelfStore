import SwiftUI

/// A spinning ring around a stop button, shown in place of Build while a build runs (like the App Store's download ring).
/// Driven by a TimelineView so it keeps spinning in List rows, after navigation and when rows are recycled,
/// where an onAppear-started repeatForever animation can silently stop.
struct BuildingRing: View {
    var size: CGFloat = 30
    var showsStop = true

    var body: some View {
        let width: CGFloat = size > 20 ? 2.5 : 2
        ZStack {
            Circle().stroke(Color.accentColor.opacity(0.18), lineWidth: width)
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: width, lineCap: .round))
                    .rotationEffect(.degrees(t.truncatingRemainder(dividingBy: 0.9) / 0.9 * 360))
            }
            if showsStop {
                RoundedRectangle(cornerRadius: 2).fill(Color.accentColor).frame(width: size * 0.3, height: size * 0.3)
            }
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
    }
}
