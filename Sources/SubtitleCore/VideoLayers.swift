import Foundation

/// Absolute-time video clip on an additional track. Missing trackID maps legacy clips to their own tracks.
public struct VideoLayer: Codable, Equatable, Identifiable {
    public var id: UUID { clip.id }
    public var clip: VideoClip
    public var start: Int64
    public var trackID: UUID?
    public var trackIdentifier: UUID { trackID ?? id }
    // Legacy PiP geometry is retained for file compatibility, but no longer rendered.
    public var x: Double=0.5
    public var y: Double=0.5
    public var scale: Double=1
    public var locked: Bool?
    public var isLocked: Bool { locked ?? false }
    public var hidden=false
    public var muted=false
    public init(clip: VideoClip,start: Int64) { self.clip=clip; self.start=start }
    public var end: Int64 { start+clip.duration }
}
public enum VideoTrackDestination: Equatable { case main, track(UUID), newTrack }

extension Project {
    public var layers: [VideoLayer] { videoLayers ?? [] }
    public var layerTracks: [[VideoLayer]] {
        var ids:[UUID]=[]; var groups:[UUID:[VideoLayer]]=[:]
        for layer in layers {
            if groups[layer.trackIdentifier] == nil { ids.append(layer.trackIdentifier) }
            groups[layer.trackIdentifier,default:[]].append(layer)
        }
        return ids.map{groups[$0]!.sorted{$0.start<$1.start}}
    }
    public var allClips: [VideoClip] { clips+layers.map(\.clip) }
    public var renderPlacements: [ClipPlacement] { placements+layerTracks.reversed().flatMap{$0.map{ClipPlacement(clip:$0.clip,start:$0.start)}} }
    public var videoDuration: Int64 { max(placements.last?.end ?? 0,layers.map(\.end).max() ?? 0) }
    public func replacingLayers(_ values: [VideoLayer]) throws -> Project {
        var next=self; next.videoClips=clips; next.videoLayers=values; next.duration=next.videoDuration
        next.videoPath=next.allClips.first?.path ?? ""
        next.cues=next.cues.compactMap { cue in
            guard cue.start<next.duration else { return nil }
            var value=cue; value.end=min(value.end,next.duration); return value
        }
        try next.validate(); return next
    }
    public func addingLayer(from id: UUID,at time: Int64,trackID: UUID?=nil) throws -> Project {
        guard var clip=allClips.first(where:{$0.id == id}),time>=0,time<1_000_000_000 else { throw SubtitleError.invalid(L("素材或插入位置无效")) }
        clip.id=UUID(); clip.transition=0; clip.timelineGap=nil
        var value=VideoLayer(clip:clip,start:time)
        if let trackID {
            guard let track=layers.first(where:{$0.trackIdentifier == trackID}),!track.isLocked else { throw SubtitleError.invalid(L("视频轨道已锁定，请先解锁")) }
            value.trackID=trackID; value.locked=track.locked; value.hidden=track.hidden; value.muted=track.muted
            return try replacingLayers(layers+[value])
        }
        return try replacingLayers([value]+layers)
    }
    /// Imported videos form one new track, placed back to back from `time`.
    public func addingLayerTrack(_ clips: [VideoClip],at time: Int64) throws -> Project {
        guard let first=clips.first,time>=0,time<1_000_000_000 else { throw SubtitleError.invalid(L("素材或插入位置无效")) }
        var start=time
        let values=clips.map { source -> VideoLayer in
            var clip=source; clip.transition=0; clip.timelineGap=nil
            var value=VideoLayer(clip:clip,start:start); value.trackID=first.id; start+=clip.duration
            return value
        }
        return try replacingLayers(values+layers)
    }
    public func replacingLayer(_ value: VideoLayer) throws -> Project {
        guard let old=layers.first(where:{$0.id == value.id}),!old.isLocked,
              let target=layers.first(where:{$0.trackIdentifier == value.trackIdentifier}),!target.isLocked else { throw SubtitleError.invalid(L("视频轨道已锁定，请先解锁")) }
        let values=layers.map{$0.id == value.id ? value : $0}
        let ordered=layerTracks.flatMap { track in values.filter{$0.trackIdentifier == track[0].trackIdentifier} }
        return try replacingLayers(ordered)
    }
    /// Move the original clip between tracks without rippling other media or copying its ID.
    public func transferringClip(_ id: UUID,to destination: VideoTrackDestination,at time: Int64) throws -> Project {
        guard time>=0,time<1_000_000_000,let placement=renderPlacements.first(where:{$0.clip.id == id}) else { throw SubtitleError.invalid(L("素材或插入位置无效")) }
        let sourceLayer=layers.first{$0.id == id}
        guard !(sourceLayer?.isLocked ?? isVideoLocked) else { throw SubtitleError.invalid(L("视频轨道已锁定，请先解锁")) }
        if sourceLayer == nil, destination == .main { return try movingMainClip(id,to:time) }
        if sourceLayer == nil,let index=clips.firstIndex(where:{$0.id == id}),
           clips[index].transition>0 || (index+1<clips.count && clips[index+1].transition>0) {
            throw SubtitleError.invalid(L("同轨片段不能重叠；叠化片段需先取消叠化再移动"))
        }
        var next=self
        var positioned=placements.filter{$0.clip.id != id}.map{($0.clip,$0.start)}
        next.videoLayers=layers.filter{$0.id != id}
        var clip=placement.clip; clip.timelineGap=nil; clip.transition=0
        switch destination {
        case .main:
            guard !isVideoLocked else { throw SubtitleError.invalid(L("视频轨道已锁定，请先解锁")) }
            positioned.append((clip,time))
        case .track(let trackID):
            guard let target=layers.first(where:{$0.trackIdentifier == trackID}),!target.isLocked else { throw SubtitleError.invalid(L("视频轨道已锁定，请先解锁")) }
            var value=sourceLayer ?? VideoLayer(clip:clip,start:time)
            value.clip=clip; value.start=time
            if value.trackIdentifier != trackID { value.trackID=trackID }
            value.locked=target.locked; value.hidden=target.hidden; value.muted=target.muted
            let values=next.layers+[value]
            next.videoLayers=layerTracks.flatMap{track in values.filter{$0.trackIdentifier == track[0].trackIdentifier}}
        case .newTrack:
            var value=sourceLayer ?? VideoLayer(clip:clip,start:time)
            value.clip=clip; value.start=time; value.trackID=UUID()
            if sourceLayer == nil { value.hidden=isVideoHidden; value.muted=isVideoMuted }
            next.videoLayers=[value]+next.layers
        }
        var end:Int64=0,main:[VideoClip]=[]
        for (index,entry) in positioned.sorted(by:{$0.1<$1.1}).enumerated() {
            var value=entry.0
            let gap=entry.1-end+(index == 0 ? 0 : value.transition)
            guard gap>=0,(value.transition == 0 || (index>0 && gap==0)) else { throw SubtitleError.invalid(L("同一视频轨道的片段不能重叠")) }
            if value.gap != gap { value.timelineGap=gap }; main.append(value); end=entry.1+value.duration
        }
        next.videoClips=main; next.duration=next.videoDuration; next.videoPath=next.allClips.first?.path ?? ""
        next.cues=next.cues.compactMap { cue in
            guard cue.start<next.duration else { return nil }; var value=cue; value.end=min(value.end,next.duration); return value
        }
        try next.validate(); return next
    }
    public func cuttingLayer(_ id: UUID,at time: Int64,removeBefore: Bool?=nil) throws -> Project {
        var values=layers
        guard let i=values.firstIndex(where:{$0.id == id}),!values[i].isLocked,time>values[i].start,time<values[i].end else { throw SubtitleError.invalid(L("请在片段内部进行剪切")) }
        let original=values[i],cut=original.clip.sourceStart+time-original.start
        if let before=removeBefore {
            if before { values[i].start=time; values[i].clip.sourceStart=cut } else { values[i].clip.sourceEnd=cut }
        } else {
            var second=original; second.trackID=original.trackIdentifier; second.clip.id=UUID(); second.start=time; second.clip.sourceStart=cut
            second.clip.effects.fadeIn=0; values[i].clip.sourceEnd=cut; values[i].clip.effects.fadeOut=0
            values.insert(second,at:i+1)
        }
        for j in values.indices {
            values[j].clip.effects.fadeIn=min(values[j].clip.effects.fadeIn,values[j].clip.duration)
            values[j].clip.effects.fadeOut=min(values[j].clip.effects.fadeOut,values[j].clip.duration-values[j].clip.effects.fadeIn)
        }
        return try replacingLayers(values)
    }
    public func validateLayers() throws {
        for track in layerTracks {
            var end:Int64=0
            for value in track {
                guard value.start>=end else { throw SubtitleError.invalid(L("同一视频轨道的片段不能重叠")) }
                guard value.isLocked==track[0].isLocked,value.hidden==track[0].hidden,value.muted==track[0].muted else { throw SubtitleError.invalid(L("视频轨道状态不一致")) }
                end=value.end
            }
        }
        guard Set(allClips.map(\.id)).count==allClips.count else { throw SubtitleError.invalid(L("视频片段 ID 重复")) }
        for layer in layers {
            guard layer.start>=0,layer.start<1_000_000_000,layer.clip.sourceDuration<1_000_000_000_000,
                  layer.clip.transition==0,[layer.x,layer.y,layer.scale].allSatisfy({$0.isFinite}),
                  (0...1).contains(layer.x),(0...1).contains(layer.y),(0.05...1).contains(layer.scale) else {
                throw SubtitleError.invalid(L("视频轨道时间或参数无效"))
            }
            var single=Project(); single.videoClips=[layer.clip]; single.duration=layer.clip.duration
            try single.validateClips()
        }
    }
}
