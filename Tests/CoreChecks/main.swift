import Foundation
import CoreGraphics
import SubtitleCore
var failures=0, passed=0
func check(_ name: String,_ body: () throws -> Bool) {
    do { if try body() { passed+=1; print("PASS \(name)") } else { failures+=1; print("FAIL \(name)") } }
    catch { failures+=1; print("FAIL \(name): \(error)") }
}
func rejects(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
check("New subtitle defaults and saved styles remain independent") {
    var q=Project()
    guard q.frenchStyle.size == 70, q.chineseStyle.size == 60,
          q.frenchStyle.width == 0.98, q.chineseStyle.width == 0.98 else { return false }
    q.frenchStyle.size=60; q.chineseStyle.size=54
    q.frenchStyle.width=nil; q.chineseStyle.width=0.75
    let restored=try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(q))
    return restored == q
}
let fr="1\r\n00:00:00,000 --> 00:00:01,500\r\nBonjour\r\n\r\n2\r\n00:00:01,500 --> 00:00:03,000\r\nUne histoire\r\n"
let cues=try SRT.parse(fr,language:.fr)
check("SRT CRLF and touching boundaries") { cues.count == 2 && cues[1].start == 1500 }
check("SRT round trip") { let decoded=try SRT.parse(SRT.encode(cues),language:.fr); return decoded.map(\.text) == cues.map(\.text) && decoded.map(\.end) == cues.map(\.end) }
check("BOM and Chinese single line") { let c=try SRT.parse("\u{FEFF}1\n00:00:00,000 --> 00:00:01,000\n你好\n世界\n",language:.zh); return c[0].text == "你好，世界" }
check("Reject malformed time") { rejects { _ = try SRT.time("00:61:00,000") } }
check("Reject overlapping SRT") { rejects { _ = try SRT.parse(fr.replacingOccurrences(of:"00:00:01,500 -->",with:"00:00:01,000 -->"),language:.fr) } }
check("Reject reversed interval") { rejects { _ = try SRT.parse("1\n00:00:02,000 --> 00:00:01,000\nX",language:.fr) } }
check("SRT hour formatting") { SRT.timestamp(3_661_007) == "01:01:01,007" }
var p=Project(); p.duration=5000; p.cues=cues
check("Active end is exclusive") { p.active(at:1500).count == 1 && p.active(at:1500)[0].text == "Une histoire" }
check("Add clipped at video end") { let c=try p.newCue(language:.zh,at:4500); return c.end == 5000 }
check("Add clips to next subtitle") { var q=p; q.cues=[Cue(language:.zh,start:1000,end:2000,text:"已有")]; return try q.newCue(language:.zh,at:500).end == 1000 }
check("Reject add in occupied interval") { rejects { _ = try p.newCue(language:.fr,at:1000) } }
check("Reject add at end") { rejects { _ = try p.newCue(language:.zh,at:5000) } }
check("Track edit range") { p.allowedRange(for:cues[1]) == 1500...5000 }
check("Language visibility") { var q=p; q.showFrench=false; return q.active(at:500).isEmpty }
check("Project detects duplicate IDs") { var q=p; q.cues.append(cues[0]); return rejects { try q.validate() } }
check("Project rejects unsupported version") { var q=p; q.version=99; return rejects { try q.validate() } }
check("Project rejects off-video cue") { var q=p; q.cues[1].end=6000; return rejects { try q.validate() } }
check("Project style override and round trip") {
    var q=p; var s=SubtitleStyle.standard(.zh); s.font="Helvetica"; s.x=0.3; s.color=RGBA(0.2,0.4,0.6); q.cues[0].style=s
    let url=FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).frzh"); defer { try? FileManager.default.removeItem(at:url) }
    try q.write(url); let loaded=try Project.read(url); return loaded == q && loaded.style(for:loaded.cues[0]) == s
}
check("Translation reorders by ID preserving times") {
    let result=try Translator.merge([Translation(id:cues[1].id,text:"一个故事"),Translation(id:cues[0].id,text:"你好\n朋友")],source:cues)
    return result[0].text == "你好，朋友" && result[1].start == 1500 && result.allSatisfy{$0.language == .zh}
}
check("Translation rejects missing IDs") { rejects { _ = try Translator.merge([Translation(id:cues[0].id,text:"你好")],source:cues) } }
check("Translation rejects duplicate IDs") { rejects { _ = try Translator.merge([Translation(id:cues[0].id,text:"你好"),Translation(id:cues[0].id,text:"你好")],source:cues) } }
check("Translation rejects untranslated French") { rejects { _ = try Translator.merge(cues.map { Translation(id:$0.id,text:$0.text) },source:cues) } }
check("Punctuation cue does not reject a translated batch") {
    let source=[Cue(language:.fr,start:0,end:1000,text:"Bonjour"),Cue(language:.fr,start:1000,end:1500,text:"?")]
    let result=try Translator.merge([Translation(id:source[0].id,text:"你好"),Translation(id:source[1].id,text:"？")],source:source)
    return result.count == 2 && result[1].text == "？" && result[1].start == 1000 && result[1].end == 1500
}
check("Numeric cue allows equivalent full-width digits") {
    let cue=Cue(language:.fr,start:0,end:1000,text:"2026")
    return try Translator.merge([Translation(id:cue.id,text:"２０２６")],source:[cue])[0].text == "２０２６"
}
check("Numeric cue rejects changed digits") {
    let cue=Cue(language:.fr,start:0,end:1000,text:"2026")
    return rejects { _=try Translator.merge([Translation(id:cue.id,text:"2025")],source:[cue]) }
}
check("French ellipsis accepts Chinese ellipsis without allowing missing translations") {
    let cue=Cue(language:.fr,start:200179,end:205639,text:"...")
    let translated=try Translator.merge([Translation(id:cue.id,text:"……")],source:[cue])
    return translated[0].text == "……" && translated[0].start == 200179 && translated[0].end == 205639
        && rejects { _=try Translator.merge([Translation(id:cue.id,text:"？")],source:[cue]) }
}
check("French words cannot be replaced with punctuation") {
    return rejects { _=try Translator.merge(cues.map{Translation(id:$0.id,text:"？")},source:cues) }
}
check("Punctuation source still rejects blank output") {
    let cue=Cue(language:.fr,start:0,end:1000,text:"?")
    return rejects { _=try Translator.merge([Translation(id:cue.id,text:" \n ")],source:[cue]) }
}
check("Nonverbal normalization preserves multiline cue punctuation") {
    let cue=Cue(language:.fr,start:0,end:1000,text:"?\n!")
    return try Translator.merge([Translation(id:cue.id,text:"？！")],source:[cue]).count == 1
}
check("Language switches filter both displayed and active cues") {
    var q=Project(); q.duration=3000
    q.cues=[Cue(language:.zh,start:0,end:1000,text:"你好"),Cue(language:.fr,start:0,end:1000,text:"Bonjour")]
    for (fr,zh,expected) in [(true,false,[Language.fr]),(false,true,[Language.zh]),(true,true,[Language.fr,.zh]),(false,false,[])] {
        q.showFrench=fr; q.showChinese=zh
        if q.displayedCues.map(\.language) != expected || q.active(at:500).map(\.language) != expected { return false }
    }
    return true
}
check("Playback following changes only at cue boundaries and clears gaps") {
    var q=Project(); q.duration=3000
    q.cues=[Cue(language:.fr,start:0,end:1000,text:"Bonjour"),Cue(language:.zh,start:0,end:1000,text:"你好"),Cue(language:.zh,start:1500,end:2500,text:"再见")]
    return q.active(at:999).count == 2 && q.active(at:1000).isEmpty && q.active(at:1499).isEmpty && q.active(at:1500).map(\.text) == ["再见"] && q.active(at:2500).isEmpty
}
check("Track style applies to every cue and clears old overrides") {
    var q=Project(); q.duration=5000
    var old=SubtitleStyle.standard(.fr); old.size=80
    q.cues=[Cue(language:.fr,start:0,end:1000,text:"Bonjour",style:old),Cue(language:.fr,start:1000,end:2000,text:"Merci"),Cue(language:.zh,start:0,end:2000,text:"你好",style:.standard(.zh))]
    let originals=q.cues, chinese=q.cues[2], oldChineseStyle=q.chineseStyle
    var updated=old; updated.size=64; updated.x=0.2; updated.y=0.6; updated.font="Helvetica"; updated.color=RGBA(1,0,0)
    q.applyStyle(updated,to:.fr)
    return q.cues.prefix(2).allSatisfy{$0.style == nil && q.style(for:$0) == updated} && q.cues[2] == chinese && q.chineseStyle == oldChineseStyle && q.cues.map(\.text) == originals.map(\.text) && q.cues.map(\.start) == originals.map(\.start) && q.cues.map(\.end) == originals.map(\.end) && q.cues.map(\.id) == originals.map(\.id)
}
check("New subtitles inherit edited language style") {
    var q=Project(); q.duration=5000; var style=SubtitleStyle.standard(.zh); style.size=71; style.y=0.3
    q.applyStyle(style,to:.zh)
    let cue=try q.newCue(language:.zh,at:1000)
    return q.style(for:cue) == style
}
check("Corner resizing grows and shrinks consistently at all four corners") {
    let center=CGPoint(x:200,y:150)
    for (dx,dy) in [(-100.0,-20.0),(100,-20),(-100,20),(100,20)] {
        let handle=CGPoint(x:center.x+dx,y:center.y+dy)
        let large=CGPoint(x:center.x+dx*1.5,y:center.y+dy*1.5)
        let small=CGPoint(x:center.x+dx*0.5,y:center.y+dy*0.5)
        if abs(VideoGeometry.resizedFontSize(initial:40,anchor:center,handle:handle,pointer:large)-60)>0.001 { return false }
        if abs(VideoGeometry.resizedFontSize(initial:40,anchor:center,handle:handle,pointer:small)-20)>0.001 { return false }
    }
    return true
}
check("Corner resizing clamps font size and handles degenerate geometry") {
    let center=CGPoint.zero,handle=CGPoint(x:10,y:10)
    return VideoGeometry.resizedFontSize(initial:40,anchor:center,handle:handle,pointer:CGPoint(x:1000,y:1000)) == 200 && VideoGeometry.resizedFontSize(initial:40,anchor:center,handle:handle,pointer:CGPoint(x:-10,y:-10)) == 8 && VideoGeometry.resizedFontSize(initial:40,anchor:center,handle:center,pointer:handle) == 40
}
check("Width drag fixes the opposite edge and allows expansion") {
    let box=CGRect(x:200,y:30,width:400,height:80)
    let left=VideoGeometry.resizedTextBox(box,delta:-100,leftEdge:true,videoWidth:1000)
    let right=VideoGeometry.resizedTextBox(box,delta:100,leftEdge:false,videoWidth:1000)
    return left.minX == 100 && left.maxX == 600 && right.minX == 200 && right.maxX == 700 && left.height == box.height
}
check("Width drag clamps to video bounds and a minimum width") {
    let box=CGRect(x:200,y:30,width:400,height:80)
    return VideoGeometry.resizedTextBox(box,delta:-9999,leftEdge:true,videoWidth:1000).minX == 0 && VideoGeometry.resizedTextBox(box,delta:9999,leftEdge:false,videoWidth:1000).maxX == 1000 && VideoGeometry.resizedTextBox(box,delta:9999,leftEdge:true,videoWidth:1000).width == 100
}
check("Old style JSON without width still decodes") {
    var legacy=SubtitleStyle.standard(.fr); legacy.size=44
    let data=try JSONEncoder().encode(legacy)
    var object=try JSONSerialization.jsonObject(with:data) as! [String:Any]; object.removeValue(forKey:"width")
    let restored=try JSONDecoder().decode(SubtitleStyle.self,from:JSONSerialization.data(withJSONObject:object))
    return restored.width == nil && restored.size == 44
}
check("Width persists and propagates without changing font size") {
    var q=Project(); q.duration=3000; q.cues=[Cue(language:.fr,start:0,end:1000,text:"Bonjour"),Cue(language:.fr,start:1000,end:2000,text:"Merci")]
    var style=q.frenchStyle; style.width=0.97; q.applyStyle(style,to:.fr)
    let restored=try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(q)); try restored.validate()
    return restored.cues.allSatisfy{restored.style(for:$0).width == 0.97 && restored.style(for:$0).size == style.size}
}
check("Invalid persisted subtitle width is rejected") {
    var q=Project(); q.duration=1000; q.cues=[Cue(language:.fr,start:0,end:1000,text:"Bonjour")]; q.frenchStyle.width=1.1
    return rejects { try q.validate() }
}
check("Portrait aspect fit") { VideoGeometry.aspectFit(video:CGSize(width:1080,height:1920),container:CGRect(x:0,y:0,width:800,height:600)) == CGRect(x:231.25,y:0,width:337.5,height:600) }
check("Landscape letterboxing") { VideoGeometry.aspectFit(video:CGSize(width:1920,height:1080),container:CGRect(x:0,y:0,width:800,height:600)) == CGRect(x:0,y:75,width:800,height:450) }
check("Subtitle box clamps to visible video") { VideoGeometry.anchoredBox(size:CGSize(width:300,height:100),video:CGSize(width:1080,height:1920),x:1,y:0) == CGRect(x:780,y:0,width:300,height:100) }
if CommandLine.arguments.count == 3 {
    check("Actual cached translation batch") {
        let source=try JSONDecoder().decode([Cue].self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
        let batch=try JSONDecoder().decode(TranslationBatch.self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2])))
        let ids=Set(batch.translations.map(\.id))
        let result=try Translator.merge(batch.translations,source:source.filter{ids.contains($0.id)})
        return result.count == batch.translations.count
    }
}
check("Legacy project without text tracks decodes") {
    let data=try JSONEncoder().encode(p)
    var json=try JSONSerialization.jsonObject(with:data) as! [String:Any]; json.removeValue(forKey:"textTracks")
    let loaded=try JSONDecoder().decode(Project.self,from:JSONSerialization.data(withJSONObject:json))
    try loaded.validate(); return loaded.tracks.isEmpty
}
check("Text tracks overlap languages but not their own clips") {
    var q=p; let t=TextTrack(name:"说明"); q.textTracks=[t]
    let c=try q.newCue(language:.zh,at:0,trackID:t.id); q.cues.append(c)
    try q.validate()
    return rejects { _=try q.newCue(language:.zh,at:500,trackID:t.id) } && q.allowedRange(for:c) == 0...5000
}
check("Independent text tracks remain visible without subtitles") {
    var q=p; let a=TextTrack(name:"标题"),b=TextTrack(name:"说明"); q.textTracks=[a,b]
    q.cues.append(try q.newCue(language:.zh,at:0,trackID:a.id)); q.cues.append(try q.newCue(language:.zh,at:0,trackID:b.id))
    q.showFrench=false; q.showChinese=false; try q.validate()
    return q.active(at:0).count == 2 && q.active(at:2000).isEmpty
}
check("Text style is isolated and persists with track IDs") {
    var q=p; let t=TextTrack(name:"说明"); q.textTracks=[t]
    let c=try q.newCue(language:.zh,at:0,trackID:t.id); q.cues.append(c)
    var style=SubtitleStyle(); style.size=72; style.y=0.7
    q.applyStyle(style,for:c)
    q.applyStyle(SubtitleStyle.standard(.zh),to:.zh)
    let decoded=try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(q)); try decoded.validate()
    return decoded == q && decoded.style(for:c) == style && decoded.frenchStyle == p.frenchStyle
}
check("Text clip boundary and missing track validation") {
    var q=p; let t=TextTrack(name:"说明"); q.textTracks=[t]
    let c=try q.newCue(language:.zh,at:4500,trackID:t.id); q.cues.append(c)
    q.textTracks=[]
    return c.end == 5000 && rejects { try q.validate() }
}
check("Readability defaults protect light text, preserve dark backed text") {
    SubtitleStyle.standard(.fr).enhancesReadability && !SubtitleStyle.standard(.zh).enhancesReadability
}
check("Readability preference persists and can be disabled") {
    var style=SubtitleStyle.standard(.fr); style.readability=false
    let loaded=try JSONDecoder().decode(SubtitleStyle.self,from:JSONEncoder().encode(style))
    return !loaded.enhancesReadability && loaded == style
}

check("Legacy video becomes one non-destructive clip") {
    var p=Project(); p.videoPath="/video.mp4"; p.duration=4000
    return p.clips.count == 1 && p.clips[0].duration == 4000 && p.placements[0].start == 0
}
check("Append, trim and reorder carry captions with source") {
    var p=Project(); p.videoPath="/a.mp4"; p.duration=4000
    p.cues=[Cue(language:.zh,start:1500,end:2500,text:"原字幕")]
    var a=p.clips[0]; a.sourceStart=1000
    let b=VideoClip(path:"/b.mp4",duration:3000)
    let trimmed=try p.replacingClips([a,b])
    let reordered=try trimmed.replacingClips([b,a])
    return trimmed.duration == 6000 && trimmed.cues[0].start == 500 && reordered.cues[0].start == 3500
}
check("Split preserves source boundaries and splits crossing caption IDs") {
    var p=Project(); p.videoPath="/a.mp4"; p.duration=4000
    p.cues=[Cue(language:.fr,start:1000,end:3000,text:"Bonjour")]
    let q=try p.splittingClip(p.clips[0].id,at:2000)
    return q.duration == 4000 && q.clips.count == 2 && q.clips[1].sourceStart == 2000 && q.cues.count == 2 && Set(q.cues.map(\.id)).count == 2 && q.cues.map{$0.end-$0.start}.reduce(0,+) == 2000
}
check("Dissolve shortens timeline without overlapping captions") {
    var p=Project(); p.videoPath="/a.mp4"; p.duration=4000
    let a=p.clips[0]; var b=VideoClip(path:"/b.mp4",duration:4000)
    p=try p.replacingClips([a,b]); p.cues=[Cue(language:.zh,start:0,end:4000,text:"一"),Cue(language:.zh,start:4000,end:8000,text:"二")]
    b.transition=1000; let q=try p.replacingClips([a,b]); try q.validate()
    return q.duration == 7000 && q.cues[0].end == 3500 && q.cues[1].start == 3500
}
check("Clip edits reject invalid source bounds and excessive transitions") {
    var p=Project(); var c=VideoClip(path:"a.mp4",duration:4000); c.sourceEnd=5000
    let bounds=rejects{_ = try p.replacingClips([c])}
    c.sourceEnd=4000; c.transition=1000
    let first=rejects{_ = try p.replacingClips([c])}
    c.transition=0; c.effects.contrast = .nan
    return bounds && first && rejects{_ = try p.replacingClips([c])}
}
check("Clip effects and source trims persist; old JSON remains readable") {
    var p=Project(); var c=VideoClip(path:"含 空格.mp4",duration:4000); c.sourceStart=1000; c.effects.saturation=0.5
    p=try p.replacingClips([c]); let q=try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(p)); try q.validate()
    return q == p && q.clips[0].sourceStart == 1000
}
check("Removing a clip removes its captions and ripples remaining material") {
    var p=Project(); p.videoPath="a.mp4"; p.duration=2000; let a=p.clips[0],b=VideoClip(path:"b.mp4",duration:2000)
    p=try p.replacingClips([a,b]); p.cues=[Cue(language:.zh,start:500,end:1000,text:"一"),Cue(language:.zh,start:2500,end:3000,text:"二")]
    let q=try p.replacingClips([b]); return q.duration == 2000 && q.cues.count == 1 && q.cues[0].text == "二" && q.cues[0].start == 500
}
check("Trim-left button maps source in-point and carries captions") {
    var p=Project(); p.videoPath="a.mp4"; p.duration=4000
    p.cues=[Cue(language:.zh,start:1000,end:3000,text:"中间")]
    let q=try p.trimmingClip(p.clips[0].id,at:2000,removeBefore:true)
    return q.duration == 2000 && q.clips[0].sourceStart == 2000 && q.cues[0].start == 0 && q.cues[0].end == 1000
}
check("Trim-right button clips captions and ripples following video") {
    var p=Project(); p.videoPath="a.mp4"; p.duration=4000
    let a=p.clips[0],b=VideoClip(path:"b.mp4",duration:2000)
    p=try p.replacingClips([a,b]); p.cues=[Cue(language:.fr,start:1000,end:3000,text:"Un"),Cue(language:.fr,start:4500,end:5000,text:"Deux")]
    let q=try p.trimmingClip(a.id,at:2000,removeBefore:false)
    return q.duration == 4000 && q.cues[0].end == 2000 && q.cues[1].start == 2500 && q.placements[1].start == 2000
}
check("Trim buttons reject boundaries and wrong clip IDs") {
    var p=Project(); p.videoPath="a.mp4"; p.duration=4000
    return rejects{_ = try p.trimmingClip(p.clips[0].id,at:0,removeBefore:true)} && rejects{_ = try p.trimmingClip(p.clips[0].id,at:4000,removeBefore:false)} && rejects{_ = try p.trimmingClip(UUID(),at:1000,removeBefore:true)}
}
check("Erase regions persist and survive source-based split") {
    var p=Project(); var clip=VideoClip(path:"a.mp4",duration:4000)
    let region=VideoEraseRegion(x:0.1,y:0.1,width:0.7,height:0.2,sourceStart:500,sourceEnd:3500)
    clip.eraseRegions=[region]; p=try p.replacingClips([clip])
    let split=try p.splittingClip(clip.id,at:2000)
    let decoded=try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(split)); try decoded.validate()
    return decoded.clips.count == 2 && decoded.clips.allSatisfy{$0.eraseRegions == [region]}
}
check("Erase regions reject invalid rectangles, colors and times") {
    var p=Project(); var clip=VideoClip(path:"a.mp4",duration:4000)
    clip.eraseRegions=[VideoEraseRegion(x:0.9,y:0,width:0.2,height:0.2,sourceStart:0,sourceEnd:4000)]
    let outside=rejects{_ = try p.replacingClips([clip])}
    clip.eraseRegions=[VideoEraseRegion(x:0,y:0,width:0.2,height:0.2,sourceStart:4000,sourceEnd:4000)]
    let emptyTime=rejects{_ = try p.replacingClips([clip])}
    clip.eraseRegions=[VideoEraseRegion(x:0,y:0,width:0.2,height:0.2,sourceStart:0,sourceEnd:4000,color:RGBA(.nan,0,0))]
    return outside && emptyTime && rejects{_ = try p.replacingClips([clip])}
}
check("Legacy styles default to centered alignment") {
    let data=try JSONEncoder().encode(SubtitleStyle())
    var json=try JSONSerialization.jsonObject(with:data) as! [String:Any]
    json.removeValue(forKey:"alignment")
    return try JSONDecoder().decode(SubtitleStyle.self,from:JSONSerialization.data(withJSONObject:json)).textAlignment == .center
}
check("Alignment survives project persistence and applies only to selected track") {
    var q=p; var style=SubtitleStyle(); style.alignment = .right
    q.applyStyle(style,for:q.cues[0])
    let restored=try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(q))
    return restored.cues.allSatisfy { restored.style(for:$0).textAlignment == .right } && restored.style(for:Cue(language:.zh,start:0,end:1000,text:"测试")).textAlignment == .center
}
check("UI localization renders both languages without altering arguments") {
    let payload="字幕 {1} / 中文.mp4"
    return UILocalization.text("导出完成：{0}",arguments:[payload],language:.en) == "Export complete: \(payload)"
        && UILocalization.text("导出完成：{0}",arguments:[payload],language:.zh) == "导出完成：\(payload)"
        && UILocalization.text("unknown",language:.en) == "unknown"
}
check("Every English translation preserves placeholder indices") {
    let regex=try NSRegularExpression(pattern:"\\{[0-9]+\\}")
    func tokens(_ s:String)->Set<String> { let ns=s as NSString; return Set(regex.matches(in:s,range:NSRange(location:0,length:ns.length)).map{ns.substring(with:$0.range)}) }
    return UILocalization.english.allSatisfy { tokens($0.key) == tokens($0.value) && !$0.value.isEmpty }
}
check("Background music and original-audio mute persist") {
    var q=Project(); q.duration=2000; var m=BackgroundMusic(path:"中文 音乐.mp3",duration:4000); m.start=500; m.sourceStart=100; m.sourceEnd=1600; m.volume=0.4
    q.backgroundMusic=[m]; q.muteVideoAudio=true; try q.validate()
    let copy=try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(q))
    return copy.music == [m] && copy.isVideoMuted && Project().music.isEmpty && !Project().isVideoMuted
}
check("Music validation rejects reversed ranges, invalid volume and duplicate IDs") {
    var q=Project(); var m=BackgroundMusic(path:"a.mp3",duration:2000); m.sourceEnd=0; q.backgroundMusic=[m]
    let reversed=rejects{try q.validate()}; m.sourceEnd=2000; m.volume = .nan; q.backgroundMusic=[m]
    let volume=rejects{try q.validate()}; m.volume=1; q.backgroundMusic=[m,m]
    return reversed && volume && rejects{try q.validate()}
}
check("Music split keeps source continuity, gain, video and captions") {
    var q=p; var m=BackgroundMusic(path:"music.mp3",duration:8000); m.start=1000; m.sourceStart=2000; m.sourceEnd=5000; m.volume=0.25; q.backgroundMusic=[m]
    let result=try q.cuttingMusic(m.id,at:2500)
    return result.music.count==2 && result.music[0].id==m.id && result.music[1].id != m.id && result.music[0].sourceEnd==3500 && result.music[1].sourceStart==3500 && result.music[1].start==2500 && result.music[1].sourceEnd==5000 && result.music[1].volume==0.25 && result.cues==q.cues && result.clips==q.clips && result.duration==q.duration
}
check("Music trim left and right preserve absolute timeline and source positions") {
    var q=p; var m=BackgroundMusic(path:"music.mp3",duration:8000); m.start=1000; m.sourceStart=2000; m.sourceEnd=5000; q.backgroundMusic=[m]
    let left=try q.cuttingMusic(m.id,at:2500,removeBefore:true).music[0]
    let right=try q.cuttingMusic(m.id,at:2500,removeBefore:false).music[0]
    return left.start==2500 && left.sourceStart==3500 && left.sourceEnd==5000 && right.start==1000 && right.sourceStart==2000 && right.sourceEnd==3500
}
check("Music cuts reject endpoints, missing selection and playhead beyond video") {
    var q=Project(); q.duration=2000; let m=BackgroundMusic(path:"music.mp3",duration:8000); q.backgroundMusic=[m]
    return rejects{_ = try q.cuttingMusic(m.id,at:0)} && rejects{_ = try q.cuttingMusic(m.id,at:2000)} && rejects{_ = try q.cuttingMusic(m.id,at:3000)} && rejects{_ = try q.cuttingMusic(UUID(),at:1000)}
}
check("Long music retains full source range without extending video export duration") {
    var q=Project(); q.duration=41000; var m=BackgroundMusic(path:"two minutes.mp3",duration:120000); m.start=5000; q.backgroundMusic=[m]
    try q.validate()
    let restored=try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(q))
    return restored.music[0].sourceEnd==120000 && restored.music[0].duration==120000 && restored.timelineExtent==125000 && restored.duration==41000
}
check("Video track flags preserve legacy defaults and round trip independently") {
    var p=Project()
    let legacy=try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(p))
    guard !legacy.isVideoLocked && !legacy.isVideoHidden && !legacy.isVideoMuted else { return false }
    p.lockVideoTrack=true; p.hideVideoTrack=true; p.muteVideoAudio=false
    let restored=try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(p))
    return restored.isVideoLocked && restored.isVideoHidden && !restored.isVideoMuted
}
check("Project speed preserves editing times and round trips") {
    var p=Project(); p.duration=10000
    guard p.speed==1 && p.exportDuration==10000 else { return false }
    p.playbackRate=2
    let q=try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(p))
    guard q.speed==2 && q.exportDuration==5000 && q.duration==10000 else { return false }
    p.playbackRate=0.25
    return p.exportDuration==40000
}
check("Reject invalid project speed") {
    [0.0,0.1,3,Double.infinity,Double.nan].allSatisfy { speed in
        var p=Project(); p.playbackRate=speed; return rejects { try p.validate() }
    }
}
check("Media insertion duplicates range with fresh ID and ripples existing subtitles") {
    var p=Project(); var a=VideoClip(path:"a.mp4",duration:4000); a.sourceStart=1000
    let b=VideoClip(path:"b.mp4",duration:2000)
    p=try p.replacingClips([a,b]); p.cues=[Cue(language:.fr,start:3500,end:4000,text:"B")]
    let q=try p.insertingCopy(of:a.id,at:1)
    return q.clips.count==3 && q.clips[1].id != a.id && q.clips[1].sourceStart==1000 && q.duration==8000 && q.cues.count==1 && q.cues[0].start==6500 && p.duration==5000
}
check("Media insertion accepts endpoints and rejects locked or invalid drops") {
    var p=try Project().replacingClips([VideoClip(path:"a.mp4",duration:2000)])
    let id=p.clips[0].id
    guard try p.insertingCopy(of:id,at:0).duration==4000,try p.insertingCopy(of:id,at:1).duration==4000 else { return false }
    guard rejects({ _ = try p.insertingCopy(of:id,at:2) }),rejects({ _ = try p.insertingCopy(of:UUID(),at:0) }) else { return false }
    p.lockVideoTrack=true
    return rejects { _ = try p.insertingCopy(of:id,at:0) }
}
check("PiP tracks retain absolute time and extend duration without moving main captions") {
    var p=try Project().replacingClips([VideoClip(path:"a.mp4",duration:2000)])
    p.cues=[Cue(language:.fr,start:0,end:1000,text:"Main")]
    let q=try p.addingLayer(from:p.clips[0].id,at:1500)
    guard q.duration==3500,q.clips==p.clips,q.cues==p.cues,q.layers[0].id != p.clips[0].id else { return false }
    var layers=q.layers; layers[0].start=500
    let r=try q.replacingLayers(layers)
    let removed=try r.replacingLayers([])
    return r.duration==2500 && r.cues==p.cues && removed.duration==2000
}
check("Dropped files on the new-track zone form one new track without changing the main video") {
    var p=try Project().replacingClips([VideoClip(path:"a.mp4",duration:2000)])
    p=try p.addingLayer(from:p.clips[0].id,at:0)
    var gapped=VideoClip(path:"c.mp4",duration:500); gapped.timelineGap=300
    let q=try p.addingLayerTrack([VideoClip(path:"b.mp4",duration:1000),gapped],at:1500)
    let track=q.layerTracks[0]
    guard q.clips==p.clips,q.layerTracks.count==2,track.count==2,track.map(\.start)==[1500,2500],
          track.allSatisfy({ $0.trackIdentifier==track[0].id && $0.clip.timelineGap==nil }),q.duration==3000 else { return false }
    return rejects({ _ = try p.addingLayerTrack([],at:0) })
}
check("PiP stacking and project persistence preserve independent position and visibility") {
    let p=try Project().replacingClips([VideoClip(path:"a.mp4",duration:2000)])
    let q=try p.addingLayer(from:p.clips[0].id,at:0)
    var r=try q.addingLayer(from:p.clips[0].id,at:100)
    r.videoLayers![0].x=0.3; r.videoLayers![0].scale=0.6; r.videoLayers![0].muted=true
    let restored=try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(r))
    try restored.validate()
    return restored==r && restored.renderPlacements.last?.clip.id==r.layers[0].id && p.layers.isEmpty
}
check("PiP rejects invalid geometry and IDs, survives deleting main video") {
    let p=try Project().replacingClips([VideoClip(path:"a.mp4",duration:2000)])
    let q=try p.addingLayer(from:p.clips[0].id,at:1000)
    var bad=q.layers; bad[0].scale=0
    guard rejects({ _ = try q.replacingLayers(bad) }) else { return false }
    bad=q.layers; bad[0].clip.id=p.clips[0].id
    guard rejects({ _ = try q.replacingLayers(bad) }) else { return false }
    let r=try q.replacingClips([])
    return r.duration==3000 && r.clips.isEmpty && r.allClips.count==1 && !r.videoPath.isEmpty
}
check("PiP lock defaults off in legacy projects and persists independently") {
    var layer=VideoLayer(clip:VideoClip(path:"a.mp4",duration:2000),start:0)
    let legacy=try JSONDecoder().decode(VideoLayer.self,from:JSONEncoder().encode(layer))
    guard !legacy.isLocked else { return false }
    layer.locked=true; layer.hidden=true; layer.muted=true
    let restored=try JSONDecoder().decode(VideoLayer.self,from:JSONEncoder().encode(layer))
    return restored.isLocked && restored.hidden && restored.muted && restored==layer
}
check("Multiple clips share a track and splitting preserves its row and timing") {
    let base=try Project().replacingClips([VideoClip(path:"main.mp4",duration:5000)])
    let p=try base.addingLayer(from:base.clips[0].id,at:1000)
    let split=try p.cuttingLayer(p.layers[0].id,at:3000)
    guard split.layerTracks.count==1,split.layerTracks[0].count==2,split.layers[1].clip.sourceStart==2000,split.duration==6000 else { return false }
    let appended=try split.addingLayer(from:base.clips[0].id,at:6000,trackID:split.layers[0].trackIdentifier)
    let restored=try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(appended)); try restored.validate()
    let deleted=try restored.replacingLayers(Array(restored.layers.dropFirst()))
    return deleted.layerTracks.count==1 && deleted.layerTracks[0].count==2 && restored==appended
}
check("Same-track collisions and locked destinations reject edits without moving captions") {
    var base=try Project().replacingClips([VideoClip(path:"main.mp4",duration:5000)])
    base.cues=[Cue(language:.zh,start:1000,end:2000,text:"字幕")]
    let p=try base.addingLayer(from:base.clips[0].id,at:0)
    let id=p.layers[0].trackIdentifier
    guard rejects({ _ = try p.addingLayer(from:base.clips[0].id,at:4000,trackID:id) }) else { return false }
    var locked=p; locked.videoLayers?[0].locked=true
    guard rejects({ _ = try locked.addingLayer(from:base.clips[0].id,at:5000,trackID:id) }) else { return false }
    let split=try p.cuttingLayer(p.layers[0].id,at:2000)
    var collision=split.layers[1]; collision.start=1000
    return rejects({ _ = try split.replacingLayer(collision) }) && split.cues==base.cues
}
check("Moving between video tracks preserves destination order and inherited controls") {
    let base=try Project().replacingClips([VideoClip(path:"main.mp4",duration:2000)])
    let first=try base.addingLayer(from:base.clips[0].id,at:0)
    let p=try first.addingLayer(from:base.clips[0].id,at:4000)
    var moved=p.layers[0]; moved.trackID=p.layers[1].trackIdentifier; moved.start=2000
    let q=try p.replacingLayer(moved)
    return q.layerTracks.count==1 && q.layerTracks[0].count==2 && q.layerTracks[0][1].id==moved.id && q.layers.allSatisfy{$0.scale==1 && $0.x==0.5 && $0.y==0.5}
}
check("Main video can start at five seconds with captions and persistence") {
    var p=try Project().replacingClips([VideoClip(path:"a.mp4",duration:2000)])
    p.cues=[Cue(language:.fr,start:200,end:900,text:"Caption")]
    let q=try p.movingMainClip(p.clips[0].id,to:5000)
    let restored=try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(q)); try restored.validate()
    let split=try q.splittingClip(q.clips[0].id,at:6000)
    return q.placements[0].start==5000 && q.duration==7000 && q.cues[0].start==5200 && restored==q && split.placements.map(\.start)==[5000,6000] && split.duration==7000
}
check("Main movement keeps other video and music positions and rejects collision or lock") {
    var p=try Project().replacingClips([VideoClip(path:"a.mp4",duration:2000),VideoClip(path:"b.mp4",duration:2000)])
    let a=p.clips[0].id,b=p.clips[1].id
    p.backgroundMusic=[BackgroundMusic(path:"music.mp3",duration:10000)]
    guard rejects({ _ = try p.movingMainClip(a,to:1000) }) else { return false }
    let q=try p.movingMainClip(a,to:5000)
    guard q.placements.first(where:{$0.clip.id==b})?.start==2000,q.placements.first(where:{$0.clip.id==a})?.start==5000,q.music==p.music else { return false }
    let layer=try q.addingLayer(from:a,at:0)
    guard layer.layers[0].clip.gap==0 else { return false }
    var locked=p; locked.lockVideoTrack=true
    return rejects { _ = try locked.movingMainClip(a,to:5000) }
}
check("Timeline transfer moves original clip to new track without rippling others") {
    var p=try Project().replacingClips([VideoClip(path:"a.mp4",duration:2000),VideoClip(path:"b.mp4",duration:2000)])
    p.cues=[Cue(language:.fr,start:2500,end:3000,text:"Caption")]
    let id=p.clips[0].id,other=p.clips[1].id
    let q=try p.transferringClip(id,to:.newTrack,at:5000)
    guard q.layers.count==1,q.layers[0].id==id,q.layers[0].start==5000,q.placements[0].clip.id==other,q.placements[0].start==2000,q.cues==p.cues else { return false }
    let r=try q.transferringClip(id,to:.main,at:0)
    return r.layers.isEmpty && r.placements.map(\.start)==[0,2000] && r.clips.map(\.id)==p.clips.map(\.id)
}
check("Transfer into existing track inherits controls and rejects occupied or locked destinations") {
    let base=try Project().replacingClips([VideoClip(path:"a.mp4",duration:2000)])
    var p=try base.addingLayer(from:base.clips[0].id,at:0)
    p.videoLayers?[0].muted=true
    let track=p.layers[0].trackIdentifier,id=p.clips[0].id
    guard rejects({ _ = try p.transferringClip(id,to:.track(track),at:1000) }) else { return false }
    let q=try p.transferringClip(id,to:.track(track),at:2000)
    guard q.clips.isEmpty,q.layerTracks.count==1,q.layerTracks[0].count==2,q.layers.allSatisfy({$0.muted}) else { return false }
    var locked=p; locked.videoLayers?[0].locked=true
    return rejects { _ = try locked.transferringClip(id,to:.track(track),at:2000) }
}
check("Moving one split clip to a new track preserves the original track and locked main") {
    let base=try Project().replacingClips([VideoClip(path:"a.mp4",duration:4000)])
    let p=try base.addingLayer(from:base.clips[0].id,at:0)
    var split=try p.cuttingLayer(p.layers[0].id,at:2000); split.lockVideoTrack=true
    let q=try split.transferringClip(split.layers[0].id,to:.newTrack,at:0)
    return q.layerTracks.count==2 && q.layerTracks[0][0].id==split.layers[0].id && q.layerTracks[0][0].trackIdentifier != split.layerTracks[0][0].trackIdentifier && q.clips==split.clips
}
check("Multilingual project persists English style visibility and language pair") {
    var q=Project(); q.duration=1000; q.generationLanguages=GenerationLanguages(source:.en,target:.fr)
    q.cues=[Cue(language:.en,start:0,end:1000,text:"Hello"),Cue(language:.fr,start:0,end:1000,text:"Bonjour")]
    var style=SubtitleStyle.standard(.en); style.size=80; q.applyStyle(style,to:.en); q.setVisible(false,for:.en)
    let restored=try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(q))
    try restored.validate()
    return restored == q && restored.subtitleLanguages == [.en,.fr] && restored.displayedCues.count == 1 && restored.style(for:q.cues[0]).size == 80
}
check("English and French translation retain punctuation timing and reject missing IDs") {
    let source=[Cue(language:.fr,start:100,end:900,text:"Bonjour")]
    let en=try Translator.merge([Translation(id:source[0].id,text:"Hello,\nworld!")],source:source,target:.en)
    let fr=try Translator.merge([Translation(id:source[0].id,text:"C’est vrai !")],source:source,target:.fr)
    return en[0].text == "Hello, world!" && en[0].language == .en && en[0].start == 100 && fr[0].language == .fr && rejects { _ = try Translator.merge([],source:source,target:.en) }
}
check("Legacy project and same-language generation keep compatible track counts") {
    var q=Project(); q.generationLanguages=GenerationLanguages(source:.en,target:.en)
    guard q.subtitleLanguages == [.en] else { return false }
    var json=try JSONSerialization.jsonObject(with:JSONEncoder().encode(q)) as! [String:Any]
    json.removeValue(forKey:"generationLanguages"); json.removeValue(forKey:"englishStyle"); json.removeValue(forKey:"showEnglish")
    let old=try JSONDecoder().decode(Project.self,from:JSONSerialization.data(withJSONObject:json))
    return old.subtitleLanguages == [.fr,.zh] && old.visible(.en)
}
print("\(passed) passed, \(failures) failed")
exit(failures == 0 ? 0:1)
