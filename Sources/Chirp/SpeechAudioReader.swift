import AVFoundation
import FluidAudio

/// Incremental conversion for the speech-presence check. A single converter
/// preserves resampling history across reads; no recording-sized allocation.
final class SpeechAudioReader {
    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let input: AVAudioPCMBuffer
    private let output: AVAudioPCMBuffer
    private var finished = false

    enum ReadError: Error { case unsupportedFormat, stalledConversion }

    init(url: URL) throws {
        file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let source = file.processingFormat
        guard source.sampleRate > 0, (1...2).contains(source.channelCount),
              let target = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1),
              let converter = AVAudioConverter(from: source, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 16_384),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096)
        else { throw ReadError.unsupportedFormat }
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        self.converter = converter
        self.input = input
        self.output = output
    }

    func nextChunk() throws -> [Float]? {
        guard !finished else { return nil }
        var readError: Error?
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { [self] requested, status in
            guard file.framePosition < file.length else {
                status.pointee = .endOfStream
                return nil
            }
            do {
                let count = min(input.frameCapacity, requested,
                                AVAudioFrameCount(min(Int64(input.frameCapacity), file.length - file.framePosition)))
                guard count > 0 else { throw ReadError.stalledConversion }
                try file.read(into: input, frameCount: count)
                guard input.frameLength > 0 else { throw ReadError.stalledConversion }
                status.pointee = .haveData
                return input
            } catch {
                readError = error
                status.pointee = .noDataNow
                return nil
            }
        }
        if let readError { throw readError }
        if let conversionError { throw conversionError }
        guard status != .error else { throw ReadError.stalledConversion }
        finished = status == .endOfStream
        guard output.frameLength > 0, let data = output.floatChannelData else {
            if finished { return nil }
            throw ReadError.stalledConversion
        }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }

    static func runSelfTest() throws -> Bool {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-resampling-test-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        for (rate, channels) in [(16000.0, AVAudioChannelCount(1)), (48000.0, 1), (44100.0, 2)] {
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
            let frames = AVAudioFrameCount(rate * 2) + 123
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            for channel in 0..<Int(channels) {
                for index in 0..<Int(frames) {
                    buffer.floatChannelData![channel][index] = Float(sin(Double(index) * 0.07)) * 0.2
                        + Float(channel) * 0.03
                }
            }
            do {
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                try file.write(from: buffer)
            }
            let reference = try AudioConverter().resampleAudioFile(url)
            let reader = try SpeechAudioReader(url: url)
            var streamed: [Float] = []
            var sizes: [Int] = []
            while let chunk = try reader.nextChunk() {
                streamed.append(contentsOf: chunk)
                sizes.append(chunk.count)
            }
            let afterEOF = try reader.nextChunk()
            let same = reference.count == streamed.count
                && zip(reference, streamed).allSatisfy { abs($0 - $1) < 0.00001 }
                && sizes.dropLast().allSatisfy { $0 == 4096 }
                && afterEOF == nil
            if !same {
                print("FAIL: speech resampling at \(Int(rate)) Hz / \(channels) channels: reference \(reference.count), streamed \(streamed.count)")
                return false
            }
        }
        return true
    }
}
