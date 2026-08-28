import AVFoundation
import Foundation
import NaturalLanguage
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

    /// Un pipeline de transcription complet pour UNE locale. En mode
    /// automatique, deux pipelines (fr, en) écoutent le même micro et la
    /// meilleure hypothèse gagne à la fin (détection de langue par duel).
    private final class Pipeline {
        let locale: Locale
        let transcriber: SpeechTranscriber
        let analyzer: SpeechAnalyzer
        var continuation: AsyncStream<AnalyzerInput>.Continuation?
        var converter: AVAudioConverter?
        var format: AVAudioFormat?
        var resultsTask: Task<Void, Never>?
        var finalizedText = ""
        var volatileText = ""
        var confidenceSum = 0.0
        var confidenceCount = 0

        /// Confiance moyenne du transcripteur sur les segments finaux (0…1).
        var averageConfidence: Double {
            confidenceCount > 0 ? confidenceSum / Double(confidenceCount) : 0
        }

        var text: String {
            (finalizedText + volatileText).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        init(locale: Locale) {
            self.locale = locale
            transcriber = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults],
                attributeOptions: [.transcriptionConfidence]
            )
            analyzer = SpeechAnalyzer(modules: [transcriber])
        }
    }

    private var audioEngine: AVAudioEngine?
    private var pipelines: [Pipeline] = []
    private var audioFile: AVAudioFile?
    private(set) var startedAt: Date?

    /// Locale de la meilleure hypothèse après `stop()` (défaut : la première demandée).
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

    /// Démarre l'écoute micro sur une ou plusieurs locales (plusieurs =
    /// détection de langue par duel : chaque pipeline transcrit le même
    /// audio, la meilleure hypothèse gagne à la fin). `recordingURL` :
    /// fichier caf écrit en parallèle pour la réécoute.
    func startMicrophone(locales: [Locale], recordingURL: URL?) async throws {
        precondition(!locales.isEmpty)
        locale = locales[0]
        startedAt = Date()
        pipelines = locales.map { Pipeline(locale: $0) }

        for pipeline in pipelines {
            try await Self.ensureModel(for: pipeline.transcriber, locale: pipeline.locale)
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [pipeline.transcriber]) else {
                throw DictationError.audioEngineUnavailable
            }
            pipeline.format = format
            let (inputSequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            pipeline.continuation = continuation

            // Consommer les résultats. Le HUD affiche l'hypothèse du premier
            // pipeline (langue préférée) pendant l'écoute.
            let isPrimary = pipeline === pipelines[0]
            pipeline.resultsTask = Task { [weak self, weak pipeline] in
                guard let pipeline else { return }
                do {
                    for try await result in pipeline.transcriber.results {
                        let text = String(result.text.characters)
                        let confidences: [Double] = result.isFinal
                            ? result.text.runs.compactMap { $0.transcriptionConfidence }
                            : []
                        await MainActor.run {
                            if result.isFinal {
                                pipeline.finalizedText += text
                                pipeline.volatileText = ""
                                for confidence in confidences {
                                    pipeline.confidenceSum += confidence
                                    pipeline.confidenceCount += 1
                                }
                            } else {
                                pipeline.volatileText = text
                            }
                            if isPrimary, let self {
                                self.onVolatileText?(pipeline.text)
                            }
                        }
                    }
                } catch {
                    // La séquence se termine avec l'analyzer.
                }
            }
            try await pipeline.analyzer.start(inputSequence: inputSequence)
        }

        let audioEngine = AVAudioEngine()
        self.audioEngine = audioEngine
        let input = audioEngine.inputNode
        let tapFormat = input.outputFormat(forBus: 0)
        guard tapFormat.sampleRate > 0 else { throw DictationError.audioEngineUnavailable }

        for pipeline in pipelines {
            if let format = pipeline.format {
                pipeline.converter = AVAudioConverter(from: tapFormat, to: format)
            }
        }
        if let recordingURL {
            audioFile = try? AVAudioFile(forWriting: recordingURL, settings: tapFormat.settings)
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
            Task { @MainActor [weak self] in
                self?.ingest(buffer: buffer)
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    private func ingest(buffer: AVAudioPCMBuffer) {
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

        // Distribuer le buffer converti à chaque pipeline.
        for pipeline in pipelines {
            guard let converter = pipeline.converter, let format = pipeline.format else { continue }
            let ratio = format.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { continue }
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
                pipeline.continuation?.yield(AnalyzerInput(buffer: converted))
            }
        }
    }

    /// Durée écoulée depuis le début de la session.
    var elapsed: TimeInterval {
        startedAt.map { Date().timeIntervalSince($0) } ?? 0
    }

    /// Arrête l'écoute, départage les hypothèses et retourne la meilleure
    /// transcription. `self.locale` devient la locale gagnante.
    func stop() async -> String {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioFile = nil

        for pipeline in pipelines {
            pipeline.continuation?.finish()
            pipeline.continuation = nil
            try? await pipeline.analyzer.finalizeAndFinishThroughEndOfInput()
            await pipeline.resultsTask?.value
            pipeline.resultsTask = nil
        }
        let hypotheses = pipelines.map {
            (locale: $0.locale, text: $0.text, confidence: $0.averageConfidence)
        }
        pipelines = []

        if ProcessInfo.processInfo.environment["BUTTERFLY_DEBUG"] != nil {
            for hypothesis in hypotheses {
                FileHandle.standardError.write(Data(
                    "[duel] \(hypothesis.locale.identifier) conf=\(String(format: "%.2f", hypothesis.confidence)) « \(hypothesis.text.prefix(90)) »\n".utf8
                ))
            }
        }
        let best = Self.pickBest(hypotheses)
        if let best {
            locale = best.locale
        }
        return best?.text ?? ""
    }

    /// Départage des hypothèses multi-langues. Trois signaux, du plus fort
    /// au plus faible : la CONFIANCE du transcripteur lui-même (le mauvais
    /// modèle doute), la cohérence linguistique du texte (NLLanguageRecognizer),
    /// et la longueur (le bon modèle capte plus de mots). Fonction pure,
    /// testée par --test-langpick.
    static func pickBest(
        _ hypotheses: [(locale: Locale, text: String, confidence: Double)]
    ) -> (locale: Locale, text: String, confidence: Double)? {
        let nonEmpty = hypotheses.filter { !$0.text.isEmpty }
        guard nonEmpty.count > 1 else { return nonEmpty.first ?? hypotheses.first }
        let hasConfidence = nonEmpty.allSatisfy { $0.confidence > 0 }
        func score(_ hypothesis: (locale: Locale, text: String, confidence: Double)) -> Double {
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(hypothesis.text)
            let expected = hypothesis.locale.language.languageCode?.identifier ?? ""
            let probability = recognizer.languageHypotheses(withMaximum: 5)[NLLanguage(rawValue: expected)] ?? 0
            let lengthBonus = min(0.049, Double(hypothesis.text.count) / 10000)
            // Sans confiance disponible (vieux modèle, test), la cohérence
            // linguistique porte seule le verdict.
            return hasConfidence
                ? hypothesis.confidence * 0.7 + probability * 0.3 + lengthBonus
                : probability + lengthBonus
        }
        return nonEmpty.max { score($0) < score($1) }
    }

    /// Annule la session sans exploiter le résultat.
    func cancel() async {
        _ = await stop()
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
