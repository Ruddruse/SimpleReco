import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import AudioToolbox

class AudioRecorder: NSObject {
    private var stream: SCStream?
    private var audioFile: AVAudioFile?
    private var tempFileURL: URL?
    private var recordingState: RecordingState
    private var actualSampleRate: Double = 48000
    private var actualChannelCount: UInt32 = 2
    private var isFirstBuffer: Bool = true
    private var totalFramesWritten: Int64 = 0
    private var fileFormat: AVAudioFormat?

    init(recordingState: RecordingState) {
        self.recordingState = recordingState
        super.init()
    }

    private func getSystemAudioSampleRate() -> Double {
        var deviceID = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )

        guard status == noErr else {
            print("Failed to get default output device, using 48000 Hz")
            return 48000
        }

        var sampleRate: Float64 = 0
        size = UInt32(MemoryLayout<Float64>.size)
        address.mSelector = kAudioDevicePropertyNominalSampleRate
        address.mScope = kAudioObjectPropertyScopeGlobal

        let rateStatus = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &sampleRate
        )

        guard rateStatus == noErr, sampleRate > 0 else {
            print("Failed to get sample rate, using 48000 Hz")
            return 48000
        }

        print("System audio sample rate: \(sampleRate) Hz")
        return sampleRate
    }

    func startRecording() {
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

                guard let display = content.displays.first else {
                    await MainActor.run {
                        recordingState.errorMessage = "No display found"
                    }
                    return
                }

                let filter = SCContentFilter(display: display, excludingWindows: [])

                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                // Use system's native sample rate to avoid resampling issues
                let nativeSampleRate = self.getSystemAudioSampleRate()
                config.sampleRate = Int(nativeSampleRate)
                config.channelCount = 2
                print("Requesting audio at \(config.sampleRate) Hz")

                config.width = 2
                config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                config.showsCursor = false

                let tempDir = FileManager.default.temporaryDirectory
                let tempFile = tempDir.appendingPathComponent(UUID().uuidString + ".wav")
                self.tempFileURL = tempFile
                self.isFirstBuffer = true
                self.totalFramesWritten = 0
                self.audioFile = nil
                self.fileFormat = nil

                stream = SCStream(filter: filter, configuration: config, delegate: self)

                try stream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))

                try await stream?.startCapture()
                print("Recording started")

            } catch {
                await MainActor.run {
                    recordingState.errorMessage = "Failed to start recording: \(error.localizedDescription)"
                }
            }
        }
    }

    private func createAudioFile(sampleRate: Double, channelCount: UInt32) -> AVAudioFile? {
        guard let tempFile = tempFileURL else { return nil }

        // Use standard non-interleaved format for the file
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: false
        ) else {
            print("Failed to create audio format")
            return nil
        }

        self.fileFormat = format

        do {
            let file = try AVAudioFile(forWriting: tempFile, settings: format.settings)
            print("Created audio file at: \(tempFile.path)")
            print("File format: \(format)")
            return file
        } catch {
            print("Error creating audio file: \(error)")
            return nil
        }
    }

    func stopRecording(completion: @escaping (URL?) -> Void) {
        Task {
            do {
                try await stream?.stopCapture()
                stream = nil

                let framesWritten = totalFramesWritten
                audioFile = nil
                fileFormat = nil

                print("Recording stopped. Total frames written: \(framesWritten)")

                guard let tempURL = tempFileURL else {
                    print("No temp URL")
                    completion(nil)
                    return
                }

                let fileManager = FileManager.default
                if fileManager.fileExists(atPath: tempURL.path) {
                    do {
                        let attributes = try fileManager.attributesOfItem(atPath: tempURL.path)
                        let fileSize = attributes[.size] as? Int64 ?? 0
                        print("Temp file size: \(fileSize) bytes")

                        if fileSize == 0 || framesWritten == 0 {
                            print("Warning: Audio file is empty!")
                            completion(nil)
                            return
                        }
                    } catch {
                        print("Error getting file attributes: \(error)")
                    }
                } else {
                    print("Temp file does not exist!")
                    completion(nil)
                    return
                }

                // Skip conversion - use WAV directly to preserve sample rate
                print("Recording complete: \(tempURL.path)")
                completion(tempURL)

            } catch {
                print("Error stopping capture: \(error)")
                completion(nil)
            }
        }
    }
}

extension AudioRecorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("Stream stopped with error: \(error)")
        Task { @MainActor in
            recordingState.errorMessage = "Stream stopped: \(error.localizedDescription)"
        }
    }
}

extension AudioRecorder: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }

        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return
        }

        let sampleRate = asbd.pointee.mSampleRate
        let channelCount = asbd.pointee.mChannelsPerFrame
        let bytesPerFrame = Int(asbd.pointee.mBytesPerFrame)
        let bitsPerChannel = asbd.pointee.mBitsPerChannel
        let formatFlags = asbd.pointee.mFormatFlags

        if isFirstBuffer {
            isFirstBuffer = false
            actualSampleRate = sampleRate
            actualChannelCount = channelCount
            audioFile = createAudioFile(sampleRate: sampleRate, channelCount: channelCount)
            print("Audio format from stream:")
            print("  Sample rate: \(sampleRate) Hz")
            print("  Channels: \(channelCount)")
            print("  Bytes per frame: \(bytesPerFrame)")
            print("  Bits per channel: \(bitsPerChannel)")
            print("  Format flags: \(formatFlags) (isFloat=\(formatFlags & 1), isNonInterleaved=\((formatFlags >> 5) & 1))")
        }

        guard let audioFile = audioFile, let fileFormat = fileFormat else { return }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

        guard let data = dataPointer else { return }

        // Use actual bytes per frame from ASBD instead of assuming Float32
        let frameCount = bytesPerFrame > 0 ? length / bytesPerFrame : 0
        let totalSamples = frameCount * Int(channelCount)

        guard frameCount > 0 else { return }

        // Create buffer matching the file format (non-interleaved)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            print("Failed to create buffer")
            return
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        // Input data is interleaved: L0 R0 L1 R1 L2 R2 ...
        // Output needs to be non-interleaved: L0 L1 L2 ... | R0 R1 R2 ...
        let floatPointer = UnsafeRawPointer(data).bindMemory(to: Float.self, capacity: totalSamples)

        if let channelData = buffer.floatChannelData {
            for frame in 0..<frameCount {
                for channel in 0..<Int(channelCount) {
                    let inputIndex = frame * Int(channelCount) + channel
                    channelData[channel][frame] = floatPointer[inputIndex]
                }
            }
        }

        do {
            try audioFile.write(from: buffer)
            totalFramesWritten += Int64(frameCount)
        } catch {
            print("Error writing audio: \(error)")
        }

        // Update live waveform (use left channel)
        var sum: Float = 0
        let samplesToCheck = min(frameCount, 500)
        for i in 0..<samplesToCheck {
            sum += abs(floatPointer[i * Int(channelCount)])
        }
        let avg = sum / Float(samplesToCheck)

        Task { @MainActor in
            recordingState.appendLiveSample(avg * 5)
        }
    }
}
