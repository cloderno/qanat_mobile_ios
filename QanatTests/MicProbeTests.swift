import XCTest
@testable import Qanat

final class MicProbeTests: XCTestCase {
    private func int32(_ data: Data, _ offset: Int) -> Int { Int(data.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian) }
    private func int16(_ data: Data, _ offset: Int) -> Int { Int(data.subdata(in: offset..<offset + 2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian) }
    private func ascii(_ data: Data, _ offset: Int) -> String { String(decoding: data.subdata(in: offset..<offset + 4), as: UTF8.self) }

    func testWavHeaderDescribes16kHzMonoS16le() {
        let header = wavHeader(dataBytes: 32_000, sampleRate: 16_000, channels: 1, bitsPerSample: 16)
        XCTAssertEqual(header.count, wavHeaderSize)
        XCTAssertEqual(ascii(header, 0), "RIFF")
        XCTAssertEqual(int32(header, 4), 36 + 32_000)
        XCTAssertEqual(ascii(header, 8), "WAVE")
        XCTAssertEqual(ascii(header, 12), "fmt ")
        XCTAssertEqual(int32(header, 16), 16)
        XCTAssertEqual(int16(header, 20), 1)
        XCTAssertEqual(int16(header, 22), 1)
        XCTAssertEqual(int32(header, 24), 16_000)
        XCTAssertEqual(int32(header, 28), 32_000)
        XCTAssertEqual(int16(header, 32), 2)
        XCTAssertEqual(int16(header, 34), 16)
        XCTAssertEqual(ascii(header, 36), "data")
        XCTAssertEqual(int32(header, 40), 32_000)
    }

    func testWavFileHasHeaderAndPcmInOrder() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("nested/probe.wav")
        try writeWav(url, chunks: [Data([1, 2, 3, 4]), Data([5, 6])], sampleRate: 16_000, channels: 1)
        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(bytes.count, wavHeaderSize + 6)
        XCTAssertEqual(bytes.prefix(wavHeaderSize), wavHeader(dataBytes: 6, sampleRate: 16_000, channels: 1, bitsPerSample: 16))
        XCTAssertEqual(Data(bytes.suffix(6)), Data([1, 2, 3, 4, 5, 6]))
    }

    func testBackToBackFramesHaveNoGaps() {
        // 320 сэмплов при 16 кГц — 20 мс.
        let frames = (0..<5).map { AudioFrameTiming(presentationTimeUs: Int64($0) * 20_000, samples: 320) }
        XCTAssertEqual(findAudioGaps(frames, sampleRate: 16_000), .none)
    }

    func testSmallJitterIsNotAGap() {
        let frames = [0, 25_000, 45_000].map { AudioFrameTiming(presentationTimeUs: Int64($0), samples: 320) }
        XCTAssertEqual(findAudioGaps(frames, sampleRate: 16_000), .none)
    }

    func testLateFramesAreCountedWithLongestGap() {
        let frames = [0, 20_000, 100_000, 120_000, 175_000].map { AudioFrameTiming(presentationTimeUs: Int64($0), samples: 320) }
        XCTAssertEqual(findAudioGaps(frames, sampleRate: 16_000), AudioGaps(count: 2, maxGapMs: 60))
    }

    func testOutOfOrderFramesAreCountedAndDoNotHideGaps() {
        let frames = [0, 40_000, 20_000, 60_000].map { AudioFrameTiming(presentationTimeUs: Int64($0), samples: 320) }
        XCTAssertEqual(findAudioGaps(frames, sampleRate: 16_000), AudioGaps(count: 0, maxGapMs: 0, outOfOrder: 1, overlaps: 0))
    }
}
