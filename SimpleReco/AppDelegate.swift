import Cocoa
import SwiftUI
import ScreenCaptureKit

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var floatingWindow: NSWindow?
    var recordingState = RecordingState()
    var audioRecorder: AudioRecorder?
    var recordingTimer: Timer?
    var blinkTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        requestPermissions()
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            updateMenuBarIcon(isRecording: false)
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self
        }
    }

    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else {
            toggleWindow()
            return
        }

        if event.type == .rightMouseUp {
            showMenu()
        } else {
            toggleWindow()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open SimpleReco", action: #selector(toggleWindow), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func quitApp() {
        if recordingState.status == .recording {
            clearRecording()
        }
        NSApp.terminate(nil)
    }

    func updateMenuBarIcon(isRecording: Bool) {
        guard let button = statusItem?.button else { return }

        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        let iconName = isRecording ? "record.circle.fill" : "record.circle"

        if let image = NSImage(systemSymbolName: iconName, accessibilityDescription: "SimpleReco") {
            let configuredImage = image.withSymbolConfiguration(config)
            button.image = configuredImage

            if isRecording {
                button.contentTintColor = .systemRed
            } else {
                button.contentTintColor = nil
            }
        }
    }

    func startBlinkingIcon() {
        var isOn = true
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.recordingState.isRecordingIndicatorOn = isOn
                if let button = self?.statusItem?.button {
                    button.contentTintColor = isOn ? .systemRed : .gray
                }
                isOn.toggle()
            }
        }
    }

    func stopBlinkingIcon() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        updateMenuBarIcon(isRecording: false)
    }

    private func requestPermissions() {
        Task {
            do {
                try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                await MainActor.run {
                    recordingState.permissionGranted = true
                }
            } catch {
                await MainActor.run {
                    recordingState.permissionGranted = false
                    recordingState.errorMessage = "Screen recording permission required. Please enable in System Settings > Privacy & Security > Screen Recording."
                }
            }
        }
    }

    @objc private func toggleWindow() {
        if let window = floatingWindow, window.isVisible {
            window.orderOut(nil)
        } else {
            showFloatingWindow()
        }
    }

    private func showFloatingWindow() {
        if floatingWindow == nil {
            let contentView = ContentView(recordingState: recordingState, appDelegate: self)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 280, height: 220),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )

            window.contentView = NSHostingView(rootView: contentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.backgroundColor = NSColor.windowBackgroundColor
            window.isReleasedWhenClosed = false
            window.delegate = self

            floatingWindow = window
        }

        positionWindowNearStatusItem()
        floatingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func positionWindowNearStatusItem() {
        guard let window = floatingWindow,
              let button = statusItem?.button,
              let buttonWindow = button.window else { return }

        let buttonFrame = button.convert(button.bounds, to: nil)
        let screenFrame = buttonWindow.convertToScreen(buttonFrame)

        let windowWidth = window.frame.width
        let windowHeight = window.frame.height

        let x = screenFrame.midX - windowWidth / 2
        let y = screenFrame.minY - windowHeight - 5

        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func startRecording() {
        guard recordingState.permissionGranted else {
            recordingState.errorMessage = "Permission not granted"
            return
        }

        audioRecorder = AudioRecorder(recordingState: recordingState)
        audioRecorder?.startRecording()

        recordingState.status = .recording
        recordingState.duration = 0
        recordingState.liveWaveformSamples = []

        updateMenuBarIcon(isRecording: true)
        startBlinkingIcon()

        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.recordingState.duration += 0.1
            }
        }
    }

    func stopRecording() {
        recordingTimer?.invalidate()
        recordingTimer = nil

        stopBlinkingIcon()

        audioRecorder?.stopRecording { [weak self] url in
            Task { @MainActor in
                guard let self = self else { return }
                self.recordingState.status = .recorded
                self.recordingState.audioURL = url

                if let url = url {
                    self.generateWaveform(from: url)
                }
            }
        }
    }

    private func generateWaveform(from url: URL) {
        Task {
            do {
                let file = try AVAudioFile(forReading: url)
                let format = file.processingFormat
                let frameCount = AVAudioFrameCount(file.length)

                guard frameCount > 0 else {
                    print("No frames in audio file")
                    return
                }

                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                    print("Failed to create buffer")
                    return
                }
                try file.read(into: buffer)

                let sampleCount = 50
                var samples: [Float] = []

                if format.isInterleaved {
                    guard let floatData = buffer.floatChannelData?[0] else {
                        print("No float channel data (interleaved)")
                        return
                    }
                    let totalSamples = Int(buffer.frameLength) * Int(format.channelCount)
                    let samplesPerBucket = totalSamples / sampleCount

                    for i in 0..<sampleCount {
                        let start = i * samplesPerBucket
                        let end = min(start + samplesPerBucket, totalSamples)
                        var sum: Float = 0
                        for j in start..<end {
                            sum += abs(floatData[j])
                        }
                        let avg = sum / Float(end - start)
                        samples.append(avg)
                    }
                } else {
                    guard let floatData = buffer.floatChannelData?[0] else {
                        print("No float channel data (non-interleaved)")
                        return
                    }
                    let samplesPerBucket = Int(buffer.frameLength) / sampleCount

                    for i in 0..<sampleCount {
                        let start = i * samplesPerBucket
                        let end = min(start + samplesPerBucket, Int(buffer.frameLength))
                        var sum: Float = 0
                        for j in start..<end {
                            sum += abs(floatData[j])
                        }
                        let avg = sum / Float(end - start)
                        samples.append(avg)
                    }
                }

                let maxSample = samples.max() ?? 1.0
                if maxSample > 0 {
                    samples = samples.map { $0 / maxSample }
                }

                print("Generated waveform with \(samples.count) samples, max: \(maxSample)")

                await MainActor.run {
                    recordingState.setFinalWaveform(samples)
                }
            } catch {
                print("Error generating waveform: \(error)")
            }
        }
    }

    func clearRecording() {
        if recordingState.status == .recording {
            stopRecording()
        }

        if let url = recordingState.audioURL {
            try? FileManager.default.removeItem(at: url)
        }

        recordingState.reset()
        updateMenuBarIcon(isRecording: false)
    }
}

extension AppDelegate: NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            if recordingState.status == .recording {
                clearRecording()
            }
        }
    }
}
