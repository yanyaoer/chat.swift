import Foundation
import Speech
import AVFoundation

@MainActor
class SpeechManager: ObservableObject {
    @Published var transcribedText: String = ""
    @Published var isRecording: Bool = false

    private var audioEngine: AVAudioEngine?
    private var speechAnalyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?

    private let audioQueue = DispatchQueue(label: "audio.queue", qos: .userInitiated)
    private let recognitionQueue = DispatchQueue(label: "recognition.queue", qos: .userInitiated)

    private var inputStream: AsyncStream<AnalyzerInput>?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?

    init() {
        audioEngine = AVAudioEngine()
        Task {
            await setupSpeechAnalyzer()
        }
    }

    private func setupSpeechAnalyzer() async {
        guard await SpeechTranscriber.isAvailable else {
            print("SpeechTranscriber not available")
            return
        }

        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else {
            print("Locale not supported")
            return
        }

        do {
            try await AssetInventory.reserve(locale: locale)

            transcriber = SpeechTranscriber(locale: locale)

            let installed = (await SpeechTranscriber.installedLocales).contains(locale)
            if !installed {
                if let installationRequest = try await AssetInventory.assetInstallationRequest(supporting: [transcriber!]) {
                    try await installationRequest.downloadAndInstall()
                }
            }

            let preset: SpeechTranscriber.Preset = .timeIndexedProgressiveTranscription
            transcriber = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: preset.transcriptionOptions,
                reportingOptions: preset.reportingOptions.union([.alternativeTranscriptions]),
                attributeOptions: preset.attributeOptions.union([.transcriptionConfidence])
            )

            speechAnalyzer = SpeechAnalyzer(modules: [transcriber!], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        } catch {
            print("Error setting up speech analyzer: \(error)")
        }
    }

    func startRecording() {
        isRecording = true
        audioQueue.async {
            self.startAudioEngine()
        }
    }

    func stopRecording() {
        isRecording = false
        audioQueue.async {
            self.stopAudioEngine()
        }
    }

    private func startAudioEngine() {
        (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()

        let inputNode = audioEngine!.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { (buffer, when) in
            let input = AnalyzerInput(buffer: buffer)
            self.inputContinuation?.yield(input)
        }

        audioEngine?.prepare()

        do {
            try audioEngine?.start()
        } catch {
            print("Audio engine start error: \(error)")
        }
    }

    private func stopAudioEngine() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        inputContinuation?.finish()
    }

    func startRecognition() {
        recognitionQueue.async {
            Task {
                do {
                    try await self.speechAnalyzer?.start(inputSequence: self.inputStream!)
                    for try await result in self.transcriber!.results {
                        self.transcribedText = result.text
                    }
                } catch {
                    print("Recognition error: \(error)")
                }
            }
        }
    }
}
