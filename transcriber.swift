import Cocoa
import AVFoundation
import Carbon

// MARK: - Configuration

private enum Config {
    static let modifierKeyCode: CGKeyCode = 58 // Left Option
    static let triggerKeyCode: CGKeyCode = 1   // 'S' Key
    static let triggerKeyName = "S"
    static let whisperPath = FileManager.default.currentDirectoryPath + "/whisper.cpp/build/bin/whisper-cli"
    static let modelPath = FileManager.default.currentDirectoryPath + "/whisper.cpp/models/ggml-small.en-q8_0.bin"
}

// MARK: - State

private var isRecording = false
private var isModifierDown = false
private var isTriggerDown = false
private var recordingWorkItem: DispatchWorkItem?
private var audioRecorder: AVAudioRecorder?
private var currentRecordingURL: URL?
private var eventTap: CFMachPort?
private let processingQueue = DispatchQueue(label: "com.whisper.processing", qos: .userInitiated)

// MARK: - Helpers

private func checkAccessibilityPermissions() -> Bool {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
    return AXIsProcessTrustedWithOptions(options as CFDictionary)
}

private func speak(_ text: String) {
    let process = Process()
    process.launchPath = "/usr/bin/say"
    process.arguments = ["-r", "200", text]
    process.launch()
}

// MARK: - Audio Recording

private func startRecording() {
    guard !isRecording else { return }
    
    let filename = "rec-\(UUID().uuidString).wav"
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
    
    let settings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVSampleRateKey: 16000.0,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false
    ]
    
    do {
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.prepareToRecord()
        recorder.record()
        
        audioRecorder = recorder
        currentRecordingURL = url
        isRecording = true
        
        Logger.shared.clear()
        Logger.shared.log("🎤 Started recording: \(url.lastPathComponent)")
        speak("Listening")
    } catch {
        Logger.shared.log("❌ Failed to start recording: \(error)")
    }
}

private func stopRecording() {
    recordingWorkItem?.cancel()
    recordingWorkItem = nil
    
    guard let recorder = audioRecorder, let url = currentRecordingURL, isRecording else { return }
    
    Logger.shared.log("🛑 Stopped recording")
    speak("Processing")
    recorder.stop()
    isRecording = false
    
    // Cleanup state immediately, process in background
    audioRecorder = nil
    currentRecordingURL = nil
    
    processingQueue.async {
        transcribe(audioURL: url)
    }
}

// MARK: - Transcription

private func transcribe(audioURL: URL) {
    defer { try? FileManager.default.removeItem(at: audioURL) }
    
    guard FileManager.default.fileExists(atPath: Config.modelPath) else {
        Logger.shared.log("❌ Model missing at: \(Config.modelPath)")
        return
    }
    
    let process = Process()
    process.executableURL = URL(fileURLWithPath: Config.whisperPath)
    process.arguments = [
        "-m", Config.modelPath,
        "-f", audioURL.path,
        "-t", "8",
        "--no-timestamps",
        "-l", "en",
        "-nf",
        "-et", "2.8",
        "-bs", "5"
    ]
    
    let pipe = Pipe()
    process.standardOutput = pipe
    
    do {
        try process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8) {
            let text = cleanOutput(output)
            if !text.isEmpty {
                Logger.shared.log("📝 Transcribed: \(text)")
                DispatchQueue.main.async { paste(text: text) }
            }
        }
    } catch {
        Logger.shared.log("❌ Whisper error: \(error)")
    }
}

private func cleanOutput(_ text: String) -> String {
    var clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
    
    if clean.lowercased().hasPrefix("listening") {
        let index = clean.index(clean.startIndex, offsetBy: 9)
        clean = String(clean[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
        while clean.hasPrefix(".") {
            clean = String(clean.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    
    let hallucinations = ["Thank you.", "Thank you", "Thanks.", "Thanks", "[Silence]", "(Silence)", "[Background noise]", "[NO OUTPUT]", "[]"]
    if hallucinations.contains(where: { clean.caseInsensitiveCompare($0) == .orderedSame }) {
        return ""
    }
    
    return clean
}

// MARK: - System Integration

private func paste(text: String) {
    guard !text.isEmpty else { return }
    
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    
    let script = """
    tell application "System Events"
        keystroke "v" using command down
    end tell
    """
    
    if let appleScript = NSAppleScript(source: script) {
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
        if let error = error {
            Logger.shared.log("❌ Paste error: \(error)")
        }
    }
}

// MARK: - Event Tap

private func eventCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passRetained(event)
    }
    
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    
    // Modifier Key Handling
    if type == .flagsChanged && keyCode == Config.modifierKeyCode {
        let isPressed = event.flags.contains(.maskAlternate)
        isModifierDown = isPressed
        
        if !isPressed {
            if isRecording {
                stopRecording()
            } else {
                cancelRecording()
            }
        }
    }
    
    // Trigger Key Handling
    if keyCode == Config.triggerKeyCode && isModifierDown {
        if type == .keyDown {
            if !isTriggerDown {
                isTriggerDown = true
                scheduleRecording()
            }
            return nil // Suppress original key event
        } else if type == .keyUp {
            isTriggerDown = false
            if isRecording {
                stopRecording()
            } else {
                cancelRecording()
            }
            return nil
        }
        return nil
    }
    
    return Unmanaged.passRetained(event)
}

private func scheduleRecording() {
    guard !isRecording, recordingWorkItem == nil else { return }
    
    Logger.shared.log("⏳ Waiting for hold...")
    let item = DispatchWorkItem { startRecording() }
    recordingWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
}

private func cancelRecording() {
    if let item = recordingWorkItem {
        item.cancel()
        recordingWorkItem = nil
        speak("Cancelled")
        Logger.shared.log("ℹ️ Cancelled")
    }
}

private func setupEventTap() {
    let mask = (1 << CGEventType.keyDown.rawValue) |
               (1 << CGEventType.keyUp.rawValue) |
               (1 << CGEventType.flagsChanged.rawValue)
    
    eventTap = CGEvent.tapCreate(
        tap: .cghidEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: CGEventMask(mask),
        callback: eventCallback,
        userInfo: nil
    )
    
    guard let tap = eventTap else {
        Logger.shared.log("❌ Failed to create event tap")
        exit(1)
    }
    
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    
    Logger.shared.log("👂 System ready. Hold Left Option + \(Config.triggerKeyName)")
    CFRunLoopRun()
}

// MARK: - Entry Point

func main() {
    guard checkAccessibilityPermissions() else {
        print("❌ Accessibility permissions required.")
        exit(1)
    }

    setupEventTap()
}

main()
