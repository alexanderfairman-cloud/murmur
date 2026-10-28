import AVFoundation
import CoreMedia

/// Converts whatever the microphone or a file gives us into what the speech model wants:
/// 16,000 samples a second, one channel, numbers between -1 and 1.
final class Resampler {
    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    private let converter: AVAudioConverter
    private let ratio: Double

    init?(from format: AVAudioFormat) {
        guard format.sampleRate > 0, format.channelCount > 0,
              let converter = AVAudioConverter(from: format, to: Self.targetFormat)
        else { return nil }
        self.converter = converter
        ratio = Self.targetFormat.sampleRate / format.sampleRate
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else { return [] }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
    }

    /// Reads a whole audio file (wav, aiff, m4a, mp3...) into model-ready samples.
    static func samples(fromFile url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let resampler = Resampler(from: file.processingFormat) else {
            throw RecorderError.noInput
        }
        var all: [Float] = []
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384) else { break }
            try file.read(into: buffer)
            if buffer.frameLength == 0 { break }
            all.append(contentsOf: resampler.convert(buffer))
        }
        return all
    }
}

enum RecorderError: Error, LocalizedError {
    case noInput
    var errorDescription: String? { "No microphone is available." }
}

/// Listens to the microphone and keeps what it hears as model-ready samples.
///
/// A fresh capture session is made for every recording, so a changed microphone (AirPods, a cable) never leaves it stuck.
/// It uses Apple's capture API, which lets a specific microphone be chosen and copes when a microphone's format changes.
/// (The audio engine API was tried first. It can crash the app with an error Swift cannot catch if the microphone
/// changes at the wrong moment, and it fails when asked to switch microphones.)
final class AudioRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    /// Called with the loudness of each small slice, on the capture queue. Set before `start()`.
    var onLevel: ((Float) -> Void)?

    /// The microphone the current or last recording used, for messages and the log.
    private(set) var microphoneName = "the microphone"

    private var session: AVCaptureSession?
    private let queue = DispatchQueue(label: "com.jamesseriph.murmur.capture", qos: .userInteractive)
    private let lock = NSLock()
    private var samples: [Float] = []
    private var convertedFormat: AVAudioFormat?
    private var resampler: Resampler?

    /// Starts listening and returns the name of the microphone used. When the Mac's chosen microphone is a Bluetooth
    /// headset (AirPods) and `preferBuiltIn` is true, the built-in microphone is used instead: a Bluetooth microphone can
    /// deliver no sound at all (it did on this Mac), and using one switches the earbuds to a poor-quality mode while you dictate.
    @discardableResult
    func start(preferBuiltIn: Bool = true) throws -> String {
        guard let device = Self.chooseMicrophone(preferBuiltIn: preferBuiltIn) else { throw RecorderError.noInput }
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        guard session.canAddInput(input), session.canAddOutput(output) else { throw RecorderError.noInput }
        session.addInput(input)
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: queue)

        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
        convertedFormat = nil
        resampler = nil

        session.startRunning()
        guard session.isRunning else { throw RecorderError.noInput }
        self.session = session
        microphoneName = device.localizedName
        return microphoneName
    }

    /// Stops listening and hands back everything heard since `start()`.
    @discardableResult
    func stop() -> [Float] {
        session?.stopRunning()
        session = nil
        // Slices still in flight on the capture queue are finished before the samples are collected.
        queue.sync {}
        lock.lock()
        defer { lock.unlock() }
        let heard = samples
        samples = []
        return heard
    }

    // MARK: - Choosing the microphone

    private static let bluetooth: Set<Int32> = [
        Int32(bitPattern: 0x626C_7565), // 'blue', Bluetooth
        Int32(bitPattern: 0x626C_6561), // 'blea', Bluetooth Low Energy
    ]
    private static let builtIn = Int32(bitPattern: 0x626C_746E) // 'bltn'

    static func chooseMicrophone(preferBuiltIn: Bool) -> AVCaptureDevice? {
        let chosen = AVCaptureDevice.default(for: .audio)
        if preferBuiltIn, let chosen, bluetooth.contains(chosen.transportType) {
            let all = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
            if let builtInMicrophone = all.first(where: { $0.transportType == builtIn }) { return builtInMicrophone }
        }
        return chosen
    }

    // MARK: - Incoming sound

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              let format = AVAudioFormat(streamDescription: &asbd)
        else { return }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList) == noErr
        else { return }

        // Built from the first slice, and again if the microphone's format ever changes.
        if convertedFormat != format {
            convertedFormat = format
            resampler = Resampler(from: format)
        }
        guard let resampler else { return }
        let chunk = resampler.convert(buffer)
        guard !chunk.isEmpty else { return }
        var sum: Float = 0
        for v in chunk { sum += v * v }
        lock.lock()
        samples.append(contentsOf: chunk)
        lock.unlock()
        onLevel?((sum / Float(chunk.count)).squareRoot())
    }
}
