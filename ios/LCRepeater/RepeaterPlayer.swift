import Foundation
import AVFoundation
import MediaPlayer
import Combine

@MainActor
final class RepeaterPlayer: ObservableObject {
    @Published private(set) var lessonID: UUID?
    @Published private(set) var lesson: Lesson?
    @Published private(set) var sentenceID: Int?
    @Published private(set) var repetition = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var phase = "재생을 눌러 시작하세요"
    @Published private(set) var progress = 0.0
    @Published var error: String?
    @Published var settings: StudySettings {
        didSet {
            guard settings.isValid else { settings = oldValue; return }
            if let data = try? JSONEncoder().encode(settings) {
                UserDefaults.standard.set(data, forKey: "study.settings")
            }
            guard settings != oldValue, lesson != nil else { return }
            let resume = isPlaying
            resetQueue()
            if !visibleSentences.contains(where: { $0.i == sentenceID }) {
                sentenceID = visibleSentences.first?.i
            }
            if resume { play(sentenceID: sentenceID) }
            else { phase = "재생을 눌러 시작하세요" }
        }
    }

    var visibleSentences: [Sentence] { lesson.map { settings.sentences(in: $0) } ?? [] }
    var currentSentence: Sentence? { lesson?.sentences.first { $0.i == sentenceID } }
    var position: Int { visibleSentences.firstIndex { $0.i == sentenceID } ?? 0 }

    private struct Slot {
        let id = UUID()
        let step: PlaybackStep
        let buffer: AVAudioPCMBuffer
        let start: AVAudioFramePosition
        let clipFrames: AVAudioFrameCount
        let key: String
    }
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var audioFile: AVAudioFile?
    private var cursor: PlaybackCursor?
    private var slots: [Slot] = []
    private var buffers: [String: (AVAudioPCMBuffer, AVAudioFrameCount)] = [:]
    private var nextFrame: AVAudioFramePosition = 0
    private var generation = UUID()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private var resumeAfterInterruption = false

    init() {
        if let data = UserDefaults.standard.data(forKey: "study.settings"),
           let saved = try? JSONDecoder().decode(StudySettings.self, from: data), saved.isValid {
            settings = saved
        } else {
            settings = StudySettings()
        }
        engine.attach(node)
        engine.attach(timePitch)
        configureRemoteCommands()
        observeAudioSession()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshDisplay() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func load(_ entry: LibraryEntry, audioURL: URL, savedSentence: Int?) {
        if lessonID == entry.id, lesson == entry.lesson { return }
        unload()
        do {
            let file = try AVAudioFile(forReading: audioURL, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard file.processingFormat.sampleRate == 32_000, file.processingFormat.channelCount == 1 else {
                throw LessonError.invalidAudio
            }
            audioFile = file
            engine.connect(node, to: timePitch, format: file.processingFormat)
            engine.connect(timePitch, to: engine.mainMixerNode, format: file.processingFormat)
            lessonID = entry.id
            lesson = entry.lesson
            sentenceID = visibleSentences.first(where: { $0.i == savedSentence })?.i ?? visibleSentences.first?.i
            updateNowPlaying()
        } catch {
            self.error = "음원을 열지 못했어요: \(error.localizedDescription)"
        }
    }

    func unload() {
        resetQueue()
        engine.stop()
        engine.disconnectNodeOutput(node)
        engine.disconnectNodeOutput(timePitch)
        audioFile = nil
        lesson = nil
        lessonID = nil
        sentenceID = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func toggle() {
        if isPlaying { pause() }
        else if !slots.isEmpty { resume() }
        else { play(sentenceID: sentenceID) }
    }

    func play(sentenceID requestedID: Int? = nil) {
        guard let lesson, audioFile != nil else { return }
        resetQueue()
        cursor = PlaybackCursor(lesson: lesson, settings: settings, sentenceID: requestedID ?? sentenceID)
        do {
            try activateSession()
            timePitch.rate = Float(settings.speed)
            try fillQueue()
            guard !slots.isEmpty else { return }
            if !engine.isRunning { try engine.start() }
            node.play()
            isPlaying = true
            refreshDisplay()
        } catch {
            fail(error)
        }
    }

    func pause() {
        node.pause()
        engine.pause()
        isPlaying = false
        phase = "일시정지"
        updateNowPlaying()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func resume() {
        do {
            try activateSession()
            if !engine.isRunning { try engine.start() }
            node.play()
            isPlaying = true
            refreshDisplay()
        } catch { fail(error) }
    }

    func move(_ offset: Int) {
        let sentences = visibleSentences
        let target = position + offset
        guard sentences.indices.contains(target) else { return }
        play(sentenceID: sentences[target].i)
    }

    private func resetQueue() {
        generation = UUID()  // stop() also invokes pending completion callbacks.
        node.stop()
        engine.pause()
        slots.removeAll()
        buffers.removeAll()
        cursor = nil
        nextFrame = 0
        isPlaying = false
        repetition = 0
        progress = 0
        phase = "재생을 눌러 시작하세요"
    }

    private func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
    }

    private func fillQueue() throws {
        guard var plan = cursor else { return }
        // Keep three cycles queued, including real PCM silence. Playback timing is
        // owned by the audio engine, while callbacks replenish the queue ahead of time.
        while slots.count < 3, let step = plan.next() {
            let key = "\(step.sentence.i):\(step.gapSeconds)"
            let (buffer, clipFrames): (AVAudioPCMBuffer, AVAudioFrameCount)
            if let cached = buffers[key] {
                (buffer, clipFrames) = cached
            } else {
                (buffer, clipFrames) = try makeBuffer(for: step)
                buffers[key] = (buffer, clipFrames)
            }
            let slot = Slot(step: step, buffer: buffer, start: nextFrame, clipFrames: clipFrames, key: key)
            nextFrame += AVAudioFramePosition(buffer.frameLength)
            slots.append(slot)
            let expectedGeneration = generation
            node.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) {
                [weak self] _ in
                // Never stop an AVAudioPlayerNode from its audio callback thread.
                Task { @MainActor [weak self] in self?.completed(slot.id, generation: expectedGeneration) }
            }
        }
        cursor = plan
    }

    private func makeBuffer(for step: PlaybackStep) throws -> (AVAudioPCMBuffer, AVAudioFrameCount) {
        guard let file = audioFile else { throw LessonError.invalidAudio }
        let format = file.processingFormat
        let start = max(0, AVAudioFramePosition((step.sentence.start * format.sampleRate).rounded()))
        let end = min(file.length, AVAudioFramePosition((step.sentence.end * format.sampleRate).rounded()))
        guard end > start else { throw LessonError.invalidAudio }
        let clipFrames = AVAudioFrameCount(end - start)
        // TimePitch changes the duration of silence too: compensate for its rate so
        // an explicit 1-second gap stays 1 second at both 0.7x and 1.3x.
        let gapFrames = AVAudioFrameCount((step.gapSeconds * settings.speed * format.sampleRate).rounded())
        guard let clip = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: clipFrames),
              let cycle = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: clipFrames + gapFrames),
              let destination = cycle.floatChannelData else { throw LessonError.invalidAudio }
        file.framePosition = start
        try file.read(into: clip, frameCount: clipFrames)
        guard clip.frameLength == clipFrames, let source = clip.floatChannelData else { throw LessonError.invalidAudio }
        cycle.frameLength = clipFrames + gapFrames
        let count = Int(clipFrames)
        let fade = min(Int(0.006 * format.sampleRate), count / 2)
        for channel in 0..<Int(format.channelCount) {
            destination[channel].initialize(repeating: 0, count: Int(cycle.frameLength))
            destination[channel].update(from: source[channel], count: count)
            if fade > 0 {
                for k in 0..<fade {
                    let gain = Float(k) / Float(fade)
                    destination[channel][k] *= gain
                    destination[channel][count - 1 - k] *= gain
                }
            }
        }
        return (cycle, clipFrames)
    }

    private func completed(_ id: UUID, generation expected: UUID) {
        guard generation == expected, let first = slots.first, first.id == id else { return }
        slots.removeFirst()
        do { try fillQueue() } catch { fail(error); return }
        let keys = Set(slots.map(\.key))
        buffers = buffers.filter { keys.contains($0.key) }
        if slots.isEmpty {
            sentenceID = first.step.sentence.i
            repetition = first.step.repetition
            isPlaying = false
            phase = "다 들었어요"
            progress = 1
            node.stop()
            engine.pause()
            updateNowPlaying()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } else if isPlaying {
            refreshDisplay()
        }
    }

    private func refreshDisplay() {
        guard isPlaying, let first = slots.first, let file = audioFile else { return }
        let frame = node.lastRenderTime.flatMap { node.playerTime(forNodeTime: $0)?.sampleTime } ?? first.start
        let slot = slots.first { frame < $0.start + AVAudioFramePosition($0.buffer.frameLength) } ?? first
        sentenceID = slot.step.sentence.i
        repetition = slot.step.repetition
        let localFrame = max(0, frame - slot.start)
        progress = min(1, Double(localFrame) / Double(slot.clipFrames))
        phase = localFrame < AVAudioFramePosition(slot.clipFrames) ? "재생 중" : "잠깐 쉬는 중"
        updateNowPlaying(elapsed: min(Double(localFrame) / file.processingFormat.sampleRate, slot.step.sentence.duration))
    }

    private func fail(_ cause: Error) {
        resetQueue()
        self.error = "재생하지 못했어요: \(cause.localizedDescription)"
        updateNowPlaying()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func updateNowPlaying(elapsed: Double = 0) {
        guard let lesson, let currentSentence else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: currentSentence.en,
            MPMediaItemPropertyArtist: "LC Repeater",
            MPMediaItemPropertyAlbumTitle: lesson.title,
            MPMediaItemPropertyPlaybackDuration: currentSentence.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? settings.speed : 0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
    }

    private func configureRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        func add(_ command: MPRemoteCommand, action: @escaping @MainActor (RepeaterPlayer) -> Void) {
            command.isEnabled = true
            let token = command.addTarget { [weak self] _ in
                Task { @MainActor [weak self] in if let self { action(self) } }
                return .success
            }
            remoteTargets.append((command, token))
        }
        add(commands.playCommand) { player in if !player.isPlaying { player.toggle() } }
        add(commands.pauseCommand) { player in if player.isPlaying { player.pause() } }
        add(commands.togglePlayPauseCommand) { $0.toggle() }
        add(commands.nextTrackCommand) { $0.move(1) }
        add(commands.previousTrackCommand) { $0.move(-1) }
        commands.changePlaybackPositionCommand.isEnabled = false
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) {
            [weak self] notification in
            let type = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let options = AVAudioSession.InterruptionOptions(
                rawValue: notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if type == .began {
                    self.resumeAfterInterruption = self.isPlaying
                    if self.isPlaying { self.pause() }
                } else if type == .ended {
                    if self.resumeAfterInterruption && options.contains(.shouldResume) { self.toggle() }
                    self.resumeAfterInterruption = false
                }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) {
            [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor [weak self] in
                if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                    self?.resumeAfterInterruption = false
                    self?.pause()
                }
            }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.engine.isRunning, !self.slots.isEmpty else { return }
                self.resetQueue()
                self.phase = "오디오 출력이 바뀌었어요. 재생을 다시 눌러 주세요."
                self.updateNowPlaying()
            }
        })
    }
}
