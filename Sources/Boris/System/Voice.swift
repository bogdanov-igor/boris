import AppKit
import BorisCore

/// Plays the walrus's short sounds. A new sound always cuts the previous one.
/// It plays what it is told: how often a notification may sound is decided in `NotificationRouter`.
@MainActor
final class Voice {
    private var current: NSSound?
    var volume: () -> Double = { 0.6 }

    func play(_ sound: WalrusSound) {
        current?.stop()
        guard let url = Bundle.main.url(forResource: sound.rawValue, withExtension: "caf"), let player = NSSound(contentsOf: url, byReference: true) else { return }
        player.volume = Float(volume())
        player.play()
        current = player
    }
}
