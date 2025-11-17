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
        Task {
            await startAudioEngine()
        }
    }

    func stopRecording() {
        isRecording = false
        Task {
            await stopAudioEngine()
        }
    }

    private func startAudioEngine() async {
        do {
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement, options: .duckOthers)
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("Audio session setup error: \(error)")
            return
        }

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

    private func stopAudioEngine() async {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        inputContinuation?.finish()

        try? await self.speechAnalyzer?.finalize(through: nil)

        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("Audio session deactivation error: \(error)")
        }
    }

    func startRecognition() {
        Task {
            do {
                try await speechAnalyzer?.start(inputSequence: inputStream!)
                for try await result in transcriber!.results {
                    self.transcribedText = result.text
                }
            } catch {
                print("Recognition error: \(error)")
            }
        }
    }
}
