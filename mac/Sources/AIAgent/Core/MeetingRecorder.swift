import AVFoundation
import CoreAudio
import Foundation
import Observation
import Speech

/// Mac で鳴っている音声（会議アプリの相手の声など）を、macOS のプロセスタップで取り出して文字起こしする。
/// 自分のアプリの読み上げは取り込まない。必要な許可は「システムオーディオの録音」だけ（画面収録は不要）。
final class SystemAudioTranscriber: @unchecked Sendable {
    struct SetupError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var tapFormat: AVAudioFormat?
    private var targetFormat: AVAudioFormat?
    private let queue = DispatchQueue(label: "AIAgent.systemAudio")

    /// locale は聞き取る言語。会議の記録は日本語、字幕では相手の言語を指定する
    func start(locale: Locale = Locale(identifier: "ja-JP"), assetStatus: (@MainActor (String) -> Void)? = nil,
               onFinal: @escaping @MainActor (String) -> Void) async throws {
        // 1) 自分のプロセスを除いた、Mac 全体の音声のタップを作る
        var pid = getpid()
        var own = AudioObjectID(kAudioObjectUnknown)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &own)
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: own == kAudioObjectUnknown ? [] : [own])
        desc.uuid = UUID()
        desc.name = "AIエージェント 会議記録"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var status = AudioHardwareCreateProcessTap(desc, &tapID)
        guard status == noErr else {
            throw SetupError(message: "Mac の音声を取り込めません。システム設定 → プライバシーとセキュリティ → 画面収録とシステムオーディオ録音 で許可してください（\(status)）")
        }

        addr.mSelector = kAudioTapPropertyFormat
        var asbd = AudioStreamBasicDescription()
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            await stop()
            throw SetupError(message: "音声の形式を取得できません（\(status)）")
        }
        tapFormat = format

        // 2) タップを読み出すための、非公開の集約デバイスを作る
        let outputUID = try Self.defaultOutputUID()
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AIAgent-MeetingTap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        status = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggregateID)
        guard status == noErr else {
            await stop()
            throw SetupError(message: "音声の取り込み口を作れません（\(status)）")
        }

        // 3) 音声認識（確定した文だけを受け取る）
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            await assetStatus?("音声認識モデルをダウンロード中…")
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            await stop()
            throw SetupError(message: "音声認識の形式を取得できません")
        }
        targetFormat = target
        converter = AVAudioConverter(from: format, to: target)
        try await analyzer.prepareToAnalyze(in: target)
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        continuation = cont
        resultsTask = Task {
            do {
                for try await r in transcriber.results where r.isFinal {
                    let text = String(r.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { await onFinal(text) }
                }
            } catch {}
        }
        try await analyzer.start(inputSequence: stream)

        // 4) 読み出し開始
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            self?.process(input)
        }
        guard status == noErr else {
            await stop()
            throw SetupError(message: "音声の読み出しを始められません（\(status)）")
        }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            await stop()
            throw SetupError(message: "音声の読み出しを始められません（\(status)）")
        }
    }

    private func process(_ list: UnsafePointer<AudioBufferList>) {
        guard let tapFormat, let targetFormat, let converter, let continuation,
              let buffer = AVAudioPCMBuffer(pcmFormat: tapFormat, bufferListNoCopy: list, deallocator: nil),
              buffer.frameLength > 0 else { return }
        let ratio = targetFormat.sampleRate / tapFormat.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, out.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: out)) }
    }

    func stop() async {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        procID = nil
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        continuation?.finish()
        continuation = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        analyzer = nil
        await resultsTask?.value
        resultsTask = nil
    }

    private static func defaultOutputUID() throws -> String {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr else {
            throw SetupError(message: "出力デバイスが見つかりません")
        }
        addr.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &uid) == noErr, let s = uid?.takeRetainedValue() else {
            throw SetupError(message: "出力デバイスの ID を取得できません")
        }
        return s as String
    }
}

/// 会議の記録。発言を時刻つきで貯め、議事録ファイルに少しずつ書き込む（途中でアプリが落ちても残る）
@MainActor @Observable
final class MeetingRecorder {
    struct Segment {
        let time: Date
        let speaker: String  // "自分" | "相手"
        let text: String
    }

    static let folder: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/AIエージェント/議事録")

    private(set) var isRecording = false
    private(set) var startedAt: Date?
    private(set) var segments: [Segment] = []
    private(set) var fileURL: URL?
    private let system = SystemAudioTranscriber()

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func start() async throws {
        guard !isRecording else { return }
        let now = Date()
        let nameFmt = DateFormatter()
        nameFmt.dateFormat = "yyyy-MM-dd_HHmm"
        let titleFmt = DateFormatter()
        titleFmt.locale = Locale(identifier: "ja_JP")
        titleFmt.dateFormat = "yyyy年M月d日(E) H:mm"
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let url = Self.folder.appendingPathComponent("\(nameFmt.string(from: now))_会議.md")
        try "# 会議メモ \(titleFmt.string(from: now))\n\n## 文字起こし\n\n".write(to: url, atomically: true, encoding: .utf8)
        segments = []
        fileURL = url
        startedAt = now
        try await system.start { [weak self] text in self?.add(speaker: "相手", text: text) }
        isRecording = true
    }

    /// マイク側（自分の声）の確定した文を加える
    func add(speaker: String, text: String) {
        guard isRecording || speaker == "相手" else { return }
        let seg = Segment(time: Date(), speaker: speaker, text: text)
        segments.append(seg)
        append("- [\(Self.timeFmt.string(from: seg.time))] **\(speaker)**: \(text)\n")
    }

    /// 記録を止めて、文字起こし全文を返す
    func stop() async -> String {
        guard isRecording else { return "" }
        isRecording = false
        await system.stop()
        return transcript
    }

    var transcript: String {
        segments.map { "[\(Self.timeFmt.string(from: $0.time))] \($0.speaker): \($0.text)" }.joined(separator: "\n")
    }

    /// 要約を議事録ファイルの先頭側（見出しの下）に書き足す
    func writeSummary(_ markdown: String) {
        guard let url = fileURL, var body = try? String(contentsOf: url, encoding: .utf8) else { return }
        if let r = body.range(of: "## 文字起こし") {
            body.insert(contentsOf: markdown.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n", at: r.lowerBound)
        }
        try? body.write(to: url, atomically: true, encoding: .utf8)
    }

    private func append(_ line: String) {
        guard let url = fileURL, let h = try? FileHandle(forWritingTo: url) else { return }
        h.seekToEndOfFile()
        h.write(Data(line.utf8))
        try? h.close()
    }
}
