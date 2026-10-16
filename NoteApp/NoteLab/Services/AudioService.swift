import AVFoundation
import SwiftUI

/// 강의 녹음 + 필기 동기화 재생
///
/// - CAF 컨테이너로 녹음해서, 앱이 강제 종료돼도 그때까지 녹음된 내용이 남는다.
/// - 녹음 시작 즉시 메타데이터를 저장하고, 다시 열 때 길이를 복구한다.
/// - 백그라운드 오디오 모드라 다른 앱으로 넘어가도 녹음이 이어진다.
/// - 각 필기 획에는 PencilKit이 기록한 생성 시각이 있어서, 획을 탭하면 그 시점으로 이동한다.
@MainActor
final class AudioService: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    /// 지금 녹음 중이거나 재생 대상인 녹음
    @Published private(set) var activeRecording: Recording?
    @Published var errorMessage: String?

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private weak var doc: NotebookDocument?
    private var interruptionObserver: NSObjectProtocol?

    init(doc: NotebookDocument) {
        self.doc = doc
        super.init()
        repairRecordings()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor in self?.handleInterruption(raw) }
        }
    }

    deinit {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
    }

    // MARK: 녹음

    func startRecording() {
        guard !isRecording else { return }
        AVAudioApplication.requestRecordPermission { granted in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if granted {
                    self.beginRecording()
                } else {
                    self.errorMessage = "마이크 권한이 필요합니다. 설정 앱 > NoteLab에서 허용해 주세요."
                }
            }
        }
    }

    private func beginRecording() {
        guard let doc else { return }
        stopPlayback()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            try session.setActive(true)
            let file = "rec-\(UUID().uuidString).caf"
            let url = Storage.recordingFile(doc.id, name: file)
            Storage.ensureParent(url)
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let rec = try AVAudioRecorder(url: url, settings: settings)
            rec.delegate = self
            guard rec.record() else {
                errorMessage = "녹음을 시작할 수 없습니다."
                return
            }
            let start = Date()
            let recording = Recording(file: file, startDate: start, duration: 0,
                                      title: Format.dateTime.string(from: start))
            doc.addRecording(recording)
            doc.saveNow()
            recorder = rec
            activeRecording = recording
            isRecording = true
            currentTime = 0
            startTimer()
        } catch {
            errorMessage = "녹음 오류: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        guard isRecording, let rec = recorder, var recording = activeRecording else { return }
        let length = max(rec.currentTime, Date().timeIntervalSince(recording.startDate))
        rec.stop()
        recorder = nil
        isRecording = false
        recording.duration = length
        doc?.updateRecording(recording)
        doc?.saveNow()
        activeRecording = recording
        duration = length
        currentTime = 0
        stopTimer()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func handleInterruption(_ raw: UInt?) {
        guard let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .ended, isRecording {
            try? AVAudioSession.sharedInstance().setActive(true)
            recorder?.record()
        }
        if type == .began, isPlaying {
            isPlaying = false
        }
    }

    /// 비정상 종료로 길이가 0으로 남은 녹음을 복구
    private func repairRecordings() {
        guard let doc else { return }
        for r in doc.notebook.recordings where r.duration <= 0 {
            let url = Storage.recordingFile(doc.id, name: r.file)
            var fixed = r
            if let p = try? AVAudioPlayer(contentsOf: url) {
                fixed.duration = p.duration
                doc.updateRecording(fixed)
            }
        }
    }

    // MARK: 재생

    func play(_ recording: Recording, at offset: TimeInterval? = nil) {
        guard !isRecording, let doc else { return }
        do {
            if activeRecording?.id != recording.id || player == nil {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .spokenAudio)
                try session.setActive(true)
                let p = try AVAudioPlayer(contentsOf: Storage.recordingFile(doc.id, name: recording.file))
                p.delegate = self
                p.enableRate = true
                p.prepareToPlay()
                player = p
                activeRecording = recording
                duration = p.duration
            }
            if let offset { player?.currentTime = max(0, min(offset, duration)) }
            player?.play()
            isPlaying = true
            currentTime = player?.currentTime ?? 0
            startTimer()
        } catch {
            errorMessage = "재생 오류: \(error.localizedDescription)"
        }
    }

    func togglePlay() {
        if isPlaying {
            player?.pause()
            isPlaying = false
        } else if let r = activeRecording {
            play(r)
        }
    }

    func seek(to t: TimeInterval) {
        player?.currentTime = max(0, min(t, duration))
        currentTime = player?.currentTime ?? t
    }

    func skip(_ delta: TimeInterval) { seek(to: currentTime + delta) }

    var rate: Float {
        get { player?.rate ?? 1 }
        set { player?.rate = newValue; objectWillChange.send() }
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        isPlaying = false
        if !isRecording {
            activeRecording = nil
            stopTimer()
        }
    }

    /// 획의 생성 시각으로 해당 녹음 위치 재생. 성공하면 true.
    @discardableResult
    func playMoment(_ date: Date) -> Bool {
        guard let doc, !isRecording else { return false }
        guard let rec = doc.notebook.recordings.first(where: {
            date >= $0.startDate.addingTimeInterval(-1) && date <= $0.endDate.addingTimeInterval(1)
        }) else { return false }
        play(rec, at: date.timeIntervalSince(rec.startDate) - 2)
        return true
    }

    /// 재생 위치에 해당하는 실제 시각 (필기 하이라이트에 사용)
    var playbackDate: Date? {
        guard let r = activeRecording, !isRecording else { return nil }
        return r.startDate.addingTimeInterval(currentTime)
    }

    // MARK: 타이머

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        if isRecording, let r = activeRecording {
            currentTime = Date().timeIntervalSince(r.startDate)
        } else if let p = player {
            currentTime = p.currentTime
            if !p.isPlaying && isPlaying { isPlaying = false }
        }
    }
}

extension AudioService: AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.currentTime = self.duration
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            self.errorMessage = "녹음 인코딩 오류가 발생했습니다."
            self.stopRecording()
        }
    }
}
