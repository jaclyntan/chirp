import AVFAudio
import Foundation

/// A bounded FIFO for optional live inference. Recordings still go straight
/// to disk; a slow caption/turn model must never retain an entire meeting.
struct AudioBufferQueue {
    private var storage: [AVAudioPCMBuffer?] = []
    private var head = 0
    private(set) var duration: TimeInterval = 0
    private let maximumDuration: TimeInterval
    private let maximumCount: Int

    init(maximumDuration: TimeInterval = 3, maximumCount: Int = 64) {
        self.maximumDuration = maximumDuration
        self.maximumCount = maximumCount
    }

    var count: Int { storage.count - head }
    var isEmpty: Bool { count == 0 }

    /// Refuse excess audio instead of silently skipping/reordering speech.
    /// The caller suspends its optional inference for this session.
    mutating func append(_ buffer: AVAudioPCMBuffer) -> Bool {
        let seconds = Self.duration(of: buffer)
        guard seconds > 0, count < maximumCount,
              duration + seconds <= maximumDuration else { return false }
        storage.append(buffer)
        duration += seconds
        return true
    }

    mutating func popFirst() -> AVAudioPCMBuffer? {
        guard head < storage.count, let buffer = storage[head] else { return nil }
        storage[head] = nil // release consumed audio immediately
        head += 1
        duration = max(0, duration - Self.duration(of: buffer))
        if head == storage.count {
            removeAll()
        } else if head >= maximumCount {
            storage.removeFirst(head) // amortized, never per audio buffer
            head = 0
        }
        return buffer
    }

    mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
        duration = 0
    }

    private static func duration(of buffer: AVAudioPCMBuffer) -> TimeInterval {
        guard buffer.format.sampleRate > 0 else { return 0 }
        return Double(buffer.frameLength) / buffer.format.sampleRate
    }

    /// Audio-engine taps may reuse their storage after the callback. Own
    /// just the captured frames before sending them to asynchronous work.
    static func ownedCopy(of source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard source.frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength)
        else { return nil }
        copy.frameLength = source.frameLength
        let input = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let output = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard input.count == output.count else { return nil }
        for index in input.indices {
            guard let from = input[index].mData, let to = output[index].mData else { return nil }
            memcpy(to, from, Int(min(input[index].mDataByteSize, output[index].mDataByteSize)))
        }
        return copy
    }

    static func runSelfTest() -> Bool {
        var passed = true
        func check(_ value: Bool, _ label: String) {
            if !value { passed = false }
            print("\(value ? "PASS" : "FAIL"): \(label)")
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        func buffer() -> AVAudioPCMBuffer {
            let value = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
            value.frameLength = 1600
            return value
        }
        let original = buffer()
        original.floatChannelData![0][0] = 0.5
        let owned = ownedCopy(of: original)
        original.floatChannelData![0][0] = 0
        check(owned?.floatChannelData?[0][0] == 0.5 && owned?.frameCapacity == original.frameLength,
              "async audio owns its samples without retaining unused tap capacity")
        var queue = AudioBufferQueue(maximumDuration: 0.25, maximumCount: 3)
        var first: AVAudioPCMBuffer? = buffer()
        weak var retained = first
        let second = buffer()
        check(queue.append(first!) && queue.append(second), "live audio accepts buffers within its budget")
        check(!queue.append(buffer()) && queue.count == 2, "slow inference cannot grow the audio queue past its duration budget")
        check(queue.popFirst() === first, "live audio preserves arrival order")
        first = nil
        check(retained == nil, "consumed audio is released before the rest of the queue drains")
        check(queue.popFirst() === second && queue.isEmpty && queue.duration == 0, "draining resets the audio budget")
        var tiny = AudioBufferQueue(maximumDuration: 100, maximumCount: 2)
        check(tiny.append(buffer()) && tiny.append(buffer()) && !tiny.append(buffer()), "tiny audio buffers are also bounded by count")
        tiny.removeAll()
        check(tiny.isEmpty && tiny.append(buffer()), "stopping frees queued audio and allows a fresh session")
        for _ in 0..<1000 {
            _ = tiny.append(buffer())
            _ = tiny.popFirst()
        }
        check(tiny.count == 1, "FIFO compaction survives a long streaming session")
        return passed
    }
}
