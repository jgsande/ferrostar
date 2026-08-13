import AVFoundation
import Combine
import FerrostarCoreFFI
import Foundation

/// An Spoken instruction provider that triggers speech synthesis in response to navigation events.
///
/// Automatically handles audio session management,
/// including ducking volume from other apps when appropriate.
public class SpokenInstructionObserver {
    @Published public private(set) var isMuted: Bool

    let synthesizer: SpeechSynthesizer
    private let audioManager = AudioSessionManager()
    private var audioFocusReleaseTask: Task<Void, Never>?

    /// FORK ADDITION: when `false`, this observer performs NO `AVAudioSession` work at all —
    /// no focus request before an utterance, no deferred release after one. The host then owns the
    /// session outright and may hold it active for a whole navigation session.
    ///
    /// Why a host would want that: the default per-utterance activate/deactivate means the system has
    /// no active playback session between announcements, so the hardware volume buttons fall back to
    /// adjusting ringer volume. The rider can only change guidance volume during the few seconds an
    /// announcement is actually playing.
    ///
    /// Defaults to `true`, so upstream behaviour is byte-identical unless a host opts out.
    private let managesAudioSession: Bool

    /// When `true`, an instruction's plain `text` is spoken in preference to its `ssml`, so the
    /// utterance carries the host's prosody settings. Defaults to `false`.
    private let prefersPlainText: Bool

    /// Creates a spoken instruction observer with any ``SpeechSynthesizer``.
    ///
    /// - Parameters:
    ///   - synthesizer: The speech synthesizer.
    ///   - isMuted: Whether the speech synthesizer is currently muted. Assume false if unknown.
    ///   - managesAudioSession: Whether this observer owns the `AVAudioSession` lifecycle. Pass `false`
    /// to take ownership in the host (see the property docs above).
    ///   - prefersPlainText: Whether to speak an instruction's plain text in preference to its SSML.
    public init(
        synthesizer: SpeechSynthesizer,
        isMuted: Bool,
        managesAudioSession: Bool = true,
        prefersPlainText: Bool = false
    ) {
        self.synthesizer = synthesizer
        self.isMuted = isMuted
        self.managesAudioSession = managesAudioSession
        self.prefersPlainText = prefersPlainText
    }

    deinit {
        audioFocusReleaseTask?.cancel()
        // NOTE: The audioFocusReleaseTask will deinit itself
    }

    public func spokenInstructionTriggered(_ instruction: FerrostarCoreFFI.SpokenInstruction) {
        guard !isMuted else {
            return
        }

        Task {
            if managesAudioSession {
                cancelAudioFocusRelease()
                await audioManager.requestAudioFocus()
            }

            let utterance: AVSpeechUtterance = if !prefersPlainText,
                                                  #available(iOS 16.0, *),
                                                  let ssml = instruction.ssml,
                                                  let ssmlUtterance = AVSpeechUtterance(ssmlRepresentation: ssml)
            {
                ssmlUtterance
            } else {
                AVSpeechUtterance(string: instruction.text)
            }

            self.synthesizer.speak(utterance)
            scheduleAudioFocusRelease()
        }
    }

    /// Toggle the mute.
    public func toggleMute() {
        let isCurrentlyMuted = isMuted
        isMuted = !isCurrentlyMuted

        // This used to have `synthesizer.isSpeaking`, but I think we want to run it regardless.
        if isMuted {
            stopAndClearQueue()
        }
    }

    public func stopAndClearQueue() {
        Task {
            synthesizer.stopSpeaking(at: .immediate)
            if managesAudioSession {
                await audioManager.releaseAudioFocus()
            }
        }
    }

    func scheduleAudioFocusRelease() {
        guard managesAudioSession else { return }
        cancelAudioFocusRelease()

        audioFocusReleaseTask = Task { [weak self] in
            // Wait at least 500ms; then keep waiting until either:
            //   - The task is cancelled
            //   - The synthesizer is no longer speaking
            repeat {
                try? await Task.sleep(nanoseconds: 500 * NSEC_PER_MSEC)
            } while !Task.isCancelled && self?.synthesizer.isSpeaking ?? false

            guard !Task.isCancelled else {
                return
            }

            // Release audio focus (unduck other sources) once we're done speaking
            await self?.audioManager.releaseAudioFocus()
        }
    }

    private func cancelAudioFocusRelease() {
        audioFocusReleaseTask?.cancel()
        audioFocusReleaseTask = nil
    }
}

public extension SpokenInstructionObserver {
    /// Create a new spoken instruction observer with AFFoundation's AVSpeechSynthesizer.
    ///
    /// - Parameters:
    ///    - synthesizer: An instance of AVSpeechSynthesizer. One is provided by default, but you can inject your own.
    ///    - isMuted: If the synthesizer is muted. This should be false unless you're providing a "hot" synth that is
    /// speaking.
    /// - Returns: The instance of SpokenInstructionObserver
    static func initAVSpeechSynthesizer(synthesizer: AVSpeechSynthesizer = AVSpeechSynthesizer(),
                                        isMuted: Bool = false) -> SpokenInstructionObserver
    {
        SpokenInstructionObserver(synthesizer: synthesizer, isMuted: isMuted)
    }
}
