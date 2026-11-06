import Foundation

public struct BackgroundMusic: Codable, Equatable, Identifiable {
    public var id=UUID()
    public var path: String
    public var sourceDuration: Int64
    public var sourceStart: Int64 = 0
    public var sourceEnd: Int64
    public var start: Int64 = 0
    public var volume: Double = 0.3
    public var duration: Int64 { sourceEnd-sourceStart }
    public init(path: String,duration: Int64) { self.path=path; sourceDuration=duration; sourceEnd=duration }
}
extension Project {
    public var timelineExtent: Int64 { max(duration,music.map { $0.start+$0.duration }.max() ?? 0) }
    public var music: [BackgroundMusic] { backgroundMusic ?? [] }
    public var isVideoMuted: Bool { muteVideoAudio ?? false }
    public func validateMusic() throws {
        guard Set(music.map(\.id)).count == music.count else { throw SubtitleError.invalid(L("背景音乐 ID 重复")) }
        for m in music {
            guard !m.path.isEmpty,m.sourceDuration>0,m.sourceDuration<1_000_000_000_000,m.sourceStart>=0,m.sourceEnd>m.sourceStart,m.sourceEnd<=m.sourceDuration,m.start>=0,m.start<1_000_000_000_000,m.volume.isFinite,(0...1).contains(m.volume) else { throw SubtitleError.invalid(L("背景音乐时间或音量无效")) }
        }
    }
}

extension Project {
    /// No video, only audio: subtitles (lyrics) are timed against the audio on the timeline.
    public var isAudioOnly: Bool { videoPath.isEmpty && allClips.isEmpty && !music.isEmpty }
    /// Without video, `duration` is the end of the last audio clip; cues past it are trimmed or dropped.
    /// Projects with video keep the video-defined duration unchanged.
    public func syncingAudioOnlyDuration() -> Project {
        guard videoPath.isEmpty,allClips.isEmpty else { return self }
        var next=self; next.duration=music.map { $0.start+$0.duration }.max() ?? 0
        guard next.duration < duration else { return next }
        next.cues=cues.compactMap { cue in
            guard cue.start<next.duration else { return nil }
            var value=cue; value.end=min(value.end,next.duration); return value
        }
        return next
    }
}

extension Project {
    /// Music cuts preserve absolute timeline positions and never ripple video/subtitles.
    public func cuttingMusic(_ id: UUID,at time: Int64,removeBefore: Bool? = nil) throws -> Project {
        guard let index=music.firstIndex(where:{$0.id == id}) else { throw SubtitleError.invalid(L("请先选择音乐片段")) }
        let original=music[index]
        guard time>original.start,time<min(duration,original.start+original.duration) else { throw SubtitleError.invalid(L("请将播放头放在音乐片段内部")) }
        var next=self; var list=music; let sourceCut=original.sourceStart+time-original.start
        if let removeBefore {
            if removeBefore { list[index].sourceStart=sourceCut; list[index].start=time }
            else { list[index].sourceEnd=sourceCut }
        } else {
            list[index].sourceEnd=sourceCut
            var right=original; right.id=UUID(); right.start=time; right.sourceStart=sourceCut
            list.insert(right,at:index+1)
        }
        next.backgroundMusic=list; try next.validate(); return next
    }
}
