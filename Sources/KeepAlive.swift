import AVFoundation
import UIKit

/// iOS 后台保活。
///
/// 问题：iOS 锁屏/切后台后会挂起 App，监听 socket 还在但进程不响应，
/// 对端连接全部超时（实测：ping 通、TCP 超时）。
///
/// 做法：声明的 `UIBackgroundModes = audio` + 循环播放一段 2 秒静音 WAV。
/// 只要音频会话处于活跃状态，系统就不会挂起进程，HTTP 服务得以持续响应。
/// 这是越狱侧载场景下代价最小的方案（App Store 会拒，但我们不走商店）。
final class KeepAlive {
    static let shared = KeepAlive()
    private var player: AVAudioPlayer?
    private var session: AVAudioSession?

    func start() {
        let s = AVAudioSession.sharedInstance()
        session = s
        do {
            try s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try s.setActive(true)
        } catch {
            NSLog("lanxfer audio session: \(error)")
        }

        guard let url = silentWav() else {
            NSLog("lanxfer: silence.wav 生成失败")
            return
        }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.numberOfLoops = -1     // 无限循环
            p.volume = 0             // 完全静音
            p.prepareToPlay()
            p.play()
            player = p
            NSLog("lanxfer keepalive audio started")
        } catch {
            NSLog("lanxfer player: \(error)")
        }

        // 来电/其他音频打断后重新激活
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main) { [weak self] _ in
            try? self?.session?.setActive(true)
            self?.player?.play()
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main) { [weak self] _ in
            try? self?.session?.setActive(true)
            self?.player?.play()
        }
    }

    /// 生成 2 秒 8kHz 单声道 16bit 的静音 WAV
    private func silentWav() -> URL? {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lanxfer-silence.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }

        let sampleRate: UInt32 = 8000
        let seconds: UInt32 = 2
        let channels: UInt16 = 1
        let bits: UInt16 = 16
        let bytesPerFrame = UInt32(channels) * UInt32(bits / 8)
        let dataSize = sampleRate * seconds * bytesPerFrame
        let byteRate = sampleRate * bytesPerFrame

        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }

        d.append(contentsOf: Array("RIFF".utf8))
        u32(36 + dataSize)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        u32(16); u16(1); u16(channels); u32(sampleRate); u32(byteRate)
        u16(UInt16(bytesPerFrame)); u16(bits)
        d.append(contentsOf: Array("data".utf8))
        u32(dataSize)
        d.append(Data(count: Int(dataSize)))

        do { try d.write(to: url); return url } catch { return nil }
    }
}
