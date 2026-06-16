import XCTest
import AVFAudio
@testable import OpenTypeless

final class AudioProcessingTests: XCTestCase {

    // MARK: - AudioMeterCalculator.audioLevel

    func testAudioLevel_Silence() {
        let buffer = makeBuffer(samples: Array(repeating: 0.0, count: 1024))
        // normalizedMeterLevel clamps minimum to 0.03
        XCTAssertEqual(AudioMeterCalculator.audioLevel(from: buffer), 0.03, accuracy: 0.001)
    }

    func testAudioLevel_FullScale() {
        let buffer = makeBuffer(samples: Array(repeating: 1.0, count: 1024))
        let level = AudioMeterCalculator.audioLevel(from: buffer)
        XCTAssertEqual(level, 1.0, accuracy: 0.01)
    }

    func testAudioLevel_Positive() {
        // Use a small signal that doesn't saturate the meter (rms * 12 < 1 → rms < 0.083)
        let buffer = makeBuffer(samples: Array(repeating: 0.05, count: 1024))
        let level = AudioMeterCalculator.audioLevel(from: buffer)
        XCTAssertGreaterThan(level, 0.03)
        XCTAssertLessThan(level, 1.0)
    }

    func testAudioLevel_ZeroFrameLength() {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 0) else {
            XCTFail("Could not create buffer")
            return
        }
        buffer.frameLength = 0
        XCTAssertEqual(AudioMeterCalculator.audioLevel(from: buffer), 0)
    }

    func testAudioLevel_SmallSignal() {
        let buffer = makeBuffer(samples: Array(repeating: 0.001, count: 1024))
        let level = AudioMeterCalculator.audioLevel(from: buffer)
        XCTAssertGreaterThan(level, 0)
        XCTAssertLessThan(level, 0.1)
    }

    func testAudioLevel_NegativeSamples() {
        let buffer = makeBuffer(samples: Array(repeating: -0.5, count: 1024))
        let level = AudioMeterCalculator.audioLevel(from: buffer)
        XCTAssertGreaterThan(level, 0)
    }

    func testAudioLevel_MixedPositiveNegative() {
        var samples = [Float](repeating: 0, count: 1024)
        for i in 0..<1024 {
            samples[i] = i % 2 == 0 ? 0.3 : -0.3
        }
        let buffer = makeBuffer(samples: samples)
        let level = AudioMeterCalculator.audioLevel(from: buffer)
        XCTAssertGreaterThan(level, 0)
    }

    // MARK: - AudioMeterCalculator.normalizedMeterLevel

    func testNormalizedMeterLevel_Zero() {
        let level = AudioMeterCalculator.normalizedMeterLevel(rms: 0)
        XCTAssertEqual(level, 0.03, accuracy: 0.001)
    }

    func testNormalizedMeterLevel_One() {
        let level = AudioMeterCalculator.normalizedMeterLevel(rms: 1.0)
        XCTAssertEqual(level, 1.0, accuracy: 0.01)
    }

    func testNormalizedMeterLevel_Infinity() {
        XCTAssertEqual(AudioMeterCalculator.normalizedMeterLevel(rms: .infinity), 0)
    }

    func testNormalizedMeterLevel_NaN() {
        XCTAssertEqual(AudioMeterCalculator.normalizedMeterLevel(rms: .nan), 0)
    }

    func testNormalizedMeterLevel_Monotonic() {
        // Use rms values in the non-saturating range (< ~0.083)
        let low = AudioMeterCalculator.normalizedMeterLevel(rms: 0.005)
        let mid = AudioMeterCalculator.normalizedMeterLevel(rms: 0.02)
        let high = AudioMeterCalculator.normalizedMeterLevel(rms: 0.05)
        XCTAssertLessThan(low, mid)
        XCTAssertLessThan(mid, high)
    }

    // MARK: - Helpers

    private func makeBuffer(samples: [Float], sampleRate: Double = 48000) -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(samples.count)) else {
            fatalError("Could not create audio buffer")
        }
        buffer.frameLength = UInt32(samples.count)
        let channelData = buffer.floatChannelData![0]
        for (i, sample) in samples.enumerated() {
            channelData[i] = sample
        }
        return buffer
    }
}
