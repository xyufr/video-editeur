import Foundation

public struct ClipEffects: Codable, Equatable {
    public var brightness: Double = 0
    public var contrast: Double = 1
    public var saturation: Double = 1
    public var fadeIn: Int64 = 0
    public var fadeOut: Int64 = 0
    public init() {}
}
public struct VideoEraseRegion: Codable, Equatable, Identifiable {
    public var id=UUID()
    /// Normalized output-frame coordinates, origin at bottom left.
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var sourceStart: Int64
    public var sourceEnd: Int64
    /// nil samples the background strip just inside the bottom edge every frame.
    public var color: RGBA?
    public init(x: Double,y: Double,width: Double,height: Double,sourceStart: Int64,sourceEnd: Int64,color: RGBA? = nil) {
        self.x=x; self.y=y; self.width=width; self.height=height; self.sourceStart=sourceStart; self.sourceEnd=sourceEnd; self.color=color
    }
}
public struct VideoClip: Codable, Equatable, Identifiable {
    public var id: UUID
    public var path: String
    public var sourceDuration: Int64
    public var sourceStart: Int64
    public var sourceEnd: Int64
    /// Empty time before this main-track clip. Legacy projects default to zero.
    public var timelineGap: Int64?
    public var gap: Int64 { timelineGap ?? 0 }
    /// Cross dissolve into this clip; zero means a straight cut.
    public var transition: Int64 = 0
    public var effects = ClipEffects()
    public var eraseRegions: [VideoEraseRegion]?
    /// Split-screen cell; nil fills the whole canvas as before.
    public var frame: VideoFrame?
    /// Cut-away edges of the source picture; nil keeps the whole picture.
    public var crop: VideoCrop?
    public var duration: Int64 { sourceEnd-sourceStart }
    public init(id: UUID = UUID(), path: String, duration: Int64) {
        self.id=id; self.path=path; sourceDuration=duration; sourceStart=0; sourceEnd=duration
    }
}
public struct ClipPlacement {
    public let clip: VideoClip
    public let start: Int64
    public var end: Int64 { start+clip.duration }
}
extension Project {
    public var clips: [VideoClip] {
        videoClips ?? (videoPath.isEmpty || duration <= 0 ? [] : [VideoClip(id:UUID(uuidString:"00000000-0000-0000-0000-000000000001")!,path:videoPath,duration:duration)])
    }
    public var placements: [ClipPlacement] {
        var cursor: Int64=0
        return clips.enumerated().map { i,clip in
            let start=cursor+clip.gap-(i == 0 ? 0 : clip.transition)
            cursor=start+clip.duration
            return ClipPlacement(clip:clip,start:start)
        }
    }
    public func validateClips() throws {
        let clips=self.clips
        guard Set(clips.map(\.id)).count == clips.count else { throw SubtitleError.invalid(L("视频片段 ID 重复")) }
        for (i,c) in clips.enumerated() {
            let regions=c.eraseRegions ?? []
            guard Set(regions.map(\.id)).count == regions.count else { throw SubtitleError.invalid(L("去字区域 ID 重复")) }
            for region in regions {
                guard [region.x,region.y,region.width,region.height].allSatisfy({$0.isFinite}),
                      region.x>=0,region.y>=0,region.width>0,region.height>0,
                      region.x+region.width<=1.000001,region.y+region.height<=1.000001,
                      region.sourceStart>=0,region.sourceEnd>region.sourceStart,region.sourceEnd<=c.sourceDuration else { throw SubtitleError.invalid(L("去字区域或生效时间无效")) }
                if let color=region.color,!([color.r,color.g,color.b,color.a].allSatisfy{$0.isFinite && (0...1).contains($0)}) { throw SubtitleError.invalid(L("去字背景颜色无效")) }
            }
            guard c.frame?.isValid ?? true else { throw SubtitleError.invalid(L("分屏画面位置无效")) }
            guard c.crop?.isValid ?? true else { throw SubtitleError.invalid(L("裁切范围无效：每边 0–45%，上下或左右合计不超过 90%")) }
            let e=c.effects
            guard c.gap>=0,c.gap<1_000_000_000,(c.transition == 0 || c.gap == 0),!c.path.isEmpty,c.sourceDuration>0,c.sourceStart>=0,c.sourceEnd<=c.sourceDuration,c.duration>0,
                  c.transition>=0,c.transition <= c.duration/2,
                  (i == 0 ? c.transition == 0 : c.transition <= clips[i-1].duration/2),
                  e.brightness.isFinite,(-1...1).contains(e.brightness),e.contrast.isFinite,(0...2).contains(e.contrast),
                  e.saturation.isFinite,(0...2).contains(e.saturation),e.fadeIn>=0,e.fadeOut>=0,e.fadeIn+e.fadeOut<=c.duration else {
                throw SubtitleError.invalid(L("视频裁剪或特效参数无效：叠化不能超过相邻片段一半，淡入淡出不能超过片段时长"))
            }
        }
        if videoClips != nil {
            guard videoDuration == duration else { throw SubtitleError.invalid(L("剪辑时间轴长度不一致")) }
        }
    }
    /// Ripple edit: carry captions with their source clip. During a dissolve,
    /// caption ownership switches at the midpoint so same-language cues never overlap.
    public func replacingClips(_ clips: [VideoClip], origins: [UUID:UUID] = [:]) throws -> Project {
        var next=self; next.videoClips=clips; next.videoPath=next.allClips.first?.path ?? ""
        next.duration=next.videoDuration
        try next.validateClips()
        let old=placements, new=next.placements
        func visible(_ placements: [ClipPlacement],_ i: Int) -> (Int64,Int64) {
            let p=placements[i]
            return (p.start+p.clip.transition/2,p.end-(i+1<placements.count ? placements[i+1].clip.transition/2 : 0))
        }
        var mapped: [Cue]=[],used=Set<UUID>()
        for (i,p) in new.enumerated() {
            guard let j=old.firstIndex(where:{$0.clip.id == (origins[p.clip.id] ?? p.clip.id)}) else { continue }
            let before=old[j], oldVisible=visible(old,j), newVisible=visible(new,i)
            for cue in cues {
                let a=max(cue.start,oldVisible.0), b=min(cue.end,oldVisible.1)
                guard b>a else { continue }
                let offset=p.start-p.clip.sourceStart-before.start+before.clip.sourceStart
                let start=max(newVisible.0,a+offset),end=min(newVisible.1,b+offset)
                guard end>start else { continue }
                var c=cue; c.start=start; c.end=end
                if used.contains(c.id) { c.id=UUID() }; used.insert(c.id); mapped.append(c)
            }
        }
        let oldMainEnd=old.last?.end ?? 0
        let tailOffset=(new.last?.end ?? 0)-oldMainEnd
        for cue in cues where cue.end>oldMainEnd {
            var tail=cue; tail.start=max(cue.start,oldMainEnd)+tailOffset; tail.end=min(cue.end+tailOffset,next.duration)
            guard tail.end>tail.start else { continue }
            if used.contains(tail.id) { tail.id=UUID() }; used.insert(tail.id); mapped.append(tail)
        }
        next.cues=mapped.sorted{$0.start<$1.start}
        try next.validate(); return next
    }
    public func movingMainClip(_ id: UUID,to time: Int64) throws -> Project {
        guard !isVideoLocked else { throw SubtitleError.invalid(L("视频轨道已锁定，请先解锁")) }
        guard time>=0,time<1_000_000_000,placements.contains(where:{$0.clip.id == id}) else { throw SubtitleError.invalid(L("素材或插入位置无效")) }
        let positioned=placements.map{($0.clip,$0.clip.id == id ? time : $0.start)}.sorted{$0.1<$1.1}
        var values:[VideoClip]=[],end:Int64=0
        for (i,entry) in positioned.enumerated() {
            var clip=entry.0
            let transition=i == 0 ? 0 : clip.transition
            let gap=entry.1-end+transition
            guard gap>=0,(clip.transition == 0 || (i>0 && gap==0)) else { throw SubtitleError.invalid(L("同轨片段不能重叠；叠化片段需先取消叠化再移动")) }
            clip.timelineGap=gap; values.append(clip); end=entry.1+clip.duration
        }
        return try replacingClips(values)
    }
    public func insertingCopy(of id: UUID, at index: Int) throws -> Project {
        guard !isVideoLocked else { throw SubtitleError.invalid(L("视频轨道已锁定，请先解锁")) }
        guard var clip=allClips.first(where:{$0.id == id}), (0...clips.count).contains(index) else {
            throw SubtitleError.invalid(L("素材或插入位置无效"))
        }
        clip.id=UUID(); clip.transition=0; clip.timelineGap=nil
        var edited=clips; edited.insert(clip,at:index)
        for i in edited.indices {
            edited[i].transition=i == 0 ? 0 : min(edited[i].transition,min(edited[i].duration,edited[i-1].duration)/2)
        }
        return try replacingClips(edited)
    }
    public func trimmingClip(_ id: UUID, at time: Int64, removeBefore: Bool) throws -> Project {
        guard let p=placements.first(where:{$0.clip.id == id}),let i=clips.firstIndex(where:{$0.id == id}),time>p.start,time<p.end else {
            throw SubtitleError.invalid(L("请将播放头放在要裁剪的视频片段内部"))
        }
        var edited=clips
        let sourceTime=p.clip.sourceStart+time-p.start
        if removeBefore {
            edited[i].sourceStart=sourceTime; edited[i].effects.fadeIn=0
            edited[i].effects.fadeOut=min(edited[i].effects.fadeOut,edited[i].duration)
        } else {
            edited[i].sourceEnd=sourceTime; edited[i].effects.fadeOut=0
            edited[i].effects.fadeIn=min(edited[i].effects.fadeIn,edited[i].duration)
        }
        for index in edited.indices {
            edited[index].transition=index == 0 ? 0 : min(edited[index].transition,min(edited[index].duration,edited[index-1].duration)/2)
        }
        return try replacingClips(edited)
    }
    public func splittingClip(_ id: UUID, at time: Int64) throws -> Project {
        guard let p=placements.first(where:{$0.clip.id == id}),let i=clips.firstIndex(where:{$0.id == id}) else { throw SubtitleError.invalid(L("请先选择视频片段")) }
        let offset=time-p.start
        guard offset>p.clip.transition,offset<p.clip.duration-(placements.indices.contains(i+1) ? placements[i+1].clip.transition : 0) else { throw SubtitleError.invalid(L("请在片段内部、叠化区域以外分割")) }
        var a=p.clip,b=p.clip
        a.sourceEnd=a.sourceStart+offset; a.effects.fadeOut=0; a.effects.fadeIn=min(a.effects.fadeIn,a.duration)
        b.id=UUID(); b.sourceStart=a.sourceEnd; b.transition=0; b.timelineGap=nil; b.effects.fadeIn=0; b.effects.fadeOut=min(b.effects.fadeOut,b.duration)
        var edited=clips; edited.replaceSubrange(i...i,with:[a,b])
        return try replacingClips(edited,origins:[b.id:a.id])
    }
}
