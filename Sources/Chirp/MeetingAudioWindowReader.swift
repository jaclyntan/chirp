import AVFoundation

/// Matches FluidAudio's ten-second, non-overlapping diarization windows.
/// The borrowed samples are valid only during the synchronous callback;
/// the next disk read reuses the same storage, including for the short tail.
final class MeetingAudioWindowReader {
    static let sampleRate = 16_000
    static let windowSeconds = 10
    static let windowFrames = sampleRate * windowSeconds

    enum ReadError: Error {
        case unsupportedFormat
        case incompleteRead(expected: AVAudioFrameCount, actual: AVAudioFrameCount)
    }

    private let file: AVAudioFile
    private let readBuffer: AVAudioPCMBuffer
    private var window = [Float](repeating: 0, count: windowFrames)
    var isEmpty: Bool { file.length == 0 }
    var hasMore: Bool { file.framePosition < file.length }

    init(url: URL) throws {
        file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.processingFormat.sampleRate == Double(Self.sampleRate),
              file.processingFormat.channelCount == 1,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: 16_384)
        else { throw ReadError.unsupportedFormat }
        self.readBuffer = buffer
    }

    func withNextWindow<Result>(
        _ process: (UnsafeBufferPointer<Float>, TimeInterval) throws -> Result
    ) throws -> Result? {
        guard hasMore else { return nil }
        let first = file.framePosition
        let count = AVAudioFrameCount(min(Int64(Self.windowFrames), file.length - first))
        var filled: AVAudioFrameCount = 0
        while filled < count {
            // AVAudioFile can return a short read before EOF (including
            // Float32 CAF files). Fill the exact engine window across reads
            // so a packet boundary never moves a speaker's timestamp.
            let requested = min(readBuffer.frameCapacity, count - filled)
            try file.read(into: readBuffer, frameCount: requested)
            guard readBuffer.frameLength > 0, readBuffer.frameLength <= requested,
                  let data = readBuffer.floatChannelData else {
                throw ReadError.incompleteRead(expected: count, actual: filled)
            }
            window.withUnsafeMutableBufferPointer {
                $0.baseAddress!.advanced(by: Int(filled))
                    .update(from: data[0], count: Int(readBuffer.frameLength))
            }
            filled += readBuffer.frameLength
        }
        return try window.withUnsafeBufferPointer {
            try process(
                UnsafeBufferPointer(start: $0.baseAddress, count: Int(count)),
                Double(first) / Double(Self.sampleRate))
        }
    }
}
