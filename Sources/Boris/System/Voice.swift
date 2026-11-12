import AppKit
import BorisCore

/// What actually makes the sound. A test puts a fake here, because a check must never make a noise.
@MainActor
protocol SoundOutput: AnyObject {
    /// A new sound cuts the previous one. False means nothing came out.
    func play(_ sound: WalrusSound, volume: Double) -> Bool
    /// A file of the person's own, for a secret word.
    func play(file: URL, volume: Double) -> Bool
}

extension SoundOutput {
    func play(file: URL, volume: Double) -> Bool { false }
}

@MainActor
final class Speakers: SoundOutput {
    private var current: NSSound?

    func play(_ sound: WalrusSound, volume: Double) -> Bool {
        current?.stop()
        guard let url = Bundle.main.url(forResource: sound.rawValue, withExtension: "caf"), let player = NSSound(contentsOf: url, byReference: true) else { return false }
        player.volume = Float(volume)
        current = player
        return player.play()
    }

    func play(file: URL, volume: Double) -> Bool {
        current?.stop()
        guard let player = NSSound(contentsOf: file, byReference: true) else { return false }
        player.volume = Float(volume)
        current = player
        return player.play()
    }
}

/// Plays the walrus's short sounds. It plays what it is told: how often a notification may sound is decided in `NotificationRouter`.
@MainActor
final class Voice {
    private let output: any SoundOutput
    var volume: () -> Double = { 0.6 }

    init(output: any SoundOutput = Speakers()) {
        self.output = output
    }

    func play(_ sound: WalrusSound) {
        AppLog.note(output.play(sound, volume: volume()) ? .soundPlayed : .soundFailed, .choice(sound))
    }

    /// The file's name stays out of the log: it is the person's own.
    func play(file: URL) {
        AppLog.note(output.play(file: file, volume: volume()) ? .soundPlayed : .soundFailed, .word(.secretWordSound))
    }
}
