import AppKit
import AVKit
import SubtitleCore

let accent=NSColor(srgbRed:0.10,green:0.83,blue:0.80,alpha:1)
let panelColor=NSColor(srgbRed:0.115,green:0.125,blue:0.14,alpha:1)
let muted=NSColor(srgbRed:0.55,green:0.59,blue:0.64,alpha:1)
func label(_ text: String, size: CGFloat = 12, color: NSColor = .labelColor, bold: Bool = false) -> NSTextField {
    let l=NSTextField(labelWithString:text); l.font=bold ? .systemFont(ofSize:size,weight:.semibold) : .systemFont(ofSize:size); l.textColor=color; return l
}
final class ActionButton: NSButton {
    var actionBlock: (()->Void)?
    convenience init(_ title: String, symbol: String? = nil, action: @escaping ()->Void) {
        self.init(frame:.zero); self.title=title; if InterfaceLanguage.current == .en { font = .systemFont(ofSize:11) }; bezelStyle = .rounded; target=self; self.action=#selector(invoke); actionBlock=action
        if let symbol { image=NSImage(systemSymbolName:symbol,accessibilityDescription:title); imagePosition = .imageLeading }
    }
    @objc func invoke() { actionBlock?() }
}
final class ActionPopUp: NSPopUpButton {
    var actionBlock: (()->Void)?
    convenience init(frame: NSRect, items: [String], action: @escaping ()->Void) {
        self.init(frame:frame,pullsDown:false); addItems(withTitles:items); target=self; self.action=#selector(invoke); actionBlock=action
    }
    @objc func invoke() { actionBlock?() }
}
final class PanelDivider: NSView {
    var onResize: ((CGFloat,Bool)->Void)?
    var onReset: (()->Void)?
    var isVertical=false
    private var previousY: CGFloat?
    private func coordinate(_ event:NSEvent) -> CGFloat { isVertical ? event.locationInWindow.x : event.locationInWindow.y }
    override init(frame:NSRect) {
        super.init(frame:frame)
        toolTip=L("上下拖动调整预览与时间轴高度；双击恢复默认")
        setAccessibilityElement(true); setAccessibilityRole(.splitter)
        setAccessibilityLabel(L("调整预览与时间轴高度"))
    }
    required init?(coder:NSCoder) { fatalError() }
    override func resetCursorRects() { addCursorRect(bounds,cursor:isVertical ? .resizeLeftRight : .resizeUpDown) }
    override func draw(_ dirtyRect:NSRect) {
        NSColor.white.withAlphaComponent(0.35).setFill()
        let grip=isVertical ? CGRect(x:bounds.midX-1.5,y:bounds.midY-24,width:3,height:48) : CGRect(x:bounds.midX-24,y:bounds.midY-1.5,width:48,height:3)
        NSBezierPath(roundedRect:grip,xRadius:1.5,yRadius:1.5).fill()
    }
    override func mouseDown(with event:NSEvent) {
        if event.clickCount == 2 { previousY=nil; onReset?(); return }
        previousY=coordinate(event)
    }
    override func mouseDragged(with event:NSEvent) {
        guard let y=previousY else { return }
        previousY=coordinate(event)
        onResize?(coordinate(event)-y,false)
    }
    override func mouseUp(with event:NSEvent) {
        guard previousY != nil else { return }
        previousY=nil; onResize?(0,true)
    }
}
final class LayoutView: NSView {
    var onLayout: (()->Void)?
    override func layout() { super.layout(); onLayout?() }
}
/// A wrapping editor must never horizontally scroll its first character away.
final class TextEditorClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect=super.constrainBoundsRect(proposedBounds)
        rect.origin.x=0
        return rect
    }
}
/// Keep gutters hidden even when macOS prefers always-visible scrollers.
class AutoHidingScrollView: NSScrollView {
    private var hideScroller: DispatchWorkItem?
    private var scrolling=false
    override var scrollerStyle: NSScroller.Style {
        get { super.scrollerStyle }
        set { super.scrollerStyle = .overlay }
    }
    override func tile() {
        super.tile()
        verticalScroller?.alphaValue=scrolling ? 1 : 0
        horizontalScroller?.alphaValue=scrolling ? 1 : 0
    }
    override func scrollWheel(with event: NSEvent) {
        scrolling=true
        verticalScroller?.alphaValue=1
        horizontalScroller?.alphaValue=1
        super.scrollWheel(with:event)
        hideScroller?.cancel()
        let work=DispatchWorkItem { [weak self] in
            self?.scrolling=false
            self?.verticalScroller?.alphaValue=0
            self?.horizontalScroller?.alphaValue=0
        }
        hideScroller=work
        DispatchQueue.main.asyncAfter(deadline:.now()+0.8,execute:work)
    }
    deinit { hideScroller?.cancel() }
}

/// Timeline scrollers stay hidden until a video is on the timeline, then remain visible on the right and bottom.
/// Legacy style is required: AppKit fades overlay scrollers on its own.
final class TimelineScrollView: NSScrollView {
    var showsScrollers=false { didSet { if showsScrollers != oldValue { applyScrollers() } } }
    func applyScrollers() {
        scrollerStyle = showsScrollers ? .legacy : .overlay
        scrollerKnobStyle = .light
        autohidesScrollers = !showsScrollers
        hasHorizontalScroller=showsScrollers; hasVerticalScroller=showsScrollers
        tile()
    }
}

final class TextEditorScrollView: AutoHidingScrollView {
    override func tile() {
        super.tile()
        guard let text=documentView as? NSTextView else { return }
        let width=max(1,contentSize.width)
        if text.frame.width != width || text.frame.minX != 0 {
            text.setFrameOrigin(NSPoint(x:0,y:text.frame.minY))
            text.setFrameSize(NSSize(width:width,height:text.frame.height))
        }
        if contentView.bounds.minX != 0 {
            contentView.scroll(to:NSPoint(x:0,y:contentView.bounds.minY))
        }
    }
}
final class SubtitleTableView: NSTableView {
    var onDeselect: (()->Void)?
    override func mouseDown(with event: NSEvent) {
        let blank=row(at:convert(event.locationInWindow,from:nil)) < 0
        super.mouseDown(with:event)
        if blank { onDeselect?() }
    }
}
final class DropView: NSView {
    var drop: ((URL)->Void)?
    override init(frame: NSRect) { super.init(frame:frame); registerForDraggedTypes([.fileURL]) }
    required init?(coder: NSCoder) { fatalError() }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url=(sender.draggingPasteboard.readObjects(forClasses:[NSURL.self],options:nil) as? [URL])?.first else { return false }; drop?(url); return true
    }
}
final class PreviewOverlay: NSView {
    var project=Project(); var time: Int64=0; var videoSize=CGSize(width:16,height:9)
    var editingEnabled=true
    var onDeselect: (()->Void)?
    var selected: UUID?; var onSelect: ((UUID)->Void)?
    var onGestureBegan: (()->Void)?
    var onStyleChange: ((UUID,SubtitleStyle,Bool)->Void)?
    var onGestureCancelled: (()->Void)?
    var eraseMode=false
    var eraseRect: CGRect?
    private var eraseAnchor: CGPoint?
    var onEraseStarted: ((CGPoint)->Void)?
    var onEraseSelected: (()->Void)?
    var onEraseCancelled: (()->Void)?
    var hitBoxes: [(UUID,CGRect)] = []
    private struct Gesture {
        var id: UUID
        var style: SubtitleStyle
        var origin: CGPoint
        var center: CGPoint
        var resizing: Bool
        var widthEdge: Int?
        var box: CGRect
        var changed=false
    }
    private var gesture: Gesture?
    override var acceptsFirstResponder: Bool { true }
    private func handles(_ rect: CGRect) -> [CGPoint] {
        let r=rect.insetBy(dx:-4,dy:-4)
        return [CGPoint(x:r.minX,y:r.minY),CGPoint(x:r.maxX,y:r.minY),CGPoint(x:r.minX,y:r.maxY),CGPoint(x:r.maxX,y:r.maxY)]
    }
    private func sideHandles(_ box: CGRect) -> [CGPoint] {
        [CGPoint(x:box.minX-4,y:box.midY),CGPoint(x:box.maxX+4,y:box.midY)]
    }
    private func resizeTarget(at point: CGPoint, box: CGRect) -> (corner: Bool, edge: Int?)? {
        // Small text brings corner and side hit areas together. Choose the nearest
        // visible control instead of letting a side handle steal corner drags.
        let corners=handles(box).map { ($0,true,Optional<Int>.none) }
        let sides=sideHandles(box).enumerated().map { ($0.element,false,Optional($0.offset)) }
        guard let target=(corners+sides).filter({ abs($0.0.x-point.x)<=10 && abs($0.0.y-point.y)<=10 })
            .min(by:{ hypot($0.0.x-point.x,$0.0.y-point.y) < hypot($1.0.x-point.x,$1.0.y-point.y) }) else { return nil }
        return (target.1,target.2)
    }
    var videoRect: CGRect {
        VideoGeometry.aspectFit(video:videoSize, container:bounds)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx=NSGraphicsContext.current?.cgContext else { return }
        let rect=videoRect
        ctx.saveGState(); ctx.translateBy(x:rect.minX,y:rect.minY)
        hitBoxes=SubtitleRenderer.draw(project:project,at:time,size:rect.size,context:ctx)
        if let item=hitBoxes.first(where: { $0.0 == selected }) {
            ctx.saveGState()
            ctx.setShadow(offset:CGSize(width:0,height:-1),blur:2,color:NSColor.black.withAlphaComponent(0.35).cgColor)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
            ctx.setLineWidth(1); ctx.stroke(item.1.insetBy(dx:-4,dy:-4))
            ctx.setFillColor(NSColor.white.cgColor)
            for point in handles(item.1) {
                ctx.fillEllipse(in:CGRect(x:point.x-4.5,y:point.y-4.5,width:9,height:9))
            }
            for point in sideHandles(item.1) {
                let grip=CGRect(x:point.x-2.5,y:point.y-5,width:5,height:10)
                ctx.addPath(CGPath(roundedRect:grip,cornerWidth:2.5,cornerHeight:2.5,transform:nil)); ctx.fillPath()
            }
            ctx.restoreGState()
        }
        if eraseMode,let region=eraseRect {
            let box=CGRect(x:region.minX*rect.width,y:region.minY*rect.height,width:region.width*rect.width,height:region.height*rect.height)
            ctx.setFillColor(accent.withAlphaComponent(0.13).cgColor); ctx.fill(box)
            ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(1.5); ctx.setLineDash(phase:0,lengths:[5,3]); ctx.stroke(box)
            ctx.setLineDash(phase:0,lengths:[]); ctx.setFillColor(NSColor.white.cgColor)
            for point in [CGPoint(x:box.minX,y:box.minY),CGPoint(x:box.maxX,y:box.minY),CGPoint(x:box.minX,y:box.maxY),CGPoint(x:box.maxX,y:box.maxY)] { ctx.fillEllipse(in:CGRect(x:point.x-3,y:point.y-3,width:6,height:6)) }
        }
        ctx.restoreGState()
        window?.invalidateCursorRects(for:self)
    }
    override func resetCursorRects() {
        guard editingEnabled else { return }
        let r=videoRect
        if eraseMode { addCursorRect(r,cursor:.crosshair); return }
        for (_,box) in hitBoxes { addCursorRect(box.offsetBy(dx:r.minX,dy:r.minY),cursor:.openHand) }
        if let hit=hitBoxes.first(where:{$0.0 == selected}) {
            let band=min(6,(hit.1.height+8)/4)
            for p in sideHandles(hit.1) { addCursorRect(CGRect(x:p.x+r.minX-10,y:p.y+r.minY-band,width:20,height:band*2),cursor:.resizeLeftRight) }
            for p in handles(hit.1) { addCursorRect(CGRect(x:p.x+r.minX-10,y:p.y+r.minY-band,width:20,height:band*2),cursor:.crosshair) }
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard editingEnabled else { return }
        window?.makeFirstResponder(self)
        let location=convert(event.locationInWindow,from:nil),r=videoRect
        let point=CGPoint(x:location.x-r.minX,y:location.y-r.minY)
        if eraseMode {
            guard r.contains(location),r.width>0,r.height>0 else { return }
            eraseAnchor=CGPoint(x:point.x/r.width,y:point.y/r.height); eraseRect=nil; onEraseStarted?(eraseAnchor!); needsDisplay=true; return
        }
        let selectedHit=hitBoxes.first(where:{$0.0 == selected})
        let target=selectedHit.flatMap { resizeTarget(at:point,box:$0.1) }
        let widthEdge=target?.edge
        let onHandle=target?.corner ?? false
        let hit=(onHandle || widthEdge != nil) ? selectedHit : hitBoxes.reversed().first(where:{$0.1.insetBy(dx:-6,dy:-6).contains(point)})
        guard let hit,let cue=project.cues.first(where:{$0.id == hit.0}) else { onDeselect?(); return }
        onSelect?(hit.0)
        gesture=Gesture(id:hit.0,style:project.style(for:cue),origin:point,center:CGPoint(x:hit.1.midX,y:hit.1.midY),resizing:onHandle,widthEdge:widthEdge,box:hit.1)
    }
    override func mouseDragged(with event: NSEvent) {
        if eraseMode,editingEnabled,let anchor=eraseAnchor {
            let location=convert(event.locationInWindow,from:nil),r=videoRect
            guard r.width>0,r.height>0 else { return }
            let x=max(0,min(1,(location.x-r.minX)/r.width)),y=max(0,min(1,(location.y-r.minY)/r.height))
            eraseRect=CGRect(x:min(anchor.x,x),y:min(anchor.y,y),width:abs(anchor.x-x),height:abs(anchor.y-y)); needsDisplay=true; return
        }
        guard editingEnabled,var g=gesture, let cue=project.cues.first(where:{$0.id == g.id}) else { return }
        let location=convert(event.locationInWindow,from:nil),r=videoRect
        guard r.width>0,r.height>0 else { return }
        let point=CGPoint(x:location.x-r.minX,y:location.y-r.minY)
        if !g.changed { onGestureBegan?(); g.changed=true; gesture=g }
        var style=g.style
        if let edge=g.widthEdge {
            let box=VideoGeometry.resizedTextBox(g.box,delta:point.x-g.origin.x,leftEdge:edge == 0,videoWidth:r.width)
            style.width=box.width/r.width; style.x=box.midX/r.width
        } else if g.resizing {
            style.size=VideoGeometry.resizedFontSize(initial:g.style.size,anchor:g.center,handle:g.origin,pointer:point)
        } else {
            style.x=max(0,min(1,g.style.x+(point.x-g.origin.x)/r.width))
            style.y=max(0,min(1,g.style.y+(point.y-g.origin.y)/r.height))
        }
        project.applyStyle(style,for:cue)
        onStyleChange?(g.id,style,false); needsDisplay=true
    }
    override func mouseUp(with event: NSEvent) {
        if eraseMode {
            // Include the final pointer position even when drag events were coalesced.
            if eraseAnchor != nil { mouseDragged(with:event) }
            eraseAnchor=nil
            if let box=eraseRect,box.width*videoRect.width>=3,box.height*videoRect.height>=3 { onEraseSelected?() } else { eraseRect=nil }
            needsDisplay=true; return
        }
        if let g=gesture,g.changed,let cue=project.cues.first(where:{$0.id == g.id}) { onStyleChange?(g.id,project.style(for:cue),true) }
        gesture=nil; window?.invalidateCursorRects(for:self)
    }
    override func cancelOperation(_ sender: Any?) {
        if eraseMode { eraseAnchor=nil; eraseRect=nil; eraseMode=false; onEraseCancelled?(); needsDisplay=true; return }
        if gesture?.changed == true { onGestureCancelled?() }; gesture=nil; needsDisplay=true
    }

}
final class TimelineView: NSView {
    var canDropFiles: (([URL])->Bool)?
    var dropFiles: (([URL])->Bool)?
    private var fileDropHighlighted=false { didSet { needsDisplay=true } }
    func acceptsFileDrop(_ pasteboard: NSPasteboard) -> Bool {
        let urls=mediaFileURLs(from:pasteboard)
        return editingEnabled && !urls.isEmpty && canDropFiles?(urls) == true
    }
    func importFileDrop(_ pasteboard: NSPasteboard) -> Bool {
        guard acceptsFileDrop(pasteboard) else { return false }
        return dropFiles?(mediaFileURLs(from:pasteboard)) ?? false
    }

    var subtitleTracksRequested = false
    var subtitleRowCount: Int { subtitleTracksRequested || project.cues.contains(where: { $0.trackID == nil }) ? project.subtitleLanguages.count : 0 }
    var transferVideoClip: ((UUID,VideoTrackDestination,Int64)->Void)?
    private var bodyDrag: (id:UUID,origin:CGFloat,originY:CGFloat,start:Int64,base:Project)?
    private var pendingTransfer: (VideoTrackDestination,Int64)?
    private var transferGhost: CGRect?
    private var validTransfer=false
    private var bodyHasDragged=false
    var insertMediaClip: ((UUID,Int)->Bool)?
    var addVideoLayer: ((UUID,Int64,UUID?)->Bool)?
    private var dropTrackID: UUID?
    var moveVideoLayer: ((VideoLayer)->Void)?
    private var layerDrag: (VideoLayer,CGFloat,Int)?
    private var pendingLayerMove: VideoLayer?
    private var layerDropTime: Int64? { didSet { needsDisplay=true } }
    private var dropIndex: Int? { didSet { needsDisplay=true } }
    override init(frame: NSRect) { super.init(frame:frame); registerForDraggedTypes([mediaClipDragType,.fileURL]) }
    required init?(coder: NSCoder) { super.init(coder:coder); registerForDraggedTypes([mediaClipDragType,.fileURL]) }
    private func mediaDrop(_ sender: NSDraggingInfo) -> (UUID,Int)? {
        let point=convert(sender.draggingLocation,from:nil)
        guard editingEnabled,point.x>=leading,
              point.y>=layerY,
              let raw=sender.draggingPasteboard.string(forType:mediaClipDragType),let id=UUID(uuidString:raw),
              project.allClips.contains(where:{$0.id == id}) else { return nil }
        if point.y>=newLayerY { return (id,-1) }
        if let track=project.layerTracks.first(where:{ let y=videoRowY($0[0].id); return point.y>=y && point.y<y+videoHeight }),!track[0].isLocked {
            let time=max(0,Int64((point.x-leading)/pointsPerSecond*1000))
            guard (try? project.addingLayer(from:id,at:time,trackID:track[0].trackIdentifier)) != nil else { return nil }
            return (id,-2)
        }
        guard !project.isVideoLocked,point.y>=videoY-8,point.y<=videoY+videoHeight+8 else { return nil }
        let places=project.placements
        let index=places.firstIndex(where:{point.x < x($0.start+($0.end-$0.start)/2)}) ?? places.count
        return (id,index)
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if let event=NSApp.currentEvent { autoscroll(with:event) }
        if sender.draggingPasteboard.availableType(from:[mediaClipDragType]) == nil {
            dropIndex=nil; layerDropTime=nil; dropTrackID=nil
            fileDropHighlighted=acceptsFileDrop(sender.draggingPasteboard)
            return fileDropHighlighted ? .copy : []
        }
        fileDropHighlighted=false
        let drop=mediaDrop(sender)
        dropIndex=drop?.1
        dropTrackID=drop?.1 == -2 ? trackID(at:convert(sender.draggingLocation,from:nil).y) : nil
        layerDropTime=(drop?.1 ?? 0)<0 ? max(0,Int64((convert(sender.draggingLocation,from:nil).x-leading)/pointsPerSecond*1000)) : nil
        return drop == nil ? [] : .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropIndex=nil; layerDropTime=nil; dropTrackID=nil; fileDropHighlighted=false }
    override func draggingEnded(_ sender: NSDraggingInfo) { dropIndex=nil; layerDropTime=nil; dropTrackID=nil; fileDropHighlighted=false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { dropIndex=nil; layerDropTime=nil; dropTrackID=nil; fileDropHighlighted=false }
        if sender.draggingPasteboard.availableType(from:[mediaClipDragType]) == nil { return importFileDrop(sender.draggingPasteboard) }
        guard let (id,index)=mediaDrop(sender) else { return false }
        if index<0 {
            let time=max(0,Int64((convert(sender.draggingLocation,from:nil).x-leading)/pointsPerSecond*1000))
            return addVideoLayer?(id,time,index == -2 ? trackID(at:convert(sender.draggingLocation,from:nil).y) : nil) ?? false
        }
        return insertMediaClip?(id,index) ?? false
    }

    var project=Project() { didSet { needsLayout=true } }; var current: Int64=0; var selected: UUID? { didSet { needsDisplay=true; window?.invalidateCursorRects(for:self) } }; var pointsPerSecond: CGFloat=65
    var clipThumbnails: [UUID:[NSImage?]]=[:]
    var clipWaveforms: [UUID:[Float]]=[:]
    let videoHeight: CGFloat=76
    var selectedMusic: UUID?
    var selectMusic: ((UUID)->Void)?
    var editMusic: (()->Void)?
    var moveMusic: ((BackgroundMusic)->Void)?
    private var musicDrag: (BackgroundMusic,CGFloat,Int)?
    var selectedClip: UUID?
    var selectVideo: ((UUID)->Void)?
    var editVideo: (()->Void)?
    var editVideoRange: ((UUID,Int64,Int64)->Void)?
    var editVideoTrack: ((UUID,Int)->Void)?
    private var videoDrag: (VideoClip,CGFloat,Int)?
    var editingEnabled=true { didSet { needsLayout=true } }
    var onDeselect: (()->Void)?
    var select: ((UUID)->Void)?; var seek: ((Int64)->Void)?; var edit: ((UUID,Int64,Int64)->Void)?
    private var drag: (Cue,CGFloat,Int)?
    var toggleVideoTrackControl: ((Int)->Void)?
    var toggleLayerTrackControl: ((UUID,Int)->Void)?
    private var layerButtons: [UUID:[NSButton]]=[:]
    private var trackButtons: [NSButton]=[]
    override func layout() {
        super.layout()
        if trackButtons.isEmpty {
            for index in 0..<3 {
                let button=NSButton(); button.tag=index; button.isBordered=false
                button.setButtonType(.toggle); button.target=self; button.action=#selector(trackControlPressed(_:))
                button.imagePosition = .imageOnly; addSubview(button); trackButtons.append(button)
            }
        }
        for id in Array(layerButtons.keys) where !project.layers.contains(where:{$0.trackIdentifier == id}) {
            layerButtons.removeValue(forKey:id)?.forEach{$0.removeFromSuperview()}
        }
        for (row,track) in project.layerTracks.enumerated() {
            let layer=track[0],id=layer.trackIdentifier
            if layerButtons[id] == nil {
                layerButtons[id]=(0..<3).map { index in
                    let button=NSButton(); button.tag=index; button.identifier=NSUserInterfaceItemIdentifier(id.uuidString)
                    button.isBordered=false; button.setButtonType(.toggle); button.target=self; button.action=#selector(layerControlPressed(_:))
                    button.imagePosition = .imageOnly; addSubview(button); return button
                }
            }
            let states=[layer.isLocked,layer.hidden,layer.muted]
            let symbols=[layer.isLocked ? "lock.fill" : "lock.open",layer.hidden ? "eye.slash" : "eye",layer.muted ? "speaker.slash.fill" : "speaker.wave.2"]
            let labels=[L(layer.isLocked ? "解锁视频轨道" : "锁定视频轨道"),L(layer.hidden ? "显示视频轨道" : "隐藏视频轨道"),L(layer.muted ? "恢复视频原声" : "静音原视频")]
            for (i,button) in (layerButtons[id] ?? []).enumerated() {
                button.frame=CGRect(x:5+CGFloat(i)*25,y:videoRowY(layer.id)+32,width:23,height:25)
                let title=L("视频")+" \(project.layerTracks.count-row+1) · "+labels[i]
                button.image=NSImage(systemSymbolName:symbols[i],accessibilityDescription:title)
                button.toolTip=title; button.setAccessibilityLabel(title)
                button.state=states[i] ? .on : .off; button.contentTintColor=states[i] ? accent : muted
                button.isEnabled=editingEnabled
            }
        }
        let symbols=[project.isVideoLocked ? "lock.fill" : "lock.open",project.isVideoHidden ? "eye.slash" : "eye",project.isVideoMuted ? "speaker.slash.fill" : "speaker.wave.2"]
        let labels=[L(project.isVideoLocked ? "解锁视频轨道" : "锁定视频轨道"),L(project.isVideoHidden ? "显示视频轨道" : "隐藏视频轨道"),L(project.isVideoMuted ? "恢复视频原声" : "静音原视频")]
        for (i,button) in trackButtons.enumerated() {
            button.frame=CGRect(x:5+CGFloat(i)*25,y:videoY+32,width:23,height:25)
            button.image=NSImage(systemSymbolName:symbols[i],accessibilityDescription:labels[i])
            button.toolTip=labels[i]; button.setAccessibilityLabel(labels[i])
            let on=[project.isVideoLocked,project.isVideoHidden,project.isVideoMuted][i]
            button.state=on ? .on : .off; button.contentTintColor=on ? accent : muted
            button.isEnabled=editingEnabled && !project.clips.isEmpty
        }
    }
    override func cancelOperation(_ sender: Any?) {
        if bodyDrag != nil { bodyDrag=nil; pendingTransfer=nil; transferGhost=nil; needsDisplay=true }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard editingEnabled,let id=trackID(at:convert(event.locationInWindow,from:nil).y),
              let index=project.layerTracks.firstIndex(where:{$0[0].trackIdentifier == id}) else { return nil }
        let menu=NSMenu(); menu.autoenablesItems=false
        for (action,title) in [L("删除轨道"),L("上移轨道"),L("下移轨道")].enumerated() {
            let item=NSMenuItem(title:title,action:#selector(videoTrackMenuAction(_:)),keyEquivalent:"")
            item.target=self; item.tag=action; item.representedObject=id.uuidString
            item.isEnabled = !project.layerTracks[index][0].isLocked
            if action>0 {
                let adjacent=index+(action == 1 ? -1 : 1)
                item.isEnabled = item.isEnabled && project.layerTracks.indices.contains(adjacent) && !project.layerTracks[adjacent][0].isLocked
            }
            menu.addItem(item)
        }
        return menu
    }
    @objc private func videoTrackMenuAction(_ sender: NSMenuItem) {
        guard let raw=sender.representedObject as? String,let id=UUID(uuidString:raw) else { return }
        editVideoTrack?(id,sender.tag)
    }
    @objc private func layerControlPressed(_ sender: NSButton) {
        guard let raw=sender.identifier?.rawValue,let id=UUID(uuidString:raw) else { return }
        toggleLayerTrackControl?(id,sender.tag)
    }
    @objc private func trackControlPressed(_ sender: NSButton) { toggleVideoTrackControl?(sender.tag) }
    var leading: CGFloat=InterfaceLanguage.current == .en ? 104 : 84
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    func x(_ ms: Int64) -> CGFloat { leading+CGFloat(ms)/1000*pointsPerSecond }
    func ms(_ x: CGFloat) -> Int64 { max(0,min(project.duration,Int64(max(0,x-leading)/pointsPerSecond*1000))) }
    var layerY: CGFloat { 51+CGFloat(subtitleRowCount+project.tracks.count)*44 }
    var videoY: CGFloat { layerY+CGFloat(project.layerTracks.count)*(videoHeight+11) }
    func videoRowY(_ id: UUID) -> CGFloat { project.layerTracks.firstIndex(where:{$0.contains(where:{$0.id == id})}).map{layerY+CGFloat($0)*(videoHeight+11)} ?? videoY }
    func trackID(at y: CGFloat) -> UUID? {
        project.layerTracks.first(where:{ let row=videoRowY($0[0].id); return y>=row && y<row+videoHeight })?.first?.trackIdentifier
    }
    var newLayerY: CGFloat { videoY+videoHeight+11+CGFloat(project.music.count)*44 }
    var contentHeight: CGFloat { newLayerY+60 }
    func rect(_ cue: Cue) -> CGRect {
        let row=cue.trackID.flatMap { id in project.tracks.firstIndex(where:{$0.id == id}) }.map{$0+subtitleRowCount} ?? (project.subtitleLanguages.firstIndex(of:cue.language) ?? 0)
        return CGRect(x:x(cue.start),y:47+CGFloat(row)*44,width:max(2,x(cue.end)-x(cue.start)),height:32)
    }
    private func edgeHandle(_ cue: Cue, left: Bool) -> CGRect {
        let r=rect(cue)
        return CGRect(x:(left ? r.minX : r.maxX)-5,y:r.minY-2,width:10,height:r.height+4)
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        guard editingEnabled else { return }
        for cue in project.cues where project.visible(cue) {
            addCursorRect(rect(cue),cursor:.openHand)
        }
        if let cue=project.cues.first(where:{$0.id == selected && project.visible($0)}) {
            addCursorRect(edgeHandle(cue,left:true),cursor:.resizeLeftRight)
            addCursorRect(edgeHandle(cue,left:false),cursor:.resizeLeftRight)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed:0.08,green:0.09,blue:0.105,alpha:1).setFill(); bounds.fill()
        let paragraph=NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        func text(_ s: String, _ rect: CGRect, _ color: NSColor = muted, _ size: CGFloat=10) {
            (s as NSString).draw(in:rect,withAttributes:[.font:NSFont.monospacedSystemFont(ofSize:size,weight:.medium),.foregroundColor:color,.paragraphStyle:paragraph])
        }
        let step: Int = pointsPerSecond > 45 ? 1 : (pointsPerSecond > 15 ? 5 : 10)
        let first=max(0,Int((dirtyRect.minX-leading)/pointsPerSecond)/step*step), last=min(Int(project.timelineExtent/1000)+1,Int((dirtyRect.maxX-leading)/pointsPerSecond)+1)
        if first <= last { for sec in stride(from:first,through:last,by:step) {
            let px=x(Int64(sec)*1000); NSColor(white:0.23,alpha:1).setFill(); CGRect(x:px,y:28,width:1,height:bounds.height-28).fill()
            text(String(format:"%02d:%02d",sec/60,sec%60),CGRect(x:px+4,y:8,width:55,height:16))
        } }
        if subtitleRowCount > 0 {
            for (i,language) in project.subtitleLanguages.enumerated() { text(language.rawValue.uppercased()+" · "+language.title,CGRect(x:10,y:55+CGFloat(i)*44,width:70,height:20)) }
        }
        text(L("视频")+" 1",CGRect(x:10,y:videoY+14,width:70,height:20))
        for (i,track) in project.tracks.enumerated() { text(track.name,CGRect(x:10,y:55+CGFloat(subtitleRowCount+i)*44,width:70,height:20),accent) }
        for cue in project.cues where project.visible(cue) && rect(cue).intersects(dirtyRect) {
            let r=rect(cue); let visible=project.visible(cue)
            (cue.trackID != nil ? NSColor.systemTeal : cue.language == .fr ? NSColor(srgbRed:0.35,green:0.31,blue:0.61,alpha:visible ? 1:0.35) : NSColor(srgbRed:0.65,green:0.36,blue:0.24,alpha:visible ? 1:0.35)).setFill()
            NSBezierPath(roundedRect:r,xRadius:5,yRadius:5).fill()
            text(cue.text,r.insetBy(dx:7,dy:8),.white,11)

        }
        for p in project.renderPlacements {
            let videoY=videoRowY(p.clip.id)
            let r=CGRect(x:x(p.start),y:videoY,width:max(2,x(p.end)-x(p.start)),height:videoHeight)
            guard r.intersects(dirtyRect) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect:r.insetBy(dx:1,dy:0),xRadius:4,yRadius:4).addClip()
            NSColor(srgbRed:0.02,green:0.29,blue:0.31,alpha:1).setFill(); r.fill()
            if let images=clipThumbnails[p.clip.id],!images.isEmpty {
                NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect:r).addClip()
                let first=max(0,Int((dirtyRect.minX-r.minX)/90)),last=min(Int(r.width/90),Int((dirtyRect.maxX-r.minX)/90))
                if first<=last { for i in first...last {
                    let ratio=min(0.999,(CGFloat(i)*90+45)/max(1,r.width))
                    let index=min(images.count-1,Int(ratio*CGFloat(images.count)))
                    guard let image=images[index] ?? images.compactMap({$0}).first else { continue }
                    let tile=CGRect(x:r.minX+CGFloat(i)*90,y:videoY+19,width:89,height:40)
                    // Fill each tile without stretching portrait footage.
                    let scale=max(tile.width/image.size.width,tile.height/image.size.height)
                    let sourceSize=CGSize(width:tile.width/scale,height:tile.height/scale)
                    let source=CGRect(x:(image.size.width-sourceSize.width)/2,y:(image.size.height-sourceSize.height)/2,width:sourceSize.width,height:sourceSize.height)
                    image.draw(in:tile,from:source,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
                } }
                NSGraphicsContext.restoreGraphicsState()
            }
            let title=URL(fileURLWithPath:p.clip.path).lastPathComponent+"  "+SRT.timestamp(p.clip.duration).replacingOccurrences(of:",",with:".")
            text(title,CGRect(x:r.minX+5,y:videoY+2,width:max(1,r.width-10),height:16),.white,10)
            let wave=CGRect(x:r.minX,y:videoY+60,width:r.width,height:16)
            NSColor(srgbRed:0.02,green:0.36,blue:0.38,alpha:1).setFill(); wave.fill()
            NSColor(srgbRed:0.20,green:0.77,blue:0.79,alpha:1).setFill()
            CGRect(x:wave.minX,y:wave.midY,width:wave.width,height:0.5).fill()
            if let peaks=clipWaveforms[p.clip.id],!peaks.isEmpty {
                let start=max(0,Int((dirtyRect.minX-r.minX)/2)),end=min(Int(ceil(r.width/2)),Int(ceil((dirtyRect.maxX-r.minX)/2)))
                if start<end { for bar in start..<end {
                    let lo=min(peaks.count-1,Int(CGFloat(bar*2)/r.width*CGFloat(peaks.count)))
                    let hi=min(peaks.count,max(lo+1,Int(CGFloat(bar*2+2)/r.width*CGFloat(peaks.count))))
                    let amplitude=CGFloat(peaks[lo..<hi].max() ?? 0)
                    let height=max(0.5,min(14,sqrt(amplitude)*14))
                    CGRect(x:r.minX+CGFloat(bar*2),y:wave.midY-height/2,width:1,height:height).fill()
                } }
            }
            if p.clip.transition>0 {
                let transition=CGRect(x:r.minX,y:videoY,width:CGFloat(p.clip.transition)/1000*pointsPerSecond,height:videoHeight)
                NSColor.systemOrange.withAlphaComponent(0.45).setFill(); transition.fill()
                text(L("叠化"),transition.insetBy(dx:3,dy:5),.white)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        for (i,track) in project.layerTracks.enumerated() {
            let layer=track[0]
            text(L("视频")+" \(project.layerTracks.count-i+1)",CGRect(x:5,y:videoRowY(layer.id)+4,width:leading-10,height:25),accent)
        }
        let dropRect=CGRect(x:leading,y:newLayerY,width:max(10,bounds.width-leading),height:48)
        NSColor.systemTeal.withAlphaComponent(layerDropTime == nil ? 0.07 : 0.25).setFill(); dropRect.fill()
        text(L("拖动视频到此处新建视频轨道"),dropRect.insetBy(dx:12,dy:14),accent)
        if let time=layerDropTime {
            let row=dropTrackID.flatMap{ id in project.layers.first{$0.trackIdentifier == id} }.map{videoRowY($0.id)} ?? newLayerY
            accent.setFill(); CGRect(x:x(time)-2,y:row,width:4,height:videoHeight).fill()
        }
        if let ghost=transferGhost {
            let color=validTransfer ? accent : NSColor.systemRed
            color.withAlphaComponent(0.35).setFill(); ghost.fill(); color.setStroke()
            let border=NSBezierPath(rect:ghost.insetBy(dx:1,dy:1)); border.lineWidth=2; border.stroke()
        }
        // Dark seams distinguish actual cuts from individual thumbnail tiles.
        for p in project.renderPlacements {
            let videoY=videoRowY(p.clip.id)
            let r=CGRect(x:x(p.start),y:videoY,width:max(2,x(p.end)-x(p.start)),height:videoHeight)
            guard r.insetBy(dx:-2,dy:-1).intersects(dirtyRect) else { continue }
            NSColor(white:0.08,alpha:1).setFill()
            for px in [r.minX,r.maxX] { CGRect(x:px-1,y:r.minY,width:2,height:r.height).fill() }
        }
        // Selection is drawn last so adjoining clips cannot obscure its outline.
        if let p=project.renderPlacements.first(where:{$0.clip.id == selectedClip}) {
            let videoY=videoRowY(p.clip.id)
            let r=CGRect(x:x(p.start),y:videoY,width:max(2,x(p.end)-x(p.start)),height:videoHeight)
            NSColor.white.setStroke()
            let border=NSBezierPath(roundedRect:r.insetBy(dx:1,dy:1),xRadius:4,yRadius:4)
            border.lineWidth=2; border.stroke()
            NSColor.white.setFill()
            for px in [r.minX+1,r.maxX-3] { CGRect(x:px,y:r.midY-8,width:2,height:16).fill() }
        }
        // Draw selection after all clips so adjacent clips cannot cover its handles.
        if let cue=project.cues.first(where:{$0.id == selected && project.visible($0)}) {
            let r=rect(cue)
            NSColor.white.setStroke()
            let border=NSBezierPath(roundedRect:r.insetBy(dx:-1,dy:-1),xRadius:4,yRadius:4)
            border.lineWidth=2; border.stroke()
            for left in [true,false] {
                let handle=edgeHandle(cue,left:left)
                NSColor.white.setFill(); NSBezierPath(roundedRect:handle,xRadius:3,yRadius:3).fill()
                NSColor.black.withAlphaComponent(0.65).setFill()
                CGRect(x:handle.midX-1,y:handle.midY-6,width:2,height:12).fill()
            }
        }
        for (i,music) in project.music.enumerated() {
            let r=musicRect(music)
            text(L("音乐")+" \(i+1)",CGRect(x:8,y:r.minY+8,width:leading-12,height:20),muted,10)
            NSColor.systemGreen.withAlphaComponent(0.55).setFill(); NSBezierPath(roundedRect:r,xRadius:4,yRadius:4).fill()
            text(URL(fileURLWithPath:music.path).lastPathComponent,r.insetBy(dx:7,dy:7),.white,11)
            if music.id == selectedMusic { NSColor.white.setStroke(); let border=NSBezierPath(rect:r.insetBy(dx:1,dy:1)); border.lineWidth=2; border.stroke() }
        }
        if let index=dropIndex,index>=0 {
            let placements=project.placements
            let time=index<placements.count ? placements[index].start : (placements.last?.end ?? 0)
            let px=x(time); accent.setFill()
            CGRect(x:px-2,y:videoY-6,width:4,height:videoHeight+12).fill()
            CGRect(x:px-6,y:videoY-6,width:12,height:4).fill()
        }
        if fileDropHighlighted {
            accent.withAlphaComponent(0.12).setFill(); visibleRect.fill()
            accent.setStroke(); let border=NSBezierPath(roundedRect:visibleRect.insetBy(dx:2,dy:2),xRadius:6,yRadius:6); border.lineWidth=2; border.stroke()
        }
        let px=x(current); accent.setFill(); CGRect(x:px,y:29,width:1.5,height:bounds.height-29).fill()
        let head=NSBezierPath(); head.move(to:CGPoint(x:px-5,y:25)); head.line(to:CGPoint(x:px+5,y:25)); head.line(to:CGPoint(x:px,y:33)); head.close(); head.fill()
    }
    func musicRect(_ music: BackgroundMusic) -> CGRect {
        let index=project.music.firstIndex(where:{$0.id == music.id}) ?? 0
        return CGRect(x:x(music.start),y:videoY+videoHeight+11+CGFloat(index)*44,width:max(2,x(music.start+music.duration)-x(music.start)),height:32)
    }
    override func mouseDown(with event: NSEvent) {
        let p=convert(event.locationInWindow,from:nil)
        guard editingEnabled else { return }
        window?.makeFirstResponder(self)
        if let music=project.music.first(where:{ musicRect($0).contains(p) || (p.x<leading && (musicRect($0).minY...musicRect($0).maxY).contains(p.y)) }) {
            if p.x>=leading { seek?(ms(p.x)) }; selectMusic?(music.id); selectedMusic=music.id
            if event.clickCount == 2 { editMusic?(); return }
            let r=musicRect(music); musicDrag=(music,p.x,p.x-r.minX<8 ? -1 : r.maxX-p.x<8 ? 1 : 0); needsDisplay=true; return
        }
        if let p=project.renderPlacements.reversed().first(where:{CGRect(x:x($0.start),y:videoRowY($0.clip.id),width:x($0.end)-x($0.start),height:videoHeight).contains(p)}) {
            selectVideo?(p.clip.id); selectedClip=p.clip.id
            let point=convert(event.locationInWindow,from:nil)
            seek?(ms(point.x))
            if event.clickCount == 2 { if project.layers.contains(where:{$0.id == p.clip.id}) || !project.isVideoLocked { editVideo?() }; return }
            let mode=abs(point.x-x(p.start))<8 ? -1 : abs(point.x-x(p.end))<8 ? 1 : 0
            if mode == 0 {
                let locked=project.layers.first(where:{$0.id == p.clip.id})?.isLocked ?? project.isVideoLocked
                if !locked { bodyDrag=(p.clip.id,point.x,point.y,p.start,project); bodyHasDragged=false; pendingTransfer=nil; transferGhost=nil }
                needsDisplay=true; return
            }
            if let layer=project.layers.first(where:{$0.id == p.clip.id}) { if !layer.isLocked { layerDrag=(layer,point.x,mode); pendingLayerMove=nil } }
            else if !project.isVideoLocked { videoDrag=(p.clip,point.x,mode) }
            needsDisplay=true; return
        }
        if let cue=project.cues.first(where:{$0.id == selected && project.visible($0)}),
           edgeHandle(cue,left:true).contains(p) || edgeHandle(cue,left:false).contains(p) {
            let left=abs(p.x-rect(cue).minX) <= abs(p.x-rect(cue).maxX)
            select?(cue.id); drag=(cue,p.x,left ? -1 : 1)
        } else if let cue=project.cues.first(where:{project.visible($0) && rect($0).contains(p)}) {
            select?(cue.id); let r=rect(cue)
            let edge=min(7,r.width/3)
            drag=(cue,p.x,p.x-r.minX < edge ? -1 : (r.maxX-p.x < edge ? 1 : 0))
        } else { seek?(ms(p.x)); if p.y>32 { onDeselect?() } }
    }
    override func mouseDragged(with event: NSEvent) {
        guard editingEnabled else { return }
        let p=convert(event.locationInWindow,from:nil)
        if let g=bodyDrag {
            guard bodyHasDragged || hypot(p.x-g.origin,p.y-g.originY)>2 else { return }; bodyHasDragged=true
            let destination:VideoTrackDestination
            let row:CGFloat
            if p.y>=newLayerY { destination = .newTrack; row=newLayerY }
            else if p.y>=videoY && p.y<videoY+videoHeight { destination = .main; row=videoY }
            else if let id=trackID(at:p.y),let track=project.layers.first(where:{$0.trackIdentifier == id}) { destination = .track(id); row=videoRowY(track.id) }
            else { pendingTransfer=nil; transferGhost=nil; needsDisplay=true; return }
            let time=max(0,g.start+Int64((p.x-g.origin)/pointsPerSecond*1000))
            let duration=g.base.allClips.first(where:{$0.id == g.id})?.duration ?? 0
            transferGhost=CGRect(x:x(time),y:row,width:max(2,CGFloat(duration)/1000*pointsPerSecond),height:videoHeight)
            validTransfer=(try? g.base.transferringClip(g.id,to:destination,at:time)) != nil
            pendingTransfer=validTransfer ? (destination,time) : nil
            frame.size.width=max(frame.width,x(time+duration)+120)
            frame.size.height=max(frame.height,row+videoHeight+12)
            needsDisplay=true; autoscroll(with:event); return
        }
        if let (original,origin,mode)=musicDrag,let index=project.music.firstIndex(where:{$0.id == original.id}) {
            let delta=Int64((p.x-origin)/pointsPerSecond*1000); var value=original
            if mode == 0 { value.start=max(0,min(max(0,project.duration-1),original.start+delta)) }
            else if mode == -1 {
                let change=max(-min(original.start,original.sourceStart),min(original.duration-1,delta)); value.start+=change; value.sourceStart+=change
            } else { value.sourceEnd=max(original.sourceStart+1,min(original.sourceDuration,original.sourceEnd+delta)) }
            project.backgroundMusic?[index]=value; needsDisplay=true; return
        }
        if let (original,origin,mode)=layerDrag {
            let delta=Int64((p.x-origin)/pointsPerSecond*1000); var value=original
            if mode == -1 {
                let change=max(-min(original.start,original.clip.sourceStart),min(original.clip.duration-1,delta))
                value.start+=change; value.clip.sourceStart+=change
            } else { value.clip.sourceEnd=max(original.clip.sourceStart+1,min(original.clip.sourceDuration,original.clip.sourceEnd+delta)) }
            if let next=try? project.replacingLayer(value) {
                pendingLayerMove=value
                if value.trackIdentifier == original.trackIdentifier { project=next }
                needsDisplay=true
            }
            return
        }
        if let (original,origin,mode)=videoDrag {
            let delta=Int64((p.x-origin)/pointsPerSecond*1000)
            var clips=project.clips
            guard let i=clips.firstIndex(where:{$0.id == original.id}) else { return }
            if mode == -1 { clips[i].sourceStart=max(0,min(original.sourceEnd-1,original.sourceStart+delta)) }
            else { clips[i].sourceEnd=min(original.sourceDuration,max(original.sourceStart+1,original.sourceEnd+delta)) }
            if let next=try? project.replacingClips(clips) { project=next; needsDisplay=true }
            return
        }
        guard let (original,origin,mode)=drag,let index=project.cues.firstIndex(where:{$0.id == original.id}) else { seek?(ms(p.x)); return }
        let delta=Int64((p.x-origin)/pointsPerSecond*1000), range=project.allowedRange(for:original)
        var cue=original
        if mode == -1 { cue.start=max(range.lowerBound,min(original.end-1,original.start+delta)) }
        else if mode == 1 { cue.end=min(range.upperBound,max(original.start+1,original.end+delta)) }
        else { cue.start=max(range.lowerBound,min(range.upperBound-(original.end-original.start),original.start+delta)); cue.end=cue.start+(original.end-original.start) }
        project.cues[index]=cue; needsDisplay=true
    }
    override func mouseUp(with event: NSEvent) {
        if let g=bodyDrag {
            guard bodyHasDragged else { bodyDrag=nil; return }
            mouseDragged(with:event)
            let pending=pendingTransfer
            bodyDrag=nil; pendingTransfer=nil; transferGhost=nil
            if let (destination,time)=pending { transferVideoClip?(g.id,destination,time) }
            needsDisplay=true; return
        }
        if layerDrag != nil { layerDrag=nil; if let value=pendingLayerMove { moveVideoLayer?(value) }; pendingLayerMove=nil; needsDisplay=true; return }
        if let (music,_,_)=musicDrag,let value=project.music.first(where:{$0.id == music.id}) { musicDrag=nil; moveMusic?(value); return }
        if let (clip,_,_)=videoDrag,let value=project.clips.first(where:{$0.id == clip.id}) {
            videoDrag=nil; editVideoRange?(clip.id,value.sourceStart,value.sourceEnd); return
        }
        if let (cue,_,_)=drag,let value=project.cues.first(where:{$0.id == cue.id}) { if value.start != cue.start || value.end != cue.end { edit?(cue.id,value.start,value.end) } }; drag=nil; window?.invalidateCursorRects(for:self)
    }
}

/// Brackets with a center cut; dotted brackets indicate the side being removed.
func timelineCutIcon(_ mode: Int) -> NSImage {
    let image=NSImage(size:NSSize(width:20,height:18),flipped:false) { _ in
        NSColor.labelColor.setStroke()
        let cut=NSBezierPath(); cut.lineWidth=1.5
        cut.move(to:NSPoint(x:10,y:2)); cut.line(to:NSPoint(x:10,y:16)); cut.stroke()
        for isLeft in [true,false] {
            let path=NSBezierPath(); path.lineWidth=1.5
            let edge: CGFloat=isLeft ? 3 : 17, inner: CGFloat=isLeft ? 7 : 13
            path.move(to:NSPoint(x:inner,y:3)); path.line(to:NSPoint(x:edge,y:3))
            path.line(to:NSPoint(x:edge,y:15)); path.line(to:NSPoint(x:inner,y:15))
            if (mode == 1 && isLeft) || (mode == 2 && !isLeft) { path.setLineDash([1.5,1.5],count:2,phase:0) }
            path.stroke()
        }
        return true
    }
    image.isTemplate=true; return image
}
