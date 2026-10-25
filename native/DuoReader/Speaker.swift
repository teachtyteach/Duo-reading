import Foundation
import AVFoundation
import MediaPlayer

/// Reads the book aloud with Apple's best installed voice. Keeps playing with the screen locked.
/// The text arrives one paragraph at a time, so the voice pauses between paragraphs like a person would.
final class Speaker: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    static let shared = Speaker()

    private let synthesizer = AVSpeechSynthesizer()
    private let sampler = AVSpeechSynthesizer()
    private var offsets: [AVSpeechUtterance: Int] = [:]
    private var lastUtterance: AVSpeechUtterance?
    private var title = ""
    private var author = ""

    override init() {
        super.init()
        synthesizer.delegate = self
        setUpRemoteControls()
    }

    // MARK: Reading

    struct Segment {
        let offset: Int
        let text: String
        let isHeading: Bool
    }

    func speak(segments: [Segment], rate: Double, voiceID: String, title: String, author: String) {
        self.title = title
        self.author = author
        activateAudio()

        sampler.stopSpeaking(at: .immediate)
        lastUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        offsets.removeAll()

        let voice = Speaker.voice(for: voiceID)
        let speechRate = Speaker.speechRate(rate)
        for (index, segment) in segments.enumerated() {
            let utterance = AVSpeechUtterance(string: segment.text)
            utterance.voice = voice
            utterance.rate = speechRate
            utterance.pitchMultiplier = 1.0
            utterance.volume = 1.0
            utterance.prefersAssistiveTechnologySettings = false
            utterance.preUtteranceDelay = index == 0 ? 0.05 : 0
            utterance.postUtteranceDelay = segment.isHeading ? 0.6 : 0.3
            offsets[utterance] = segment.offset
            lastUtterance = utterance
            synthesizer.speak(utterance)
        }
        if segments.isEmpty {
            NativeBridge.shared.send("window.duoSpeech && window.duoSpeech('done')")
        }
        updateNowPlaying(playing: true)
    }

    func pause() {
        synthesizer.pauseSpeaking(at: .word)
        updateNowPlaying(playing: false)
        NativeBridge.shared.send("window.duoSpeech && window.duoSpeech('paused')")
    }

    func resume() {
        if synthesizer.isPaused {
            synthesizer.continueSpeaking()
            updateNowPlaying(playing: true)
            NativeBridge.shared.send("window.duoSpeech && window.duoSpeech('playing')")
        }
    }

    func stop() {
        lastUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        sampler.stopSpeaking(at: .immediate)
        offsets.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Apple's slider is not linear. 0.5 is a normal pace; small steps above it get fast quickly.
    static func speechRate(_ speed: Double) -> Float {
        let base = Double(AVSpeechUtteranceDefaultSpeechRate)
        let value = speed >= 1 ? base + (speed - 1) * 0.2 : base - (1 - speed) * 0.45
        return Float(min(Double(AVSpeechUtteranceMaximumSpeechRate), max(Double(AVSpeechUtteranceMinimumSpeechRate), value)))
    }

    private func activateAudio() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [])
        try? session.setActive(true)
    }

    // MARK: Voices

    private static let favorites = ["Ava", "Zoe", "Evan", "Nathan", "Noelle", "Joelle", "Allison", "Tom", "Susan", "Samantha", "Serena", "Jamie", "Matilda", "Lee"]

    private static func isUsable(_ voice: AVSpeechSynthesisVoice) -> Bool {
        if voice.voiceTraits.contains(.isNoveltyVoice) { return false }
        if voice.identifier.lowercased().contains("eloquence") { return false }
        return true
    }

    private static func qualityName(_ voice: AVSpeechSynthesisVoice) -> String {
        if voice.voiceTraits.contains(.isPersonalVoice) { return "personal" }
        switch voice.quality {
        case .premium: return "premium"
        case .enhanced: return "enhanced"
        default: return "default"
        }
    }

    private static func score(_ voice: AVSpeechSynthesisVoice, language: String) -> Int {
        var value = 0
        switch voice.quality {
        case .premium: value += 300
        case .enhanced: value += 200
        default: value += 100
        }
        if voice.language == language { value += 20 }
        if let rank = favorites.firstIndex(of: voice.name) { value += 15 - rank }
        return value
    }

    static func englishVoices() -> [AVSpeechSynthesisVoice] {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let prefix = language.hasPrefix("en") ? "en" : String(language.prefix(2))
        return AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(prefix) && isUsable($0) }
    }

    static func bestVoice() -> AVSpeechSynthesisVoice? {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let pool = englishVoices().filter { !$0.voiceTraits.contains(.isPersonalVoice) }
        return pool.max(by: { score($0, language: language) < score($1, language: language) }) ?? AVSpeechSynthesisVoice(language: language)
    }

    static func voice(for id: String) -> AVSpeechSynthesisVoice? {
        if !id.isEmpty, let chosen = AVSpeechSynthesisVoice(identifier: id) { return chosen }
        return bestVoice()
    }

    func sendVoices() {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let voices = Speaker.englishVoices().sorted { Speaker.score($0, language: language) > Speaker.score($1, language: language) }
        let list: [[String: String]] = voices.map {
            ["id": $0.identifier, "name": $0.name, "lang": $0.language, "q": Speaker.qualityName($0)]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: list),
              let json = String(data: data, encoding: .utf8) else { return }
        NativeBridge.shared.send("window.duoVoices && window.duoVoices(\(json))")
    }

    func sample(voiceID: String) {
        if synthesizer.isSpeaking && !synthesizer.isPaused { pause() }
        sampler.stopSpeaking(at: .immediate)
        guard let voice = Speaker.voice(for: voiceID) else { return }
        activateAudio()
        let utterance = AVSpeechUtterance(string: "Hi, I’m \(voice.name). It was the best of times, it was the worst of times.")
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.prefersAssistiveTechnologySettings = false
        sampler.speak(utterance)
    }

    func requestPersonalVoice() {
        AVSpeechSynthesizer.requestPersonalVoiceAuthorization { status in
            DispatchQueue.main.async {
                var message = ""
                switch status {
                case .authorized:
                    let hasOne = AVSpeechSynthesisVoice.speechVoices().contains { $0.voiceTraits.contains(.isPersonalVoice) }
                    if !hasOne { message = "No Personal Voice yet. Make one in Settings → Accessibility → Personal Voice." }
                case .denied:
                    message = "Personal Voice is turned off for Duo Reader. Turn it on in Settings → Accessibility → Personal Voice."
                case .unsupported:
                    message = "This iPhone doesn’t support Personal Voice."
                default:
                    break
                }
                Speaker.shared.sendVoices()
                if !message.isEmpty {
                    NativeBridge.shared.send("window.duoVoiceMsg && window.duoVoiceMsg(\(NativeBridge.js(message)))")
                }
            }
        }
    }

    // MARK: Delegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        guard synthesizer === self.synthesizer, let base = offsets[utterance] else { return }
        let start = base + characterRange.location
        NativeBridge.shared.send("window.duoSpeech && window.duoSpeech('range', \(start), \(characterRange.length))")
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard synthesizer === self.synthesizer else { return }
        offsets.removeValue(forKey: utterance)
        if utterance === lastUtterance {
            lastUtterance = nil
            NativeBridge.shared.send("window.duoSpeech && window.duoSpeech('done')")
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        offsets.removeValue(forKey: utterance)
    }

    // MARK: Lock screen controls

    private func setUpRemoteControls() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            self?.resume()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if self.synthesizer.isPaused { self.resume() } else { self.pause() }
            return .success
        }
    }

    private func updateNowPlaying(playing: Bool) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title.isEmpty ? "Duo Reader" : title,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0
        ]
        if !author.isEmpty { info[MPMediaItemPropertyArtist] = author }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
