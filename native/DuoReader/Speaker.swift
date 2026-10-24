import Foundation
import AVFoundation
import MediaPlayer

/// Reads the book aloud with Apple's best installed voice. Keeps playing with the screen locked.
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = Speaker()

    private let synthesizer = AVSpeechSynthesizer()
    private var baseOffset = 0
    private var stoppedOnPurpose = false
    private var title = ""
    private var author = ""

    override init() {
        super.init()
        synthesizer.delegate = self
        setUpRemoteControls()
    }

    func speak(text: String, offset: Int, rate: Double, title: String, author: String) {
        baseOffset = offset
        self.title = title
        self.author = author

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [])
        try? session.setActive(true)

        stoppedOnPurpose = true
        synthesizer.stopSpeaking(at: .immediate)
        stoppedOnPurpose = false

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Speaker.bestVoice()
        utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate, Float(rate) * AVSpeechUtteranceDefaultSpeechRate)
        utterance.prefersAssistiveTechnologySettings = false
        synthesizer.speak(utterance)
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
        stoppedOnPurpose = true
        synthesizer.stopSpeaking(at: .immediate)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    static func bestVoice() -> AVSpeechSynthesisVoice? {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let prefix = String(language.prefix(2))
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(prefix) }
        let exact = voices.filter { $0.language == language }
        for pool in [exact, voices] {
            if let premium = pool.first(where: { $0.quality == .premium }) { return premium }
            if let enhanced = pool.first(where: { $0.quality == .enhanced }) { return enhanced }
        }
        return AVSpeechSynthesisVoice(language: language)
    }

    // MARK: Delegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        let start = baseOffset + characterRange.location
        NativeBridge.shared.send("window.duoSpeech && window.duoSpeech('range', \(start), \(characterRange.length))")
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        if !stoppedOnPurpose {
            NativeBridge.shared.send("window.duoSpeech && window.duoSpeech('done')")
        }
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
