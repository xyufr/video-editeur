import AppKit
import SubtitleCore

extension SplitLayout {
    var title: String { switch self { case .row: return L("一行（左右并排）"); case .column: return L("一列（上下堆叠）"); case .grid: return L("2 × 2 宫格") } }
    /// A canvas shape that keeps each cell close to the usual 16:9 source.
    var suggestedCanvas: CanvasAspect { .fitVideos }
}
extension CanvasAspect {
    var title: String { switch self { case .fitVideos: return L("自动（完整显示每个视频）"); case .source: return L("保持原视频比例"); case .portrait: return L("竖屏 9:16"); case .landscape: return L("横屏 16:9"); case .square: return L("方形 1:1") } }
}

/// Width / height of the picture a clip shows after its crop.
func shownAspect(_ clip: VideoClip) throws -> Double {
    let size=try MediaProbe(clip.path).size
    let kept=(clip.crop ?? VideoCrop()).keptRect(in:size)
    guard kept.width>0,kept.height>0 else { throw SubtitleError.invalid(L("无法读取视频比例，请选择其他画布")) }
    return Double(kept.width/kept.height)
}
/// Applies the dialog's canvas. Choosing Auto resizes the canvas so `clip`'s cell matches its picture,
/// unless Auto was already set and the clip's position and crop are unchanged.
func applyCanvas(_ canvas: CanvasAspect,to project: inout Project,clip: VideoClip,original: VideoClip) throws {
    guard canvas == .fitVideos else { project.setCanvas(canvas); return }
    if project.canvas == .fitVideos,project.canvasRatio != nil,clip.frame == original.frame,clip.crop == original.crop { return }
    let cell=clip.frame ?? VideoFrame(x:0,y:0,width:1,height:1)
    project.setCanvas(.fitVideos,ratio:try shownAspect(clip)*cell.height/cell.width)
    try project.validate()
}

extension EditorController {
    @objc func chooseSplitScreen() {
        guard !busy else { return }
        pauseForEditing()
        let panel=NSOpenPanel(); panel.allowedContentTypes=[.movie]; panel.allowsMultipleSelection=true
        panel.title=L("分屏：选择 1–4 个视频"); panel.message=L("按选择顺序从左到右或从上到下排列")
        guard panel.runModal() == .OK else { return }
        let urls=panel.urls
        guard (1...4).contains(urls.count) else { showError(SubtitleError.invalid(L("分屏需要 1–4 个视频；2×2 需要 4 个"))); return }
        guard let (layout,canvas)=chooseSplitLayout(count:urls.count) else { return }
        addSplitScreen(urls,layout:layout,canvas:canvas)
    }
    func chooseSplitLayout(count: Int) -> (SplitLayout,CanvasAspect)? {
        let alert=NSAlert(); alert.messageText=L("分屏 · {0} 个视频",[String(count)])
        alert.informativeText=project.clips.isEmpty
            ? L("第一个视频作为主视频，其余各占一条新视频轨道，从 0 秒同时开始。每个视频填满自己的格子，超出部分裁掉。")
            : L("每个视频各占一条新视频轨道，从播放头 {0} 同时开始。每个视频填满自己的格子，超出部分裁掉。",[String(SRT.timestamp(current).prefix(8))])
        let box=NSView(frame:NSRect(x:0,y:0,width:360,height:76))
        let layoutTitle=label(L("排列"),size:12); layoutTitle.frame=NSRect(x:0,y:46,width:90,height:24); box.addSubview(layoutTitle)
        let canvasTitle=label(L("画布"),size:12); canvasTitle.frame=NSRect(x:0,y:6,width:90,height:24); box.addSubview(canvasTitle)
        let canvasChoice=NSPopUpButton(frame:NSRect(x:95,y:4,width:260,height:28),pullsDown:false)
        canvasChoice.addItems(withTitles:CanvasAspect.allCases.map(\.title)); canvasChoice.setAccessibilityLabel(L("画布"))
        let layouts=SplitLayout.allCases
        let layoutChoice=ActionPopUp(frame:NSRect(x:95,y:44,width:260,height:28),items:layouts.map(\.title)) {}
        layoutChoice.setAccessibilityLabel(L("排列")); layoutChoice.autoenablesItems=false
        for (i,layout) in layouts.enumerated() { layoutChoice.item(at:i)?.isEnabled=layout.supports(count) }
        func select(_ layout: SplitLayout) {
            layoutChoice.selectItem(at:layouts.firstIndex(of:layout) ?? 0)
            canvasChoice.selectItem(at:CanvasAspect.allCases.firstIndex(of:layout.suggestedCanvas) ?? 0)
        }
        select(count == 4 ? .grid : .column)
        layoutChoice.actionBlock={ [weak layoutChoice] in
            guard let layoutChoice else { return }
            canvasChoice.selectItem(at:CanvasAspect.allCases.firstIndex(of:layouts[max(0,layoutChoice.indexOfSelectedItem)].suggestedCanvas) ?? 0)
        }
        box.addSubview(layoutChoice); box.addSubview(canvasChoice)
        alert.accessoryView=box; alert.addButton(withTitle:L("添加")); alert.addButton(withTitle:L("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return (layouts[max(0,layoutChoice.indexOfSelectedItem)],CanvasAspect.allCases[max(0,canvasChoice.indexOfSelectedItem)])
    }
    @discardableResult func addSplitScreen(_ urls: [URL],layout: SplitLayout,canvas: CanvasAspect) -> Bool {
        guard !busy else { return false }
        do {
            // Letterbox bars recorded into a source would otherwise be enlarged into the cell.
            let videos=try urls.map { url -> VideoClip in
                var clip=VideoClip(path:url.path,duration:try MediaProbe(url.path).duration)
                clip.crop=BlackBorderDetector.detect(path:url.path); return clip
            }
            let next=try project.addingSplitScreen(videos,layout:layout,canvas:canvas,at:current,aspects:try videos.map { try shownAspect($0) })
            commit(next,name:L("分屏"))
            guard project == next else { return false }
            loadTimelineThumbnails(for:videos)
            if let first=next.allClips.first(where:{ clip in videos.contains { $0.id == clip.id } }) { selectVideoClip(first.id,seek:false) }
            return true
        } catch { showError(error); return false }
    }
}

/// "Screen position" and project canvas controls shared by the main-clip and track-clip edit dialogs.
struct FrameControls {
    /// nil frame = full canvas. A position matching no preset is offered as an unchanged custom item.
    private let presets: [(title: String,frame: VideoFrame?)]
    let position: NSPopUpButton
    let canvas: NSPopUpButton
    static var presetList: [(title: String,frame: VideoFrame?)] {
        var list: [(String,VideoFrame?)]=[(L("全画布"),nil)]
        for count in 2...4 { for (i,cell) in SplitLayout.row.cells(count).enumerated() { list.append((L("一行 {0} 格 · 从左数第 {1} 格",[String(count),String(i+1)]),cell)) } }
        for count in 2...4 { for (i,cell) in SplitLayout.column.cells(count).enumerated() { list.append((L("一列 {0} 格 · 从上数第 {1} 格",[String(count),String(i+1)]),cell)) } }
        for (title,cell) in zip([L("2 × 2 · 左上"),L("2 × 2 · 右上"),L("2 × 2 · 左下"),L("2 × 2 · 右下")],SplitLayout.grid.cells(4)) { list.append((title,cell)) }
        return list
    }
    let cropFields: [NSTextField]
    let autoCrop: ActionButton
    /// Grows `form` by three rows at the bottom and moves its existing rows up.
    init(adding form: NSView,clip: VideoClip,canvas aspect: CanvasAspect) {
        let current=clip.frame
        let all=Self.presetList
        let match=all.firstIndex { preset in preset.frame.map { f in current.map { abs(f.x-$0.x)<1e-6 && abs(f.y-$0.y)<1e-6 && abs(f.width-$0.width)<1e-6 && abs(f.height-$0.height)<1e-6 } ?? false } ?? (current == nil) }
        let isCustom=match == nil
        presets=(isCustom ? [(L("自定义位置（保持不变）"),current)] : [])+all
        for view in form.subviews { view.frame.origin.y += 112 }
        form.frame.size.height += 112
        position=NSPopUpButton(frame:NSRect(x:160,y:74,width:242,height:26),pullsDown:false)
        position.addItems(withTitles:presets.map(\.title)); position.selectItem(at:match.map { $0+(isCustom ? 1 : 0) } ?? 0)
        position.setAccessibilityLabel(L("画面位置"))
        canvas=NSPopUpButton(frame:NSRect(x:160,y:38,width:242,height:26),pullsDown:false)
        canvas.addItems(withTitles:CanvasAspect.allCases.map(\.title)); canvas.selectItem(at:CanvasAspect.allCases.firstIndex(of:aspect) ?? 0)
        canvas.setAccessibilityLabel(L("画布（整个工程）"))
        let crop=clip.crop ?? VideoCrop()
        let names=[L("上"),L("下"),L("左"),L("右")]
        let fields=zip([crop.top,crop.bottom,crop.left,crop.right],names).enumerated().map { i,pair -> NSTextField in
            let field=NSTextField(string:String(format:"%.1f",pair.0*100)); field.frame=NSRect(x:160+CGFloat(i)*46,y:4,width:42,height:24)
            field.placeholderString=pair.1; field.toolTip=pair.1+" %"; field.setAccessibilityLabel(L("裁切")+" "+pair.1); return field
        }
        cropFields=fields
        autoCrop=ActionButton(L("自动"),action:{
            let found=BlackBorderDetector.detect(path:clip.path,sourceStart:clip.sourceStart,sourceEnd:clip.sourceEnd) ?? VideoCrop()
            for (field,value) in zip(fields,[found.top,found.bottom,found.left,found.right]) { field.stringValue=String(format:"%.1f",value*100) }
        })
        autoCrop.frame=NSRect(x:344,y:2,width:60,height:28); autoCrop.toolTip=L("自动检测视频里录进去的黑边")
        for (title,y,control) in [(L("画面位置"),76,position),(L("画布（整个工程）"),40,canvas)] as [(String,CGFloat,NSView)] {
            let text=label(title,size:12); text.frame=NSRect(x:0,y:y,width:156,height:24); form.addSubview(text); form.addSubview(control)
        }
        let cropTitle=label(L("裁黑边 %（上 下 左 右）"),size:12); cropTitle.frame=NSRect(x:0,y:6,width:156,height:24); form.addSubview(cropTitle)
        fields.forEach(form.addSubview); form.addSubview(autoCrop)
    }
    var selectedFrame: VideoFrame? { presets[max(0,position.indexOfSelectedItem)].frame }
    var selectedCanvas: CanvasAspect { CanvasAspect.allCases[max(0,canvas.indexOfSelectedItem)] }
    /// nil when a field is not a number; validity of the ranges is checked with the project.
    var selectedCrop: VideoCrop?? {
        let values=cropFields.map { Double($0.stringValue.replacingOccurrences(of:",",with:".").trimmingCharacters(in:.whitespaces)) }
        guard values.allSatisfy({ $0 != nil }) else { return nil }
        let crop=VideoCrop(top:values[0]!/100,bottom:values[1]!/100,left:values[2]!/100,right:values[3]!/100)
        return .some(crop.isEmpty ? nil : crop)
    }
}
