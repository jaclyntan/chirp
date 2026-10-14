import AVFoundation
import Foundation

// Compile alongside Sources/Chirp/MeetingAudioWindowReader.swift. This
// measures file ingestion only, without speech models or the app's UI.
@main
struct MeetingAudioBenchmark {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 2 else {
            print("Usage: meeting-audio-benchmark create|array|stream <caf> [seconds]")
            exit(1)
        }
        let url = URL(fileURLWithPath: args[1])
        switch args[0] {
        case "create":
            let seconds = args.count > 2 ? Int(args[2]) ?? 3600 : 3600
            guard seconds > 0 && seconds <= 86_400 else { exit(1) }
            let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
            buffer.frameLength = buffer.frameCapacity
            buffer.floatChannelData![0].initialize(repeating: 0.25, count: 16000)
            for _ in 0..<seconds { try file.write(from: buffer) }
            print("Created \(seconds) seconds of synthetic mono Float32 audio")

        case "array":
            // The previous production ingestion algorithm.
            let file = try AVAudioFile(forReading: url)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384)!
            var samples: [Float] = []
            samples.reserveCapacity(Int(file.length))
            while file.framePosition < file.length {
                try file.read(into: buffer, frameCount: buffer.frameCapacity)
                guard buffer.frameLength > 0, let data = buffer.floatChannelData else { exit(1) }
                samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
            }
            print("Array: \(samples.count) frames, checksum \(samples.reduce(0.0) { $0 + Double($1) })")

        case "stream":
            // The actual reader used by the app, not a benchmark substitute.
            let reader = try MeetingAudioWindowReader(url: url)
            var frames = 0
            var sum = 0.0
            while let count = try reader.withNextWindow({ samples, _ in
                sum += samples.reduce(0.0) { $0 + Double($1) }
                return samples.count
            }) { frames += count }
            print("Stream: \(frames) frames, checksum \(sum)")

        default:
            exit(1)
        }
    }
}
