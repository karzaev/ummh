// Bounded producer/consumer capture queue adapted from VoiceInk CoreAudioRecorder.
// GPL-3.0; see NOTICE.md for the source revision.
import AVFoundation
import AudioToolbox
import Foundation
import Synchronization

final class CaptureBuffer: @unchecked Sendable {
    private let slots: [AVAudioPCMBuffer]
    private let converter: AVAudioConverter
    private let output: AVAudioPCMBuffer
    private let writeIndex = Atomic<UInt64>(0)
    private let readIndex = Atomic<UInt64>(0)
    private let failed = Atomic<Bool>(false)
    private let queue = DispatchQueue(label: "xyz.karzaev.ummh.capture", qos: .userInitiated)
    private let signal: DispatchSourceUserDataAdd
    private let lock = NSLock()
    private var samples: [Float] = []
    private var power: Float = 0

    init(format: AVAudioFormat, capacity: AVAudioFrameCount) throws {
        guard format.sampleRate > 0, format.channelCount > 0, capacity > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target),
              let output = AVAudioPCMBuffer(pcmFormat: target,
                  frameCapacity: AVAudioFrameCount(ceil(Double(capacity) * 16_000 / format.sampleRate)) + 64) else {
            throw CaptureError.unavailable
        }
        let slots = (0..<96).compactMap { _ in AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) }
        guard slots.count == 96 else { throw CaptureError.unavailable }
        self.slots = slots
        converter.downmix = true
        self.converter = converter
        self.output = output
        signal = DispatchSource.makeUserDataAddSource(queue: queue)
        signal.setEventHandler { [weak self] in self?.drain() }
        signal.activate()
    }

    deinit { signal.cancel() }

    var hasFailure: Bool { failed.load(ordering: .acquiring) }
    var level: Float { lock.withLock { power } }
    func snapshot() -> [Float] { lock.withLock { samples } }

    // Called by the single AUHAL producer. All audio storage is preallocated.
    func receive(frames: UInt32, render: (UnsafeMutablePointer<AudioBufferList>) -> OSStatus) -> OSStatus {
        let write = writeIndex.load(ordering: .relaxed)
        let read = readIndex.load(ordering: .acquiring)
        guard write - read < UInt64(slots.count), frames <= slots[0].frameCapacity else {
            failed.store(true, ordering: .releasing)
            return noErr
        }
        let slot = slots[Int(write % UInt64(slots.count))]
        slot.frameLength = frames
        let status = render(slot.mutableAudioBufferList)
        guard status == noErr else {
            failed.store(true, ordering: .releasing)
            return status
        }
        writeIndex.store(write + 1, ordering: .releasing)
        signal.add(data: 1)
        return noErr
    }

    // AUHAL must be stopped and its callbacks drained before this is called.
    func finish() -> [Float] {
        queue.sync {
            drain()
            var error: NSError?
            var status: AVAudioConverterOutputStatus
            repeat {
                status = converter.convert(to: output, error: &error) { _, state in
                    state.pointee = .endOfStream
                    return nil
                }
                collect(status: status, error: error)
            } while status == .haveData && output.frameLength > 0
        }
        return snapshot()
    }

    private func drain() {
        var read = readIndex.load(ordering: .relaxed)
        while read < writeIndex.load(ordering: .acquiring) {
            let slot = slots[Int(read % UInt64(slots.count))]
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true
                state.pointee = .haveData
                return slot
            }
            collect(status: status, error: error)
            read += 1
            readIndex.store(read, ordering: .releasing)
        }
    }

    private func collect(status: AVAudioConverterOutputStatus, error: NSError?) {
        guard status != .error, error == nil, let channel = output.floatChannelData?[0] else {
            failed.store(true, ordering: .releasing)
            return
        }
        let pcm = UnsafeBufferPointer(start: channel, count: Int(output.frameLength))
        let rms = pcm.isEmpty ? 0 : sqrt(pcm.reduce(Float(0)) { $0 + $1 * $1 } / Float(pcm.count))
        lock.withLock {
            samples.append(contentsOf: pcm)
            power = min(1, rms * 5)
        }
    }
}
