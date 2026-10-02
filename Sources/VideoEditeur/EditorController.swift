import AppKit
import AVKit
import UniformTypeIdentifiers
import SubtitleCore

final class EditorController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate, NSTextFieldDelegate {
    var project=Project()
    var projectURL: URL?
    var eraseClipID: UUID?
    var eraseSampleID: UUID?
    var eraseSampleColor: RGBA?
    var thumbnailJob: TimelineThumbnailJob?
    var selectedMusic: UUID?
    var selectedClip: UUID?
    var selected: UUID?
    var current: Int64=0
    let history=UndoManager()
    let player=AVPlayer()
    var observer: Any?
    private var deleteKeyMonitor: Any?
    private var playbackKeyMonitor: Any?
    private var blankClickMonitor: Any?
    private var deselectedCueIDs: Set<UUID>?
    deinit { localLibraryJob?.cancel(); thumbnailJob?.cancel(); if let deleteKeyMonitor { NSEvent.removeMonitor(deleteKeyMonitor) }; if let playbackKeyMonitor { NSEvent.removeMonitor(playbackKeyMonitor) }; if let blankClickMonitor { NSEvent.removeMonitor(blankClickMonitor) } }
    var generation: GenerationJob?
    var retryDirectory: URL?
    var subtitleFileRetryDirectory: URL?
    var subtitleFileRetryProject: Project?
    var exporter: VideoExporter?
    var busy=false
    var autosave: DispatchWorkItem?
    let root=LayoutView(), header=NSView(), left=NSView(), center=DropView(), right=NSView(), bottom=NSView()
    let preview=AVPlayerView(), overlay=PreviewOverlay(), table=SubtitleTableView(), tableScroll=AutoHidingScrollView()
    let panelDivider=PanelDivider(), leftDivider=PanelDivider(), rightDivider=PanelDivider()
    var mediaPanelWidth: CGFloat=CGFloat(max(250,UserDefaults.standard.double(forKey:"editor.mediaWidth")))
    var propertyPanelWidth: CGFloat=CGFloat(max(300,UserDefaults.standard.object(forKey:"editor.propertyWidth") == nil ? 300 : UserDefaults.standard.double(forKey:"editor.propertyWidth")))
    var timelinePanelHeight: CGFloat = {
        let saved=UserDefaults.standard.double(forKey:"editor.timelineHeight")
        return saved.isFinite && saved >= 140 ? CGFloat(saved) : 260
    }()
    let textTrackChoice=NSPopUpButton()
    let timeline=TimelineView(), timelineScroll=AutoHidingScrollView()
    let titleLabel=label(L("字幕工坊"),size:18,bold:true), subtitleLabel=label(L("多语言字幕 · 本地视频工作台"),size:10,color:muted)
    let fileLabel=label(L("尚未导入视频"),size:12,bold:true), statusLabel=label(L("准备就绪"),size:11,color:muted)
    let timeLabel=label("00:00:00 / 00:00:00",size:11,color:accent)
    let playbackSpeedChoice=NSPopUpButton()
    let playbackSpeeds: [Float]=[0.25,0.5,0.75,1,1.25,1.5,2]
    var playbackSpeed: Float { Float(project.speed) }
    let emptyTitle=label(L("让每一句话，都被看见"),size:24,color:.white,bold:true)
    let emptyHint=label(L("拖入视频，选择语言生成字幕"),size:13,color:muted)
    let progress=NSProgressIndicator(), scrub=NSSlider(), zoom=NSSlider()
    var importButton: ActionButton!, generateButton: ActionButton!, exportButton: ActionButton!, cancelButton: ActionButton!, playButton: ActionButton!
    let displayMode=NSSegmentedControl(labels:[L("法语"),L("中文")],trackingMode:.selectAny,target:nil,action:nil)
    let languageChoice=NSSegmentedControl(labels:[L("素材"),L("字幕"),L("本地素材库")],trackingMode:.selectOne,target:nil,action:nil)
    let panelToggles=NSSegmentedControl(labels:[L("素材"), L("时间轴"), L("字幕属性")],trackingMode:.selectAny,target:nil,action:nil)
    private let panelKeys=["editor.showMedia", "editor.showTimeline", "editor.showInspector"]
    let inspectorScroll=AutoHidingScrollView(), inspector=NSStackView()
    let alignmentChoice=NSSegmentedControl(labels:[L("左"), L("中"), L("右")],trackingMode:.selectOne,target:nil,action:nil)
    let textEditor=NSTextView(), fontChoice=NSPopUpButton(), startField=NSTextField(), endField=NSTextField(), sizeField=NSTextField(), widthField=NSTextField(), outlineField=NSTextField(), xField=NSTextField(), yField=NSTextField()
    let textColor=NSColorWell(), outlineColor=NSColorWell(), backgroundColor=NSColorWell(), backgroundEnabled=NSButton(checkboxWithTitle:L("显示背景"),target:nil,action:nil)
    let readabilityEnabled=NSButton(checkboxWithTitle:L("增强可读性（对比描边与阴影）"),target:nil,action:nil)
    let selectionLabel=label(L("选择字幕开始编辑"),size:13,bold:true)
    var inspectorUpdating=false
    var inspectorPositioned=false
    let mediaGrid=MediaGridView(), mediaSearch=NSSearchField()
    var mediaImportButton: NSButton!
    struct LibraryEntry {
        let title: String
        let detail: String
        let language: Language?
        let trackID: UUID?
        var musicID: UUID? = nil
        var clipID: UUID? = nil
        var isMedia: Bool { language == nil && trackID == nil }
        func contains(_ cue: Cue) -> Bool {
            !isMedia && (trackID != nil ? cue.trackID == trackID : cue.trackID == nil && cue.language == language)
        }
    }
    var localLibraryEntries: [LocalVideoEntry]=[]
    var localLibraryJob: LocalVideoScan?
    var localLibraryMessage=""
    var selectedLocalVideo: URL?
    var showsLocalLibrary: Bool { languageChoice.selectedSegment == 2 }
    var showsGrid: Bool { showsMedia || showsLocalLibrary }
    var showsMedia: Bool { languageChoice.selectedSegment == 0 }
    var libraryEntries: [LibraryEntry] {
        if showsMedia {
            return project.renderPlacements.enumerated().map { i,p in LibraryEntry(title:"\(i+1). \(URL(fileURLWithPath:p.clip.path).lastPathComponent)",detail:L("{0} · {1} 秒", [String(describing: SRT.timestamp(p.start).prefix(8)), String(describing: String(format:"%.2f",Double(p.clip.duration)/1000))]),language:nil,trackID:nil,clipID:p.clip.id) } + project.music.map { music in LibraryEntry(title:URL(fileURLWithPath:music.path).lastPathComponent,detail:L("音乐")+" · "+String(format:"%.2f s",Double(music.duration)/1000),language:nil,trackID:nil,musicID:music.id) }
        }
        var entries: [LibraryEntry] = project.videoPath.isEmpty ? [] : project.subtitleLanguages.map { language in
            LibraryEntry(title:language.title+" · "+L("字幕"),detail:L("{0} 条字幕", [String(describing: project.cues.filter{$0.trackID == nil && $0.language == language}.count)]),language:language,trackID:nil)
        }
        entries += project.tracks.map { track in
            LibraryEntry(title:track.name,detail:L("{0} 条文字", [String(describing: project.cues.filter{$0.trackID == track.id}.count)]),language:nil,trackID:track.id)
        }
        return entries
    }
    func syncLibrarySelection() {
        guard !showsGrid else { return }
        let cue=project.cues.first{$0.id == selected}
        let index=cue.flatMap { cue in libraryEntries.firstIndex{$0.contains(cue)} }
        setTableSelection(index.map{IndexSet(integer:$0)} ?? [])
    }
    var syncingSelection=false
    var preferredLanguage: Language = .zh
    var styleDragOriginal: Project?
    override var undoManager: UndoManager? { history }
    override func loadView() { view=root; root.frame=NSRect(x:0,y:0,width:1440,height:900); setup() }
    func setup() {
        root.wantsLayer=true; root.layer?.backgroundColor=NSColor(srgbRed:0.055,green:0.065,blue:0.078,alpha:1).cgColor
        for pane in [header,left,center,right,bottom] { pane.wantsLayer=true; pane.layer?.backgroundColor=panelColor.cgColor; pane.layer?.cornerRadius=8; root.addSubview(pane) }
        header.layer?.backgroundColor=NSColor.clear.cgColor
        importButton=ActionButton(L("导入视频"),symbol:"plus",action:{[weak self] in self?.importVideo()})
        generateButton=ActionButton(L("生成字幕"),symbol:"sparkles",action:{[weak self] in self?.generate()})
        exportButton=ActionButton(L("导出视频"),symbol:"square.and.arrow.up",action:{[weak self] in self?.exportVideo()}); exportButton.contentTintColor=accent
        let new=ActionButton(L("新建"),symbol:"doc.badge.plus",action:{[weak self] in self?.newProject()}); new.identifier=NSUserInterfaceItemIdentifier("newProject")
        let save=ActionButton(L("保存"),symbol:"square.and.arrow.down",action:{[weak self] in self?.saveProject()}); save.identifier=NSUserInterfaceItemIdentifier("save")
        let settings=ActionButton("",symbol:"gearshape",action:{[weak self] in self?.showSettings()}); settings.identifier=NSUserInterfaceItemIdentifier("settings")
        for v in [titleLabel,subtitleLabel,importButton!,generateButton!,exportButton!,new,save,settings] { header.addSubview(v) }
        panelToggles.target=self; panelToggles.action=#selector(panelsChanged(_:))
        panelToggles.setAccessibilityLabel(L("面板显示开关"))
        panelToggles.toolTip=L("点击显示或收起面板；选中表示已展开")
        for index in panelKeys.indices {
            panelToggles.setSelected(UserDefaults.standard.object(forKey:panelKeys[index]) as? Bool ?? true,forSegment:index)
        }
        header.addSubview(panelToggles)
        let mediaTitle=label(L("素材 / 字幕"),size:13,bold:true); mediaTitle.frame=NSRect(x:16,y:0,width:220,height:22); mediaTitle.identifier=NSUserInterfaceItemIdentifier("mediaTitle"); left.addSubview(mediaTitle)
        left.addSubview(fileLabel)
        mediaImportButton=ActionButton("",symbol:"plus",action:{[weak self] in if let self { if self.showsLocalLibrary { self.chooseLocalLibraryDirectory() } else { self.appendVideos() } }})
        mediaImportButton.imagePosition = .imageOnly
        mediaImportButton.toolTip=L("导入")
        mediaImportButton.setAccessibilityLabel(L("导入"))
        left.addSubview(mediaImportButton); left.addSubview(mediaSearch)
        mediaSearch.placeholderString=L("搜索文件名"); mediaSearch.target=self; mediaSearch.action=#selector(mediaSearchChanged(_:))
        mediaSearch.sendsSearchStringImmediately=true
        mediaGrid.canDrop={[weak self] urls in
            guard let self,self.showsMedia else { return false }
            return self.canImportMediaFiles(urls)
        }
        mediaGrid.dropFiles={[weak self] urls in self?.appendMedia(urls) ?? false }
        timeline.canDropFiles={[weak self] urls in self?.canImportMediaFiles(urls) ?? false }
        timeline.dropFiles={[weak self] urls in self?.appendMedia(urls) ?? false }


        table.headerView=nil; table.backgroundColor = .clear; table.rowHeight=61; table.intercellSpacing=NSSize(width:0,height:3)
        let column=NSTableColumn(identifier:NSUserInterfaceItemIdentifier("subtitle")); column.width=240; table.addTableColumn(column); table.delegate=self; table.dataSource=self
        table.allowsMultipleSelection=false; table.selectionHighlightStyle = .regular; tableScroll.documentView=table; tableScroll.hasVerticalScroller=true; tableScroll.drawsBackground=false; left.addSubview(tableScroll)
        tableScroll.scrollerStyle = .overlay
        tableScroll.autohidesScrollers=true
        languageChoice.selectedSegment=0; languageChoice.setAccessibilityLabel(L("素材与字幕分类")); languageChoice.target=self; languageChoice.action=#selector(libraryChanged(_:)); left.addSubview(languageChoice)
        let add=ActionButton(L("添加"),symbol:"plus",action:{[weak self] in self?.addLibraryItem()}); add.identifier=NSUserInterfaceItemIdentifier("add"); left.addSubview(add)
        let delete=ActionButton("",symbol:"trash",action:{[weak self] in self?.deleteSubtitle()}); delete.identifier=NSUserInterfaceItemIdentifier("delete"); left.addSubview(delete)
        center.drop={[weak self] in self?.loadVideo($0)}
        preview.player=player; preview.allowsVideoFrameAnalysis=false; preview.controlsStyle = .none; preview.videoGravity = .resizeAspect; center.addSubview(preview); center.addSubview(overlay)
        let eraseButton=ActionButton(L("区域去字"),symbol:"eraser",action:{[weak self] in self?.beginRegionErase()}); eraseButton.setButtonType(.pushOnPushOff); eraseButton.identifier=NSUserInterfaceItemIdentifier("regionErase"); eraseButton.toolTip=L("框选原视频文字，按 Delete 用背景色覆盖"); center.addSubview(eraseButton)
        overlay.onEraseStarted={[weak self] point in self?.sampleEraseColor(at:point) }
        overlay.onEraseSelected={[weak self] in self?.statusLabel.stringValue=L("已框选区域 · 按 Delete 设置背景覆盖，Esc 取消") }
        overlay.onEraseCancelled={[weak self] in self?.cancelRegionErase(); self?.statusLabel.stringValue=L("已取消区域框选") }
        center.addSubview(emptyTitle); center.addSubview(emptyHint)
        let previewTitle=label(L("预览"),size:12,color:muted); previewTitle.identifier=NSUserInterfaceItemIdentifier("previewTitle"); center.addSubview(previewTitle)
        displayMode.target=self; displayMode.action=#selector(modeChanged(_:)); center.addSubview(displayMode)
        playButton=ActionButton("",symbol:"play.fill",action:{[weak self] in self?.togglePlay()}); center.addSubview(playButton)
        playbackSpeedChoice.addItems(withTitles:playbackSpeeds.map{String(format:"%g×",$0)})
        playbackSpeedChoice.selectItem(at:3); playbackSpeedChoice.target=self; playbackSpeedChoice.action=#selector(playbackSpeedChanged(_:))
        playbackSpeedChoice.setAccessibilityLabel(L("播放速度")); playbackSpeedChoice.toolTip=L("工程播放与导出速度")
        center.addSubview(playbackSpeedChoice)
        scrub.minValue=0; scrub.maxValue=1; scrub.target=self; scrub.action=#selector(scrubChanged); scrub.isContinuous=true; center.addSubview(scrub); center.addSubview(timeLabel)
        table.target=self; table.doubleAction=#selector(libraryDoubleClicked)
        timeline.insertMediaClip={[weak self] id,index in
            guard let self,!self.busy,!self.project.isVideoLocked else { return false }
            self.pauseForEditing()
            do {
                let next=try self.project.insertingCopy(of:id,at:index)
                self.mediaSearch.stringValue=""
                self.commit(next,name:L("插入视频素材"))
                guard self.project == next else { return false }
                self.selectVideoClip(next.clips[index].id); return true
            } catch { self.showError(error); return false }
        }
        timeline.addVideoLayer={[weak self] id,time,trackID in
            guard let self,!self.busy else { return false }; self.pauseForEditing()
            do {
                let oldIDs=Set(self.project.layers.map(\.id))
                let next=try self.project.addingLayer(from:id,at:time,trackID:trackID)
                self.commit(next,name:L("新建视频轨道"))
                guard self.project == next,let layer=next.layers.first(where:{!oldIDs.contains($0.id)}) else { return false }
                self.selectVideoClip(layer.id); return true
            } catch { self.showError(error); return false }
        }
        timeline.transferVideoClip={[weak self] id,destination,time in
            guard let self,!self.busy else { return }; self.pauseForEditing()
            do {
                self.commit(try self.project.transferringClip(id,to:destination,at:time),name:L("移动视频片段"))
                self.selectedClip=id; self.timeline.selectedClip=id; self.refresh()
            } catch { self.showError(error); self.refresh() }
        }
        timeline.moveVideoLayer={[weak self] layer in self?.updateVideoLayer(layer) }
        timeline.toggleLayerTrackControl={[weak self] id,control in self?.toggleLayerTrackControl(id,control) }
        timeline.selectVideo={[weak self] id in self?.selectVideoClip(id) }
        timeline.editVideoTrack={[weak self] id,action in self?.editVideoTrack(id,action) }
        timeline.editVideoRange={[weak self] id,start,end in
            guard let self else { return }; var clips=self.project.clips
            guard let i=clips.firstIndex(where:{$0.id == id}) else { return }
            clips[i].sourceStart=start; clips[i].sourceEnd=end
            do { self.commit(try self.project.replacingClips(clips),name:L("拖动裁剪视频")); self.refresh() } catch { self.showError(error); self.refresh() }
        }
        timeline.editVideo={[weak self] in self?.editSelectedVideo() }
        let clipEdit=ActionButton(L("剪辑 / 特效"),symbol:"scissors",action:{[weak self] in self?.editSelectedVideo()}); clipEdit.identifier=NSUserInterfaceItemIdentifier("clipEdit"); bottom.addSubview(clipEdit)
        let cutActions: [(String,String,()->Void)] = [
            ("splitVideo",L("在播放头分割选中素材（⌘B）"),{[weak self] in self?.splitSelectedVideo()}),
            ("trimVideoLeft",L("删除选中素材在播放头左侧的部分"),{[weak self] in self?.trimSelectedVideo(removeBefore:true)}),
            ("trimVideoRight",L("删除选中素材在播放头右侧的部分"),{[weak self] in self?.trimSelectedVideo(removeBefore:false)})
        ]
        for (index,item) in cutActions.enumerated() {
            let button=ActionButton("",action:item.2)
            button.identifier=NSUserInterfaceItemIdentifier(item.0); button.toolTip=item.1; button.setAccessibilityLabel(item.1)
            button.image=timelineCutIcon(index); button.imagePosition = .imageOnly
            bottom.addSubview(button)
        }
        table.onDeselect={[weak self] in self?.clearSelection() }
        overlay.onDeselect={[weak self] in self?.clearSelection() }
        timeline.onDeselect={[weak self] in self?.clearSelection() }
        overlay.onSelect={[weak self] in self?.pauseForEditing(); self?.select($0,seek:false)}
        overlay.onGestureBegan={[weak self] in self?.styleDragOriginal=self?.project }
        overlay.onStyleChange={[weak self] id,style,finished in self?.previewTrackStyle(id:id,style:style,finished:finished) }
        overlay.onGestureCancelled={[weak self] in
            guard let self,let original=self.styleDragOriginal else { return }
            self.styleDragOriginal=nil; self.project=original; self.refresh(); self.refreshInspector()
        }
        setupInspector()
        let timelineTitle=label(L("时间轴"),size:12,bold:true); timelineTitle.identifier=NSUserInterfaceItemIdentifier("timelineTitle"); bottom.addSubview(timelineTitle)
        let tip=label(L("拖动片段调整时间 · 拖动边缘调整时长"),size:10,color:muted); tip.identifier=NSUserInterfaceItemIdentifier("timelineTip"); bottom.addSubview(tip)
        let newTrack=ActionButton(L("新建文字轨道"),symbol:"plus",action:{[weak self] in self?.addTextTrack()}); newTrack.identifier=NSUserInterfaceItemIdentifier("newTrack"); bottom.addSubview(newTrack)
        let newText=ActionButton(L("添加文字"),symbol:"text.badge.plus",action:{[weak self] in self?.addTrackText()}); newText.identifier=NSUserInterfaceItemIdentifier("newText"); bottom.addSubview(newText)
        let deleteTrack=ActionButton(L("删除轨道"),symbol:"trash",action:{[weak self] in self?.deleteTextTrack()}); deleteTrack.identifier=NSUserInterfaceItemIdentifier("deleteTrack"); deleteTrack.toolTip=L("删除所选文字轨道及全部文字片段（⌘Z 可撤销）"); bottom.addSubview(deleteTrack)
        textTrackChoice.setAccessibilityLabel(L("目标文字轨道")); bottom.addSubview(textTrackChoice)
        timelineScroll.hasVerticalScroller=true
        timelineScroll.scrollerStyle = .overlay
        timelineScroll.autohidesScrollers=true
        zoom.minValue=5; zoom.maxValue=150; zoom.doubleValue=65; zoom.target=self; zoom.action=#selector(zoomChanged); bottom.addSubview(zoom)
        setupMusicControls()
        timelineScroll.documentView=timeline; timelineScroll.hasHorizontalScroller=true; timelineScroll.hasVerticalScroller=true; timelineScroll.drawsBackground=false; bottom.addSubview(timelineScroll)
        timeline.select={[weak self] in self?.pauseForEditing(); self?.select($0)}; timeline.seek={[weak self] in self?.seek($0)}
        timeline.edit={[weak self] id,start,end in self?.updateCue(id) { c,_ in c.start=start; c.end=end }; self?.refreshInspector() }
        root.addSubview(statusLabel); progress.style = .bar; progress.isIndeterminate=false; progress.minValue=0; progress.maxValue=1; root.addSubview(progress); progress.isHidden=true
        cancelButton=ActionButton(L("取消"),action:{[weak self] in self?.generation?.cancel(); self?.exporter?.cancel(); self?.statusLabel.stringValue=L("正在取消…")}); root.addSubview(cancelButton); cancelButton.isHidden=true
        for (divider,title) in [(leftDivider,L("素材面板")),(rightDivider,L("字幕属性面板"))] {
            divider.isVertical=true; divider.toolTip=L("左右拖动调整{0}宽度；双击恢复默认", [String(describing: title)])
            divider.setAccessibilityLabel(L("调整{0}宽度", [String(describing: title)])); root.addSubview(divider)
        }
        leftDivider.onResize={[weak self] delta,finished in self?.resizeSidePanel(left:true,delta:delta,finished:finished) }
        rightDivider.onResize={[weak self] delta,finished in self?.resizeSidePanel(left:false,delta:delta,finished:finished) }
        leftDivider.onReset={[weak self] in self?.resetSidePanel(left:true) }
        rightDivider.onReset={[weak self] in self?.resetSidePanel(left:false) }
        root.addSubview(panelDivider)
        panelDivider.onResize={[weak self] delta,finished in
            guard let self else { return }
            self.timelinePanelHeight=max(140,min(self.root.bounds.height-350,self.bottom.frame.height+delta))
            self.root.needsLayout=true; self.root.layoutSubtreeIfNeeded()
            if finished { UserDefaults.standard.set(Double(self.timelinePanelHeight),forKey:"editor.timelineHeight") }
        }
        panelDivider.onReset={[weak self] in
            guard let self else { return }
            self.timelinePanelHeight=260; UserDefaults.standard.set(260,forKey:"editor.timelineHeight")
            self.root.needsLayout=true; self.root.layoutSubtreeIfNeeded()
        }
        root.onLayout={[weak self] in self?.layoutEditor()}
        observer=player.addPeriodicTimeObserver(forInterval:CMTime(value:1,timescale:30),queue:.main) {[weak self] time in
            guard let self else { return }; let seconds=CMTimeGetSeconds(time); guard seconds.isFinite else { return }
            self.current=Int64(seconds*1000); self.refreshPlayback()
            if self.current >= self.project.duration-40, self.player.rate == 0 { self.playButton.image=NSImage(systemSymbolName:"play.fill",accessibilityDescription:L("播放")) }
        }
        blankClickMonitor=NSEvent.addLocalMonitorForEvents(matching:.leftMouseDown) { [weak self] event in
            guard let self,let window=self.view.window,event.window === window,window.attachedSheet == nil,NSApp.modalWindow == nil else { return event }
            if self.overlay.eraseMode,self.overlay.videoRect.contains(self.overlay.convert(event.locationInWindow,from:nil)) { return event }
            var hit=self.root.hitTest(self.root.convert(event.locationInWindow,from:nil))
            while let v=hit {
                // These views handle their own selection or edit the current selection.
                if v is NSControl || v is NSTextView || v is NSScrollView || v === self.overlay || v === self.timeline || v === self.right || v === self.panelDivider || v === self.leftDivider || v === self.rightDivider { return event }
                hit=v.superview
            }
            self.clearSelection(); return event
        }
        deleteKeyMonitor=NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
            guard let self,let window=self.view.window,event.window === window,
                  window.isKeyWindow,window.attachedSheet == nil,NSApp.modalWindow == nil,
                  event.keyCode == 51 || event.keyCode == 117,
                  event.modifierFlags.intersection([.command,.control,.option,.shift]).isEmpty,
                  !(window.firstResponder is NSText),!self.busy,(self.selected != nil || self.selectedClip != nil || self.selectedMusic != nil || self.overlay.eraseRect != nil) else { return event }
            // Holding Delete must not remove successive playback-selected clips.
            if !event.isARepeat { self.pauseForEditing(); if self.overlay.eraseMode,self.overlay.eraseRect != nil { self.applySelectedEraseRegion() } else if self.selectedMusic != nil { self.deleteMusic() } else if self.selectedClip != nil { self.deleteSelectedVideo() } else { self.deleteSubtitle() } }
            return nil
        }
        playbackKeyMonitor=NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
            guard let self,let window=self.view.window,event.window === window,
                  window.isKeyWindow,window.attachedSheet == nil,NSApp.modalWindow == nil,
                  event.keyCode == 49,
                  event.modifierFlags.intersection([.command,.control,.option,.shift]).isEmpty,
                  !(window.firstResponder is NSText),!self.project.videoPath.isEmpty else { return event }
            // Consume repeats too: holding Space should toggle playback only once.
            if !event.isARepeat { self.togglePlay() }
            return nil
        }
        NSColorPanel.shared.showsAlpha=true
        // Every launch starts with the fresh Project initialized by this controller.
        languageChoice.selectedSegment=0
        refresh(); refreshInspector(); reloadLocalLibrary()
    }
    @objc func panelsChanged(_ sender: NSSegmentedControl) {
        // Commit any field being edited before its panel is hidden.
        view.window?.makeFirstResponder(nil)
        for index in panelKeys.indices {
            UserDefaults.standard.set(sender.isSelected(forSegment:index),forKey:panelKeys[index])
        }
        root.needsLayout=true
        root.layoutSubtreeIfNeeded()
    }
    func resizeSidePanel(left isLeft:Bool,delta:CGFloat,finished:Bool) {
        let remaining=center.frame.width-320
        if isLeft { mediaPanelWidth=max(250,min(left.frame.width+delta,left.frame.width+remaining)) }
        else { propertyPanelWidth=max(300,min(right.frame.width-delta,right.frame.width+remaining)) }
        root.needsLayout=true; root.layoutSubtreeIfNeeded()
        if finished { UserDefaults.standard.set(Double(isLeft ? mediaPanelWidth : propertyPanelWidth),forKey:isLeft ? "editor.mediaWidth" : "editor.propertyWidth") }
    }
    func resetSidePanel(left isLeft:Bool) {
        if isLeft { mediaPanelWidth=250 } else { propertyPanelWidth=300 }
        UserDefaults.standard.set(isLeft ? 250 : 300,forKey:isLeft ? "editor.mediaWidth" : "editor.propertyWidth")
        root.needsLayout=true; root.layoutSubtreeIfNeeded()
    }
    func layoutEditor() {
        let w=root.bounds.width,h=root.bounds.height,margin:CGFloat=10,headerH:CGFloat=62,statusH:CGFloat=30
        let bottomH=max(140,min(timelinePanelHeight,h-350))
        header.frame=NSRect(x:margin,y:h-headerH,width:w-20,height:headerH)
        titleLabel.frame=NSRect(x:8,y:31,width:230,height:25); subtitleLabel.frame=NSRect(x:9,y:13,width:250,height:15)
        exportButton.frame=NSRect(x:header.bounds.width-114,y:20,width:110,height:32)
        generateButton.frame=NSRect(x:header.bounds.width-384,y:20,width:142,height:32)
        header.subviews.first{$0.identifier?.rawValue == "newProject"}?.frame=NSRect(x:header.bounds.width-587,y:20,width:80,height:32)
        importButton.frame=NSRect(x:header.bounds.width-501,y:20,width:110,height:32)
        header.subviews.first{$0.identifier?.rawValue == "save"}?.frame=NSRect(x:header.bounds.width-237,y:20,width:74,height:32)
        header.subviews.first{$0.identifier?.rawValue == "settings"}?.frame=NSRect(x:header.bounds.width-160,y:20,width:40,height:32)
        panelToggles.frame=NSRect(x:270,y:22,width:262,height:28)
        left.isHidden = !panelToggles.isSelected(forSegment:0)
        right.isHidden = !panelToggles.isSelected(forSegment:2)
        bottom.isHidden = !panelToggles.isSelected(forSegment:1)
        panelDivider.isHidden=bottom.isHidden
        panelDivider.frame=NSRect(x:margin,y:statusH+bottomH,width:w-2*margin,height:10)
        let y=statusH+(bottom.isHidden ? 0 : bottomH+10), paneH=max(240,h-headerH-y-8)
        let available=w-2*margin-320-(left.isHidden ? 0 : 8)-(right.isHidden ? 0 : 8)
        let rightW=max(300,min(propertyPanelWidth,available-(left.isHidden ? 0 : 250)))
        let leftW=max(250,min(mediaPanelWidth,available-(right.isHidden ? 0 : rightW)))
        leftDivider.isHidden=left.isHidden; rightDivider.isHidden=right.isHidden
        leftDivider.frame=NSRect(x:margin+leftW,y:y,width:8,height:paneH)
        rightDivider.frame=NSRect(x:w-margin-rightW-8,y:y,width:8,height:paneH)
        let leftSpace:CGFloat=left.isHidden ? 0 : leftW+8
        let rightSpace:CGFloat=right.isHidden ? 0 : rightW+8
        left.frame=NSRect(x:margin,y:y,width:leftW,height:paneH); right.frame=NSRect(x:w-margin-rightW,y:y,width:rightW,height:paneH)
        center.frame=NSRect(x:margin+leftSpace,y:y,width:w-2*margin-leftSpace-rightSpace,height:paneH)
        left.subviews.first{$0.identifier?.rawValue == "mediaTitle"}?.frame=NSRect(x:16,y:paneH-37,width:220,height:22)
        fileLabel.frame=NSRect(x:16,y:paneH-65,width:leftW-32,height:21); fileLabel.lineBreakMode = .byTruncatingMiddle
        tableScroll.frame=NSRect(x:8,y:showsGrid ? 53 : 85,width:leftW-16,height:paneH-(showsGrid ? 127 : 159))
        mediaImportButton.frame=NSRect(x:12,y:paneH-64,width:30,height:26)
        mediaSearch.frame=NSRect(x:48,y:paneH-64,width:leftW-60,height:26)
        tableScroll.tile()
        if showsGrid { mediaGrid.arrange(width:tableScroll.contentSize.width,minimumHeight:tableScroll.contentSize.height) }
        table.tableColumns.first?.width=max(1,tableScroll.contentSize.width)
        languageChoice.frame=NSRect(x:12,y:15,width:leftW-24,height:26)
        left.subviews.first{$0.identifier?.rawValue == "add"}?.frame=NSRect(x:12,y:47,width:90,height:30)
        left.subviews.first{$0.identifier?.rawValue == "delete"}?.frame=NSRect(x:110,y:47,width:34,height:30)
        let cw=center.bounds.width
        center.subviews.first{$0.identifier?.rawValue == "previewTitle"}?.frame=NSRect(x:16,y:paneH-33,width:80,height:20)
        displayMode.frame=NSRect(x:cw-188,y:paneH-35,width:173,height:25)
        preview.frame=NSRect(x:10,y:80,width:cw-20,height:max(100,paneH-128)); overlay.frame=preview.frame
        emptyTitle.frame=NSRect(x:20,y:paneH/2+6,width:cw-40,height:35); emptyTitle.alignment = .center
        emptyHint.frame=NSRect(x:20,y:paneH/2-26,width:cw-40,height:24); emptyHint.alignment = .center
        playButton.frame=NSRect(x:14,y:10,width:38,height:30)
        playbackSpeedChoice.frame=NSRect(x:62,y:12,width:85,height:26)
        timeLabel.frame=NSRect(x:14,y:43,width:cw-28,height:15)
        center.subviews.first{$0.identifier?.rawValue == "regionErase"}?.frame=NSRect(x:cw-130,y:17,width:116,height:30)
        scrub.frame=NSRect(x:14,y:62,width:cw-28,height:14)
        inspectorScroll.frame=right.bounds.insetBy(dx:14,dy:16)
        inspectorScroll.tile()
        // Use the actual clip width: traditional scrollbars occupy layout space.
        inspector.frame.size.width=max(0,inspectorScroll.contentSize.width-8)
        inspector.layoutSubtreeIfNeeded()
        if !inspectorPositioned { inspector.layoutSubtreeIfNeeded(); inspectorScroll.contentView.scroll(to:NSPoint(x:0,y:max(0,inspector.frame.height-inspectorScroll.contentSize.height))); inspectorPositioned=true }
        bottom.frame=NSRect(x:margin,y:statusH,width:w-20,height:bottomH)
        bottom.subviews.first{$0.identifier?.rawValue == "timelineTitle"}?.frame=NSRect(x:15,y:bottomH-32,width:70,height:20)
        bottom.subviews.first{$0.identifier?.rawValue == "timelineTip"}?.frame=NSRect(x:89,y:bottomH-31,width:0,height:20)
        bottom.subviews.first{$0.identifier?.rawValue == "newTrack"}?.frame=NSRect(x:90,y:bottomH-35,width:136,height:28)
        textTrackChoice.frame=NSRect(x:235,y:bottomH-35,width:140,height:28)
        bottom.subviews.first{$0.identifier?.rawValue == "newText"}?.frame=NSRect(x:383,y:bottomH-35,width:112,height:28)
        bottom.subviews.first{$0.identifier?.rawValue == "deleteTrack"}?.frame=NSRect(x:503,y:bottomH-35,width:112,height:28)
        bottom.subviews.first{$0.identifier?.rawValue == "clipEdit"}?.frame=NSRect(x:625,y:bottomH-35,width:148,height:28)
        for (index,name) in ["splitVideo","trimVideoLeft","trimVideoRight"].enumerated() {
            bottom.subviews.first{$0.identifier?.rawValue == name}?.frame=NSRect(x:781+CGFloat(index)*33,y:bottomH-35,width:30,height:28)
        }
        zoom.frame=NSRect(x:bottom.bounds.width-175,y:bottomH-33,width:156,height:24)
        timelineScroll.frame=NSRect(x:0,y:0,width:bottom.bounds.width,height:bottomH-44); resizeTimeline()
        statusLabel.frame=NSRect(x:17,y:6,width:w-330,height:17); progress.frame=NSRect(x:w-310,y:12,width:190,height:6); cancelButton.frame=NSRect(x:w-106,y:1,width:90,height:26)
    }
    func resizeTimeline() { timeline.frame=NSRect(x:0,y:0,width:max(timelineScroll.contentSize.width,CGFloat(project.timelineExtent)/1000*timeline.pointsPerSecond+120),height:max(timelineScroll.contentSize.height,timeline.contentHeight)); timeline.needsDisplay=true }
    func setupInspector() {
        inspectorScroll.scrollerStyle = .overlay
        inspectorScroll.autohidesScrollers=true
        inspector.orientation = .vertical; inspector.alignment = .leading; inspector.spacing=13; inspector.edgeInsets=NSEdgeInsets(top:0,left:0,bottom:20,right:0)
        inspectorScroll.documentView=inspector; inspectorScroll.hasVerticalScroller=true; inspectorScroll.hasHorizontalScroller=false; inspectorScroll.drawsBackground=false; right.addSubview(inspectorScroll)
        func add(_ view: NSView, height: CGFloat) { view.translatesAutoresizingMaskIntoConstraints=false; inspector.addArrangedSubview(view); view.widthAnchor.constraint(equalTo:inspector.widthAnchor).isActive=true; view.heightAnchor.constraint(equalToConstant:height).isActive=true }
        func heading(_ name: String) { add(label(name,size:11,color:muted),height:16) }
        func row(_ name: String,_ control: NSControl) {
            let row=NSView(); let l=label(name,size:12,color:muted)
            l.translatesAutoresizingMaskIntoConstraints=false; control.translatesAutoresizingMaskIntoConstraints=false
            row.addSubview(l); row.addSubview(control); add(row,height:30)
            NSLayoutConstraint.activate([
                l.leadingAnchor.constraint(equalTo:row.leadingAnchor), l.widthAnchor.constraint(equalToConstant:InterfaceLanguage.current == .en ? 84 : 68), l.centerYAnchor.constraint(equalTo:row.centerYAnchor),
                control.leadingAnchor.constraint(equalTo:row.leadingAnchor,constant:InterfaceLanguage.current == .en ? 90 : 75), control.trailingAnchor.constraint(equalTo:row.trailingAnchor),
                control.centerYAnchor.constraint(equalTo:row.centerYAnchor), control.heightAnchor.constraint(equalToConstant:28)
            ])
            control.target=self; control.action=#selector(inspectorChanged(_:))
            (control as? NSTextField)?.delegate=self
        }
        add(label(L("字幕属性"),size:15,bold:true),height:24); add(selectionLabel,height:20); heading(L("文本内容"))
        let scroll=TextEditorScrollView(); scroll.scrollerStyle = .overlay; scroll.autohidesScrollers=true; scroll.contentView=TextEditorClipView(); scroll.borderType = .bezelBorder; scroll.hasVerticalScroller=true; scroll.hasHorizontalScroller=false; scroll.documentView=textEditor
        textEditor.frame=NSRect(x:0,y:0,width:242,height:94); textEditor.minSize=NSSize(width:0,height:94); textEditor.maxSize=NSSize(width:CGFloat.greatestFiniteMagnitude,height:10000); textEditor.autoresizingMask=[.width]
        textEditor.isVerticallyResizable=true; textEditor.isHorizontallyResizable=false; textEditor.textContainer?.widthTracksTextView=true; textEditor.textContainerInset=NSSize(width:12,height:8); textEditor.textContainer?.lineFragmentPadding=0
        textEditor.font = .systemFont(ofSize:14); textEditor.backgroundColor=NSColor(white:0.09,alpha:1); textEditor.textColor = .white; textEditor.isRichText=false; textEditor.delegate=self; add(scroll,height:98)
        heading(L("时间 · 秒")); row(L("开始"),startField); row(L("结束"),endField)
        heading(L("字体与样式"))
        fontChoice.addItems(withTitles:NSFontManager.shared.availableFontFamilies.sorted()); row(L("字体"),fontChoice)
        alignmentChoice.font = .systemFont(ofSize:11); alignmentChoice.selectedSegment=1; alignmentChoice.toolTip=L("文字在字幕框内左对齐、居中或右对齐"); row(L("对齐"),alignmentChoice)
        row(L("字号"),sizeField); widthField.placeholderString=L("自动"); row(L("宽度 %"),widthField); row(L("颜色"),textColor); row(L("描边宽度"),outlineField); row(L("描边颜色"),outlineColor)
        readabilityEnabled.target=self; readabilityEnabled.action=#selector(inspectorChanged(_:)); add(readabilityEnabled,height:24)
        backgroundEnabled.target=self; backgroundEnabled.action=#selector(inspectorChanged(_:)); add(backgroundEnabled,height:24); row(L("背景颜色"),backgroundColor)
        heading(L("位置 · %，Y 从底部计算")); row(L("水平 X"),xField); row(L("垂直 Y"),yField)
        add(label(L("位置和样式自动应用于同轨全部文字"),size:10,color:accent),height:18)
        add(label(L("四角调字号 · 左右手柄调宽度"),size:10,color:muted),height:18)
        inspector.translatesAutoresizingMaskIntoConstraints=true
        inspector.frame=NSRect(x:0,y:0,width:250,height:inspector.fittingSize.height)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { libraryEntries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry=libraryEntries[row],cell=NSTableCellView()
        cell.frame.size.width=tableColumn?.width ?? 240
        let isMedia=entry.clipID != nil || entry.musicID != nil
        let textX: CGFloat=isMedia ? 88 : 8
        if isMedia {
            let thumbnail=NSImageView(frame:NSRect(x:8,y:8,width:72,height:45))
            thumbnail.identifier=NSUserInterfaceItemIdentifier("mediaThumbnail")
            thumbnail.imageScaling = .scaleProportionallyUpOrDown
            thumbnail.wantsLayer=true; thumbnail.layer?.backgroundColor=NSColor.black.withAlphaComponent(0.35).cgColor
            thumbnail.layer?.cornerRadius=5; thumbnail.layer?.masksToBounds=true
            thumbnail.contentTintColor=muted
            thumbnail.image=entry.clipID.flatMap { timeline.clipThumbnails[$0]?.compactMap{$0}.first }
                ?? NSImage(systemSymbolName:entry.musicID != nil ? "music.note" : "film",accessibilityDescription:nil)
            cell.addSubview(thumbnail)
        }
        cell.toolTip=entry.title
        let title=label(entry.title,size:13,bold:true)
        title.frame=NSRect(x:textX,y:32,width:max(1,cell.frame.width-textX-8),height:22)
        title.lineBreakMode = .byTruncatingTail; title.autoresizingMask=[.width]; cell.addSubview(title)
        let detail=label(entry.detail,size:11,color:muted)
        detail.frame=NSRect(x:textX,y:8,width:max(1,cell.frame.width-textX-8),height:20)
        detail.lineBreakMode = .byTruncatingTail
        detail.autoresizingMask=[.width]; cell.addSubview(detail)
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncingSelection else { return }
        let i=table.selectedRow
        guard libraryEntries.indices.contains(i) else { return }
        let entry=libraryEntries[i]
        if entry.isMedia { if let id=entry.musicID { selectMusicClip(id); return }; if let id=entry.clipID { selectVideoClip(id) }; return }
        pauseForEditing()
        if let language=entry.language { preferredLanguage=language }
        if let id=entry.trackID,let item=textTrackChoice.itemArray.first(where:{$0.representedObject as? UUID == id}) { textTrackChoice.select(item) }
        let cues=project.cues.filter{entry.contains($0)}.sorted{$0.start < $1.start}
        if let cue=cues.first(where:{$0.start <= current && current < $0.end}) ?? cues.first {
            select(cue.id)
        } else {
            selected=nil; overlay.selected=nil; timeline.selected=nil
            overlay.needsDisplay=true; timeline.needsDisplay=true; refreshInspector()
        }
    }
    @objc func libraryChanged(_ sender: NSSegmentedControl) {
        view.window?.makeFirstResponder(nil)
        setTableSelection([])
        refresh(); root.needsLayout=true
    }
    func addLibraryItem() {
        if showsMedia { appendVideos() }
        else if let entry=libraryEntries.indices.contains(table.selectedRow) ? libraryEntries[table.selectedRow] : nil,entry.trackID != nil { addTrackText() }
        else { addSubtitle() }
    }
    func setTableSelection(_ indexes: IndexSet) {
        syncingSelection=true; table.selectRowIndexes(indexes,byExtendingSelection:false); syncingSelection=false
        updateMediaGridSelection()
    }
    func clearSelection() {
        guard !busy else { return }
        view.window?.makeFirstResponder(nil)
        deselectedCueIDs=Set(project.active(at:current).map(\.id))
        selectedMusic=nil; timeline.selectedMusic=nil
        selectedClip=nil; timeline.selectedClip=nil
        selected=nil; setTableSelection([])
        overlay.selected=nil; overlay.needsDisplay=true; overlay.window?.invalidateCursorRects(for:overlay)
        timeline.selected=nil; timeline.needsDisplay=true
        refreshInspector()
        (left.subviews.first{$0.identifier?.rawValue == "delete"} as? NSButton)?.isEnabled=false
    }
    func select(_ id: UUID, seek shouldSeek: Bool = true) {
        guard let cue=project.cues.first(where:{$0.id == id}) else { return }
        deselectedCueIDs=nil
        selectedMusic=nil; timeline.selectedMusic=nil
        selectedClip=nil; timeline.selectedClip=nil
        selected=id; preferredLanguage=cue.language
        if let id=cue.trackID,let item=textTrackChoice.itemArray.first(where:{$0.representedObject as? UUID == id}) { textTrackChoice.select(item) }
        syncLibrarySelection()
        if shouldSeek { seek(cue.start) }
        overlay.selected=player.rate == 0 ? selected : nil; overlay.needsDisplay=true; timeline.selected=selected; timeline.needsDisplay=true; refreshInspector()
    }
    func followCurrentSubtitles() {
        let active=project.active(at:current), ids=Set(active.map(\.id))
        if let dismissed=deselectedCueIDs {
            if dismissed == ids { return }
            deselectedCueIDs=nil
        }
        let next=active.first(where:{$0.id == selected})?.id ?? active.first(where:{$0.trackID == nil && $0.language == preferredLanguage})?.id ?? active.first?.id
        if selected != next { selected=next; overlay.selected=player.rate == 0 ? next : nil; timeline.selected=next; refreshInspector() }
        syncLibrarySelection()
        (left.subviews.first{$0.identifier?.rawValue == "delete"} as? NSButton)?.isEnabled = !busy && selected != nil
    }
    func refresh() {
        if let id=selectedClip,!project.allClips.contains(where:{$0.id == id}) { selectedClip=nil }
        let document: NSView=showsGrid ? mediaGrid : table
        if tableScroll.documentView !== document { tableScroll.documentView=document }
        fileLabel.isHidden=showsGrid; mediaSearch.isHidden = !showsGrid; mediaImportButton.isHidden = !showsGrid
        mediaImportButton.toolTip=showsLocalLibrary ? L("选择素材库目录") : L("导入")
        mediaImportButton.isEnabled = !busy; mediaSearch.isEnabled = !busy
        left.subviews.first{$0.identifier?.rawValue == "add"}?.isHidden=showsGrid
        refreshMediaGrid()
        playbackSpeedChoice.selectItem(at:playbackSpeeds.firstIndex(of:playbackSpeed) ?? 3)
        if player.rate != 0 && abs(player.rate-playbackSpeed)>0.001 {
            player.currentItem?.audioTimePitchAlgorithm = .spectral
            player.playImmediately(atRate:playbackSpeed)
        }
        refreshMusicControls()
        fileLabel.stringValue=project.videoPath.isEmpty ? L("尚未导入视频") : URL(fileURLWithPath:project.videoPath).lastPathComponent
        syncingSelection=true; table.reloadData(); syncingSelection=false
        if let selected,project.cues.contains(where:{$0.id == selected}) { syncLibrarySelection() }
        else { selected=nil; setTableSelection([]); refreshInspector() }
        if showsMedia,let id=selectedMusic,let index=libraryEntries.firstIndex(where:{$0.musicID == id}) { setTableSelection(IndexSet(integer:index)) }
        (center.subviews.first{$0.identifier?.rawValue == "regionErase"} as? NSButton)?.isEnabled = !busy && !project.allClips.isEmpty
        refreshRegionEraseButton()
        overlay.editingEnabled = !busy; timeline.editingEnabled = !busy
        overlay.project=project; overlay.selected=player.rate == 0 ? selected : nil; overlay.time=current; overlay.needsDisplay=true
        let chosen=textTrackChoice.selectedItem?.representedObject as? UUID
        textTrackChoice.removeAllItems()
        for track in project.tracks {
            textTrackChoice.addItem(withTitle:track.name); textTrackChoice.lastItem?.representedObject=track.id
        }
        if let chosen,let item=textTrackChoice.itemArray.first(where:{$0.representedObject as? UUID == chosen}) { textTrackChoice.select(item) }
        textTrackChoice.isEnabled = !busy && !project.tracks.isEmpty
        (bottom.subviews.first{$0.identifier?.rawValue == "deleteTrack"} as? NSButton)?.isEnabled = !busy && !project.tracks.isEmpty
        for v in bottom.subviews where ["newTrack","newText"].contains(v.identifier?.rawValue ?? "") { (v as? NSButton)?.isEnabled = !busy && project.duration > 0 }
        timeline.project=project; timeline.selectedClip=selectedClip; timeline.selected=selected; timeline.current=current; resizeTimeline()
        emptyTitle.isHidden = !project.videoPath.isEmpty; emptyHint.isHidden=emptyTitle.isHidden
        for control in [displayMode] {
            control.segmentCount=project.subtitleLanguages.count
            for (i,language) in project.subtitleLanguages.enumerated() { control.setLabel(language.title,forSegment:i); control.setSelected(project.visible(language),forSegment:i) }
            control.isEnabled = !busy
        }
        languageChoice.isEnabled = !busy
        (left.subviews.first{$0.identifier?.rawValue == "delete"})?.isHidden=showsGrid
        (header.subviews.first{$0.identifier?.rawValue == "newProject"} as? NSButton)?.isEnabled = !busy
        generateButton.isEnabled = !busy && !project.videoPath.isEmpty; exportButton.isEnabled=generateButton.isEnabled; importButton.isEnabled = !busy
        scrub.isEnabled = !project.videoPath.isEmpty; scrub.maxValue=max(1,Double(project.duration))
        playbackSpeedChoice.isEnabled = !busy && player.currentItem != nil
        (left.subviews.first{$0.identifier?.rawValue == "add"} as? NSButton)?.title = showsMedia ? L("添加素材") : L("添加")
        (left.subviews.first{$0.identifier?.rawValue == "add"} as? NSButton)?.isEnabled = !busy && (showsMedia || !project.videoPath.isEmpty)
        (left.subviews.first{$0.identifier?.rawValue == "delete"} as? NSButton)?.isEnabled = !busy && selected != nil
        refreshPlayback()
    }
    func refreshPlayback() {
        refreshCutButtons()
        timeLabel.stringValue="\(SRT.timestamp(current).replacingOccurrences(of:",",with:".")) / \(SRT.timestamp(project.duration).prefix(8))"
        if player.rate != 0 { followCurrentSubtitles() }
        let previewSelection=player.rate == 0 ? selected : nil
        if overlay.selected != previewSelection {
            overlay.selected=previewSelection
            overlay.window?.invalidateCursorRects(for:overlay)
        }
        scrub.doubleValue=Double(current); overlay.time=current; overlay.needsDisplay=true; timeline.current=current; timeline.needsDisplay=true
    }
    func refreshInspector() {
        inspectorUpdating=true; defer { inspectorUpdating=false }
        let enabled = !busy && project.cues.contains{$0.id == selected}
        for control in [alignmentChoice,fontChoice,startField,endField,sizeField,widthField,outlineField,xField,yField,textColor,outlineColor,backgroundColor,backgroundEnabled,readabilityEnabled] as [NSControl] { control.isEnabled=enabled }
        for button in inspector.arrangedSubviews.compactMap({$0 as? NSButton}) { button.isEnabled=enabled }
        guard let cue=project.cues.first(where:{$0.id == selected}) else { selectionLabel.stringValue=L("选择字幕开始编辑"); textEditor.string=""; textEditor.isEditable=false; return }
        textEditor.isEditable = !busy; selectionLabel.stringValue="\(project.tracks.first(where:{$0.id == cue.trackID})?.name ?? (cue.language.title+" · "+L("字幕"))) · \(cue.style == nil ? L("轨道样式") : L("自定义样式"))"
        textEditor.string=cue.text; startField.stringValue=String(format:"%.3f",Double(cue.start)/1000); endField.stringValue=String(format:"%.3f",Double(cue.end)/1000)
        let s=project.style(for:cue); let family=NSFont(name:s.font,size:12)?.familyName ?? s.font
        if fontChoice.itemTitles.contains(family) { fontChoice.selectItem(withTitle:family) }
        alignmentChoice.selectedSegment=SubtitleAlignment.allCases.firstIndex(of:s.textAlignment) ?? 1
        widthField.stringValue=s.width.map { String(format:"%.1f",$0*100) } ?? ""
        sizeField.stringValue=String(format:"%.1f",s.size); outlineField.stringValue=String(format:"%.1f",s.outlineWidth); xField.stringValue=String(format:"%.1f",s.x*100); yField.stringValue=String(format:"%.1f",s.y*100)
        readabilityEnabled.state=s.enhancesReadability ? .on : .off
        textColor.color=s.color.ns; outlineColor.color=s.outline.ns; backgroundColor.color=s.background.a > 0 ? s.background.ns : NSColor(white:0,alpha:0.65); backgroundEnabled.state=s.background.a > 0 ? .on : .off
    }
    func commit(_ next: Project, name: String = L("编辑字幕")) {
        guard next != project else { return }
        if project.isVideoLocked && next.clips != project.clips && !history.isUndoing && !history.isRedoing {
            showError(SubtitleError.invalid(L("视频轨道已锁定，请先解锁"))); refresh(); return
        }
        if !history.isUndoing && !history.isRedoing {
            for old in project.layers where old.isLocked {
                guard var candidate=next.layers.first(where:{$0.id == old.id}) else { showError(SubtitleError.invalid(L("视频轨道已锁定，请先解锁"))); refresh(); return }
                candidate.locked=old.locked; candidate.hidden=old.hidden; candidate.muted=old.muted
                guard candidate == old else { showError(SubtitleError.invalid(L("视频轨道已锁定，请先解锁"))); refresh(); return }
            }
        }
        do { try next.validate() } catch { showError(error); refreshInspector(); return }
        let old=project
        if old.clips != next.clips || old.layers != next.layers || old.music != next.music || old.isVideoMuted != next.isVideoMuted || old.isVideoHidden != next.isVideoHidden {
            do { try installPreview(for:next) } catch { showError(error); return }
            retryDirectory=nil; UserDefaults.standard.removeObject(forKey:"pendingJob"); generateButton.title=L("生成字幕")
        }
        history.registerUndo(withTarget:self) { target in target.commit(old,name:name); target.refreshInspector() }; history.setActionName(name)
        project=next
        if !busy && retryDirectory != nil && next.cues != old.cues { retryDirectory=nil; UserDefaults.standard.removeObject(forKey:"pendingJob"); generateButton.title=L("生成字幕") }
        refresh(); scheduleSave()
    }
    func updateCue(_ id: UUID, _ edit: (inout Cue,Project)->Void) {
        guard !busy,let i=project.cues.firstIndex(where:{$0.id == id}) else { return }
        var next=project; edit(&next.cues[i],project); commit(next)
    }
    func pauseForEditing() {
        if player.rate != 0 { player.pause(); playButton.image=NSImage(systemSymbolName:"play.fill",accessibilityDescription:L("播放")); refreshPlayback() }
    }
    func textDidBeginEditing(_ notification: Notification) { pauseForEditing() }
    func controlTextDidBeginEditing(_ notification: Notification) { pauseForEditing() }
    func textDidChange(_ notification: Notification) {
        guard !inspectorUpdating,!busy,let id=selected,!textEditor.string.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return }
        let text=textEditor.string; updateCue(id) { cue,_ in cue.text=cue.trackID == nil && cue.language == .zh ? text.components(separatedBy:.newlines).joined(separator:"，") : text }
    }
    func textDidEndEditing(_ notification: Notification) {
        if textEditor.string.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && selected != nil {
            refreshInspector(); statusLabel.stringValue=L("字幕内容不能为空；移除字幕请使用删除按钮")
        }
    }
    @objc func inspectorChanged(_ sender: NSControl) {
        guard !inspectorUpdating,!busy,let id=selected else { return }
        if sender === widthField,let cue=project.cues.first(where:{$0.id == id}) {
            let raw=widthField.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
            let value=Double(raw.replacingOccurrences(of:",",with:"."))
            guard raw.isEmpty || (value.map{$0.isFinite && (10...100).contains($0)} ?? false) else {
                showError(SubtitleError.invalid(L("宽度请输入 10 到 100，留空恢复自动宽度"))); refreshInspector(); return
            }
            pauseForEditing(); var next=project; var style=project.style(for:cue); style.width=value.map{$0/100}
            next.applyStyle(style,for:cue); commit(next,name:L("调整同语言字幕宽度")); refreshInspector(); return
        }
        let fields=[startField,endField,sizeField,outlineField,xField,yField]
        let values=fields.compactMap { Double($0.stringValue.replacingOccurrences(of:",",with:".")) }
        guard values.count == 6, values.allSatisfy(\.isFinite),abs(values[0])<1e9,abs(values[1])<1e9 else { showError(SubtitleError.invalid(L("请输入有效数值"))); refreshInspector(); return }
        guard let index=project.cues.firstIndex(where:{$0.id == id}) else { return }
        pauseForEditing()
        var next=project
        if sender === startField || sender === endField {
            next.cues[index].start=Int64(values[0]*1000); next.cues[index].end=Int64(values[1]*1000)
        } else {
            let cue=project.cues[index]; var style=project.style(for:cue)
            if sender === fontChoice {
                style.font=NSFontManager.shared.font(withFamily:fontChoice.titleOfSelectedItem ?? "PingFang SC",traits:[],weight:5,size:12)?.fontName ?? style.font
            }
            if sender === alignmentChoice,SubtitleAlignment.allCases.indices.contains(alignmentChoice.selectedSegment) { style.alignment=SubtitleAlignment.allCases[alignmentChoice.selectedSegment] }
            if sender === sizeField { style.size=values[2] }
            if sender === readabilityEnabled { style.readability=readabilityEnabled.state == .on }
            if sender === textColor { style.color=RGBA(textColor.color) }
            if sender === outlineColor { style.outline=RGBA(outlineColor.color) }
            if sender === outlineField { style.outlineWidth=values[3] }
            if sender === backgroundEnabled || sender === backgroundColor { style.background=backgroundEnabled.state == .on ? RGBA(backgroundColor.color) : .clear }
            if sender === xField { style.x=values[4]/100 }
            if sender === yField { style.y=values[5]/100 }
            next.applyStyle(style,for:cue)
        }
        commit(next,name:L("编辑字幕属性")); refreshInspector()
    }
    func previewTrackStyle(id: UUID, style: SubtitleStyle, finished: Bool) {
        guard !busy,let original=styleDragOriginal,let cue=original.cues.first(where:{$0.id == id}) else { return }
        var next=original; next.applyStyle(style,for:cue)
        if finished {
            styleDragOriginal=nil; project=original; commit(next,name:L("调整同语言字幕样式"))
        } else {
            project=next; overlay.project=next; overlay.needsDisplay=true; timeline.project=next; timeline.needsDisplay=true
        }
        refreshInspector()
    }
    func deleteTextTrack() {
        guard !busy,let id=textTrackChoice.selectedItem?.representedObject as? UUID,
              project.tracks.contains(where:{$0.id == id}) else { return }
        view.window?.makeFirstResponder(nil)
        pauseForEditing()
        var next=project
        next.cues.removeAll{$0.trackID == id}
        next.textTracks=next.tracks.filter{$0.id != id}
        if let selected,!next.cues.contains(where:{$0.id == selected}) { self.selected=nil }
        commit(next,name:L("删除文字轨道")); refreshInspector()
    }
    func addTextTrack() {
        guard !busy,project.duration > 0 else { return }
        pauseForEditing()
        do {
            var next=project
            let track=TextTrack(name:L("文字 {0}", [String(describing: next.tracks.count+1)]))
            next.textTracks=next.tracks+[track]
            let cue=try next.newCue(language:.zh,at:min(current,max(0,next.duration-2000)),trackID:track.id)
            next.cues.append(cue); commit(next,name:L("新建文字轨道"))
            textTrackChoice.selectItem(at:next.tracks.count-1); select(cue.id)
            timeline.scrollToVisible(timeline.rect(cue))
        } catch { showError(error) }
    }
    func addTrackText() {
        guard !busy else { return }
        guard let id=textTrackChoice.selectedItem?.representedObject as? UUID else { addTextTrack(); return }
        pauseForEditing()
        do {
            let cue=try project.newCue(language:.zh,at:current,trackID:id)
            var next=project; next.cues.append(cue); commit(next,name:"添加说明文字"); select(cue.id)
            timeline.scrollToVisible(timeline.rect(cue))
        } catch { showError(error) }
    }
    func addSubtitle() {
        guard !busy else { return }
        guard project.subtitleLanguages.contains(where: { project.visible($0) }) else { showError(SubtitleError.invalid(L("请先选择要显示的字幕语言"))); return }
        let language: Language = project.subtitleLanguages.contains(preferredLanguage) && project.visible(preferredLanguage) ? preferredLanguage : project.subtitleLanguages.first(where: { project.visible($0) })!
        do { let cue=try project.newCue(language:language,at:current); var next=project; next.cues.append(cue); commit(next,name:L("添加字幕")); select(cue.id) } catch { showError(error) }
    }
    func deleteSubtitle() { guard !busy,let id=selected else { return }; var next=project; next.cues.removeAll{$0.id == id}; selected=nil; commit(next,name:L("删除字幕")); refreshInspector() }
    @objc func modeChanged(_ sender: NSSegmentedControl) {
        guard !busy else { refresh(); return }
        var next=project; for (i,language) in project.subtitleLanguages.enumerated() { next.setVisible(sender.isSelected(forSegment:i),for:language) }
        if sender.selectedSegment >= 0, sender.isSelected(forSegment:sender.selectedSegment) { preferredLanguage=project.subtitleLanguages[sender.selectedSegment] }
        commit(next,name:L("切换字幕显示")); followCurrentSubtitles(); refreshInspector()
    }
    @objc func zoomChanged() { timeline.pointsPerSecond=zoom.doubleValue; resizeTimeline() }
    @objc func scrubChanged() { seek(Int64(scrub.doubleValue)) }
    func seek(_ ms: Int64) { current=max(0,min(project.duration,ms)); player.seek(to:CMTime(value:current,timescale:1000),toleranceBefore:.zero,toleranceAfter:.zero); followCurrentSubtitles(); refreshPlayback() }
    @objc func togglePlay() {
        guard !project.videoPath.isEmpty else { return }
        if player.rate == 0 { cancelRegionErase(); if current >= project.duration-40 { seek(0) }; player.currentItem?.audioTimePitchAlgorithm = .spectral; player.playImmediately(atRate:playbackSpeed); playButton.image=NSImage(systemSymbolName:"pause.fill",accessibilityDescription:L("暂停")) }
        else { player.pause(); playButton.image=NSImage(systemSymbolName:"play.fill",accessibilityDescription:L("播放")) }
        refreshPlayback()
    }
    @objc func playbackSpeedChanged(_ sender: NSPopUpButton) {
        guard !busy,playbackSpeeds.indices.contains(sender.indexOfSelectedItem) else { return }
        var next=project; next.playbackRate=Double(playbackSpeeds[sender.indexOfSelectedItem])
        commit(next,name:L("修改播放速度"))
    }
    func showError(_ error: Error) { let alert=NSAlert(error:error); alert.runModal() }
    @objc func importVideo() {
        guard !busy else { return }
        let panel=NSOpenPanel(); panel.allowedContentTypes=[.movie]; panel.allowsMultipleSelection=false
        if panel.runModal() == .OK,let url=panel.url { loadVideo(url) }
    }
    func loadVideo(_ url: URL, preservingProject: Bool = false) {
        guard !busy else { return }
        cancelRegionErase()
        if url.pathExtension == "frzh" { openProject(url); return }
        let asset=AVURLAsset(url:url)
        guard let track=asset.tracks(withMediaType:.video).first else { showError(SubtitleError.invalid(L("无法读取视频，请选择支持的 MP4 或 MOV 文件"))); return }
        let seconds=CMTimeGetSeconds(asset.duration)
        guard seconds.isFinite,seconds>0,seconds<1e9 else { showError(SubtitleError.invalid(L("视频时长无效"))); return }
        if !preservingProject {
            archiveCurrentProject()
            timeline.subtitleTracksRequested=false
            project=Project(); project.duration=Int64(seconds*1000); project.videoPath=url.path; projectURL=nil; UserDefaults.standard.removeObject(forKey:"projectURL"); selected=nil; history.removeAllActions(); retryDirectory=nil; UserDefaults.standard.removeObject(forKey:"pendingJob"); generateButton.title=L("生成字幕")
        } else {
            guard abs(Int64(seconds*1000)-project.duration) <= 1000 else { showError(SubtitleError.invalid(L("所选视频时长与工程不一致，请选择原视频"))); return }
            project.videoPath=url.path
        }
        player.pause(); player.replaceCurrentItem(with:AVPlayerItem(asset:asset)); current=0
        let rect=CGRect(origin:.zero,size:track.naturalSize).applying(track.preferredTransform); overlay.videoSize=CGSize(width:abs(rect.width),height:abs(rect.height))
        refresh(); refreshInspector(); scheduleSave(); statusLabel.stringValue=L("视频已加载 · {0} × {1}", [String(describing: Int(overlay.videoSize.width)), String(describing: Int(overlay.videoSize.height))])
        loadTimelineThumbnails(for:project.allClips)
    }

    func archiveCurrentProject() {
        persistNow()
        if projectURL == nil && !project.cues.isEmpty {
            let dir=supportDirectory.appendingPathComponent("Recovered Projects")
            do { try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true); try project.write(dir.appendingPathComponent("\(UUID().uuidString).frzh")) } catch { showError(error) }
        }
    }
    func scheduleSave() {
        autosave?.cancel(); let task=DispatchWorkItem { [weak self] in self?.persistNow() }; autosave=task; DispatchQueue.main.asyncAfter(deadline:.now()+0.6,execute:task)
    }
    func persistNow() {
        guard hasProjectContent || projectURL != nil else { return }
        do {
            try project.write(supportDirectory.appendingPathComponent("Recovery.frzh"))
        } catch { statusLabel.stringValue=L("自动保存失败：{0}", [String(describing: error.localizedDescription)]) }
    }
    var hasProjectContent: Bool {
        !project.videoPath.isEmpty || !project.allClips.isEmpty || !project.cues.isEmpty || !project.music.isEmpty || !project.tracks.isEmpty
    }
    var needsSaveBeforeClosing: Bool {
        guard let url=projectURL else { return hasProjectContent }
        return (try? Project.read(url)) != project
    }
    func confirmSaveBeforeClosing() -> Bool {
        view.window?.makeFirstResponder(nil)
        pauseForEditing()
        guard needsSaveBeforeClosing else { return true }
        let alert=NSAlert()
        alert.messageText=L("退出前保存工程？")
        alert.informativeText=L("工程有未保存的修改。选择不保存将保留上次保存的工程版本。")
        alert.addButton(withTitle:L("保存"))
        alert.addButton(withTitle:L("不保存"))
        alert.addButton(withTitle:L("取消"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return saveProjectToDisk()
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }
    @objc func saveProject() { _ = saveProjectToDisk() }
    func saveProjectToDisk() -> Bool {
        guard hasProjectContent || projectURL != nil else { return false }
        let panel=NSSavePanel(); panel.nameFieldStringValue=projectURL?.lastPathComponent ?? (project.videoPath.isEmpty ? "Project.frzh" : URL(fileURLWithPath:project.videoPath).deletingPathExtension().lastPathComponent+".frzh")
        panel.title=L("保存字幕工程"); panel.allowedContentTypes=[UTType(exportedAs:"local.videoediteur.project",conformingTo:.json)]
        if panel.runModal() == .OK,let url=panel.url { do { try project.write(url); projectURL=url; UserDefaults.standard.set(url.path,forKey:"projectURL"); statusLabel.stringValue=L("工程已保存：{0}", [String(describing: url.lastPathComponent)]); return true } catch { showError(error) } }
        return false
    }
    @objc func newProject() {
        guard !busy else { statusLabel.stringValue=L("请先取消或等待当前任务完成，再新建工程"); return }
        view.window?.makeFirstResponder(nil)
        pauseForEditing()
        let hasContent = !project.videoPath.isEmpty || !project.allClips.isEmpty || !project.cues.isEmpty || !project.music.isEmpty
        let saved = projectURL.flatMap { try? Project.read($0) }
        if hasContent && saved != project {
            let alert=NSAlert(); alert.messageText=L("保存当前工程后再新建？")
            alert.informativeText=L("新建将清空当前界面中的视频、字幕和时间轴。原视频和已保存的工程文件不会删除。")
            alert.addButton(withTitle:L("保存并新建")); alert.addButton(withTitle:L("不保存并新建")); alert.addButton(withTitle:L("取消"))
            switch alert.runModal() {
            case .alertFirstButtonReturn: guard saveProjectToDisk() else { return }
            case .alertSecondButtonReturn: break
            default: return
            }
        }
        // Replace recovery first; never resurrect the previous project on restart.
        let blank=Project()
        do { try blank.write(supportDirectory.appendingPathComponent("Recovery.frzh")) }
        catch { showError(error); return }
        autosave?.cancel(); autosave=nil
        thumbnailJob?.cancel(); thumbnailJob=nil
        player.pause(); player.replaceCurrentItem(with:nil)
        cancelRegionErase()
        timeline.subtitleTracksRequested=false
        project=blank; projectURL=nil; selectedMusic=nil; timeline.selectedMusic=nil; selected=nil; selectedClip=nil; current=0
        deselectedCueIDs=nil; styleDragOriginal=nil; retryDirectory=nil
        UserDefaults.standard.removeObject(forKey:"projectURL")
        UserDefaults.standard.removeObject(forKey:"pendingJob")
        history.removeAllActions()
        timeline.clipThumbnails=[:]; timeline.clipWaveforms=[:]; timeline.pointsPerSecond=65; zoom.doubleValue=65
        timelineScroll.contentView.scroll(to:.zero); timelineScroll.reflectScrolledClipView(timelineScroll.contentView)
        overlay.videoSize=CGSize(width:16,height:9); overlay.hitBoxes=[]
        languageChoice.selectedSegment=0
        generateButton.title=L("生成字幕")
        playButton.image=NSImage(systemSymbolName:"play.fill",accessibilityDescription:L("播放"))
        for field in [startField,endField,sizeField,widthField,outlineField,xField,yField] { field.stringValue="" }
        fontChoice.selectItem(at:0); alignmentChoice.selectedSegment=1
        textColor.color = .white; outlineColor.color = .black; backgroundColor.color = .clear
        backgroundEnabled.state = .off; readabilityEnabled.state = .off
        refresh(); refreshInspector(); statusLabel.stringValue=L("新工程 · 请导入视频")
    }
    @objc func chooseProject() {
        guard !busy else { return }
        let panel=NSOpenPanel(); panel.allowedContentTypes=[UTType(exportedAs:"local.videoediteur.project",conformingTo:.json)]; panel.allowsMultipleSelection=false
        if panel.runModal() == .OK,let url=panel.url { openProject(url) }
    }
    func openProject(_ url: URL) {
        guard !busy else { return }
        do { let loaded=try Project.read(url); archiveCurrentProject(); timeline.subtitleTracksRequested=false; project=loaded; projectURL=url; UserDefaults.standard.set(url.path,forKey:"projectURL"); UserDefaults.standard.removeObject(forKey:"pendingJob"); selected=nil; retryDirectory=nil; history.removeAllActions(); attachProjectVideo() } catch { showError(error) }
    }
    func attachProjectVideo() {
        if project.videoClips != nil || !project.music.isEmpty || project.isVideoMuted || project.isVideoHidden { restoreEditedProject(); return }
        let url=URL(fileURLWithPath:project.videoPath)
        if FileManager.default.fileExists(atPath:url.path) { loadVideo(url,preservingProject:true) }
        else {
            refresh(); let alert=NSAlert(); alert.messageText=L("找不到原视频"); alert.informativeText=L("字幕和样式已保留，请重新定位：\n{0}", [String(describing: url.path)]); alert.addButton(withTitle:L("重新定位")); alert.addButton(withTitle:L("稍后"))
            if alert.runModal() == .alertFirstButtonReturn { let panel=NSOpenPanel(); panel.allowedContentTypes=[.movie]; if panel.runModal() == .OK,let new=panel.url { loadVideo(new,preservingProject:true) } }
        }
    }
    func setBusy(_ value: Bool, indeterminate: Bool = true) {
        busy=value; cancelButton.isHidden = !value; progress.isHidden = !value; progress.isIndeterminate=indeterminate
        if value && indeterminate { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        refresh(); refreshInspector()
    }
    struct GenerationOptions {
        var languages: GenerationLanguages
        var filesOnly: Bool
    }
    func chooseGenerationLanguages() -> GenerationOptions? {
        let alert=NSAlert(); alert.messageText=L("生成字幕")
        alert.informativeText=L("选择视频语言和目标语言；相同语言只生成转写字幕。")
        let box=NSView(frame:NSRect(x:0,y:0,width:430,height:140))
        let source=NSPopUpButton(frame:NSRect(x:140,y:100,width:270,height:28))
        let target=NSPopUpButton(frame:NSRect(x:140,y:60,width:270,height:28))
        let sources: [Language]=[.fr,.en], targets: [Language]=[.zh,.en,.fr]
        source.addItems(withTitles:sources.map(\.title)); target.addItems(withTitles:targets.map(\.title))
        let defaults=project.generationLanguages ?? GenerationLanguages()
        source.selectItem(at:sources.firstIndex(of:defaults.source) ?? 0); target.selectItem(at:targets.firstIndex(of:defaults.target) ?? 0)
        for (title,y) in [(L("视频语言"),104.0),(L("目标语言"),64.0)] {
            let text=label(title,size:12); text.frame=NSRect(x:0,y:y,width:135,height:24); box.addSubview(text)
        }
        let filesOnly=NSButton(checkboxWithTitle:L("仅生成 SRT 字幕文件（不添加到视频）"),target:nil,action:nil)
        filesOnly.identifier=NSUserInterfaceItemIdentifier("generateSRTOnly")
        filesOnly.state = .off; filesOnly.frame=NSRect(x:0,y:15,width:430,height:28)
        box.addSubview(filesOnly)
        box.addSubview(source); box.addSubview(target); alert.accessoryView=box
        alert.addButton(withTitle:L("生成")); alert.addButton(withTitle:L("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return GenerationOptions(languages:GenerationLanguages(source:sources[source.indexOfSelectedItem],target:targets[target.indexOfSelectedItem]),filesOnly:filesOnly.state == .on)
    }
    func generate() {
        guard !busy,!project.videoPath.isEmpty else { return }
        guard let options=chooseGenerationLanguages() else { return }
        let languages=options.languages
        if options.filesOnly { generateSubtitleFiles(languages:languages); return }
        let cachedLanguages=retryDirectory.flatMap { try? Data(contentsOf:$0.appendingPathComponent("languages.json")) }.flatMap { try? JSONDecoder().decode(GenerationLanguages.self,from:$0) } ?? GenerationLanguages()
        let retry=languages == cachedLanguages ? retryDirectory : nil
        if retry == nil && project.cues.contains(where: { $0.trackID == nil }) {
            let alert=NSAlert(); alert.messageText=L("重新生成将替换现有字幕"); alert.informativeText=L("人工修改的字幕将被替换，完成后可通过撤销恢复。"); alert.addButton(withTitle:L("重新生成")); alert.addButton(withTitle:L("取消"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        do { try ToolSettings.current.validate() } catch { showError(error); return }
        let original=project, job=GenerationJob(directory:retry ?? supportDirectory.appendingPathComponent("Jobs/\(UUID().uuidString)"),languages:languages)
        var generated=project; generated.generationLanguages=languages
        for language in [languages.source,languages.target] { generated.setVisible(true,for:language) }
        if languages.source != .zh && languages.target != .zh && languages.source != languages.target {
            let cue=Cue(language:languages.target,start:0,end:1,text:"")
            if generated.style(for:cue) == SubtitleStyle.standard(languages.target) {
                var style=generated.style(for:cue); style.y=0.075; generated.applyStyle(style,to:languages.target)
            }
        }
        let generationProject=generated
        project=generated
        timeline.subtitleTracksRequested=true
        generation=job; retryDirectory=job.directory; UserDefaults.standard.set(job.directory.path,forKey:"pendingJob"); setBusy(true); player.pause()
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            do {
                let transcriptionInput=try self?.prepareTranscriptionInput(project:original,job:job) ?? URL(fileURLWithPath:original.videoPath)
                let result=try job.run(video:transcriptionInput,duration:original.duration,status:{ message in DispatchQueue.main.async { self?.statusLabel.stringValue=message } },partial:{ cues in DispatchQueue.main.async { guard let self, self.generation === job else { return }; self.project=generationProject; self.project.cues=cues+original.cues.filter{$0.trackID != nil}; self.selected=nil; self.refresh(); self.scheduleSave() } })
                DispatchQueue.main.async {
                    guard let self, self.generation === job else { return }; self.project=original; var next=generationProject; next.cues=result+original.cues.filter{$0.trackID != nil}; self.commit(next,name:L("生成字幕"))
                    self.generation=nil; self.retryDirectory=nil; UserDefaults.standard.removeObject(forKey:"pendingJob"); self.generateButton.title=L("生成字幕"); self.setBusy(false); self.statusLabel.stringValue=L("字幕已生成 · {0} 条", [String(result.count)]); self.persistNow()
                    if let first=result.first { self.select(first.id) }
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, self.generation === job else { return }
                    let partial=self.project; self.project=original; self.commit(partial,name:L("生成部分字幕"))
                    self.generation=nil; self.setBusy(false); self.generateButton.title=L("继续字幕生成"); self.statusLabel.stringValue=L("生成已停止 · 已保留完成的字幕，可继续重试")
                    self.persistNow(); if !job.runner.isCancelled { self.showError(error) }
                }
            }
        }
    }
    func exportVideo() {
        guard !busy,!project.videoPath.isEmpty else { return }
        guard let color=chooseExportColor() else { return }
        let panel=NSSavePanel(); panel.allowedContentTypes=[.mpeg4Movie]; panel.nameFieldStringValue=URL(fileURLWithPath:project.videoPath).deletingPathExtension().lastPathComponent+"-subtitles.mp4"
        panel.directoryURL=videoOutputDirectory
        guard panel.runModal() == .OK,let url=panel.url else { return }
        UserDefaults.standard.set(url.deletingLastPathComponent().path,forKey:"editor.videoOutputDirectory")
        let snapshot=project, job=VideoExporter(); exporter=job; setBusy(true,indeterminate:false); progress.doubleValue=0; statusLabel.stringValue=L("正在导出 {0}…", [String(describing: color.title)])
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            do {
                var last=Date.distantPast
                try job.run(project:snapshot,destination:url,color:color) { value in
                    if Date().timeIntervalSince(last)>0.15 || value == 1 { last=Date(); DispatchQueue.main.async { self?.progress.doubleValue=value; self?.statusLabel.stringValue=L("正在导出 · {0}%", [String(describing: Int(value*100))]) } }
                }
                DispatchQueue.main.async { self?.exporter=nil; self?.setBusy(false); self?.statusLabel.stringValue=L("导出完成：{0}", [String(describing: url.lastPathComponent)]); NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } catch { DispatchQueue.main.async { self?.exporter=nil; self?.setBusy(false); self?.statusLabel.stringValue=error.localizedDescription; self?.showError(error) } }
        }
    }
    @objc func showSettings() {
        let alert=NSAlert(); alert.messageText=L("本机工具设置"); alert.informativeText=L("复用本机 Codex 登录。转写在本机进行，字幕文本发送到 Codex 翻译；首次转写可能下载模型。")
        let box=NSView(frame:NSRect(x:0,y:0,width:530,height:365)); let settings=ToolSettings.current
        let languageTitle=label(L("界面语言"),size:12); languageTitle.frame=NSRect(x:0,y:244,width:150,height:24); box.addSubview(languageTitle)
        let language=NSPopUpButton(frame:NSRect(x:155,y:242,width:230,height:28)); language.addItems(withTitles:["中文", "English"])
        language.selectItem(at:InterfaceLanguage.preferred == .zh ? 0 : 1); box.addSubview(language)
        let languageHint=label(L("语言更改将在下次启动时生效。"),size:11,color:muted); languageHint.frame=NSRect(x:0,y:216,width:530,height:20); box.addSubview(languageHint)
        var fields: [NSTextField]=[]
        for (i,pair) in [("ffmpeg",settings.ffmpeg),("Python",settings.python),("Codex",settings.codex),(L("Skill 目录"),settings.skill)].enumerated() {
            let y=170-i*48, l=label(pair.0,size:11,color:muted); l.frame=NSRect(x:0,y:y+25,width:520,height:17); box.addSubview(l)
            let f=NSTextField(string:pair.1); f.frame=NSRect(x:0,y:y,width:525,height:24); box.addSubview(f); fields.append(f)
        }
        for subview in box.subviews { subview.frame.origin.y += 85 }
        var localDirectory=UserDefaults.standard.string(forKey:"editor.localLibraryDirectory")
        let directoryLabel=label(L("本地素材库（递归扫描视频）"),size:11,color:muted)
        directoryLabel.frame=NSRect(x:0,y:57,width:530,height:20); box.addSubview(directoryLabel)
        let directoryField=NSTextField(labelWithString:localDirectory ?? L("未选择目录"))
        directoryField.lineBreakMode = .byTruncatingMiddle; directoryField.frame=NSRect(x:0,y:22,width:390,height:24); box.addSubview(directoryField)
        let choose=ActionButton(L("选择目录"),action:{
            let panel=NSOpenPanel(); panel.canChooseDirectories=true; panel.canChooseFiles=false; panel.allowsMultipleSelection=false
            if panel.runModal() == .OK,let url=panel.url { localDirectory=url.path; directoryField.stringValue=url.path }
        })
        choose.frame=NSRect(x:400,y:20,width:125,height:28); box.addSubview(choose)
        alert.accessoryView=box; alert.addButton(withTitle:L("保存并检查")); alert.addButton(withTitle:L("取消"))
        if alert.runModal() == .alertFirstButtonReturn {
            if let localDirectory { UserDefaults.standard.set(localDirectory,forKey:"editor.localLibraryDirectory"); reloadLocalLibrary() }
            let chosen: InterfaceLanguage=language.indexOfSelectedItem == 0 ? .zh : .en
            UserDefaults.standard.set(chosen.rawValue,forKey:InterfaceLanguage.preferenceKey)
            if chosen != InterfaceLanguage.current { statusLabel.stringValue=L("语言更改将在下次启动时生效。") }
            var s=settings; s.ffmpeg=fields[0].stringValue; s.python=fields[1].stringValue; s.codex=fields[2].stringValue; s.skill=fields[3].stringValue; ToolSettings.current=s
            do { try s.validate(); statusLabel.stringValue=chosen != InterfaceLanguage.current ? L("语言更改将在下次启动时生效。") : L("工具路径检查通过") } catch { showError(error) }
        }
    }
    @objc func undoAction() { guard !busy else { return }; history.undo() }
    @objc func redoAction() { guard !busy else { return }; history.redo() }
}
