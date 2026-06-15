import SwiftUI

/// 录音浮层内容：脉动 mic 图标 + 文字 + 实时电平条。
struct RecordingOverlayView: View {
    @EnvironmentObject private var pipeline: Pipeline
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
                    .scaleEffect(pulse ? 1.25 : 1.0)
                    .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)

                Text("Recording…")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)

                Spacer()

                Text("Press shortcut to stop")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
            }

            // 实时电平条
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.2))
                    Capsule()
                        .fill(Color.white)
                        .frame(width: geo.size.width * CGFloat(min(1, max(0.03, pipeline.inputLevel))))
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(width: 340)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.78))
        )
        .onAppear { pulse = true }
    }
}
