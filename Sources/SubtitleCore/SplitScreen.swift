import Foundation
import CoreGraphics

/// Normalized canvas rectangle, origin at bottom left like subtitle positions.
public struct VideoFrame: Codable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double,y: Double,width: Double,height: Double) { self.x=x; self.y=y; self.width=width; self.height=height }
    public var isValid: Bool {
        [x,y,width,height].allSatisfy { $0.isFinite } && x>=0 && y>=0 && width>0.01 && height>0.01 && x+width<=1.000001 && y+height<=1.000001
    }
}

/// Fractions of the upright source picture to cut away, e.g. letterbox bars recorded into the video.
public struct VideoCrop: Codable, Equatable {
    public var top: Double
    public var bottom: Double
    public var left: Double
    public var right: Double
    public init(top: Double=0,bottom: Double=0,left: Double=0,right: Double=0) { self.top=top; self.bottom=bottom; self.left=left; self.right=right }
    public var isEmpty: Bool { [top,bottom,left,right].allSatisfy { $0 == 0 } }
    public var isValid: Bool {
        [top,bottom,left,right].allSatisfy { $0.isFinite && (0...0.45).contains($0) } && top+bottom<=0.9 && left+right<=0.9
    }
    /// The kept part of an upright `size` picture, in bottom-left-origin coordinates.
    public func keptRect(in size: CGSize) -> CGRect {
        CGRect(x:left*size.width,y:bottom*size.height,width:(1-left-right)*size.width,height:(1-top-bottom)*size.height)
    }
}

/// Split-screen arrangement for 1–4 videos shown at the same time.
public enum SplitLayout: String, CaseIterable {
    /// Side by side, left to right.
    case row
    /// Stacked, top to bottom.
    case column
    /// 2 × 2, reading order; requires four videos.
    case grid
    public func supports(_ count: Int) -> Bool { self == .grid ? count == 4 : (1...4).contains(count) }
    /// Cells in the order the videos were chosen.
    public func cells(_ count: Int) -> [VideoFrame] {
        guard supports(count) else { return [] }
        let share=1/Double(count)
        switch self {
        case .row: return (0..<count).map { VideoFrame(x:Double($0)*share,y:0,width:share,height:1) }
        case .column: return (0..<count).map { VideoFrame(x:0,y:1-Double($0+1)*share,width:1,height:share) }
        case .grid: return [(0,0.5),(0.5,0.5),(0,0),(0.5,0)].map { VideoFrame(x:$0.0,y:$0.1,width:0.5,height:0.5) }
        }
    }
    /// Cells sized to each picture's width/height ratio, and the canvas ratio that holds them exactly,
    /// so every video is shown whole without cropping or bars. A 2 × 2 grid uses the average ratio.
    public func fittedCells(aspects: [Double]) -> (cells: [VideoFrame],canvasRatio: Double)? {
        guard supports(aspects.count),aspects.allSatisfy({ $0.isFinite && $0>0.05 && $0<20 }) else { return nil }
        switch self {
        case .column:
            // Equal widths; heights proportional to 1 / ratio, first video on top.
            let heights=aspects.map { 1/$0 },total=heights.reduce(0,+)
            var top=1.0
            let cells=heights.map { h -> VideoFrame in let share=h/total; top-=share; return VideoFrame(x:0,y:max(0,top),width:1,height:share) }
            return (cells,1/total)
        case .row:
            let total=aspects.reduce(0,+)
            var left=0.0
            let cells=aspects.map { a -> VideoFrame in let share=a/total; defer { left+=share }; return VideoFrame(x:left,y:0,width:share,height:1) }
            return (cells,total)
        case .grid:
            return (cells(4),aspects.reduce(0,+)/Double(aspects.count))
        }
    }
}

/// Output frame shape; nil in a project keeps the first video's size.
public enum CanvasAspect: String, Codable, CaseIterable {
    /// Ratio chosen so split-screen cells match their videos (stored in `Project.canvasRatio`).
    case fitVideos
    case source, portrait, landscape, square
    /// Keeps the source's long edge (the largest source in the project) so resolution is not reduced; dimensions are even for encoders.
    /// `ratio` (width / height) is used by `fitVideos`.
    public func size(source: CGSize,ratio: Double?=nil) -> CGSize {
        let long=max(source.width,source.height)
        func even(_ value: CGFloat) -> CGFloat { max(2,(value/2).rounded()*2) }
        switch self {
        case .fitVideos:
            let r=CGFloat(ratio ?? Double(source.width/max(1,source.height)))
            return r>=1 ? CGSize(width:even(long),height:even(long/r)) : CGSize(width:even(long*r),height:even(long))
        case .source: return CGSize(width:even(source.width),height:even(source.height))
        case .portrait: return CGSize(width:even(long*9/16),height:even(long))
        case .landscape: return CGSize(width:even(long),height:even(long*9/16))
        case .square: return CGSize(width:even(long),height:even(long))
        }
    }
}

extension Project {
    public var canvas: CanvasAspect { canvasAspect ?? .source }
    public var isCanvasRatioValid: Bool { canvasRatio.map { $0.isFinite && (0.1...10).contains($0) } ?? true }
    /// Sets the project canvas; `ratio` is required for `fitVideos` and cleared otherwise.
    public mutating func setCanvas(_ canvas: CanvasAspect,ratio: Double?=nil) {
        canvasAspect=canvas == .source ? nil : canvas
        canvasRatio=canvas == .fitVideos ? ratio : nil
    }
    /// Places 1–4 videos at the same time, each on its own new video track and in its own cell.
    /// Without a main video, the first one becomes the main track starting at zero.
    /// `aspects` are the shown pictures' width/height ratios (after crop); `fitVideos` needs them.
    public func addingSplitScreen(_ videos: [VideoClip],layout: SplitLayout,canvas: CanvasAspect,at time: Int64,aspects: [Double]?=nil) throws -> Project {
        // Callers may already set `crop` (for example detected letterbox bars); it is kept.
        let fitted=canvas == .fitVideos ? aspects.flatMap { layout.fittedCells(aspects:$0) } : nil
        if canvas == .fitVideos,fitted == nil { throw SubtitleError.invalid(L("无法读取视频比例，请选择其他画布")) }
        let cells=fitted?.cells ?? layout.cells(videos.count)
        guard !cells.isEmpty,cells.count == videos.count,time>=0,time<1_000_000_000 else { throw SubtitleError.invalid(L("分屏需要 1–4 个视频；2×2 需要 4 个")) }
        var framed=zip(videos,cells).map { pair -> VideoClip in
            var clip=pair.0; clip.frame=pair.1; clip.transition=0; clip.timelineGap=nil; return clip
        }
        var next=self
        var start=time
        if clips.isEmpty {
            next=try next.replacingClips([framed.removeFirst()])
            start=0
        }
        let added=framed.map { clip -> VideoLayer in
            var value=VideoLayer(clip:clip,start:start); value.trackID=clip.id; return value
        }
        next.setCanvas(canvas,ratio:fitted?.canvasRatio)
        return try next.replacingLayers(added+next.layers)
    }
}

/// A shared edge between split-screen cells shown at the same time. Vertical dividers are lines of
/// constant x; `before` cells lie left of (or below) the line and `after` cells right of (or above) it.
public struct SplitDivider: Equatable {
    public var vertical: Bool
    public var position: Double
    /// Extent along the line, normalized.
    public var from: Double
    public var to: Double
    public var before: [UUID]
    public var after: [UUID]
}

extension Project {
    /// Clips with a split-screen cell that are visible at `time`, with their cells.
    private func framedClips(at time: Int64) -> [(UUID,VideoFrame)] {
        renderPlacements.compactMap { p in
            guard let frame=p.clip.frame,p.start<=time,time<p.end else { return nil }
            let hidden=layers.first { $0.id == p.clip.id }?.hidden ?? isVideoHidden
            return hidden ? nil : (p.clip.id,frame)
        }
    }
    public func splitDividers(at time: Int64) -> [SplitDivider] {
        let cells=framedClips(at:time)
        let eps=1e-4
        var result: [SplitDivider]=[]
        for vertical in [true,false] {
            func low(_ f: VideoFrame) -> Double { vertical ? f.x : f.y }
            func high(_ f: VideoFrame) -> Double { vertical ? f.x+f.width : f.y+f.height }
            func spanLow(_ f: VideoFrame) -> Double { vertical ? f.y : f.x }
            func spanHigh(_ f: VideoFrame) -> Double { vertical ? f.y+f.height : f.x+f.width }
            var lines: [Double]=[]
            for (_,f) in cells where high(f)<1-eps && !lines.contains(where:{ abs($0-high(f))<eps }) { lines.append(high(f)) }
            for line in lines.sorted() {
                let before=cells.filter { abs(high($0.1)-line)<eps },after=cells.filter { abs(low($0.1)-line)<eps }
                // Only a real divider: cells on both sides that face each other along the line.
                let overlaps=before.contains { b in after.contains { a in min(spanHigh(a.1),spanHigh(b.1))-max(spanLow(a.1),spanLow(b.1))>eps } }
                guard overlaps else { continue }
                let all=before+after
                result.append(SplitDivider(vertical:vertical,position:line,from:all.map { spanLow($0.1) }.min()!,to:all.map { spanHigh($0.1) }.max()!,before:before.map(\.0),after:after.map(\.0)))
            }
        }
        return result
    }
    /// Moves a divider, resizing the cells on both sides; each cell keeps at least 5% of the canvas.
    /// Other clips on the same track that share a moved cell change with it, so cut pieces stay aligned.
    public func movingSplitDivider(_ divider: SplitDivider,to position: Double) throws -> Project {
        let clipsByID=Dictionary(uniqueKeysWithValues:allClips.map { ($0.id,$0) })
        let v=divider.vertical
        let before=divider.before.compactMap { clipsByID[$0]?.frame },after=divider.after.compactMap { clipsByID[$0]?.frame }
        guard !before.isEmpty,!after.isEmpty,position.isFinite else { throw SubtitleError.invalid(L("分屏画面位置无效")) }
        let minimum=before.map { v ? $0.x : $0.y }.max()!+0.05,maximum=after.map { v ? $0.x+$0.width : $0.y+$0.height }.min()!-0.05
        guard minimum<=maximum else { return self }
        let target=min(maximum,max(minimum,position))
        func moved(_ f: VideoFrame,isBefore: Bool) -> VideoFrame {
            var g=f
            if v { if isBefore { g.width=target-f.x } else { g.width=f.x+f.width-target; g.x=target } }
            else { if isBefore { g.height=target-f.y } else { g.height=f.y+f.height-target; g.y=target } }
            return g
        }
        // Changes keyed by (track, old cell) so every piece of a cut clip on that track follows.
        var changes: [(track: UUID?,old: VideoFrame,new: VideoFrame)]=[]
        func track(of id: UUID) -> UUID? { layers.first { $0.id == id }?.trackIdentifier }
        for (ids,isBefore) in [(divider.before,true),(divider.after,false)] {
            for id in ids { if let f=clipsByID[id]?.frame { changes.append((track(of:id),f,moved(f,isBefore:isBefore))) } }
        }
        func updated(_ clip: VideoClip,track: UUID?) -> VideoClip {
            guard let f=clip.frame,let change=changes.first(where:{ $0.track == track && $0.old == f }) else { return clip }
            var c=clip; c.frame=change.new; return c
        }
        var next=self
        next.videoClips=clips.map { updated($0,track:nil) }
        next.videoLayers=layers.map { var l=$0; l.clip=updated(l.clip,track:l.trackIdentifier); return l }
        try next.validate()
        return next
    }
}

extension Project {
    /// The split-screen group around `id`: for every track (the main track counts as one) that has a
    /// split cell overlapping `id`'s time, the last such clip. Returned as (track, clip id, start, end).
    public func splitGroup(containing id: UUID) -> [(track: UUID?,clip: UUID,start: Int64,end: Int64)] {
        guard let anchor=renderPlacements.first(where:{ $0.clip.id == id }),anchor.clip.frame != nil else { return [] }
        let trackOf=Dictionary(uniqueKeysWithValues:layers.map { ($0.id,$0.trackIdentifier) })
        var tails: [UUID?:(UUID,Int64,Int64)]=[:]
        for p in renderPlacements where p.clip.frame != nil && p.start<anchor.end && anchor.start<p.end {
            let track=trackOf[p.clip.id]
            if let current=tails[track],current.2>=p.end { continue }
            tails[track]=(p.clip.id,p.start,p.end)
        }
        return tails.map { (track:$0.key,clip:$0.value.0,start:$0.value.1,end:$0.value.2) }.sorted { $0.end<$1.end }
    }
    /// Trims the longer videos of a split-screen group so all end with the shortest one.
    /// Main-track trims add the same gap before the next main clip, so nothing else moves.
    public func endingTogether(with id: UUID) throws -> Project {
        let group=splitGroup(containing:id)
        guard group.count>1,let target=group.map(\.end).min() else { throw SubtitleError.invalid(L("请先选中分屏中的一个视频")) }
        var next=self
        var mainClips=clips
        var layerValues=layers
        for member in group where member.end>target {
            guard target-member.start>=100 else { throw SubtitleError.invalid(L("视频开始得太晚，无法与最短的视频同时结束")) }
            let cut=member.end-target
            if let i=layerValues.firstIndex(where:{ $0.id == member.clip }) {
                guard !layerValues[i].isLocked else { throw SubtitleError.invalid(L("视频轨道已锁定，请先解锁")) }
                layerValues[i].clip.sourceEnd-=cut
                layerValues[i].clip.effects.fadeOut=min(layerValues[i].clip.effects.fadeOut,layerValues[i].clip.duration-layerValues[i].clip.effects.fadeIn)
            } else if let i=mainClips.firstIndex(where:{ $0.id == member.clip }) {
                guard !isVideoLocked else { throw SubtitleError.invalid(L("视频轨道已锁定，请先解锁")) }
                mainClips[i].sourceEnd-=cut
                mainClips[i].effects.fadeOut=min(mainClips[i].effects.fadeOut,mainClips[i].duration-mainClips[i].effects.fadeIn)
                if i+1<mainClips.count { mainClips[i+1].timelineGap=mainClips[i+1].gap+cut }
            }
        }
        if mainClips != clips { next=try next.replacingClips(mainClips) }
        return try next.replacingLayers(layerValues)
    }
}
