import SwiftUI
import AppKit

/// LLM 结果显示视图：展示 C 键（Assist）的答案，支持选择/复制，点击外部或按钮关闭。
struct ResultOverlayView: View {
    let answer: String
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundColor(.accentColor)
                Text("Assistant")
                    .font(.headline)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            // 答案文本，可选中复制
            ScrollView {
                Text(answer)
                    .font(.body)
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)

            HStack {
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(answer, forType: .string)
                }
                .buttonStyle(.bordered)
                Button("Close") { onClose() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 460, height: 320)
    }
}
