import AVFoundation
import FluidAudio
import Foundation
import Testing

@testable import Shirusu

struct VocabularyCorrectionTests {
    @Test("Corrects only the listed misheard words")
    func replacesKnownWords() {
        #expect(
            Vocabulary.corrected("Abre o terminal e faz comite disso.")
                == "Abre o terminal e faz commit disso.")
        #expect(
            Vocabulary.corrected("o modelo parakeed rodando")
                == "o modelo Parakeet rodando")
    }

    @Test("Leaves everything else alone")
    func doesNotTouchOrdinarySpeech() {
        // The words the CTC rescorer used to destroy.
        for sentence in [
            "na frente do condomínio",
            "De noite tava eu",
            "Fui lá na máquina",
            "dando muito drift",
            "depois de brincar com o carro",
            "eu acho que a gente devia",
            "mas eu tô querendo fazer",
            "decisão judicial pra gente",
            "Não era uma BMW, nenhum Porsche",
        ] {
            #expect(Vocabulary.corrected(sentence) == sentence, "changed: \(sentence)")
        }
    }

    @Test("Matches whole words only, and keeps punctuation")
    func respectsWordBoundaries() {
        // A listed form inside a longer word must not be touched.
        #expect(Vocabulary.corrected("comitente") == "comitente")
        #expect(Vocabulary.corrected("faz comite, tá?") == "faz commit, tá?")
        #expect(Vocabulary.corrected("") == "")
    }
}

/// End to end: the release pass produces the corrected text.
@MainActor
struct ReleasePassTests {
    private final class BundleToken {}

    @Test(
        "The inserted text carries the corrections",
        .enabled(if: ShirusuModel.isInstalled),
        .timeLimit(.minutes(5))
    )
    func endToEnd() async throws {
        let bundle = Bundle(for: BundleToken.self)
        let models = try await ModelSetup.prepare { _, _ in }
        let batch = BatchTranscriber(models: models)
        try await batch.load()

        let url = try #require(bundle.url(forResource: "speech-short", withExtension: "m4a"))
        let decoded = try await AudioDecoder.decode(url)

        let started = ContinuousClock.now
        let text = try await batch.transcribe(decoded.samples)
        let d = ContinuousClock.now - started
        let ms = (Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18) * 1000

        print(String(format: "RELEASE PASS %.0f ms | %@", ms, text))
        #expect(text.localizedCaseInsensitiveContains("commit"))
    }
}
