import Cocoa
import AVFoundation
import Carbon

// MARK: - Logger

class Logger {
    static let shared = Logger()
    private let logUrl: URL

    private init() {
        let logPath = FileManager.default.currentDirectoryPath + "/transcriber.log"
        self.logUrl = URL(fileURLWithPath: logPath)
    }

    func log(_ message: String) {
        let entry = "\(Date()): \(message)\n"
        
        // Write to file
        if !FileManager.default.fileExists(atPath: logUrl.path) {
            try? entry.write(to: logUrl, atomically: true, encoding: String.Encoding.utf8)
        } else {
            if let handle = try? FileHandle(forWritingTo: logUrl) {
                handle.seekToEndOfFile()
                if let data = entry.data(using: String.Encoding.utf8) {
                    handle.write(data)
                }
                handle.closeFile()
            }
        }
    }

    func clear() {
        try? "".write(to: logUrl, atomically: true, encoding: String.Encoding.utf8)
    }
}

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
private let synthesizer = AVSpeechSynthesizer()

// MARK: - Helpers

private func checkAccessibilityPermissions() -> Bool {
    // Check if we already have permission
    if AXIsProcessTrusted() {
        return true
    }
    
    // If not, prompt the user exactly once
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
    AXIsProcessTrustedWithOptions(options as CFDictionary)
    
    print("🔒 Accessibility permissions required.")
    print("   Please grant access in System Settings > Privacy & Security > Accessibility.")
    print("   Waiting for permission...")
    
    // Wait until permission is granted
    while !AXIsProcessTrusted() {
        Thread.sleep(forTimeInterval: 1.0)
    }
    
    print("✅ Permissions granted!")
    return true
}

private func speak(_ text: String) {
    if synthesizer.isSpeaking {
        synthesizer.stopSpeaking(at: .immediate)
    }
    
    let utterance = AVSpeechUtterance(string: text)
    // Attempt to find Daniel (British Male), otherwise fall back to any en-GB
    if let voice = AVSpeechSynthesisVoice(identifier: "com.apple.speech.synthesis.voice.Daniel") ?? AVSpeechSynthesisVoice(language: "en-GB") {
        utterance.voice = voice
    }
    utterance.rate = 0.58
    utterance.pitchMultiplier = 1.0 // Reset pitch for natural voice
    utterance.volume = 1.0
    synthesizer.speak(utterance)
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
    
    let prefixesToRemove: [String] = []
    
    for prefix in prefixesToRemove {
        if clean.lowercased().hasPrefix(prefix) {
            let index = clean.index(clean.startIndex, offsetBy: prefix.count)
            clean = String(clean[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
            while clean.hasPrefix(".") || clean.hasPrefix(",") || clean.hasPrefix("?") {
                clean = String(clean.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }
    
    let hallucinations = ["Thank you.", "Thank you", "Thanks.", "Thanks", "[Silence]", "(Silence)", "[Background noise]", "Amara.org"]
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
    
    let source = CGEventSource(stateID: .hidSystemState)
    let vKeyCode: CGKeyCode = 9 // 'v'
    
    if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true) {
        keyDown.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
    }
    
    if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) {
        keyUp.flags = .maskCommand
        keyUp.post(tap: .cghidEventTap)
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
