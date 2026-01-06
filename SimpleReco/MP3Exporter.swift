import Foundation
import AVFoundation
import AppKit
import UniformTypeIdentifiers

class MP3Exporter {

    static func convertToMP3(from sourceURL: URL) async -> URL? {
        let tempDir = FileManager.default.temporaryDirectory
        let m4aURL = tempDir.appendingPathComponent(UUID().uuidString + ".m4a")

        let asset = AVURLAsset(url: sourceURL)

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            print("Failed to create export session")
            return await convertUsingAudioFile(from: sourceURL)
        }

        do {
            try await exportSession.export(to: m4aURL, as: .m4a)
            return m4aURL
        } catch {
            print("Export failed: \(error.localizedDescription)")
            return await convertUsingAudioFile(from: sourceURL)
        }
    }

    private static func convertUsingAudioFile(from sourceURL: URL) async -> URL? {
        do {
            let sourceFile = try AVAudioFile(forReading: sourceURL)
            let format = sourceFile.processingFormat
            let frameCount = UInt32(sourceFile.length)

            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                return nil
            }

            try sourceFile.read(into: buffer)

            let aacSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 320000
            ]

            let tempDir = FileManager.default.temporaryDirectory
            let aacURL = tempDir.appendingPathComponent(UUID().uuidString + ".m4a")
            let aacFile = try AVAudioFile(forWriting: aacURL, settings: aacSettings)
            try aacFile.write(from: buffer)

            return aacURL

        } catch {
            print("Error converting audio: \(error)")
            return sourceURL
        }
    }

    static func generateFilename() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy_MM_dd"
        let dateString = dateFormatter.string(from: Date())

        let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!

        var sequenceNumber = 1
        var filename: String

        repeat {
            filename = "Recording_\(dateString)_\(String(format: "%02d", sequenceNumber)).m4a"
            sequenceNumber += 1
        } while FileManager.default.fileExists(atPath: downloadsURL.appendingPathComponent(filename).path)

        return filename
    }

    static func getDefaultSaveURL() -> URL {
        let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let filename = generateFilename()
        return downloadsURL.appendingPathComponent(filename)
    }

    static func saveToDownloads(from sourceURL: URL) -> URL? {
        let destinationURL = getDefaultSaveURL()

        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            return destinationURL
        } catch {
            print("Error saving file: \(error)")
            return nil
        }
    }

    static func saveWithPicker(from sourceURL: URL, suggestedName: String? = nil) {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [UTType.mpeg4Audio, UTType.audio]
        savePanel.nameFieldStringValue = suggestedName ?? generateFilename()
        savePanel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first

        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                do {
                    if FileManager.default.fileExists(atPath: url.path) {
                        try FileManager.default.removeItem(at: url)
                    }
                    try FileManager.default.copyItem(at: sourceURL, to: url)
                } catch {
                    print("Error saving file: \(error)")
                }
            }
        }
    }
}
