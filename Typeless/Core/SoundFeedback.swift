import Foundation
import AppKit

/// 交互声音反馈：录音开始/停止时各播一声。
final class SoundFeedback {
    /// 录音开始时（上扬音）。
    func playStart() {
        // "Tink" 是系统自带的短促高音
        NSSound(named: "Tink")?.play()
    }

    /// 录音/处理结束时（柔和音）。
    func playEnd() {
        NSSound(named: "Glass")?.play()
    }
}
