import AppKit
import SubtitleCore
import UniformTypeIdentifiers

let mediaClipDragType=NSPasteboard.PasteboardType("local.videoediteur.media-clip")

final class MediaCard: NSButton, NSDraggingSource {
    override var isFlipped: Bool { false }
    var thumbnail: NSImage? { didSet { needsDisplay=true } }
    var fileURL: URL?
    var isAdded=true
    var filename=""
    var duration=""
    var isMusic=false
    var picked=false { didSet { needsDisplay=true } }
    var doubleClick: (()->Void)?
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { context == .withinApplication ? .copy : [] }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if isMusic { super.mouseDown(with:event); if event.clickCount == 2 { doubleClick?() }; return }
        guard let window else { return }
        let origin=convert(event.locationInWindow,from:nil)
        while let next=window.nextEvent(matching:[.leftMouseDragged,.leftMouseUp]) {
            let point=convert(next.locationInWindow,from:nil)
            if next.type == .leftMouseUp {
                if bounds.contains(point) { sendAction(action,to:target); if event.clickCount == 2 { doubleClick?() } }
                return
            }
            if hypot(point.x-origin.x,point.y-origin.y)>4,let id=identifier?.rawValue {
                let item=NSPasteboardItem(); item.setString(id,forType:mediaClipDragType)
                let dragging=NSDraggingItem(pasteboardWriter:fileURL.map { $0 as NSURL as NSPasteboardWriting } ?? item)
                dragging.setDraggingFrame(bounds,contents:thumbnail ?? NSImage(systemSymbolName:"film",accessibilityDescription:nil)!)
                beginDraggingSession(with:[dragging],event:next,source:self); return
            }
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        let box=CGRect(x:1,y:22,width:bounds.width-2,height:bounds.height-24)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect:box,xRadius:5,yRadius:5).addClip()
        NSColor(white:0.07,alpha:1).setFill(); box.fill()
        if let image=thumbnail {
            let scale=min(box.width/image.size.width,box.height/image.size.height)
            let size=NSSize(width:image.size.width*scale,height:image.size.height*scale)
            image.draw(in:CGRect(x:box.midX-size.width/2,y:box.midY-size.height/2,width:size.width,height:size.height),from:.zero,operation:.sourceOver,fraction:isEnabled ? 1 : 0.5)
        } else {
            let image=NSImage(systemSymbolName:isMusic ? "music.note" : "film",accessibilityDescription:nil)
            image?.draw(in:CGRect(x:box.midX-13,y:box.midY-13,width:26,height:26))
        }
        func badge(_ value: String, right: Bool) {
            let attrs: [NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:9),.foregroundColor:NSColor.white]
            let width=min(box.width,(value as NSString).size(withAttributes:attrs).width+6)
            let r=CGRect(x:right ? box.maxX-width : box.minX,y:box.maxY-15,width:width,height:15)
            NSColor.black.withAlphaComponent(0.65).setFill(); r.fill()
            (value as NSString).draw(in:r.insetBy(dx:3,dy:1),withAttributes:attrs)
        }
        if isAdded { badge(L("已添加"),right:false) }; badge(duration,right:true)
        NSGraphicsContext.restoreGraphicsState()
        if picked {
            accent.setStroke(); let outline=NSBezierPath(roundedRect:box.insetBy(dx:1,dy:1),xRadius:5,yRadius:5); outline.lineWidth=2; outline.stroke()
        }
        let paragraph=NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        (filename as NSString).draw(in:CGRect(x:2,y:1,width:bounds.width-4,height:18),withAttributes:[.font:NSFont.systemFont(ofSize:11),.foregroundColor:picked ? NSColor.white : muted,.paragraphStyle:paragraph])
    }
}
/// Shared validation for Finder file drops in the library and timeline.
func mediaFileURLs(from pasteboard: NSPasteboard) -> [URL] {
    let urls=(pasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL]) ?? []
    guard !urls.isEmpty,urls.allSatisfy({ url in
        var isDirectory: ObjCBool=false
        guard FileManager.default.fileExists(atPath:url.path,isDirectory:&isDirectory), !isDirectory.boolValue,
              let type=try? url.resourceValues(forKeys:[.contentTypeKey]).contentType else { return false }
        return type.conforms(to:.movie) || type.conforms(to:.audio)
    }) else { return [] }
    return urls
}

final class MediaGridView: NSView {
    var canDrop: (([URL])->Bool)?
    var dropFiles: (([URL])->Bool)?
    private var dropHighlighted=false { didSet { needsDisplay=true } }
    override init(frame: NSRect) { super.init(frame:frame); registerForDraggedTypes([.fileURL]) }
    required init?(coder: NSCoder) { super.init(coder:coder); registerForDraggedTypes([.fileURL]) }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls=mediaFileURLs(from:sender.draggingPasteboard)
        dropHighlighted = !urls.isEmpty && (canDrop?(urls) ?? false)
        return dropHighlighted ? .copy : []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropHighlighted=false }
    override func draggingEnded(_ sender: NSDraggingInfo) { dropHighlighted=false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { dropHighlighted=false }
        let urls=mediaFileURLs(from:sender.draggingPasteboard)
        guard !urls.isEmpty,canDrop?(urls) == true else { return false }
        return dropFiles?(urls) ?? false
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if dropHighlighted {
            accent.withAlphaComponent(0.12).setFill(); visibleRect.fill()
            accent.setStroke(); let border=NSBezierPath(roundedRect:visibleRect.insetBy(dx:2,dy:2),xRadius:6,yRadius:6); border.lineWidth=2; border.stroke()
        }
    }

    override var isFlipped: Bool { true }
    var cards: [MediaCard]=[]
    func arrange(width: CGFloat, minimumHeight: CGFloat) {
        let columns=max(1,Int((width+10)/118)),gap: CGFloat=10
        let cardWidth=max(1,(width-CGFloat(columns-1)*gap)/CGFloat(columns))
        let cardHeight=cardWidth*0.6+24
        for (i,card) in cards.enumerated() {
            card.frame=CGRect(x:CGFloat(i%columns)*(cardWidth+gap),y:CGFloat(i/columns)*(cardHeight+10),width:cardWidth,height:cardHeight)
        }
        frame=CGRect(x:0,y:0,width:width,height:max(minimumHeight,CGFloat((cards.count+columns-1)/columns)*(cardHeight+10)))
    }
}
extension EditorController {
    @objc func mediaSearchChanged(_ sender: NSSearchField) { refreshMediaGrid() }
    @objc func mediaCardClicked(_ sender: MediaCard) {
        guard !busy,let raw=sender.identifier?.rawValue,let id=UUID(uuidString:raw) else { return }
        if sender.isMusic { selectMusicClip(id) } else { selectVideoClip(id) }
        updateMediaGridSelection()
    }
    func updateMediaGridSelection() {
        if showsLocalLibrary { for card in mediaGrid.cards { card.picked=card.fileURL == selectedLocalVideo }; return }
        for card in mediaGrid.cards { card.picked=card.identifier?.rawValue == (card.isMusic ? selectedMusic : selectedClip)?.uuidString }
    }
    func refreshMediaGrid() {
        if showsLocalLibrary { refreshLocalLibraryGrid(); return }
        for view in mediaGrid.subviews { view.removeFromSuperview() }
        mediaGrid.cards=[]
        let query=mediaSearch.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        let entries=project.allClips.map { ($0.id,$0.path,$0.duration,false) } + project.music.map { ($0.id,$0.path,$0.duration,true) }
        for (id,path,duration,music) in entries {
            let name=URL(fileURLWithPath:path).lastPathComponent
            guard query.isEmpty || name.localizedCaseInsensitiveContains(query) else { continue }
            let card=MediaCard(); card.filename=name; card.duration=String(format:"%02lld:%02lld",duration/60000,(duration/1000)%60)
            card.isMusic=music; card.identifier=NSUserInterfaceItemIdentifier(id.uuidString)
            card.thumbnail=timeline.clipThumbnails[id]?.compactMap{$0}.first
            card.title=name; card.setAccessibilityLabel(name+", "+card.duration); card.toolTip=name
            card.isBordered=false; card.target=self; card.action=#selector(mediaCardClicked(_:)); card.isEnabled = !busy
            card.doubleClick={[weak self] in self?.editSelectedVideo()}
            mediaGrid.cards.append(card); mediaGrid.addSubview(card)
        }
        updateMediaGridSelection()
        mediaGrid.arrange(width:tableScroll.contentSize.width,minimumHeight:tableScroll.contentSize.height)
    }
}
