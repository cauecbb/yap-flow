import AppKit

protocol SoundPlaying {
    func playStart()
    func playStop()
    func playLock()
}

extension SoundPlaying {
    func playLock() {}
}

final class SystemSoundPlayer: SoundPlaying {
    /// Evaluated at call time so the setting can be toggled live.
    var enabled: () -> Bool = { true }

    // Custom cues dropped into Sources/Resources/Sounds before building win (not
    // committed: bring your own). Then the soft taps in DefaultSounds, generated
    // by Tools/generate-sounds.py. The system sounds are the last resort: "Purr"
    // is warm and gentle; "Glass" is a crisp finish. Deliberately avoiding
    // Tink/Basso/Sosumi/Funk, which macOS uses for alerts and errors — they make
    // a normal start-of-dictation feel like something went wrong.
    private let start = SystemSoundPlayer.bundled("dictation-start")
        ?? SystemSoundPlayer.bundled("yap-start") ?? NSSound(named: NSSound.Name("Purr"))
    private let stop = SystemSoundPlayer.bundled("dictation-stop")
        ?? SystemSoundPlayer.bundled("yap-stop") ?? NSSound(named: NSSound.Name("Glass"))
    private let lock = SystemSoundPlayer.bundled("dictation-lock")
        ?? SystemSoundPlayer.bundled("yap-lock") ?? NSSound(named: NSSound.Name("Pop"))

    func playStart() { play(start) }

    func playStop() { play(stop) }

    /// Hands-free lock: a tap of fn, or fn+space while holding it.
    func playLock() { play(lock) }

    private func play(_ sound: NSSound?) {
        guard enabled() else { return }
        sound?.stop()
        sound?.play()
    }

    private static func bundled(_ name: String) -> NSSound? {
        let url = Bundle.main.url(forResource: name, withExtension: "wav")
            ?? Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "Sounds")
        return url.flatMap { NSSound(contentsOf: $0, byReference: true) }
    }
}
