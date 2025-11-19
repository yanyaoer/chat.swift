import Foundation
import Speech
@preconcurrency import AVFoundation

/// SpeechManager handles speech recognition with careful concurrency management.
///
/// Concurrency Strategy:
/// - @Published properties (transcribedText, isRecording) are updated on MainActor for UI binding
/// - Audio engine and speech recognizer operations happen on main thread
/// - Recognition request/task are accessed from multiple threads (audio tap, recognition callbacks)
/// - stateQueue serializes access to recognitionRequest and recognitionTask
/// - Uses @unchecked Sendable because manual synchronization ensures thread safety
class SpeechManager: ObservableObject, @unchecked Sendable {
    @Published var transcribedText: String = ""
    @Published var isRecording: Bool = false

    // Audio engine and recognizer - accessed from main thread
    private let audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    
    // Recognition state - protected by stateQueue
    // Must be accessed via stateQueue.sync/async to ensure thread safety
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    
    // Serial queue for synchronizing access to recognition state
    private let stateQueue = DispatchQueue(label: "com.chatapp.speech.state")

    init() {
        // Don't request authorization in init - let it be requested lazily when user starts recording
    }

    func startRecording() {
        print("📱 SpeechManager.startRecording() called")
        
        // Clear previous transcription
        transcribedText = ""
        
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            print("❌ Speech recognizer not available")
            return
        }

        // List available audio input devices
        listAudioInputDevices()

        // Configure AVAudioSession for recording
        #if os(macOS)
        // macOS doesn't use AVAudioSession, but we need to ensure proper audio setup
        print("🎙️ Running on macOS - no AVAudioSession needed")
        #else
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: [])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            print("✅ Audio session configured")
        } catch {
            print("❌ Failed to set up audio session: \(error)")
            return
        }
        #endif

        // Reset state on the state queue to ensure safety
        stateQueue.sync {
            recognitionTask?.cancel()
            recognitionTask = nil
            recognitionRequest = nil
        }

        // Create request
        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        
        // Store request safely
        stateQueue.sync {
            recognitionRequest = newRequest
        }

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // Install tap - this callback runs on a background audio thread
        // Note: AVAudioPCMBuffer is not Sendable but safe here because:
        // 1. It's only used within this callback's scope
        // 2. We immediately pass it to recognitionRequest on stateQueue
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] (buffer, _) in
            guard let self = self else { return }
            // Access recognitionRequest on stateQueue for thread safety
            self.stateQueue.async {
                self.recognitionRequest?.append(buffer)
            }
        }

        audioEngine.prepare()

        do {
            try audioEngine.start()
            print("✅ Audio engine started successfully")
        } catch {
            print("❌ Audio engine start error: \(error)")
            print("⚠️  请检查您的录音设备设置：")
            print("   1. 打开系统设置 > 声音 > 输入")
            print("   2. 确认选择了正确的输入设备")
            print("   3. 确认输入音量不为零")
            listAudioInputDevices()
            return
        }

        // Start recognition task
        // The result handler is called on a background queue
        let newTask = recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
            guard let self = self else { return }

            if let result = result {
                // Extract values to avoid sending non-Sendable 'result' across boundaries
                let transcription = result.bestTranscription.formattedString
                let isFinal = result.isFinal
                
                // Update @Published property on MainActor
                Task { @MainActor in
                    self.transcribedText = transcription
                    print("🎯 Transcribed: \(self.transcribedText)")
                }
                
                // Stop if final
                if isFinal {
                    self.stopRecordingInternal()
                }
            }

            if let error = error {
                print("❌ Recognition error: \(error.localizedDescription)")
                self.stopRecordingInternal()
            }
        }
        
        stateQueue.sync {
            recognitionTask = newTask
        }

        // Update @Published property on MainActor
        Task { @MainActor in
            isRecording = true
            print("📱 isRecording set to true")
        }
    }
    
    private func listAudioInputDevices() {
        #if os(macOS)
        let devices = AVCaptureDevice.devices(for: .audio)
        if devices.isEmpty {
            print("⚠️  没有找到音频输入设备")
        } else {
            print("🎙️ 可用的音频输入设备：")
            for (index, device) in devices.enumerated() {
                let isDefault = device == AVCaptureDevice.default(for: .audio)
                let marker = isDefault ? "✓ (默认)" : "  "
                print("   \(marker) \(index + 1). \(device.localizedName)")
            }
        }
        #endif
    }

    func stopRecording() {
        print("📱 Stopping recording...")
        stopRecordingInternal()
        // Update @Published property on MainActor
        Task { @MainActor in
            isRecording = false
            print("✅ Recording stopped")
        }
    }
    
    private func stopRecordingInternal() {
        // Stop audio engine immediately (thread-safe)
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        
        // Clean up state safely
        stateQueue.sync {
            recognitionRequest?.endAudio()
            recognitionRequest = nil
            recognitionTask?.cancel()
            recognitionTask = nil
        }
    }
}
