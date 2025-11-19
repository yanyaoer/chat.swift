import Foundation
import Speech
@preconcurrency import AVFoundation

class SpeechManager: ObservableObject, @unchecked Sendable {
    @Published var transcribedText: String = ""
    @Published var isRecording: Bool = false

    // Audio engine and recognizer are not thread-safe, so we need to be careful
    private let audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    
    // Mutable state that needs protection
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    
    // Queue for synchronizing access to recognition state
    // We use a serial queue to act as a lock for our mutable state
    private let stateQueue = DispatchQueue(label: "com.chatapp.speech.state")

    init() {
        // Don't request authorization in init - let it be requested lazily when user starts recording
    }

    func startRecording() {
        print("📱 SpeechManager.startRecording() called")
        
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            print("❌ Speech recognizer not available")
            return
        }

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
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] (buffer, _) in
            guard let self = self else { return }
            // Safely access the request on our state queue
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
            return
        }

        // Start recognition task
        // Note: recognitionTask(with:resultHandler:) must be called from main thread or consistent thread context
        // The result handler is called on a background queue usually
        let newTask = recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
            guard let self = self else { return }

            if let result = result {
                // Extract string here to avoid sending non-Sendable 'result' to MainActor
                let transcription = result.bestTranscription.formattedString
                
                // Update UI on MainActor
                Task { @MainActor in
                    self.transcribedText = transcription
                    print("🎯 Transcribed: \(self.transcribedText)")
                }
            }

            if error != nil || result?.isFinal == true {
                // Stop everything
                self.stopRecordingInternal()
            }
        }
        
        stateQueue.sync {
            recognitionTask = newTask
        }

        isRecording = true
        print("📱 isRecording set to true")
    }

    func stopRecording() {
        print("📱 Stopping recording...")
        stopRecordingInternal()
        isRecording = false
        print("✅ Recording stopped")
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
