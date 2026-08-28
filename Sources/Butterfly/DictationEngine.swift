import AVFoundation
import Foundation
import Speech

/// Moteur de dictée local : SpeechAnalyzer/SpeechTranscriber (macOS 26),
/// streaming depuis le micro (avec niveaux pour le HUD et enregistrement
/// du fichier audio pour la réécoute) ou depuis un fichier (tests CLI).
///
/// Architecture validée par la recherche Wispr Flow (2026-08-28) :
/// ASR rapide en streaming + passe LLM de nettoyage qui rattrape le WER.
@MainActor
final class DictationEngine {

    enum DictationError: LocalizedError {
        case localeUnsupported(String)
        case audioEngineUnavailable

        var errorDescription: String? {
            switch self {
            case .localeUnsupported(let locale):
                return "Locale non prise en charge par SpeechTranscriber : \(locale)"
            case .audioEngineUnavailable:
                return "Micro indisponible"
            }
        }
    }

    /// Transcription en cours (résultats volatils inclus, pour le HUD).
    var onVolatileText: ((String) -> Void)?
    /// Niveau micro 0…1 (RMS lissé), pour les barres du HUD.
    var onLevel: ((Double) -> Void)?

    private var audioEngine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var audioFile: AVAudioFile?

    private var finalizedText = ""
    private var volatileText = ""
    private(set) var startedAt: Date?

    /// Locale effective de la session en cours.
    private(set) var locale = Locale(identifier: "fr_FR")

    // MARK: - Disponibilité du modèle

    /// Vrai si le modèle de la locale est installé (sinon `prepare` le télécharge).
    static func isModelInstalled(for locale: Locale) async -> Bool {
        let installed = await SpeechTranscriber.installedLocales
        return installed.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
    }

    /// Télécharge le modèle de la locale si besoin (peut être long au 1er run).
    static func ensureModel(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            throw DictationError.localeUnsupported(locale.identifier)
        }
        if await isModelInstalled(for: locale) { return }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    // MARK: - Session micro

    /// Démarre l'écoute micro. `recordingURL` : fichier caf écrit en parallèle
    /// pour la réécoute dans la bibliothèque.
    func startMicrophone(locale: Locale, recordingURL: URL?) async throws {
        self.locale = locale
        finalizedText = ""
        volatileText = ""
        startedAt = Date()

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        try await Self.ensureModel(for: transcriber, locale: locale)
        self.transcriber = transcriber

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw DictationError.audioEngineUnavailable
        }

        let (inputSequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation

        // Consommer les résultats (volatils pour le HUD, finaux accumulés).
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    await MainActor.run {
                        guard let self else { return }
                        if result.isFinal {
                            self.finalizedText += text
                            self.volatileText = ""
                        } else {
                            self.volatileText = text
                        }
                        self.onVolatileText?(self.currentText)
                    }
                }
            } catch {
                // La séquence se termine avec l'analyzer ; rien à faire ici.
            }
        }

        let audioEngine = AVAudioEngine()
        self.audioEngine = audioEngine
        let input = audioEngine.inputNode
        let tapFormat = input.outputFormat(forBus: 0)
        guard tapFormat.sampleRate > 0 else { throw DictationError.audioEngineUnavailable }

        converter = AVAudioConverter(from: tapFormat, to: analyzerFormat)
        if let recordingURL {
            audioFile = try? AVAudioFile(forWriting: recordingURL, settings: tapFormat.settings)
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
            Task { @MainActor [weak self] in
                self?.ingest(buffer: buffer, targetFormat: analyzerFormat)
            }
        }

        try await analyzer.start(inputSequence: inputSequence)
        audioEngine.prepare()
        try audioEngine.start()
    }

    private func ingest(buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
        // Enregistrement pour la réécoute (format du micro, direct).
        try? audioFile?.write(from: buffer)

        // Niveau RMS → HUD.
        if let channel = buffer.floatChannelData?[0] {
            let count = Int(buffer.frameLength)
            if count > 0 {
                var sum: Float = 0
                for index in 0..<count { sum += channel[index] * channel[index] }
                let rms = sqrt(sum / Float(count))
                // ~-50 dB → 0, 0 dB → 1, échelle perceptive simple.
                let level = max(0, min(1, Double((20 * log10(max(rms, 0.00001)) + 50) / 50)))
                onLevel?(level)
            }
        }

        // Conversion vers le format de l'analyzer.
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var fed = false
        var conversionError: NSError?
        converter.convert(to: converted, error: &conversionError) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard conversionError == nil, converted.frameLength > 0 else { return }
        inputContinuation?.yield(AnalyzerInput(buffer: converted))
    }

    /// Texte courant (finalisé + volatil), pour le HUD.
    var currentText: String {
        (finalizedText + volatileText).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Durée écoulée depuis le début de la session.
    var elapsed: TimeInterval {
        startedAt.map { Date().timeIntervalSince($0) } ?? 0
    }

    /// Arrête l'écoute et retourne la transcription brute complète.
    func stop() async -> String {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioFile = nil

        inputContinuation?.finish()
        inputContinuation = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        // Attendre la fin de la séquence de résultats (le finalize la clôt).
        await resultsTask?.value
        resultsTask = nil
        analyzer = nil
        transcriber = nil
        converter = nil

        return (finalizedText + volatileText).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Annule la session sans exploiter le résultat.
    func cancel() async {
        _ = await stop()
        finalizedText = ""
        volatileText = ""
    }

    // MARK: - Transcription de fichier (tests CLI)

    /// Transcrit un fichier audio local (aiff/wav/caf) : pipeline identique
    /// au micro, sans tap. Utilisé par `--test-dictation`.
    static func transcribeFile(at url: URL, locale: Locale) async throws -> String {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
        try await ensureModel(for: transcriber, locale: locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw DictationError.audioEngineUnavailable
        }

        let file = try AVAudioFile(forReading: url)
        let trace = ProcessInfo.processInfo.environment["BUTTERFLY_DEBUG"] != nil
        func log(_ message: String) {
            if trace { FileHandle.standardError.write(Data("[engine] \(message)\n".utf8)) }
        }
        log("fichier ouvert : \(file.length) frames @ \(file.processingFormat.sampleRate) Hz")
        let (inputSequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()

        let collector = Task {
            var text = ""
            for try await result in transcriber.results where result.isFinal {
                text += String(result.text.characters)
            }
            return text
        }

        try await analyzer.start(inputSequence: inputSequence)

        log("analyzerFormat : \(analyzerFormat)")
        let converter = AVAudioConverter(from: file.processingFormat, to: analyzerFormat)
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192) else { break }
            do {
                try file.read(into: buffer)
            } catch {
                log("read a échoué à \(file.framePosition)/\(file.length) : \(error)")
                break
            }
            guard buffer.frameLength > 0 else { break }
            if file.processingFormat == analyzerFormat {
                continuation.yield(AnalyzerInput(buffer: buffer))
            } else if let converter {
                let ratio = analyzerFormat.sampleRate / file.processingFormat.sampleRate
                let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
                guard let converted = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { break }
                var fed = false
                var conversionError: NSError?
                converter.convert(to: converted, error: &conversionError) { _, status in
                    if fed {
                        status.pointee = .noDataNow
                        return nil
                    }
                    fed = true
                    status.pointee = .haveData
                    return buffer
                }
                if conversionError == nil, converted.frameLength > 0 {
                    continuation.yield(AnalyzerInput(buffer: converted))
                }
            }
        }
        continuation.finish()
        log("flux terminé, finalisation…")
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            log("finalize a échoué : \(error)")
            throw error
        }
        log("finalisé, collecte…")
        do {
            let text = try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
            log("collecté : \(text.count) caractères")
            return text
        } catch {
            log("collector a échoué : \(error)")
            throw error
        }
    }
}
