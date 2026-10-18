import AppKit
import AVFoundation
import CoreImage
import VideoToolbox
import SubtitleCore

enum VideoColor: String {
    case sdr, hlg, pq
    var title: String { switch self { case .sdr:return "SDR · H.264 / BT.709"; case .hlg:return "HDR HLG · HEVC 10-bit / BT.2020"; case .pq:return "HDR PQ · HEVC 10-bit / BT.2020" } }
    var transfer: String { switch self { case .sdr:return AVVideoTransferFunction_ITU_R_709_2; case .hlg:return AVVideoTransferFunction_ITU_R_2100_HLG; case .pq:return AVVideoTransferFunction_SMPTE_ST_2084_PQ } }
    var primaries: String { self == .sdr ? AVVideoColorPrimaries_ITU_R_709_2 : AVVideoColorPrimaries_ITU_R_2020 }
    var matrix: String { self == .sdr ? AVVideoYCbCrMatrix_ITU_R_709_2 : AVVideoYCbCrMatrix_ITU_R_2020 }
    var space: CGColorSpace { CGColorSpace(name:self == .sdr ? CGColorSpace.itur_709 : self == .hlg ? CGColorSpace.itur_2100_HLG : CGColorSpace.itur_2100_PQ)! }
    var properties: [String:Any] { [AVVideoColorPrimariesKey:primaries,AVVideoTransferFunctionKey:transfer,AVVideoYCbCrMatrixKey:matrix] }
}
struct MediaProbe {
    let color: VideoColor
    let dolbyVision: Bool
    let duration: Int64
    let size: CGSize
    let fps: Float
    var description: String { "\(Int(size.width)) × \(Int(size.height)) · \(color == .sdr ? L("SDR / 未标记 HDR") : color == .hlg ? "HLG" : "PQ")\(dolbyVision ? L(" · Dolby Vision 基础层") : "")" }
    init(_ path: String) throws {
        let asset=AVURLAsset(url:URL(fileURLWithPath:path))
        guard let track=asset.tracks(withMediaType:.video).first else { throw SubtitleError.invalid(L("无法读取视频：{0}", [String(describing: path)])) }
        let seconds=CMTimeGetSeconds(asset.duration)
        guard seconds.isFinite,seconds>0,seconds<1e9 else { throw SubtitleError.invalid(L("视频时长无效")) }
        duration=Int64(seconds*1000); fps=track.nominalFrameRate
        let rect=CGRect(origin:.zero,size:track.naturalSize).applying(track.preferredTransform)
        size=CGSize(width:abs(rect.width),height:abs(rect.height))
        guard let description=track.formatDescriptions.first else { throw SubtitleError.invalid(L("视频缺少格式信息")) }
        let format=description as! CMFormatDescription
        let extensions=(CMFormatDescriptionGetExtensions(format) as NSDictionary?) ?? NSDictionary()
        let transfer=extensions[kCMFormatDescriptionExtension_TransferFunction] as? String
        color=transfer == AVVideoTransferFunction_ITU_R_2100_HLG ? .hlg : transfer == AVVideoTransferFunction_SMPTE_ST_2084_PQ ? .pq : .sdr
        let atoms=extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] as? NSDictionary
        let codec=CMFormatDescriptionGetMediaSubType(format)
        dolbyVision=atoms?["dvcC"] != nil || atoms?["dvvC"] != nil || codec == 0x64766831 || codec == 0x64766865
    }
    static func formats(_ project: Project) throws -> ([VideoColor],String) {
        let probes=try project.allClips.map{try MediaProbe($0.path)}
        let colors=Set(probes.map{$0.color.rawValue})
        var formats: [VideoColor]=[.sdr]
        if colors.count == 1,let color=probes.first?.color,color != .sdr { formats.append(color) }
        let detail=zip(project.allClips,probes).map{URL(fileURLWithPath:$0.0.path).lastPathComponent+"："+$0.1.description}.joined(separator:"\n")
        let policy=colors.count>1 ? L("\n混合色彩格式：本版仅提供 SDR 输出，避免误标 HDR。") : ""
        let dv=probes.contains{$0.dolbyVision} ? L("\nDolby Vision 动态元数据不会保留，只可处理兼容基础层。") : ""
        return (formats,detail+policy+dv+L("\nHDR 为重新编码，非逐位无损；显示效果还取决于屏幕。"))
    }
}
struct RenderLayer {
    let trackID: CMPersistentTrackID
    let transform: CGAffineTransform
    let placement: ClipPlacement
    let outgoing: Int64
}
final class EditInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing=false
    let containsTweening=true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID=kCMPersistentTrackID_Invalid
    let layers: [RenderLayer]
    let project: Project
    let color: VideoColor
    let subtitles: Bool
    let speed: Double
    init(start: Int64,end: Int64,layers: [RenderLayer],project: Project,color: VideoColor,subtitles: Bool,speed: Double=1) {
        timeRange=CMTimeRange(start:CMTimeMultiplyByFloat64(CMTime(value:start,timescale:1000),multiplier:1/speed),end:CMTimeMultiplyByFloat64(CMTime(value:end,timescale:1000),multiplier:1/speed))
        self.speed=speed; self.layers=layers; self.project=project; self.color=color; self.subtitles=subtitles
        requiredSourceTrackIDs=layers.map{NSNumber(value:$0.trackID)}
    }
}
struct EditedAsset {
    let asset: AVMutableComposition
    let video: AVMutableVideoComposition
    let audio: AVMutableAudioMix
    let size: CGSize
    init(project: Project,color: VideoColor,subtitles: Bool,applySpeed: Bool=false) throws {
        try project.validate()
        let speed=applySpeed ? project.speed : 1
        func outputTime(_ ms: Int64) -> CMTime { CMTimeMultiplyByFloat64(CMTime(value:ms,timescale:1000),multiplier:1/speed) }
        guard let first=project.allClips.first else { throw SubtitleError.invalid(L("请先添加视频")) }
        let probe=try MediaProbe(first.path)
        if project.canvas == .source { size=CGSize(width:max(2,ceil(probe.size.width/2)*2),height:max(2,ceil(probe.size.height/2)*2)) }
        else {
            // A shaped canvas mixes several sources; use the sharpest one so no video is scaled down needlessly.
            let largest=try Set(project.allClips.map(\.path)).map { try MediaProbe($0).size }.max { max($0.width,$0.height) < max($1.width,$1.height) } ?? probe.size
            size=project.canvas.size(source:largest,ratio:project.canvasRatio)
        }
        asset=AVMutableComposition(); video=AVMutableVideoComposition(); audio=AVMutableAudioMix()
        var layers: [RenderLayer]=[],parameters: [AVAudioMixInputParameters]=[]
        let places=project.renderPlacements
        let frameDuration=Self.outputFrameDuration(rates:Set(places.map(\.clip.path)).compactMap { AVURLAsset(url:URL(fileURLWithPath:$0)).tracks(withMediaType:.video).first?.nominalFrameRate })
        for (i,p) in places.enumerated() {
            let source=AVURLAsset(url:URL(fileURLWithPath:p.clip.path))
            guard let v=source.tracks(withMediaType:.video).first,
                  let target=asset.addMutableTrack(withMediaType:.video,preferredTrackID:kCMPersistentTrackID_Invalid) else { throw SubtitleError.invalid(L("找不到视频：{0}", [String(describing: p.clip.path)])) }
            let sourceRange=CMTimeRange(start:CMTime(value:p.clip.sourceStart,timescale:1000),duration:CMTime(value:p.clip.duration,timescale:1000))
            // Edit lists can start with an empty segment (no picture); only real media counts, and the
            // hold-frame code below fills the gap with the first frame.
            let media=v.segments.filter { !$0.isEmpty }.map(\.timeMapping.target)
            let mediaRange=media.isEmpty ? v.timeRange : CMTimeRange(start:media.first!.start,end:CMTimeRangeGetEnd(media.last!))
            let range=CMTimeRangeGetIntersection(sourceRange,otherRange:mediaRange)
            guard range.isValid,CMTimeGetSeconds(range.duration)>0 else { throw SubtitleError.invalid(L("所选区间没有可用视频画面")) }
            let destination=CMTime(value:p.start,timescale:1000)
            let leading=CMTimeSubtract(range.start,sourceRange.start)
            let trailing=CMTimeSubtract(CMTimeRangeGetEnd(sourceRange),CMTimeRangeGetEnd(range))
            let sampleDuration=CMTimeMinimum(range.duration,frameDuration)
            func holdFrame(sourceStart: CMTime,at position: CMTime,duration: CMTime) throws {
                guard CMTimeGetSeconds(duration)>0 else { return }
                try target.insertTimeRange(CMTimeRange(start:sourceStart,duration:sampleDuration),of:v,at:position)
                target.scaleTimeRange(CMTimeRange(start:position,duration:sampleDuration),toDuration:duration)
            }
            try holdFrame(sourceStart:range.start,at:destination,duration:leading)
            try target.insertTimeRange(range,of:v,at:CMTimeAdd(destination,leading))
            try holdFrame(sourceStart:CMTimeSubtract(CMTimeRangeGetEnd(range),sampleDuration),at:CMTimeAdd(CMTimeAdd(destination,leading),range.duration),duration:trailing)
            let isLayer=project.layers.contains{$0.id == p.clip.id}
            let outgoing = !isLayer && i+1<project.placements.count ? places[i+1].clip.transition : 0
            layers.append(RenderLayer(trackID:target.trackID,transform:v.preferredTransform,placement:p,outgoing:outgoing))
            if (isLayer ? !(project.layers.first{$0.id == p.clip.id}?.muted ?? false) : !project.isVideoMuted),let a=source.tracks(withMediaType:.audio).first,let at=asset.addMutableTrack(withMediaType:.audio,preferredTrackID:kCMPersistentTrackID_Invalid) {
                let r=CMTimeRangeGetIntersection(sourceRange,otherRange:a.timeRange)
                if CMTimeGetSeconds(r.duration)>0 {
                    try at.insertTimeRange(r,of:a,at:CMTimeAdd(CMTime(value:p.start,timescale:1000),CMTimeSubtract(r.start,sourceRange.start)))
                    let param=AVMutableAudioMixInputParameters(track:at)
                    let fadeIn=max(p.clip.transition,p.clip.effects.fadeIn),fadeOut=max(outgoing,p.clip.effects.fadeOut)
                    param.audioTimePitchAlgorithm = .spectral
                    param.setVolume(1,at:outputTime(p.start))
                    if fadeIn>0 { param.setVolumeRamp(fromStartVolume:0,toEndVolume:1,timeRange:CMTimeRange(start:outputTime(p.start),duration:outputTime(fadeIn))) }
                    if fadeOut>0 { param.setVolumeRamp(fromStartVolume:1,toEndVolume:0,timeRange:CMTimeRange(start:outputTime(p.end-fadeOut),duration:outputTime(fadeOut))) }
                    parameters.append(param)
                }
            }
        }
        for music in project.music where music.start<project.duration {
            let source=AVURLAsset(url:URL(fileURLWithPath:music.path))
            guard let track=source.tracks(withMediaType:.audio).first,let target=asset.addMutableTrack(withMediaType:.audio,preferredTrackID:kCMPersistentTrackID_Invalid) else { throw SubtitleError.invalid(L("无法读取背景音乐：{0}",[music.path])) }
            let requested=CMTimeRange(start:CMTime(value:music.sourceStart,timescale:1000),duration:CMTime(value:min(music.duration,project.duration-music.start),timescale:1000))
            let range=CMTimeRangeGetIntersection(requested,otherRange:track.timeRange)
            guard range.isValid,CMTimeGetSeconds(range.duration)>0 else { throw SubtitleError.invalid(L("背景音乐没有可用音频")) }
            let start=CMTimeAdd(CMTime(value:music.start,timescale:1000),CMTimeSubtract(range.start,requested.start))
            try target.insertTimeRange(range,of:track,at:start)
            let parameter=AVMutableAudioMixInputParameters(track:target); parameter.audioTimePitchAlgorithm = .spectral; parameter.setVolume(Float(music.volume),at:CMTimeMultiplyByFloat64(start,multiplier:1/speed)); parameters.append(parameter)
        }
        if speed != 1 {
            asset.scaleTimeRange(CMTimeRange(start:.zero,duration:CMTime(value:project.duration,timescale:1000)),toDuration:outputTime(project.duration))
        }
        audio.inputParameters=parameters
        video.customVideoCompositorClass=EditCompositor.self
        video.renderSize=size; video.frameDuration=frameDuration
        video.colorPrimaries=color.primaries; video.colorTransferFunction=color.transfer; video.colorYCbCrMatrix=color.matrix
        let boundaries=Set(places.flatMap{[$0.start,$0.end]}+[0,project.duration]).sorted()
        video.instructions=zip(boundaries,boundaries.dropFirst()).map { a,b in
            EditInstruction(start:a,end:b,layers:layers.filter{$0.placement.start<=a && $0.placement.end>a},project:project,color:color,subtitles:subtitles,speed:speed)
        }
    }
    /// Output frame rate: the highest nominal source rate, snapped to a standard rate and capped at 60.
    /// Not `minFrameDuration`, which in variable-frame-rate files can be a single 1/600 s frame and would
    /// produce a 600 fps file that players show in slow motion.
    static func outputFrameDuration(rates: [Float]) -> CMTime {
        let standard: [(value: Int64,scale: Int32)]=[(1001,24000),(1,24),(1,25),(1001,30000),(1,30),(1,50),(1001,60000),(1,60)]
        guard let fps=rates.filter({ $0.isFinite && $0>=1 }).max().map({ min(60,Double($0)) }) else { return CMTime(value:1,timescale:30) }
        let nearest=standard.min { abs(Double($0.scale)/Double($0.value)-fps) < abs(Double($1.scale)/Double($1.value)-fps) }!
        if abs(Double(nearest.scale)/Double(nearest.value)-fps)<0.5 { return CMTime(value:nearest.value,timescale:nearest.scale) }
        return CMTime(value:1,timescale:Int32(max(1,fps.rounded())))
    }
    func playerItem() -> AVPlayerItem {
        let item=AVPlayerItem(asset:asset); item.videoComposition=video; item.audioMix=audio; return item
    }
}
/// Float compositing retains values above SDR white until the final output conversion.
final class EditCompositor: NSObject, AVVideoCompositing {
    var supportsHDRSourceFrames: Bool { true }
    var supportsWideColorSourceFrames: Bool { true }
    var sourcePixelBufferAttributes: [String:Any]? { [kCVPixelBufferPixelFormatTypeKey as String:[kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,kCVPixelFormatType_32BGRA]] }
    var requiredPixelBufferAttributesForRenderContext: [String:Any] { [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_64RGBAHalf,kCVPixelBufferMetalCompatibilityKey as String:true] }
    private let queue=DispatchQueue(label:"studio.edit.compositor")
    /// Last decoded frame per source track (queue-confined), reused when a frame is missing inside the file.
    private var lastFrames: [CMPersistentTrackID:CVPixelBuffer]=[:]
    private let context=CIContext(options:[.workingColorSpace:CGColorSpace(name:CGColorSpace.extendedLinearITUR_2020)!, .workingFormat:CIFormat.RGBAh,.cacheIntermediates:false])
    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}
    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { autoreleasepool {
            guard let instruction=request.videoCompositionInstruction as? EditInstruction,let target=request.renderContext.newPixelBuffer() else { request.finish(with:SubtitleError.invalid(L("无法创建合成画面"))); return }
            let size=request.renderContext.size,bounds=CGRect(origin:.zero,size:size)
            let ms=Int64((CMTimeGetSeconds(request.compositionTime)*1000*instruction.speed).rounded())
            var result=CIImage(color:CIColor(red:0,green:0,blue:0)).cropped(to:bounds)
            for layer in instruction.layers {
                let pip=instruction.project.layers.first{$0.id == layer.placement.clip.id}
                if pip?.hidden ?? instruction.project.isVideoHidden { continue }
                // A missing frame (gap in the source) repeats the previous one instead of stopping preview or export.
                guard let buffer=request.sourceFrame(byTrackID:layer.trackID) ?? self.lastFrames[layer.trackID] else { continue }
                self.lastFrames[layer.trackID]=buffer
                let flip=CGAffineTransform(scaleX:1,y:-1)
                var frame=CIImage(cvPixelBuffer:buffer).transformed(by:flip).transformed(by:layer.transform).transformed(by:flip)
                frame=frame.transformed(by:CGAffineTransform(translationX:-frame.extent.minX,y:-frame.extent.minY))
                if let crop=layer.placement.clip.crop,!crop.isEmpty {
                    let kept=crop.keptRect(in:frame.extent.size)
                    frame=frame.cropped(to:kept).transformed(by:CGAffineTransform(translationX:-kept.minX,y:-kept.minY))
                }
                // Full canvas: fit with black bars. Split-screen cell: fill the cell and crop the overflow.
                let cell=layer.placement.clip.frame.map { CGRect(x:$0.x*size.width,y:$0.y*size.height,width:$0.width*size.width,height:$0.height*size.height) } ?? bounds
                let scale=layer.placement.clip.frame == nil ? min(cell.width/frame.extent.width,cell.height/frame.extent.height) : max(cell.width/frame.extent.width,cell.height/frame.extent.height)
                frame=frame.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
                frame=frame.transformed(by:CGAffineTransform(translationX:cell.midX-frame.extent.midX,y:cell.midY-frame.extent.midY)).cropped(to:cell)
                let e=layer.placement.clip.effects,elapsed=ms-layer.placement.start,remaining=layer.placement.end-ms
                if e.brightness != 0 || e.contrast != 1 || e.saturation != 1 {
                    frame=frame.applyingFilter("CIColorControls",parameters:[kCIInputBrightnessKey:e.brightness,kCIInputContrastKey:e.contrast,kCIInputSaturationKey:e.saturation])
                }
                let sourceTime=layer.placement.clip.sourceStart+elapsed
                frame=VideoRegionRenderer.apply(to:frame,clip:layer.placement.clip,sourceTime:sourceTime,size:size)
                // Only the incoming image fades in for a dissolve; the outgoing image remains opaque underneath.
                var alpha=1.0
                if layer.placement.clip.transition>0 { alpha=min(alpha,Double(elapsed)/Double(layer.placement.clip.transition)) }
                if e.fadeIn>0 { alpha=min(alpha,Double(elapsed)/Double(e.fadeIn)) }
                if e.fadeOut>0 { alpha=min(alpha,Double(remaining)/Double(e.fadeOut)) }
                frame=frame.composited(over:CIImage(color:CIColor(red:0,green:0,blue:0)).cropped(to:cell))
                if alpha<1 { frame=frame.applyingFilter("CIColorMatrix",parameters:["inputAVector":CIVector(x:0,y:0,z:0,w:max(0,alpha))]) }
                result=frame.composited(over:result)
            }
            if instruction.subtitles,!instruction.project.active(at:ms).isEmpty {
                guard let cg=CGContext(data:nil,width:Int(size.width),height:Int(size.height),bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { request.finish(with:SubtitleError.invalid(L("无法绘制字幕"))); return }
                SubtitleRenderer.draw(project:instruction.project,at:ms,size:size,context:cg)
                if let image=cg.makeImage() { result=CIImage(cgImage:image).composited(over:result) }
            }
            self.context.render(result,to:target,bounds:bounds,colorSpace:instruction.color.space)
            CVBufferSetAttachment(target,kCVImageBufferColorPrimariesKey,instruction.color.primaries as CFString,.shouldPropagate)
            CVBufferSetAttachment(target,kCVImageBufferTransferFunctionKey,instruction.color.transfer as CFString,.shouldPropagate)
            CVBufferSetAttachment(target,kCVImageBufferYCbCrMatrixKey,instruction.color.matrix as CFString,.shouldPropagate)
            request.finish(withComposedVideoFrame:target)
        } }
    }
    func cancelAllPendingVideoCompositionRequests() { queue.sync { lastFrames.removeAll() } }
}

/// Text removal inside user-drawn boxes. `smart` and `patch` rebuild the background each frame from the
/// pixels around the box (a Coons patch: edge interpolation in both directions minus the corner blend);
/// this is interpolation, not AI inpainting or motion tracking. `solid` covers the box with one colour.
enum VideoRegionRenderer {
    static func apply(to image: CIImage,clip: VideoClip,sourceTime: Int64,size: CGSize) -> CIImage {
        var result=image
        for region in clip.eraseRegions ?? [] where region.sourceStart<=sourceTime && sourceTime<region.sourceEnd {
            let box=CGRect(x:region.x*size.width,y:region.y*size.height,width:region.width*size.width,height:region.height*size.height).intersection(image.extent).integral
            guard !box.isNull,box.width>=2,box.height>=2 else { continue }
            switch region.fillMode {
            case .smart: result=rebuilt(result,box:box,strokesOnly:true).composited(over:result)
            case .patch: result=rebuilt(result,box:box,strokesOnly:false).composited(over:result)
            case .solid: result=solid(result,region:region,box:box).composited(over:result)
            }
        }
        return result
    }
    private static func solid(_ image: CIImage,region: VideoEraseRegion,box: CGRect) -> CIImage {
        if let color=region.color { return CIImage(color:CIColor(color:color.ns)!).cropped(to:box) }
        // Keep a thin blank border inside the selection for reliable auto sampling.
        let inset=min(2,box.width/4),stripHeight=min(3,max(1,box.height*0.04))
        let strip=CGRect(x:box.minX+inset,y:box.minY+min(1,box.height/8),width:max(1,box.width-2*inset),height:stripHeight).intersection(image.extent)
        guard !strip.isNull,!strip.isEmpty else { return CIImage.empty() }
        return image.applyingFilter("CIAreaAverage",parameters:[kCIInputExtentKey:CIVector(cgRect:strip)]).clampedToExtent().cropped(to:box)
    }
    /// Background estimate for `box` from the ring of pixels just outside it; with `strokesOnly`, only pixels
    /// that differ clearly from that estimate (dilated a little to cover outlines and shadows) are replaced.
    static func rebuilt(_ image: CIImage,box: CGRect,strokesOnly: Bool) -> CIImage {
        // Lightly blurred and clamped so single noisy pixels and the frame edge do not streak across the box.
        let source=image.clampedToExtent().applyingGaussianBlur(sigma:1.2)
        let gap: CGFloat=2
        func pixel(_ x: CGFloat,_ y: CGFloat) -> CIImage { source.cropped(to:CGRect(x:floor(x),y:floor(y),width:1,height:1)).clampedToExtent().cropped(to:box) }
        /// One column (or row) outside the box, repeated across it.
        func column(_ x: CGFloat) -> CIImage { source.cropped(to:CGRect(x:floor(x),y:box.minY,width:1,height:box.height)).clampedToExtent().cropped(to:box) }
        func row(_ y: CGFloat) -> CIImage { source.cropped(to:CGRect(x:box.minX,y:floor(y),width:box.width,height:1)).clampedToExtent().cropped(to:box) }
        func ramp(horizontal: Bool) -> CIImage {
            let start=horizontal ? CIVector(x:box.minX,y:box.midY) : CIVector(x:box.midX,y:box.minY)
            let end=horizontal ? CIVector(x:box.maxX,y:box.midY) : CIVector(x:box.midX,y:box.maxY)
            return CIFilter(name:"CILinearGradient",parameters:["inputPoint0":start,"inputPoint1":end,"inputColor0":CIColor.black,"inputColor1":CIColor.white])!.outputImage!.cropped(to:box)
        }
        func mix(_ a: CIImage,_ b: CIImage,_ mask: CIImage) -> CIImage { b.applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:a,kCIInputMaskImageKey:mask]).cropped(to:box) }
        let across=ramp(horizontal:true),up=ramp(horizontal:false)
        let (left,right,bottom,top)=(box.minX-gap,box.maxX+gap-1,box.minY-gap,box.maxY+gap-1)
        let horizontal=mix(column(left),column(right),across)
        let vertical=mix(row(bottom),row(top),up)
        let corners=mix(mix(pixel(left,bottom),pixel(right,bottom),across),mix(pixel(left,top),pixel(right,top),across),up)
        // Coons patch: H + V − bilinear(corners) matches the surrounding pixels on all four sides.
        // Negated corners carry zero alpha so the sum keeps the opaque alpha of H + V.
        let negated=corners.applyingFilter("CIColorMatrix",parameters:["inputRVector":CIVector(x:-1,y:0,z:0,w:0),"inputGVector":CIVector(x:0,y:-1,z:0,w:0),"inputBVector":CIVector(x:0,y:0,z:-1,w:0),"inputAVector":CIVector(x:0,y:0,z:0,w:0)])
        let background=horizontal.applyingFilter("CIAdditionCompositing",parameters:[kCIInputBackgroundImageKey:vertical])
            .applyingFilter("CIAdditionCompositing",parameters:[kCIInputBackgroundImageKey:negated])
            .applyingFilter("CIColorClamp").cropped(to:box)
        guard strokesOnly else { return background }
        // Stroke mask: luminance distance from the estimate, thresholded, dilated and softened.
        let difference=image.cropped(to:box).applyingFilter("CIColorAbsoluteDifference",parameters:["inputImage2":background])
        let weights=CIVector(x:0.3*7,y:0.59*7,z:0.11*7,w:0),bias=CIVector(x:-0.55,y:-0.55,z:-0.55,w:1)
        let level=difference.applyingFilter("CIColorMatrix",parameters:["inputRVector":weights,"inputGVector":weights,"inputBVector":weights,"inputAVector":CIVector(x:0,y:0,z:0,w:0),"inputBiasVector":bias]).applyingFilter("CIColorClamp")
        let radius=max(1.5,min(box.width,box.height)*0.05)
        let mask=level.clampedToExtent().applyingFilter("CIMorphologyMaximum",parameters:[kCIInputRadiusKey:radius]).applyingGaussianBlur(sigma:1).cropped(to:box)
        // Fill strokes from nearby non-text pixels (normalized convolution: blur(image·keep) / blur(keep)), so
        // something passing the box edge does not leave a ghost of the letters. Where text covers too much
        // to have nearby picture, fall back to the edge interpolation.
        let keep=mask.applyingFilter("CIColorInvert")
        let sigma=max(3,radius*2.5)
        let weighted=image.cropped(to:box).applyingFilter("CIMultiplyCompositing",parameters:[kCIInputBackgroundImageKey:keep])
        let spread=weighted.clampedToExtent().applyingGaussianBlur(sigma:sigma).cropped(to:box)
        let weight=keep.clampedToExtent().applyingGaussianBlur(sigma:sigma).cropped(to:box)
        // CIDivideBlendMode computes background ÷ input.
        let local=weight.applyingFilter("CIDivideBlendMode",parameters:[kCIInputBackgroundImageKey:spread]).applyingFilter("CIColorClamp").cropped(to:box)
        let confidence=weight.applyingFilter("CIColorMatrix",parameters:["inputRVector":CIVector(x:8,y:0,z:0,w:0),"inputGVector":CIVector(x:8,y:0,z:0,w:0),"inputBVector":CIVector(x:8,y:0,z:0,w:0),"inputAVector":CIVector(x:0,y:0,z:0,w:0),"inputBiasVector":CIVector(x:0,y:0,z:0,w:1)]).applyingFilter("CIColorClamp")
        let filled=mix(background,local,confidence)
        return mix(image.cropped(to:box),filled,mask)
    }
}

/// Finds letterbox/pillarbox bars recorded into a video. Samples several frames and keeps the
/// smallest bar seen on each edge, so a dark scene is not mistaken for a border.
enum BlackBorderDetector {
    static func detect(path: String,sourceStart: Int64=0,sourceEnd: Int64?=nil,samples: Int=5) -> VideoCrop? {
        let asset=AVURLAsset(url:URL(fileURLWithPath:path))
        let generator=AVAssetImageGenerator(asset:asset)
        generator.appliesPreferredTrackTransform=true
        generator.maximumSize=CGSize(width:1280,height:1280)
        generator.requestedTimeToleranceBefore=CMTime(value:1,timescale:2); generator.requestedTimeToleranceAfter=CMTime(value:1,timescale:2)
        let end=sourceEnd ?? Int64(CMTimeGetSeconds(asset.duration)*1000)
        guard end>sourceStart else { return nil }
        var edges: [Double]?=nil
        for i in 0..<samples {
            let ms=sourceStart+(end-sourceStart)*Int64(i+1)/Int64(samples+1)
            guard let image=try? generator.copyCGImage(at:CMTime(value:ms,timescale:1000),actualTime:nil),let found=bars(in:image) else { continue }
            edges=edges.map { zip($0,found).map { min($0,$1) } } ?? found
        }
        guard let edges else { return nil }
        // Thin bars of a few pixels still show as a dark seam between cells, so keep them; cap so a mostly black frame is never cropped away.
        let value=edges.map { min(0.4,$0) }
        let crop=VideoCrop(top:value[0],bottom:value[1],left:value[2],right:value[3])
        return crop.isEmpty ? nil : crop
    }
    /// Top, bottom, left, right fractions of near-black rows/columns at each edge of an upright image.
    static func bars(in image: CGImage) -> [Double]? {
        let w=image.width,h=image.height
        guard w>8,h>8,let context=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGImageAlphaInfo.none.rawValue),
              let data=context.data else { return nil }
        context.draw(image,in:CGRect(x:0,y:0,width:w,height:h))
        let pixels=data.bindMemory(to:UInt8.self,capacity:w*h)
        // Context rows run top to bottom in memory.
        func dark(_ count: Int,_ value: (Int) -> UInt8) -> Bool {
            var sum=0,bright=0
            for i in 0..<count { let v=Int(value(i)); sum+=v; if v>48 { bright+=1 } }
            return sum<count*22 && bright*50<count
        }
        func rowDark(_ y: Int) -> Bool { dark(w) { pixels[y*w+$0] } }
        func columnDark(_ x: Int) -> Bool { dark(h) { pixels[$0*w+x] } }
        func run(_ limit: Int,_ isDark: (Int) -> Bool) -> Int { var n=0; while n<limit && isDark(n) { n+=1 }; return n }
        let top=run(h/2) { rowDark($0) },bottom=run(h/2) { rowDark(h-1-$0) }
        let left=run(w/2) { columnDark($0) },right=run(w/2) { columnDark(w-1-$0) }
        // An all-black frame says nothing about borders.
        if top>=h/2 || left>=w/2 { return nil }
        // Compression leaves a soft grey seam between a bar and the picture; cut 1% more to hide it.
        func edge(_ n: Int,_ total: Int) -> Double { n == 0 ? 0 : Double(n)/Double(total)+0.01 }
        return [edge(top,h),edge(bottom,h),edge(left,w),edge(right,w)]
    }
}
