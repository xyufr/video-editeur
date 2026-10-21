import Foundation
import AVFoundation
import AppKit
import CoreImage
import SubtitleCore

func runServiceChecks(video: URL, directory: URL) throws {
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    var passed=0
    func require(_ condition: Bool,_ name: String) throws { guard condition else { throw SubtitleError.invalid("CHECK_FAILED: \(name)") }; passed+=1; print("PASS \(name)") }
    let tools=ToolSettings(ffmpeg:"/missing/ffmpeg",python:"/usr/bin/true",codex:"/usr/bin/false",skill:directory.path)
    do { try tools.validate(); throw SubtitleError.invalid("missing dependency accepted") } catch { try require(error.localizedDescription.contains("ffmpeg"),"Missing dependency reports tool name") }
    let runner=CommandRunner(); let started=Date()
    DispatchQueue.global().asyncAfter(deadline:.now()+0.15) { runner.cancel() }
    do { _=try runner.run("/bin/sleep",["10"],directory:directory); throw SubtitleError.invalid("cancel accepted") }
    catch { try require(runner.isCancelled && Date().timeIntervalSince(started)<4,"Cancellation stops subprocess") }
    let timeout=CommandRunner()
    do { _=try timeout.run("/bin/sleep",["10"],directory:directory,timeout:0.1); throw SubtitleError.invalid("timeout accepted") }
    catch { try require(error.localizedDescription.contains("超时"),"Subprocess timeout is actionable") }
    let jobDir=directory.appendingPathComponent("job")
    try FileManager.default.createDirectory(at:jobDir.appendingPathComponent("scripts"),withIntermediateDirectories:true)
    try "Translate into Chinese".write(to:jobDir.appendingPathComponent("SKILL.md"),atomically:true,encoding:.utf8)
    try "# test fixture".write(to:jobDir.appendingPathComponent("scripts/transcribe_srt.py"),atomically:true,encoding:.utf8)
    let source=[Cue(language:.fr,start:0,end:1000,text:"Bonjour"),Cue(language:.fr,start:1000,end:2000,text:"Merci")]
    try JSONEncoder().encode(source).write(to:jobDir.appendingPathComponent("source.json"))
    let fixtureTools=ToolSettings(ffmpeg:"/usr/bin/true",python:"/usr/bin/true",codex:"/usr/bin/false",skill:jobDir.path)
    var partial: [Cue]=[]
    do { _=try GenerationJob(directory:jobDir,tools:fixtureTools).run(video:video,duration:3000,status:{_ in},partial:{partial=$0}); throw SubtitleError.invalid("translation should fail") }
    catch { try require(partial == source && error.localizedDescription.contains("false"),"Translation failure preserves completed French cues") }
    let translations=[Translation(id:source[0].id,text:"你好"),Translation(id:source[1].id,text:"谢谢")]
    let json=try JSONSerialization.data(withJSONObject:["translations":translations.map { ["id":$0.id.uuidString,"text":$0.text] }])
    try json.write(to:jobDir.appendingPathComponent("batch-0.json"))
    let result=try GenerationJob(directory:jobDir,tools:fixtureTools).run(video:video,duration:3000,status:{_ in},partial:{_ in})
    try require(result.count == 4 && result[2].text == "你好","Retry uses completed transcription and translation checkpoint")
    let asset=AVURLAsset(url:video); var project=Project(); project.videoPath=video.path; project.duration=Int64(CMTimeGetSeconds(asset.duration)*1000)
    project.cues=[Cue(language:.zh,start:0,end:project.duration,text:"取消测试")]
    let protected=directory.appendingPathComponent("cancelled.mp4"),original=Data("existing destination".utf8)
    try original.write(to:protected)
    let exporter=VideoExporter()
    do { try exporter.run(project:project,destination:protected) { value in if value>0 { exporter.cancel() } }; throw SubtitleError.invalid("export cancel should fail") }
    catch { try require(error.localizedDescription.contains("取消"),"Export cancellation exits cleanly") }
    try require(try Data(contentsOf:protected) == original,"Cancelled export preserves existing destination")
    let leftovers=try FileManager.default.contentsOfDirectory(atPath:directory.path).filter{$0.hasPrefix(".") && $0.hasSuffix(".mp4")}
    try require(leftovers.isEmpty,"Cancelled export removes temporary movie")
    do { try VideoExporter().run(project:project,destination:video) {_ in}; throw SubtitleError.invalid("source overwrite should fail") }
    catch { try require(error.localizedDescription.contains("不能覆盖"),"Source video overwrite is rejected") }
    print("SERVICE_CHECKS_OK \(passed)")
}

func runEditingChecks(directory: URL) throws {
    let a=directory.appendingPathComponent("a.mp4"),b=directory.appendingPathComponent("b.mp4")
    var project=Project()
    var first=VideoClip(path:a.path,duration:try MediaProbe(a.path).duration)
    var second=VideoClip(path:b.path,duration:try MediaProbe(b.path).duration)
    first.sourceStart=500; first.effects.fadeIn=300; first.effects.saturation=0.6
    second.transition=500; second.effects.fadeOut=300
    project=try project.replacingClips([first,second])
    project.cues=[Cue(language:.zh,start:0,end:project.duration,text:"多视频测试"),Cue(language:.fr,start:0,end:project.duration,text:"Bonjour, montage !")]
    try project.write(directory.appendingPathComponent("editing.frzh"))
    try VideoExporter().run(project:project,destination:directory.appendingPathComponent("edited.mp4")) {_ in}
    guard project.duration == first.duration+second.duration-500 else { throw SubtitleError.invalid("incorrect edit duration") }
    print("PASS multi-clip effects and dissolve export")
    let job=GenerationJob(directory:directory.appendingPathComponent("audio-"+UUID().uuidString))
    let mixedAudio=try EditorController().prepareTranscriptionInput(project:project,job:job)
    let audioAsset=AVURLAsset(url:mixedAudio)
    guard abs(CMTimeGetSeconds(audioAsset.duration)-Double(project.duration)/1000)<0.15 else { throw SubtitleError.invalid("mixed transcription audio duration mismatch") }
    print("PASS transcription uses edited mixed audio")
    for (file,color) in [("hlg",VideoColor.hlg),("pq",VideoColor.pq)] {
        let source=directory.appendingPathComponent(file+".mp4")
        let info=try MediaProbe(source.path)
        guard info.color == color else { throw SubtitleError.invalid("HDR detection failed") }
        var hdr=Project(); hdr.videoPath=source.path; hdr.duration=info.duration
        hdr.cues=[Cue(language:.zh,start:0,end:hdr.duration,text:"HDR 字幕测试")]
        try VideoExporter().run(project:hdr,destination:directory.appendingPathComponent(file+"-out.mp4"),color:color) {_ in}
        print("PASS \(file) 10-bit export")
        try VideoExporter().run(project:hdr,destination:directory.appendingPathComponent(file+"-sdr.mp4")) {_ in}
        var mixed=project; mixed=try mixed.replacingClips([first,VideoClip(path:source.path,duration:info.duration)])
        guard try MediaProbe.formats(mixed).0 == [.sdr] else { throw SubtitleError.invalid("Mixed HDR unexpectedly offered") }
        print("PASS mixed color limits HDR output")
    }
}

func runRegionEraseChecks(source: URL,destination: URL) throws {
    let blue=CIImage(color:CIColor(red:0,green:0,blue:1)).cropped(to:CGRect(x:0,y:0,width:100,height:100))
    let white=CIImage(color:CIColor(red:1,green:1,blue:1)).cropped(to:CGRect(x:20,y:20,width:60,height:20)).composited(over:blue)
    var clip=VideoClip(path:source.path,duration:2000)
    clip.eraseRegions=[VideoEraseRegion(x:0.1,y:0.1,width:0.8,height:0.4,sourceStart:500,sourceEnd:1500)]
    let context=CIContext()
    func pixel(_ image: CIImage) -> [UInt8] {
        var bytes=[UInt8](repeating:0,count:4)
        context.render(image,toBitmap:&bytes,rowBytes:4,bounds:CGRect(x:40,y:30,width:1,height:1),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
        return bytes
    }
    let automatic=pixel(VideoRegionRenderer.apply(to:white,clip:clip,sourceTime:1000,size:CGSize(width:100,height:100)))
    guard automatic[0]<5,automatic[1]<5,automatic[2]>250 else { throw SubtitleError.invalid("Automatic background sample mismatch: \(automatic)") }
    let inactive=pixel(VideoRegionRenderer.apply(to:white,clip:clip,sourceTime:1600,size:CGSize(width:100,height:100)))
    guard inactive[0]>250,inactive[1]>250 else { throw SubtitleError.invalid("Region time range failed") }
    clip.eraseRegions?[0].color=RGBA(1,0,0)
    let manual=pixel(VideoRegionRenderer.apply(to:white,clip:clip,sourceTime:1000,size:CGSize(width:100,height:100)))
    guard manual[0]>250,manual[1]<5,manual[2]<5 else { throw SubtitleError.invalid("Manual fill mismatch") }
    print("PASS automatic background, manual fill and time window")
    // Smart/patch: white "text" bars on a horizontal red→blue gradient with a dark speck inside the box.
    let gradient=CIFilter(name:"CILinearGradient",parameters:["inputPoint0":CIVector(x:0,y:50),"inputPoint1":CIVector(x:200,y:50),"inputColor0":CIColor(red:1,green:0,blue:0),"inputColor1":CIColor(red:0,green:0,blue:1)])!.outputImage!.cropped(to:CGRect(x:0,y:0,width:200,height:100))
    let speck=CIImage(color:CIColor(red:0.1,green:0.6,blue:0.1)).cropped(to:CGRect(x:150,y:60,width:4,height:4))
    let text=[CGRect(x:50,y:40,width:30,height:8),CGRect(x:95,y:40,width:30,height:8)].reduce(gradient) { CIImage(color:CIColor(red:1,green:1,blue:1)).cropped(to:$1).composited(over:$0) }
    let textured=speck.composited(over:text)
    func rgb(_ image: CIImage,_ x: Int,_ y: Int) -> [Int] {
        var bytes=[UInt8](repeating:0,count:4)
        context.render(image,toBitmap:&bytes,rowBytes:4,bounds:CGRect(x:x,y:y,width:1,height:1),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
        return bytes.prefix(3).map(Int.init)
    }
    var smartClip=VideoClip(path:source.path,duration:2000)
    smartClip.eraseRegions=[VideoEraseRegion(x:0.2,y:0.3,width:0.6,height:0.4,sourceStart:0,sourceEnd:2000,fill:.smart)]
    let smart=VideoRegionRenderer.apply(to:textured,clip:smartClip,sourceTime:100,size:CGSize(width:200,height:100))
    // Text pixels now follow the gradient; picture away from the strokes (inside and outside the box) is unchanged.
    for x in [55,75,100,120] {
        let after=rgb(smart,x,44),expected=rgb(gradient,x,44)
        guard zip(after,expected).allSatisfy({ abs($0-$1)<=40 }),after[1]<60 else { throw SubtitleError.invalid("Smart repair left text at \(x): \(after) vs \(expected)") }
    }
    func same(_ a: [Int],_ b: [Int]) -> Bool { zip(a,b).allSatisfy { abs($0-$1)<=2 } }
    guard same(rgb(smart,88,62),rgb(textured,88,62)),same(rgb(smart,10,44),rgb(textured,10,44)) else { throw SubtitleError.invalid("Smart repair changed pixels away from strokes: \(rgb(smart,88,62)) vs \(rgb(textured,88,62))") }
    smartClip.eraseRegions?[0].fill = .patch
    let patch=VideoRegionRenderer.apply(to:textured,clip:smartClip,sourceTime:100,size:CGSize(width:200,height:100))
    guard zip(rgb(patch,65,44),rgb(gradient,65,44)).allSatisfy({ abs($0-$1)<=40 }),same(rgb(patch,10,44),rgb(textured,10,44)) else { throw SubtitleError.invalid("Patch fill failed") }
    print("PASS smart repair replaces strokes and keeps the rest, patch fills from surroundings")
    let probe=try MediaProbe(source.path); clip=VideoClip(path:source.path,duration:probe.duration)
    clip.eraseRegions=[VideoEraseRegion(x:90.0/640,y:90.0/360,width:420.0/640,height:80.0/360,sourceStart:0,sourceEnd:probe.duration)]
    var project=try Project().replacingClips([clip])
    project.cues=[Cue(language:.zh,start:0,end:project.duration,text:"新增字幕保留")]
    try VideoExporter().run(project:project,destination:destination){_ in}
    print("PASS region erase export")
}

func runSubtitleAlignmentChecks() throws {
    for alignment in SubtitleAlignment.allCases {
        var project=Project(); project.duration=2000
        var style=SubtitleStyle(); style.width=0.8; style.alignment=alignment
        let cue=Cue(language:.fr,start:0,end:2000,text:"Bonjour docteur,\nComment allez-vous ?",style:style)
        project.cues=[cue]
        let (text,rect,pad)=SubtitleRenderer.box(cue:cue,project:project,size:CGSize(width:1920,height:1080))
        let background=SubtitleRenderer.backgroundRect(text:text,rect:rect,pad:pad)
        let paragraph=text.attribute(.paragraphStyle,at:0,effectiveRange:nil) as? NSParagraphStyle
        let expected: NSTextAlignment=alignment == .left ? .left : (alignment == .right ? .right : .center)
        let delta=alignment == .left ? background.minX-rect.minX : (alignment == .right ? background.maxX-rect.maxX : background.midX-rect.midX)
        guard paragraph?.alignment == expected,abs(delta)<0.01,background.width<rect.width else { throw SubtitleError.invalid("字幕对齐校验失败：\(alignment)") }
        print("PASS subtitle layout and fitted background: \(alignment)")
    }
}

func runRegionColorChecks() throws {
    let lower=CIImage(color:CIColor(red:1,green:0,blue:0)).cropped(to:CGRect(x:0,y:0,width:100,height:50))
    let upper=CIImage(color:CIColor(red:0,green:0,blue:1)).cropped(to:CGRect(x:0,y:50,width:100,height:50))
    let image=upper.composited(over:lower)
    let red=RegionColorSampler.sample(image,at:CGPoint(x:0,y:0))
    let blue=RegionColorSampler.sample(image,at:CGPoint(x:1,y:1))
    guard red.r>0.99,red.b<0.01,blue.b>0.99,blue.r<0.01,red.a==1,blue.a==1 else { throw SubtitleError.invalid("Point color orientation / bounds check failed") }
    print("PASS drag-start pixel color, bottom-left coordinates and edge clamping")
}

func runMusicChecks(directory: URL) throws {
    var project=Project(); project.videoPath=directory.appendingPathComponent("video.mp4").path; project.duration=2000
    var music=BackgroundMusic(path:directory.appendingPathComponent("背景 音乐.mp3").path,duration:3000); music.start=500; music.sourceStart=250; music.sourceEnd=2250; music.volume=0.5
    project.backgroundMusic=[music]
    let preview=try EditedAsset(project:project,color:.sdr,subtitles:false)
    guard preview.asset.tracks(withMediaType:.audio).count==2,abs(CMTimeGetSeconds(preview.asset.duration)-2)<0.02 else { throw SubtitleError.invalid("Mixed preview tracks/duration failed") }
    try VideoExporter().run(project:project,destination:directory.appendingPathComponent("mixed.mp4"),progress:{_ in})
    project.muteVideoAudio=true
    let muted=try EditedAsset(project:project,color:.sdr,subtitles:false)
    guard muted.asset.tracks(withMediaType:.audio).count==1 else { throw SubtitleError.invalid("Original video audio was not removed") }
    try VideoExporter().run(project:project,destination:directory.appendingPathComponent("muted.mp4"),progress:{_ in})
    print("PASS music preview mix, clipped duration, original audio mute and both exports")
}

/// Colored fixtures a (red), b (blue), c (green): each cell must show its own video edge to edge, in preview and export.
func runSplitScreenChecks(directory: URL) throws {
    // Output frame rate follows nominal rates (never a stray 1/600 s frame), snapped to standard rates, at most 60.
    let rates: [([Float],CMTime)]=[([60.0356],CMTime(value:1,timescale:60)),([30.0445,60.0356],CMTime(value:1,timescale:60)),([29.97],CMTime(value:1001,timescale:30000)),
                                   ([25],CMTime(value:1,timescale:25)),([23.976],CMTime(value:1001,timescale:24000)),([240],CMTime(value:1,timescale:60)),([15],CMTime(value:1,timescale:15)),([],CMTime(value:1,timescale:30)),([.nan],CMTime(value:1,timescale:30))]
    for (input,expected) in rates where EditedAsset.outputFrameDuration(rates:input) != expected { throw SubtitleError.invalid("Frame rate \(input) -> \(CMTimeGetSeconds(EditedAsset.outputFrameDuration(rates:input)))") }
    let urls=["a","b","c"].map { directory.appendingPathComponent($0+".mp4") }
    func color(_ frame: CGImage,_ x: Int,_ y: Int) -> String {
        var bytes=[UInt8](repeating:0,count:4)
        CIContext().render(CIImage(cgImage:frame),toBitmap:&bytes,rowBytes:4,bounds:CGRect(x:x,y:y,width:1,height:1),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB))
        let (r,g,b)=(Int(bytes[0]),Int(bytes[1]),Int(bytes[2]))
        return r>150 && g<90 && b<90 ? "red" : b>150 && r<90 ? "blue" : g>90 && r<90 && b<90 ? "green" : "other(\(r),\(g),\(b))"
    }
    func frames(_ project: Project,at ms: Int64,name: String) throws -> [CGImage] {
        let preview=try EditedAsset(project:project,color:.sdr,subtitles:false)
        let generator=AVAssetImageGenerator(asset:preview.asset); generator.videoComposition=preview.video
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let output=directory.appendingPathComponent(name+".mp4")
        try VideoExporter().run(project:project,destination:output) {_ in}
        let exportedRate=Double(AVURLAsset(url:output).tracks(withMediaType:.video).first?.nominalFrameRate ?? 0)
        let sourceRates=project.allClips.compactMap { AVURLAsset(url:URL(fileURLWithPath:$0.path)).tracks(withMediaType:.video).first?.nominalFrameRate }
        let expectedRate=1/CMTimeGetSeconds(EditedAsset.outputFrameDuration(rates:sourceRates))
        guard abs(exportedRate-expectedRate)<1 else { throw SubtitleError.invalid("Export frame rate \(exportedRate), expected \(expectedRate)") }
        let exported=AVAssetImageGenerator(asset:AVURLAsset(url:output))
        exported.requestedTimeToleranceBefore = .zero; exported.requestedTimeToleranceAfter = .zero
        return [try generator.copyCGImage(at:CMTime(value:ms,timescale:1000),actualTime:nil),try exported.copyCGImage(at:CMTime(value:ms,timescale:1000),actualTime:nil)]
    }
    let editor=EditorController(); _=editor.view
    DispatchQueue.main.asyncAfter(deadline:.now()+0.2) {
        if let view=NSApp.modalWindow?.contentView, let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) {
            view.cacheDisplay(in:view.bounds,to:bitmap)
            try? bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:"/tmp/split-screen-dialog-\(InterfaceLanguage.current.rawValue).png"))
        }
        NSApp.stopModal(withCode:.alertFirstButtonReturn)
    }
    guard let picked=editor.chooseSplitLayout(count:3),picked.0 == .column,picked.1 == .fitVideos,picked.2 else { throw SubtitleError.invalid("Split dialog defaults failed") }
    DispatchQueue.main.asyncAfter(deadline:.now()+0.2) { NSApp.stopModal(withCode:.alertSecondButtonReturn) }
    guard editor.chooseSplitLayout(count:4) == nil else { throw SubtitleError.invalid("Split dialog cancel failed") }
    guard editor.addSplitScreen(urls,layout:.column,canvas:.portrait) else { throw SubtitleError.invalid("Split screen import failed") }
    let column=editor.project
    guard column.clips.count == 1,column.layerTracks.count == 2,column.canvas == .portrait else { throw SubtitleError.invalid("Split screen tracks wrong") }
    for frame in try frames(column,at:1000,name:"split-column") {
        guard frame.width == 180,frame.height == 320 else { throw SubtitleError.invalid("Portrait canvas size \(frame.width)x\(frame.height)") }
        // CGImage rows start at the bottom here: top cell is the first video.
        let cells=[(318,"red"),(270,"red"),(216,"red"),(210,"blue"),(160,"blue"),(110,"blue"),(104,"green"),(50,"green"),(2,"green")]
        for (y,expected) in cells { for x in [2,90,177] where color(frame,x,y) != expected { throw SubtitleError.invalid("Column cell at \(x),\(y) is \(color(frame,x,y)), expected \(expected)") } }
    }
    // Edit dialogs: move a track clip to the 2 × 2 bottom-right cell and switch the canvas, then return the main clip to full canvas.
    func popups(_ view: NSView) -> [NSPopUpButton] { (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap(popups) }
    func runDialog(snapshot: String?,position: String,canvas: String,_ open: () -> Void) {
        DispatchQueue.main.asyncAfter(deadline:.now()+0.2) {
            guard let view=NSApp.modalWindow?.contentView else { return }
            if let snapshot, let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) {
                view.cacheDisplay(in:view.bounds,to:bitmap)
                try? bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:"/tmp/\(snapshot)-\(InterfaceLanguage.current.rawValue).png"))
            }
            for popup in popups(view) {
                if popup.accessibilityLabel() == L("画面位置") { popup.selectItem(withTitle:position) }
                if popup.accessibilityLabel() == L("画布（整个工程）") { popup.selectItem(withTitle:canvas) }
            }
            NSApp.stopModal(withCode:.alertFirstButtonReturn)
        }
        open()
    }
    let topLayer=column.layers.first { $0.clip.frame == SplitLayout.column.cells(3)[1] }!
    RunLoop.main.run(until:Date().addingTimeInterval(0.1))
    runDialog(snapshot:"split-position-dialog",position:L("2 × 2 · 右下"),canvas:CanvasAspect.square.title) { editor.editVideoLayer(topLayer) }
    RunLoop.main.run(until:Date().addingTimeInterval(0.1))
    guard editor.project.layers.first(where:{ $0.id == topLayer.id })?.clip.frame == SplitLayout.grid.cells(4)[3],editor.project.canvas == .square else { throw SubtitleError.invalid("Track clip position/canvas edit failed") }
    editor.selectedClip=editor.project.clips[0].id; editor.timeline.selectedClip=editor.selectedClip
    runDialog(snapshot:nil,position:L("全画布"),canvas:CanvasAspect.source.title) { editor.editSelectedVideo() }
    guard editor.project.clips[0].frame == nil,editor.project.canvasAspect == nil else { throw SubtitleError.invalid("Main clip position/canvas edit failed") }
    RunLoop.main.run(until:Date().addingTimeInterval(0.1)); editor.history.undo(); editor.history.undo()
    guard editor.project == column else { throw SubtitleError.invalid("Position edits must undo step by step: canvas \(String(describing:editor.project.canvasAspect)) frames \(editor.project.allClips.map { $0.frame.map { "\($0.x),\($0.y),\($0.width)" } ?? "nil" }) layers \(editor.project.layers.count) vs \(column.layers.count)") }
    RunLoop.main.run(until:Date().addingTimeInterval(0.1)); editor.history.undo()
    guard editor.project.allClips.isEmpty,editor.project.canvasAspect == nil else { throw SubtitleError.invalid("Split screen undo failed") }
    var base=try Project().replacingClips([VideoClip(path:urls[2].path,duration:2000)])
    base=try base.addingSplitScreen(urls.prefix(2).map { VideoClip(path:$0.path,duration:2000) },layout:.row,canvas:.landscape,at:500)
    for frame in try frames(base,at:1000,name:"split-row") {
        for (x,expected) in [(2,"red"),(80,"red"),(158,"red"),(162,"blue"),(240,"blue"),(317,"blue")] where color(frame,x,90) != expected { throw SubtitleError.invalid("Row cell at \(x) is \(color(frame,x,90)), expected \(expected)") }
    }
    // Letterboxed source: bars are detected and cropped so the cell is red to its edges.
    let boxed=directory.appendingPathComponent("d.mp4")
    guard let detected=BlackBorderDetector.detect(path:boxed.path),abs(detected.top-20.0/180)<0.03,abs(detected.bottom-20.0/180)<0.03,detected.left == 0,detected.right == 0 else { throw SubtitleError.invalid("Letterbox detection failed: \(String(describing:BlackBorderDetector.detect(path:boxed.path)))") }
    guard BlackBorderDetector.detect(path:urls[0].path) == nil else { throw SubtitleError.invalid("Borderless video reported bars") }
    let boxedEditor=EditorController(); _=boxedEditor.view
    guard boxedEditor.addSplitScreen([boxed,urls[1]],layout:.column,canvas:.portrait) else { throw SubtitleError.invalid("Letterboxed split failed") }
    for frame in try frames(boxedEditor.project,at:1000,name:"split-letterbox") {
        for (y,expected) in [(318,"red"),(240,"red"),(162,"red"),(158,"blue"),(2,"blue")] { for x in [2,90,177] where color(frame,x,y) != expected { throw SubtitleError.invalid("Letterboxed cell at \(x),\(y) is \(color(frame,x,y)), expected \(expected)") } }
    }
    // A source whose edit list starts with an empty segment must render its first frame there, in preview and export.
    let emptyEdit=directory.appendingPathComponent("e.mp4")
    var lead=Project(); lead.videoPath=emptyEdit.path; lead.duration=Int64(CMTimeGetSeconds(AVURLAsset(url:emptyEdit).duration)*1000)
    for frame in try frames(lead,at:20,name:"empty-edit") where color(frame,160,90) != "red" { throw SubtitleError.invalid("Empty leading edit rendered \(color(frame,160,90))") }
    // End together: 2.0 s and 2.1 s videos. Added with the option, or trimmed later with the toolbar action.
    let endEditor=EditorController(); _=endEditor.view
    guard endEditor.addSplitScreen([urls[0],emptyEdit],layout:.row,canvas:.landscape,endTogether:true),
          Set(endEditor.project.renderPlacements.map(\.end)).count == 1 else { throw SubtitleError.invalid("Split end-together option failed: \(endEditor.project.renderPlacements.map(\.end))") }
    let laterEditor=EditorController(); _=laterEditor.view
    guard laterEditor.addSplitScreen([urls[0],emptyEdit],layout:.row,canvas:.landscape),Set(laterEditor.project.renderPlacements.map(\.end)).count == 2 else { throw SubtitleError.invalid("Split without option changed lengths") }
    let unaligned=laterEditor.project
    RunLoop.main.run(until:Date().addingTimeInterval(0.1))
    laterEditor.selectedClip=nil; laterEditor.current=500
    laterEditor.endSplitTogether()
    guard Set(laterEditor.project.renderPlacements.map(\.end)) == [unaligned.renderPlacements.map(\.end).min()!] else { throw SubtitleError.invalid("End-together action failed") }
    RunLoop.main.run(until:Date().addingTimeInterval(0.1)); laterEditor.history.undo()
    guard laterEditor.project == unaligned else { throw SubtitleError.invalid("End-together undo failed") }
    guard laterEditor.bottom.subviews.contains(where:{ $0.identifier?.rawValue == "endTogether" }) else { throw SubtitleError.invalid("End-together button missing") }
    let toolbarWindow=NSWindow(contentRect:NSRect(x:0,y:0,width:1140,height:760),styleMask:[.titled],backing:.buffered,defer:false)
    toolbarWindow.contentViewController=laterEditor; laterEditor.view.layoutSubtreeIfNeeded()
    if let bitmap=laterEditor.bottom.bitmapImageRepForCachingDisplay(in:laterEditor.bottom.bounds) {
        laterEditor.bottom.cacheDisplay(in:laterEditor.bottom.bounds,to:bitmap)
        try? bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:"/tmp/split-end-toolbar-\(InterfaceLanguage.current.rawValue).png"))
    }
    // Region erase on a video-track clip (not only the main track): default smart repair, one undo step.
    let eraseEditor=EditorController(); _=eraseEditor.view
    guard eraseEditor.addSplitScreen([urls[0],urls[1]],layout:.row,canvas:.landscape) else { throw SubtitleError.invalid("Erase split failed") }
    let trackClip=eraseEditor.project.layers[0].clip,beforeErase=eraseEditor.project
    RunLoop.main.run(until:Date().addingTimeInterval(0.1))
    // As in the app with nothing selected: the tool starts on the main (left) clip, but the box is drawn in the right cell.
    eraseEditor.current=500
    eraseEditor.eraseClipID=eraseEditor.project.clips[0].id; eraseEditor.overlay.eraseMode=true; eraseEditor.overlay.eraseRect=CGRect(x:0.6,y:0.1,width:0.3,height:0.1)
    DispatchQueue.main.asyncAfter(deadline:.now()+0.2) {
        guard let view=NSApp.modalWindow?.contentView else { return }
        if let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) {
            view.cacheDisplay(in:view.bounds,to:bitmap)
            try? bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:"/tmp/erase-dialog-\(InterfaceLanguage.current.rawValue).png"))
        }
        NSApp.stopModal(withCode:.alertFirstButtonReturn)
    }
    eraseEditor.applySelectedEraseRegion()
    guard let erased=eraseEditor.project.layers.first(where:{ $0.id == trackClip.id })?.clip.eraseRegions,erased.count == 1,erased[0].fillMode == .smart,erased[0].color == nil,
          !eraseEditor.overlay.eraseMode else { throw SubtitleError.invalid("Track clip erase failed: \(String(describing:eraseEditor.project.layers.first?.clip.eraseRegions))") }
    guard eraseEditor.project.clips[0].eraseRegions == nil else { throw SubtitleError.invalid("Erase region went to the main clip instead of the cell under the box") }
    // The region renders inside that cell: a manual red fill shows in the right (blue) cell's box only.
    var redProject=eraseEditor.project
    if let i=redProject.videoLayers?.firstIndex(where:{ $0.id == trackClip.id }) { redProject.videoLayers?[i].clip.eraseRegions?[0].fill = .solid; redProject.videoLayers?[i].clip.eraseRegions?[0].color=RGBA(1,0,0,1) }
    for frame in try frames(redProject,at:500,name:"cell-erase") {
        let w=frame.width,h=frame.height
        guard color(frame,Int(Double(w)*0.75),Int(Double(h)*0.15)) == "red",color(frame,Int(Double(w)*0.75),Int(Double(h)*0.6)) == "blue" else { throw SubtitleError.invalid("Cell erase not rendered") }
    }
    RunLoop.main.run(until:Date().addingTimeInterval(0.1)); eraseEditor.history.undo()
    guard eraseEditor.project == beforeErase else { throw SubtitleError.invalid("Track clip erase undo failed") }
    // Divider drag in the preview: mouse down on the line between the cells, drag up, release.
    let overlayWindow=NSWindow(contentRect:NSRect(x:0,y:0,width:400,height:400),styleMask:[.titled],backing:.buffered,defer:false)
    let overlay=PreviewOverlay(frame:overlayWindow.contentView!.bounds); overlayWindow.contentView!.addSubview(overlay)
    var split=try Project().addingSplitScreen((0..<2).map { _ in VideoClip(path:urls[0].path,duration:2000) },layout:.column,canvas:.portrait,at:0)
    overlay.project=split; overlay.videoSize=CGSize(width:180,height:320); overlay.time=500
    var moved: (SplitDivider,Double)?
    overlay.onDividerMoved={ moved=($0,$1) }
    func mouse(_ type: NSEvent.EventType,_ point: CGPoint) -> NSEvent { NSEvent.mouseEvent(with:type,location:overlay.convert(point,to:nil),modifierFlags:[],timestamp:0,windowNumber:overlayWindow.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)! }
    let r=overlay.videoRect,start=CGPoint(x:r.midX+30,y:r.midY+2),end=CGPoint(x:r.midX+30,y:r.minY+r.height*0.7)
    guard overlay.divider(at:start) != nil,overlay.divider(at:CGPoint(x:r.midX,y:r.midY+40)) == nil else { throw SubtitleError.invalid("Divider hit area wrong") }
    overlay.mouseDown(with:mouse(.leftMouseDown,start)); overlay.mouseDragged(with:mouse(.leftMouseDragged,end)); overlay.mouseUp(with:mouse(.leftMouseUp,end))
    guard let (divider,position)=moved,abs(position-0.7)<0.01 else { throw SubtitleError.invalid("Divider drag not reported: \(String(describing:moved))") }
    split=try split.movingSplitDivider(divider,to:position)
    guard let top=split.clips[0].frame,abs(top.y-0.7)<0.01,abs(top.height-0.3)<0.01 else { throw SubtitleError.invalid("Divider move result wrong") }
    overlay.project=split; overlay.wantsLayer=true; overlay.layer?.backgroundColor=NSColor.darkGray.cgColor
    if let bitmap=overlay.bitmapImageRepForCachingDisplay(in:overlay.bounds) {
        overlay.cacheDisplay(in:overlay.bounds,to:bitmap)
        try? bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:"/tmp/split-divider-preview.png"))
    }
    overlay.showsDividers=false; moved=nil
    overlay.mouseDown(with:mouse(.leftMouseDown,start)); overlay.mouseUp(with:mouse(.leftMouseUp,end))
    guard moved == nil,overlay.dividers.isEmpty else { throw SubtitleError.invalid("Dividers must not move during playback") }
    // Through the editor: one undo step.
    let dividerEditor=EditorController(); _=dividerEditor.view
    dividerEditor.project=try Project().addingSplitScreen((0..<2).map { _ in VideoClip(path:urls[0].path,duration:2000) },layout:.row,canvas:.landscape,at:0)
    let beforeMove=dividerEditor.project
    RunLoop.main.run(until:Date().addingTimeInterval(0.1))
    dividerEditor.overlay.onDividerMoved?(beforeMove.splitDividers(at:0)[0],0.35)
    guard abs((dividerEditor.project.clips[0].frame?.width ?? 0)-0.35)<1e-9 else { throw SubtitleError.invalid("Editor divider commit failed") }
    RunLoop.main.run(until:Date().addingTimeInterval(0.1)); dividerEditor.history.undo()
    guard dividerEditor.project == beforeMove else { throw SubtitleError.invalid("Divider move undo failed") }
    // Auto canvas: a 16:9 video over the letterboxed one (picture 320×140 after crop) — both whole, no bars.
    let fitEditor=EditorController(); _=fitEditor.view
    guard fitEditor.addSplitScreen([urls[1],boxed],layout:.column,canvas:.fitVideos),let fitRatio=fitEditor.project.canvasRatio else { throw SubtitleError.invalid("Auto canvas split failed") }
    let boxedAspect=try shownAspect(fitEditor.project.layers[0].clip)
    guard abs(fitRatio-1/(9.0/16+1/boxedAspect))<1e-6 else { throw SubtitleError.invalid("Auto canvas ratio \(fitRatio)") }
    for frame in try frames(fitEditor.project,at:1000,name:"split-fit") {
        let w=frame.width,h=frame.height,split=Int(Double(h)*(1/boxedAspect)/(9.0/16+1/boxedAspect))
        guard abs(Double(w)/Double(h)-fitRatio)<0.02 else { throw SubtitleError.invalid("Auto canvas size \(w)x\(h)") }
        for (y,expected) in [(h-2,"blue"),(split+3,"blue"),(split-3,"red"),(1,"red")] { for x in [1,w/2,w-2] where color(frame,x,y) != expected { throw SubtitleError.invalid("Auto canvas cell at \(x),\(y) is \(color(frame,x,y)), expected \(expected)") } }
    }
    // Manual adjustment: the dialog's Auto button refills the fields after they were cleared.
    func fields(_ view: NSView) -> [NSTextField] { (view as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? view.subviews.flatMap(fields) }
    func buttons(_ view: NSView) -> [ActionButton] { (view as? ActionButton).map { [$0] } ?? view.subviews.flatMap(buttons) }
    let boxedClip=boxedEditor.project.clips[0]
    boxedEditor.selectedClip=boxedClip.id; boxedEditor.timeline.selectedClip=boxedClip.id
    RunLoop.main.run(until:Date().addingTimeInterval(0.1))
    DispatchQueue.main.asyncAfter(deadline:.now()+0.2) {
        guard let view=NSApp.modalWindow?.contentView else { return }
        let crops=fields(view).filter { $0.accessibilityLabel()?.hasPrefix(L("裁切")) == true }
        crops.forEach { $0.stringValue="0" }
        buttons(view).first { $0.title == L("自动") }?.performClick(nil)
        if let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) {
            view.cacheDisplay(in:view.bounds,to:bitmap)
            try? bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:"/tmp/split-crop-dialog-\(InterfaceLanguage.current.rawValue).png"))
        }
        crops[2].stringValue="5"
        NSApp.stopModal(withCode:.alertFirstButtonReturn)
    }
    boxedEditor.editSelectedVideo()
    guard let edited=boxedEditor.project.clips[0].crop,abs(edited.top-detected.top)<0.002,abs(edited.left-0.05)<1e-9 else { throw SubtitleError.invalid("Crop dialog failed: \(String(describing:boxedEditor.project.clips[0].crop))") }
    print("SPLIT_SCREEN_OK column 9:16 and row 16:9 cells fill edge to edge in preview and export, main video becomes first cell, edit-dialog position/canvas changes, letterbox auto-crop and manual crop, auto canvas shows each video whole, preview divider drag, empty leading edit, end together, track-clip smart erase, undo restores")
}

func runMultiTrackChecks(directory: URL) throws {
    let a=directory.appendingPathComponent("a.mp4"),b=directory.appendingPathComponent("b.mp4")
    var p=try Project().replacingClips([VideoClip(path:a.path,duration:2000)])
    var upper=VideoLayer(clip:VideoClip(path:b.path,duration:2000),start:500)
    // Legacy geometry must no longer create a small image.
    upper.x=0.75; upper.y=0.75; upper.scale=0.4
    p=try p.replacingLayers([upper]); p=try p.cuttingLayer(upper.id,at:1500)
    try p.write(directory.appendingPathComponent("multitrack.frzh"))
    func pixel(_ frame:CGImage,_ x:Int,_ y:Int)->[UInt8] {
        var bytes=[UInt8](repeating:0,count:4)
        CIContext().render(CIImage(cgImage:frame),toBitmap:&bytes,rowBytes:4,bounds:CGRect(x:x,y:y,width:1,height:1),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB))
        return bytes
    }
    func requireBlue(_ frame:CGImage) throws {
        for point in [(20,20),(160,90),(300,160)] {
            let color=pixel(frame,point.0,point.1)
            guard color[2]>150,color[0]<80 else { throw SubtitleError.invalid("Upper track did not fill canvas: \(color)") }
        }
    }
    let preview=try EditedAsset(project:p,color:.sdr,subtitles:false)
    let generator=AVAssetImageGenerator(asset:preview.asset); generator.videoComposition=preview.video
    generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
    try requireBlue(generator.copyCGImage(at:CMTime(value:1000,timescale:1000),actualTime:nil))
    let outputURL=directory.appendingPathComponent("multitrack.mp4")
    try VideoExporter().run(project:p,destination:outputURL) {_ in}
    let output=AVURLAsset(url:outputURL),images=AVAssetImageGenerator(asset:output)
    images.requestedTimeToleranceBefore = .zero; images.requestedTimeToleranceAfter = .zero
    try requireBlue(images.copyCGImage(at:CMTime(value:2000,timescale:1000),actualTime:nil))
    guard abs(CMTimeGetSeconds(output.duration)-2.5)<0.1 else { throw SubtitleError.invalid("Multitrack output duration failed") }
    let emptyTimeline=TimelineView(frame:NSRect(x:0,y:0,width:900,height:400))
    guard emptyTimeline.subtitleRowCount == 0, emptyTimeline.layerY == 51 else { throw SubtitleError.invalid("Empty subtitle rows should be hidden") }
    emptyTimeline.project.textTracks=[TextTrack(name:"Title")]
    let textCue=Cue(language:.fr,start:0,end:1000,text:"Title",trackID:emptyTimeline.project.tracks[0].id)
    guard emptyTimeline.rect(textCue).minY == 47 else { throw SubtitleError.invalid("Hidden subtitle rows left a gap") }
    emptyTimeline.subtitleTracksRequested=true
    guard emptyTimeline.subtitleRowCount == 2, emptyTimeline.rect(textCue).minY == 135 else { throw SubtitleError.invalid("Generate must reveal subtitle rows") }
    emptyTimeline.subtitleTracksRequested=false
    emptyTimeline.project.cues=[Cue(language:.zh,start:0,end:1000,text:"字幕")]
    guard emptyTimeline.subtitleRowCount == 2 else { throw SubtitleError.invalid("Existing subtitles must remain visible") }
    let timeline=TimelineView(frame:NSRect(x:0,y:0,width:900,height:400)); timeline.project=p; timeline.pointsPerSecond=180
    let window=NSWindow(contentRect:timeline.bounds,styleMask:[.titled],backing:.buffered,defer:false)
    window.contentView=timeline; timeline.layoutSubtreeIfNeeded()
    guard timeline.videoRowY(p.layers[0].id)==timeline.videoRowY(p.layers[1].id) else { throw SubtitleError.invalid("Split moved to another row") }
    let controls=timeline.subviews.compactMap{$0 as? NSButton}.filter{$0.identifier?.rawValue==upper.trackIdentifier.uuidString}.sorted{$0.tag<$1.tag}
    var calls:[Int]=[]
    timeline.toggleLayerTrackControl={ id,control in
        guard id==upper.trackIdentifier else { return }; calls.append(control)
        var values=timeline.project.layers
        for i in values.indices {
            switch control { case 0: values[i].locked=true; case 1: values[i].hidden=true; default: values[i].muted=true }
        }
        timeline.project.videoLayers=values; timeline.layoutSubtreeIfNeeded()
    }
    guard controls.count==3 else { throw SubtitleError.invalid("Multitrack controls missing") }
    for button in controls { button.performClick(nil) }
    guard calls==[0,1,2],controls.allSatisfy({$0.state == .on}) else { throw SubtitleError.invalid("Multitrack controls failed") }
    let hidden=try EditedAsset(project:timeline.project,color:.sdr,subtitles:false)
    guard hidden.asset.tracks(withMediaType:.audio).count==1 else { throw SubtitleError.invalid("Track mute did not affect all clips") }
    let hiddenFrames=AVAssetImageGenerator(asset:hidden.asset); hiddenFrames.videoComposition=hidden.video
    let red=pixel(try hiddenFrames.copyCGImage(at:CMTime(value:1000,timescale:1000),actualTime:nil),160,90)
    guard red[0]>150,red[2]<80 else { throw SubtitleError.invalid("Hidden upper track did not reveal lower video") }
    timeline.project=p; timeline.layoutSubtreeIfNeeded()
    func event(_ type:NSEvent.EventType,_ point:NSPoint)->NSEvent {
        NSEvent.mouseEvent(with:type,location:timeline.convert(point,to:nil),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
    }
    var moved:VideoLayer?; timeline.moveVideoLayer={moved=$0}
    timeline.transferVideoClip={id,destination,time in
        moved=(try? timeline.project.transferringClip(id,to:destination,at:time))?.layers.first{$0.id == id}
    }
    let source=NSPoint(x:timeline.x(2000),y:timeline.videoRowY(p.layers[1].id)+35)
    timeline.mouseDown(with:event(.leftMouseDown,source))
    let target=NSPoint(x:source.x+90,y:source.y)
    timeline.mouseDragged(with:event(.leftMouseDragged,target)); timeline.mouseUp(with:event(.leftMouseUp,target))
    guard moved?.start==2000,moved?.trackIdentifier==upper.trackIdentifier else { throw SubtitleError.invalid("Track clip movement failed") }
    let cross=try p.addingLayer(from:p.clips[0].id,at:3000)
    timeline.project=cross; timeline.layoutSubtreeIfNeeded(); moved=nil
    let crossSource=NSPoint(x:timeline.x(2000),y:timeline.videoRowY(p.layers[1].id)+35)
    let crossTarget=NSPoint(x:crossSource.x,y:timeline.videoRowY(cross.layers[0].id)+35)
    timeline.mouseDown(with:event(.leftMouseDown,crossSource))
    timeline.mouseDragged(with:event(.leftMouseDragged,crossTarget)); timeline.mouseUp(with:event(.leftMouseUp,crossTarget))
    guard moved?.trackIdentifier==cross.layers[0].trackIdentifier,moved?.start==1500 else { throw SubtitleError.invalid("Cross-track drag failed") }
    var contextAction:Int?
    timeline.editVideoTrack={_,action in contextAction=action}
    guard let menu=timeline.menu(for:event(.rightMouseDown,NSPoint(x:20,y:crossTarget.y))),menu.items.count==3 else { throw SubtitleError.invalid("Track context menu missing") }
    menu.performActionForItem(at:0)
    guard contextAction==0 else { throw SubtitleError.invalid("Track deletion menu callback failed") }
    let main=try Project().replacingClips([VideoClip(path:a.path,duration:2000),VideoClip(path:b.path,duration:2000)])
    timeline.project=main; timeline.layoutSubtreeIfNeeded()
    var reordered:UUID?; var insertion:Int64?
    timeline.transferVideoClip={id,destination,time in if destination == .main { reordered=id; insertion=time } }
    let mainStart=NSPoint(x:timeline.x(1000),y:timeline.videoY+35),mainEnd=NSPoint(x:timeline.x(6000),y:timeline.videoY+35)
    timeline.mouseDown(with:event(.leftMouseDown,mainStart)); timeline.mouseDragged(with:event(.leftMouseDragged,mainEnd)); timeline.mouseUp(with:event(.leftMouseUp,mainEnd))
    guard reordered==main.clips[0].id,insertion==5000 else { throw SubtitleError.invalid("Main track absolute movement failed") }
    var transferred:Project?; var transferCount=0
    timeline.transferVideoClip={id,destination,time in
        transferred=try? timeline.project.transferringClip(id,to:destination,at:time); transferCount+=1
    }
    timeline.project=main; timeline.layoutSubtreeIfNeeded()
    let existing=try main.addingLayer(from:main.clips[0].id,at:5000)
    timeline.project=existing; timeline.layoutSubtreeIfNeeded()
    let fromMain=NSPoint(x:timeline.x(1000),y:timeline.videoY+35)
    let toUpper=NSPoint(x:fromMain.x,y:timeline.videoRowY(existing.layers[0].id)+35)
    timeline.mouseDown(with:event(.leftMouseDown,fromMain)); timeline.mouseDragged(with:event(.leftMouseDragged,toUpper)); timeline.mouseUp(with:event(.leftMouseUp,toUpper))
    guard let onUpper=transferred,onUpper.layerTracks[0].count==2,onUpper.clips.count==1,onUpper.layers.contains(where:{$0.id==main.clips[0].id}),transferCount==1 else { throw SubtitleError.invalid("Main-to-existing timeline transfer failed") }
    timeline.project=onUpper; timeline.layoutSubtreeIfNeeded(); transferred=nil
    let fromUpper=NSPoint(x:timeline.x(1000),y:timeline.videoRowY(main.clips[0].id)+35)
    let toNew=NSPoint(x:fromUpper.x,y:timeline.newLayerY+20)
    timeline.mouseDown(with:event(.leftMouseDown,fromUpper)); timeline.mouseDragged(with:event(.leftMouseDragged,toNew)); timeline.mouseUp(with:event(.leftMouseUp,toNew))
    guard let onNew=transferred,onNew.layerTracks.count==2,onNew.layers.first?.id==main.clips[0].id,transferCount==2 else { throw SubtitleError.invalid("Timeline new-track transfer failed") }
    timeline.project=onNew; timeline.layoutSubtreeIfNeeded(); transferred=nil
    let backStart=NSPoint(x:timeline.x(1000),y:timeline.videoRowY(main.clips[0].id)+35),backEnd=NSPoint(x:timeline.x(1000),y:timeline.videoY+35)
    timeline.mouseDown(with:event(.leftMouseDown,backStart)); timeline.mouseDragged(with:event(.leftMouseDragged,backEnd)); timeline.mouseUp(with:event(.leftMouseUp,backEnd))
    guard let back=transferred,back.clips.map(\.id)==main.clips.map(\.id),transferCount==3 else { throw SubtitleError.invalid("Timeline transfer back to main failed") }
    timeline.project=back; timeline.layoutSubtreeIfNeeded(); transferred=nil
    let cancelStart=NSPoint(x:timeline.x(1000),y:timeline.videoY+35),cancelEnd=NSPoint(x:timeline.x(1000),y:timeline.newLayerY+20)
    timeline.mouseDown(with:event(.leftMouseDown,cancelStart)); timeline.mouseDragged(with:event(.leftMouseDragged,cancelEnd)); timeline.cancelOperation(nil); timeline.mouseUp(with:event(.leftMouseUp,cancelEnd))
    guard transferred==nil,transferCount==3 else { throw SubtitleError.invalid("Cancelled timeline transfer committed") }
    print("PASS main/existing/new track transfers, stable clip IDs, single completion and Esc cancellation")
    let delayed=try Project().replacingClips([VideoClip(path:a.path,duration:2000)])
    let delayedProject=try delayed.movingMainClip(delayed.clips[0].id,to:5000)
    let delayedURL=directory.appendingPathComponent("delayed-main.mp4")
    try VideoExporter().run(project:delayedProject,destination:delayedURL) {_ in}
    let delayedAsset=AVURLAsset(url:delayedURL),delayedFrames=AVAssetImageGenerator(asset:AVURLAsset(url:delayedURL))
    delayedFrames.requestedTimeToleranceBefore = .zero; delayedFrames.requestedTimeToleranceAfter = .zero
    let empty=pixel(try delayedFrames.copyCGImage(at:CMTime(value:1000,timescale:1000),actualTime:nil),160,90)
    let filled=pixel(try delayedFrames.copyCGImage(at:CMTime(value:5500,timescale:1000),actualTime:nil),160,90)
    guard empty.prefix(3).allSatisfy({$0<15}),filled[0]>150,filled[2]<80,abs(CMTimeGetSeconds(delayedAsset.duration)-7)<0.1 else { throw SubtitleError.invalid("Delayed main video export timing failed") }
    timeline.project=try cross.movingMainClip(cross.clips[0].id,to:5000); timeline.layoutSubtreeIfNeeded()
    if let bitmap=timeline.bitmapImageRepForCachingDisplay(in:timeline.bounds) {
        timeline.cacheDisplay(in:timeline.bounds,to:bitmap)
        try bitmap.representation(using:.png,properties:[:])?.write(to:directory.appendingPathComponent("tracks-"+InterfaceLanguage.current.rawValue+".png"))
    }
    print("MULTITRACK_CHECKS_OK full-canvas preview/export, split row, track controls, mute, hide, timeline movement, cross-track drag, track menu and main movement to 5 seconds with leading black export")
}

// Uses temporary project files; never touches the user's recovery or saved projects.
func runCloseChecks() throws {
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:directory) }
    let editor=EditorController(); _=editor.view
    guard !editor.needsSaveBeforeClosing else { throw SubtitleError.invalid("Blank project should close directly") }
    editor.project.videoPath=directory.appendingPathComponent("source.mp4").path
    editor.project.duration=2000
    guard editor.needsSaveBeforeClosing else { throw SubtitleError.invalid("New project must prompt") }
    let url=directory.appendingPathComponent("Saved.frzh")
    try editor.project.write(url); editor.projectURL=url
    guard !editor.needsSaveBeforeClosing else { throw SubtitleError.invalid("Saved project should close directly") }
    editor.project.cues=[Cue(language:.zh,start:0,end:1000,text:"未保存")]
    guard editor.needsSaveBeforeClosing else { throw SubtitleError.invalid("Edited project must prompt") }
    for (response,expected) in [(NSApplication.ModalResponse.alertThirdButtonReturn,false),(.alertSecondButtonReturn,true)] {
        DispatchQueue.main.asyncAfter(deadline:.now()+0.2) { NSApp.stopModal(withCode:response) }
        guard editor.confirmSaveBeforeClosing() == expected else { throw SubtitleError.invalid("Close confirmation response failed") }
    }
    guard try Project.read(url).cues.isEmpty else { throw SubtitleError.invalid("Discard changed saved file") }
    try editor.project.write(url)
    guard !editor.needsSaveBeforeClosing else { throw SubtitleError.invalid("Saving must clear pending changes") }
    print("CLOSE_OK blank, new, saved, modified, cancel, discard and saved-file preservation")
}

func runCodexPathChecks() throws {
    let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:dir) }
    let custom=dir.appendingPathComponent("custom").path, detected=dir.appendingPathComponent("codex").path
    let plain=dir.appendingPathComponent("not-executable").path, missing=dir.appendingPathComponent("old-path").path
    for path in [custom,detected,plain] {
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to:URL(fileURLWithPath:path))
        try FileManager.default.setAttributes([.posixPermissions:path == plain ? 0o644 : 0o755],ofItemAtPath:path)
    }
    guard ToolSettings.detectCodex(configured:custom,candidates:[detected]) == custom,
          ToolSettings.detectCodex(configured:missing,candidates:[plain,dir.path,detected]) == detected,
          ToolSettings.detectCodex(configured:missing,candidates:[plain,dir.path]) == nil else {
        throw SubtitleError.invalid("Codex path resolution regression")
    }
    try FileManager.default.removeItem(atPath:custom)
    guard ToolSettings.detectCodex(configured:custom,candidates:[detected]) == detected else { throw SubtitleError.invalid("Relocated CLI was not detected") }
    guard let actual=ToolSettings.detectCodex(configured:"/missing/codex") else { throw SubtitleError.invalid("No local Codex executable detected") }
    print("CODEX_PATH_OK custom priority, missing/non-executable paths, relocated CLI; local: \(actual)")
}

func runMultilingualChecks() throws {
    let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:dir) }
    let skill=dir.appendingPathComponent("skill")
    try FileManager.default.createDirectory(at:skill.appendingPathComponent("scripts"),withIntermediateDirectories:true)
    try "fixture".write(to:skill.appendingPathComponent("SKILL.md"),atomically:true,encoding:.utf8)
    let transcribe=#"""
    import sys
    from pathlib import Path
    language=sys.argv[sys.argv.index('--language')+1]
    text='Bonjour' if language=='fr' else 'Hello'
    Path(sys.argv[sys.argv.index('--output')+1]).write_text('1\n00:00:00,000 --> 00:00:01,000\n'+text+'\n')
    """#
    try transcribe.write(to:skill.appendingPathComponent("scripts/transcribe_srt.py"),atomically:true,encoding:.utf8)
    let codex=dir.appendingPathComponent("codex")
    let translator=#"""
    #!/usr/bin/python3
    import json,sys
    from pathlib import Path
    prompt=sys.stdin.read()
    language=prompt.split(' into ')[1].split('.')[0]
    data=json.loads(prompt.split('BEGIN_SUBTITLE_DATA\n')[1].split('\nEND_SUBTITLE_DATA')[0])
    text={'zh':'你好','en':'Hello!','fr':'Bonjour !'}[language]
    Path(sys.argv[sys.argv.index('-o')+1]).write_text(json.dumps({'translations':[{'id':x['id'],'text':text} for x in data]}))
    """#
    try translator.write(to:codex,atomically:true,encoding:.utf8)
    try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:codex.path)
    let tools=ToolSettings(ffmpeg:"/usr/bin/true",python:"/usr/bin/python3",codex:codex.path,skill:skill.path)
    for source in [Language.fr,.en] {
        for target in [Language.zh,.en,.fr] {
            let languages=GenerationLanguages(source:source,target:target)
            let folder=dir.appendingPathComponent(source.rawValue+target.rawValue)
            let job=GenerationJob(directory:folder,tools:tools,languages:languages)
            let cues=try job.run(video:dir.appendingPathComponent("fixture.mp4"),duration:2000,status:{_ in},partial:{_ in})
            guard cues.count == (source == target ? 1 : 2),cues.first?.language == source,cues.last?.language == target else { throw SubtitleError.invalid("Language routing failed") }
            let resumed=try job.run(video:dir.appendingPathComponent("fixture.mp4"),duration:2000,status:{_ in},partial:{_ in})
            guard resumed.map(\.text) == cues.map(\.text) else { throw SubtitleError.invalid("Retry cache failed") }
            let wrong=GenerationJob(directory:folder,tools:tools,languages:GenerationLanguages(source:source == .fr ? .en : .fr,target:target))
            do { _ = try wrong.run(video:dir,duration:2000,status:{_ in},partial:{_ in}); throw SubtitleError.invalid("Language mismatch accepted") }
            catch { guard error.localizedDescription.contains(L("任务语言不匹配，请重新生成")) else { throw error } }
        }
    }
    let claude=dir.appendingPathComponent("claude")
    let claudeTranslator=#"""
    #!/usr/bin/python3
    import json,sys
    from pathlib import Path
    assert '--json-schema' in sys.argv and '-p' in sys.argv
    prompt=sys.stdin.read()
    data=json.loads(prompt.split('BEGIN_SUBTITLE_DATA\n')[1].split('\nEND_SUBTITLE_DATA')[0])
    sys.stderr.write('diagnostic noise\n')
    Path('model.txt').write_text(sys.argv[sys.argv.index('--model')+1] if '--model' in sys.argv else '')
    print(json.dumps({'type':'result','is_error':False,'structured_output':{'translations':[{'id':x['id'],'text':'你好'} for x in data]}}))
    """#
    try claudeTranslator.write(to:claude,atomically:true,encoding:.utf8)
    try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:claude.path)
    let claudeTools=ToolSettings(ffmpeg:"/usr/bin/true",python:"/usr/bin/python3",codex:"/missing/codex",skill:skill.path,model:.claude,claude:claude.path)
    let claudeCues=try GenerationJob(directory:dir.appendingPathComponent("claude-job"),tools:claudeTools).run(video:dir.appendingPathComponent("fixture.mp4"),duration:2000,status:{_ in},partial:{_ in})
    guard claudeCues.last?.language == .zh, claudeCues.last?.text == "你好" else { throw SubtitleError.invalid("Claude translation routing failed") }
    guard try String(contentsOf:dir.appendingPathComponent("claude-job/model.txt"),encoding:.utf8).isEmpty else { throw SubtitleError.invalid("Default Claude model must not pass --model") }
    var sonnetTools=claudeTools; sonnetTools.claudeModel = .sonnet
    _ = try GenerationJob(directory:dir.appendingPathComponent("claude-sonnet-job"),tools:sonnetTools).run(video:dir.appendingPathComponent("fixture.mp4"),duration:2000,status:{_ in},partial:{_ in})
    guard try String(contentsOf:dir.appendingPathComponent("claude-sonnet-job/model.txt"),encoding:.utf8) == "sonnet" else { throw SubtitleError.invalid("Claude model choice was not passed") }
    // Partial replies: one untranslated name, one empty item, then an unusable batch; the job must finish.
    let partialSkill=dir.appendingPathComponent("partial-skill")
    try FileManager.default.createDirectory(at:partialSkill.appendingPathComponent("scripts"),withIntermediateDirectories:true)
    try "fixture".write(to:partialSkill.appendingPathComponent("SKILL.md"),atomically:true,encoding:.utf8)
    let manyCues=#"""
    import sys
    from pathlib import Path
    lines=[]
    for i in range(32):
        lines+= [str(i+1),'00:00:%02d,000 --> 00:00:%02d,500' % (i,i),'Nébécé, El Cabré.' if i==0 else 'Bonjour %d' % i,'']
    Path(sys.argv[sys.argv.index('--output')+1]).write_text('\n'.join(lines))
    """#
    try manyCues.write(to:partialSkill.appendingPathComponent("scripts/transcribe_srt.py"),atomically:true,encoding:.utf8)
    let partialClaude=dir.appendingPathComponent("claude-partial")
    let partialTranslator=#"""
    #!/usr/bin/python3
    import json,sys
    prompt=sys.stdin.read()
    data=json.loads(prompt.split('BEGIN_SUBTITLE_DATA\n')[1].split('\nEND_SUBTITLE_DATA')[0])
    if len(data) < 30:
        print(json.dumps({'type':'result','is_error':False,'structured_output':{'oops':True}})); sys.exit(0)
    items=[{'id':x['id'],'text':x['text'].replace('.','。') if i==0 else ('' if i==1 else '你好')} for i,x in enumerate(data)]
    print(json.dumps({'type':'result','is_error':False,'structured_output':{'translations':items}}))
    """#
    try partialTranslator.write(to:partialClaude,atomically:true,encoding:.utf8)
    try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:partialClaude.path)
    let partialJob=GenerationJob(directory:dir.appendingPathComponent("claude-partial-job"),tools:ToolSettings(ffmpeg:"/usr/bin/true",python:"/usr/bin/python3",skill:partialSkill.path,model:.claude,claude:partialClaude.path))
    let partialCues=try partialJob.run(video:dir.appendingPathComponent("fixture.mp4"),duration:40000,status:{_ in},partial:{_ in})
    let partialZh=partialCues.filter { $0.language == .zh }
    guard partialCues.filter({ $0.language == .fr }).count == 32, partialZh.count == 29, partialZh.first?.text == "Nébécé, El Cabré。",
          partialJob.skippedTranslations == 3 else { throw SubtitleError.invalid("Partial translation stopped the job: \(partialZh.count) zh, \(partialJob.skippedTranslations) skipped") }
    let loggedOut=dir.appendingPathComponent("claude-logged-out")
    try "#!/bin/sh\ncat >/dev/null\necho '{\"type\":\"result\",\"is_error\":true,\"result\":\"Not logged in · Please run /login\"}'\nexit 1\n".write(to:loggedOut,atomically:true,encoding:.utf8)
    try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:loggedOut.path)
    do {
        _ = try GenerationJob(directory:dir.appendingPathComponent("claude-logged-out-job"),tools:ToolSettings(ffmpeg:"/usr/bin/true",python:"/usr/bin/python3",skill:skill.path,model:.claude,claude:loggedOut.path)).run(video:dir.appendingPathComponent("fixture.mp4"),duration:2000,status:{_ in},partial:{_ in})
        throw SubtitleError.invalid("Logged-out Claude accepted")
    } catch { guard error.localizedDescription.contains("Not logged in"), error.localizedDescription.contains("/login") else { throw error } }
    let legacy=try JSONDecoder().decode(ToolSettings.self,from:Data(#"{"ffmpeg":"a","python":"b","codex":"c","skill":"d"}"#.utf8))
    guard legacy.model == .codex, legacy.modelPath == "c", legacy.claudeModel == .standard else { throw SubtitleError.invalid("Legacy tool settings did not default to Codex") }
    let editor=EditorController(); _=editor.view
    DispatchQueue.main.asyncAfter(deadline:.now()+0.2) {
        if let view=NSApp.modalWindow?.contentView, let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) {
            view.cacheDisplay(in:view.bounds,to:bitmap)
            try? bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:"/tmp/subtitle-language-picker-\(InterfaceLanguage.current.rawValue).png"))
        }
        NSApp.stopModal(withCode:.alertFirstButtonReturn)
    }
    guard let initialOptions=editor.chooseGenerationLanguages(), initialOptions.languages == GenerationLanguages(), !initialOptions.filesOnly else { throw SubtitleError.invalid("Picker defaults failed") }
    DispatchQueue.main.asyncAfter(deadline:.now()+0.2) {
        func find(_ view: NSView) -> NSButton? {
            if let button=view as? NSButton,button.identifier?.rawValue == "generateSRTOnly" { return button }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        if let view=NSApp.modalWindow?.contentView { find(view)?.state = .on }
        NSApp.stopModal(withCode:.alertFirstButtonReturn)
    }
    guard editor.chooseGenerationLanguages()?.filesOnly == true else { throw SubtitleError.invalid("SRT checkbox selection failed") }
    editor.project.generationLanguages=GenerationLanguages(source:.en,target:.fr)
    DispatchQueue.main.asyncAfter(deadline:.now()+0.2) { NSApp.stopModal(withCode:.alertFirstButtonReturn) }
    guard editor.chooseGenerationLanguages()?.languages == editor.project.generationLanguages else { throw SubtitleError.invalid("Picker restoration failed") }
    DispatchQueue.main.asyncAfter(deadline:.now()+0.2) { NSApp.stopModal(withCode:.alertSecondButtonReturn) }
    guard editor.chooseGenerationLanguages() == nil else { throw SubtitleError.invalid("Picker cancel failed") }
    DispatchQueue.main.asyncAfter(deadline:.now()+0.2) {
        if let view=NSApp.modalWindow?.contentView, let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) {
            view.cacheDisplay(in:view.bounds,to:bitmap)
            try? bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:"/tmp/tool-settings-\(InterfaceLanguage.current.rawValue).png"))
        }
        NSApp.stopModal(withCode:.alertSecondButtonReturn)
    }
    editor.showSettings()
    editor.refresh()
    guard editor.displayMode.label(forSegment:0) == Language.en.title, editor.displayMode.label(forSegment:1) == Language.fr.title else { throw SubtitleError.invalid("Display language controls failed") }
    // Deleting subtitle files from the Subtitles list (with confirmation), text tracks too, and undo.
    let listEditor=EditorController(); _=listEditor.view
    let listWindow=NSWindow(contentRect:NSRect(x:0,y:0,width:1140,height:760),styleMask:[.titled],backing:.buffered,defer:false)
    listWindow.contentViewController=listEditor
    var listed=Project(); listed.videoPath=dir.appendingPathComponent("fixture.mp4").path; listed.duration=10000; listed.generationLanguages=GenerationLanguages()
    let titleTrack=TextTrack(name:"Title"); listed.textTracks=[titleTrack]
    listed.cues=[Cue(language:.fr,start:0,end:1000,text:"Bonjour"),Cue(language:.zh,start:0,end:1000,text:"你好"),Cue(language:.zh,start:1000,end:2000,text:"再见"),Cue(language:.zh,start:3000,end:4000,text:"标题",trackID:titleTrack.id)]
    listEditor.project=listed; listEditor.timeline.subtitleTracksRequested=true
    listEditor.languageChoice.selectedSegment=1; listEditor.refresh(); listEditor.root.needsLayout=true; listEditor.root.layoutSubtreeIfNeeded(); listEditor.table.reloadData()
    func deleteButtons() -> Int { (0..<listEditor.table.numberOfRows).compactMap { listEditor.table.view(atColumn:0,row:$0,makeIfNecessary:true) }.filter { $0.subviews.contains { $0.identifier?.rawValue == "deleteLibraryEntry" } }.count }
    guard listEditor.libraryEntries.count == 3,deleteButtons() == 3 else { throw SubtitleError.invalid("Subtitle list rows or delete buttons missing: \(listEditor.libraryEntries.count) / \(deleteButtons())") }
    if let bitmap=listEditor.left.bitmapImageRepForCachingDisplay(in:listEditor.left.bounds) {
        listEditor.left.cacheDisplay(in:listEditor.left.bounds,to:bitmap)
        try? bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:"/tmp/subtitle-list-delete-\(InterfaceLanguage.current.rawValue).png"))
    }
    let rowsBefore=listEditor.timeline.subtitleRowCount
    RunLoop.main.run(until:Date().addingTimeInterval(0.1))
    DispatchQueue.main.asyncAfter(deadline:.now()+0.2) {
        if let view=NSApp.modalWindow?.contentView,let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) {
            view.cacheDisplay(in:view.bounds,to:bitmap)
            try? bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:"/tmp/subtitle-delete-confirm-\(InterfaceLanguage.current.rawValue).png"))
        }
        NSApp.stopModal(withCode:.alertFirstButtonReturn)
    }
    listEditor.deleteLibraryEntry(listEditor.libraryEntries.first { $0.language == .zh }!)
    guard listEditor.project.cues.map(\.text) == ["Bonjour","标题"],listEditor.libraryEntries.map(\.title).contains(where:{ $0.hasPrefix(Language.zh.title) }) == false,
          listEditor.timeline.subtitleRowCount == rowsBefore-1,listEditor.table.numberOfRows == 2 else { throw SubtitleError.invalid("Subtitle file delete failed: \(listEditor.project.cues.map(\.text)) rows \(listEditor.timeline.subtitleRowCount)") }
    DispatchQueue.main.asyncAfter(deadline:.now()+0.2) { NSApp.stopModal(withCode:.alertSecondButtonReturn) }
    listEditor.deleteLibraryEntry(listEditor.libraryEntries.first { $0.trackID != nil }!)
    guard listEditor.project.tracks.count == 1 else { throw SubtitleError.invalid("Cancel must keep the text track") }
    RunLoop.main.run(until:Date().addingTimeInterval(0.1))
    listEditor.deleteLibraryEntry(listEditor.libraryEntries.first { $0.trackID != nil }!,confirm:false)
    guard listEditor.project.tracks.isEmpty,listEditor.project.cues.map(\.text) == ["Bonjour"] else { throw SubtitleError.invalid("Text track delete failed") }
    RunLoop.main.run(until:Date().addingTimeInterval(0.1)); listEditor.history.undo()
    RunLoop.main.run(until:Date().addingTimeInterval(0.1)); listEditor.history.undo()
    guard listEditor.project == listed else { throw SubtitleError.invalid("Subtitle file delete undo failed") }
    print("MULTILINGUAL_OK six pairs, subtitle-file and text-track delete from the list with confirm/cancel/undo, Claude/Codex routing, Claude login error, skipped empty/unusable translations, legacy settings, same-language transcription, cache isolation, retry, picker defaults/cancel and display labels (offline fixtures)")
}

func runTimelineFileDropChecks() throws {
    let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:dir) }
    let video=dir.appendingPathComponent("video.mp4"),music=dir.appendingPathComponent("music.mp3"),text=dir.appendingPathComponent("notes.txt")
    for file in [video,music,text] { try Data().write(to:file) }
    let board=NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    func put(_ urls: [URL]) { board.clearContents(); board.writeObjects(urls.map { $0 as NSURL }) }
    let editor=EditorController(); _=editor.view
    let timeline=editor.timeline
    var imported:[URL]=[]
    var newTrackTime: Int64?
    timeline.dropFiles={ imported=$0; newTrackTime=$1; return true }
    put([video,music])
    guard timeline.registeredDraggedTypes.contains(.fileURL),timeline.acceptsFileDrop(board),timeline.importFileDrop(board),imported == [video,music],newTrackTime == nil else { throw SubtitleError.invalid("Timeline mixed file drop routing failed") }
    guard timeline.importFileDrop(board,newTrackAt:1500),newTrackTime == 1500 else { throw SubtitleError.invalid("New-track zone file drop lost its target") }
    editor.languageChoice.selectedSegment=1
    guard timeline.acceptsFileDrop(board) else { throw SubtitleError.invalid("Timeline must accept files with subtitles tab selected") }
    editor.busy=true
    guard !timeline.acceptsFileDrop(board),!timeline.importFileDrop(board) else { throw SubtitleError.invalid("Busy timeline accepted drop") }
    editor.busy=false; editor.project.lockVideoTrack=true
    guard !timeline.acceptsFileDrop(board) else { throw SubtitleError.invalid("Locked video track accepted mixed drop") }
    put([music])
    guard timeline.acceptsFileDrop(board),timeline.importFileDrop(board),imported == [music] else { throw SubtitleError.invalid("Locked video track rejected music") }
    timeline.editingEnabled=false
    guard !timeline.acceptsFileDrop(board) else { throw SubtitleError.invalid("Disabled timeline accepted drop") }
    timeline.editingEnabled=true; editor.project.lockVideoTrack=false
    for urls in [[text],[video,text],[dir],[dir.appendingPathComponent("missing.mp4")]] {
        put(urls)
        guard !timeline.acceptsFileDrop(board),!timeline.importFileDrop(board) else { throw SubtitleError.invalid("Unsupported file drop accepted") }
    }
    board.clearContents(); board.setString("https://example.com/video.mp4",forType:.string)
    guard !timeline.acceptsFileDrop(board) else { throw SubtitleError.invalid("Text URL accepted as local media") }
    var routed=""
    if let index=CommandLine.arguments.firstIndex(of:"--drop-fixture"),CommandLine.arguments.count>index+1 {
        // Real media: a drop on the new-track zone must create a track, not extend the main video.
        let fixture=URL(fileURLWithPath:CommandLine.arguments[index+1])
        let real=EditorController(); _=real.view
        guard real.appendMedia([fixture]) else { throw SubtitleError.invalid("Fixture import failed") }
        let main=real.project.clips
        RunLoop.main.run(until:Date().addingTimeInterval(0.1)) // Close the run-loop undo group of the first import.
        guard real.appendMedia([fixture],newTrackAt:500),real.project.clips == main,real.project.layerTracks.count == 1,
              real.project.layers[0].start == 500,real.project.layers[0].clip.path == fixture.path else { throw SubtitleError.invalid("New-track zone drop appended to the main video") }
        RunLoop.main.run(until:Date().addingTimeInterval(0.1)); real.history.undo()
        guard real.project.clips == main,real.project.layers.isEmpty else { throw SubtitleError.invalid("New-track drop undo failed: \(real.project.clips.count) main, \(real.project.layers.count) layers") }
        routed=", real new-track drop and undo"
    }
    print("TIMELINE_FILE_DROP_OK mixed files, audio, subtitles tab, busy/lock/disabled guards and unsupported files\(routed)")
}

func runSubtitleFileOutputChecks() throws {
    let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:dir) }
    var project=Project(); project.videoPath=dir.appendingPathComponent("video.mp4").path; project.duration=2000; project.playbackRate=2
    let cues=[Cue(language:.fr,start:0,end:2000,text:"Bonjour"),Cue(language:.zh,start:0,end:2000,text:"你好")]
    let pair=GenerationLanguages()
    let urls=try SubtitleFileOutput.write(cues:cues,languages:pair,project:project,destination:dir)
    guard urls.map(\.lastPathComponent) == ["video.fr.srt","video.zh.srt"],
          try SRT.parse(String(contentsOf:urls[0]),language:.fr).first?.end == 1000,
          try SRT.parse(String(contentsOf:urls[1]),language:.zh).first?.text == "你好" else { throw SubtitleError.invalid("SRT output timing or language failed") }
    let saved=try Data(contentsOf:urls[0])
    let second=try SubtitleFileOutput.write(cues:cues,languages:pair,project:project,destination:dir)
    guard second[0] != urls[0],try Data(contentsOf:urls[0]) == saved else { throw SubtitleError.invalid("Existing SRT was overwritten") }
    let same=try SubtitleFileOutput.write(cues:[cues[0]],languages:GenerationLanguages(source:.fr,target:.fr),project:project,destination:dir)
    guard same.count == 2,same[0] != same[1],try Data(contentsOf:same[0]) == Data(contentsOf:same[1]) else { throw SubtitleError.invalid("Same-language pair failed") }
    let count=try FileManager.default.contentsOfDirectory(atPath:dir.path).count
    do { _ = try SubtitleFileOutput.write(cues:[],languages:pair,project:project,destination:dir); throw SubtitleError.invalid("Empty SRT accepted") }
    catch { guard error.localizedDescription.contains(L("字幕文件内容不完整")) else { throw error } }
    guard try FileManager.default.contentsOfDirectory(atPath:dir.path).count == count else { throw SubtitleError.invalid("Failed output left files") }
    print("SRT_OUTPUT_OK two files, languages, export-speed timing, collision protection, same-language pair and failed output cleanup")
}

func runLocalLibraryChecks() throws {
    let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:dir.appendingPathComponent("one/two"),withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:dir) }
    for path in ["root.mp4","one/child.mov","one/two/deep.mp4","audio.mp3","notes.txt",".hidden.mp4"] { try Data().write(to:dir.appendingPathComponent(path)) }
    try FileManager.default.createSymbolicLink(at:dir.appendingPathComponent("one/loop"),withDestinationURL:dir)
    let scan=LocalVideoScan(),urls=try LocalVideoScan().videoURLs(in:dir)
    guard Set(urls.map(\.lastPathComponent)) == Set(["root.mp4","child.mov","deep.mp4"]) else { throw SubtitleError.invalid("Recursive library file filtering failed") }
    scan.cancel()
    guard try scan.videoURLs(in:dir).isEmpty else { throw SubtitleError.invalid("Cancelled scan continued") }
    guard try LocalVideoScan().scan(dir).isEmpty else { throw SubtitleError.invalid("Invalid videos were accepted") }
    if let index=CommandLine.arguments.firstIndex(of:"--library-fixture"),CommandLine.arguments.count>index+1 {
        let fixture=URL(fileURLWithPath:CommandLine.arguments[index+1])
        let nested=dir.appendingPathComponent("one/two/real.mp4")
        try FileManager.default.copyItem(at:fixture,to:nested)
        let videos=try LocalVideoScan().scan(dir)
        guard videos.count == 1,videos[0].url.standardizedFileURL.resolvingSymlinksInPath().path == nested.standardizedFileURL.resolvingSymlinksInPath().path,videos[0].duration>0,videos[0].image != nil else { throw SubtitleError.invalid("Playable video metadata/thumbnail failed: \(videos.map { "\($0.url.path):\($0.duration):\($0.image != nil)" })") }
    }
    let editor=EditorController(); _=editor.view
    guard editor.showsMedia,!editor.showsLocalLibrary else { throw SubtitleError.invalid("Startup must show Media even with a configured local library") }
    editor.localLibraryJob?.cancel()
    editor.inspectorScroll.scrollerStyle = .legacy; editor.inspectorScroll.tile()
    guard editor.selected == nil,editor.inspectorScroll.scrollerStyle == .overlay,
          editor.inspectorScroll.verticalScroller?.alphaValue == 0 else { throw SubtitleError.invalid("Unselected subtitle inspector must not show a permanent scrollbar") }
    editor.tableScroll.scrollerStyle = .legacy
    editor.tableScroll.tile()
    guard editor.tableScroll.scrollerStyle == .overlay,editor.tableScroll.verticalScroller?.alphaValue == 0 else { throw SubtitleError.invalid("Library scrollbar must stay hidden without a permanent gutter") }
    guard let textScroll=editor.textEditor.enclosingScrollView else { throw SubtitleError.invalid("Missing text editor scroll view") }
    textScroll.scrollerStyle = .legacy; textScroll.tile()
    guard textScroll.scrollerStyle == .overlay,textScroll.verticalScroller?.alphaValue == 0,editor.textEditor.frame.minX == 0 else { throw SubtitleError.invalid("Text editor scrollbar or left edge regression") }
    let before=editor.project
    guard editor.project.clips.isEmpty, !editor.timelineScroll.showsScrollers, !editor.timelineScroll.hasHorizontalScroller, !editor.timelineScroll.hasVerticalScroller else { throw SubtitleError.invalid("Timeline scrollbars must be hidden while no video is on the timeline") }
    editor.project.videoPath=urls[0].path; editor.project.duration=12000; editor.resizeTimeline()
    guard editor.timelineScroll.showsScrollers, editor.timelineScroll.scrollerStyle == .legacy, !editor.timelineScroll.autohidesScrollers,
          editor.timelineScroll.hasHorizontalScroller, !editor.timelineScroll.hasVerticalScroller else { throw SubtitleError.invalid("Timeline must show only the bottom scrollbar once a video is on the timeline") }
    editor.project=before; editor.resizeTimeline()
    guard !editor.timelineScroll.showsScrollers else { throw SubtitleError.invalid("Timeline scrollbars must hide again without video") }
    editor.localLibraryEntries=[LocalVideoEntry(url:urls[0],duration:12000,image:nil)]
    editor.languageChoice.selectedSegment=2; editor.refresh(); editor.root.needsLayout=true; editor.root.layoutSubtreeIfNeeded()
    guard editor.languageChoice.segmentCount == 3,editor.mediaGrid.cards.count == 1,
          editor.mediaGrid.cards[0].fileURL == urls[0],!editor.mediaGrid.cards[0].isAdded,editor.project == before,
          editor.mediaGrid.superview != nil else { throw SubtitleError.invalid("Local library changed project or failed to display") }
    editor.mediaSearch.stringValue="no-match"; editor.refreshMediaGrid()
    guard editor.mediaGrid.cards.isEmpty else { throw SubtitleError.invalid("Local library search failed") }
    print("LOCAL_LIBRARY_OK recursive folders, filtering, symlink loop, cancellation, invalid media, grid/search and unchanged project")
}
