import AppKit
import AVFoundation
import CoreImage
import SubtitleCore

extension EditorController {
    func sampleEraseColor(at point: CGPoint) {
        eraseSampleColor=nil
        guard let item=player.currentItem else { return }
        let token=UUID(); eraseSampleID=token
        let generator=AVAssetImageGenerator(asset:item.asset)
        generator.appliesPreferredTrackTransform=true
        generator.videoComposition=item.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let time=player.currentTime()
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            do {
                let image=try generator.copyCGImage(at:time,actualTime:nil)
                let color=RegionColorSampler.sample(CIImage(cgImage:image),at:point)
                DispatchQueue.main.async {
                    guard let self,self.eraseSampleID == token,self.overlay.eraseMode else { return }
                    self.eraseSampleColor=color
                    self.statusLabel.stringValue=L("框选后按 Delete 智能去字")
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self,self.eraseSampleID == token else { return }
                    self.eraseSampleID=nil
                    self.statusLabel.stringValue=L("起点取色失败，请重新框选：{0}",[error.localizedDescription])
                }
            }
        }
    }
    func refreshRegionEraseButton() {
        guard let button=center.subviews.first(where:{$0.identifier?.rawValue == "regionErase"}) as? NSButton else { return }
        button.state=overlay.eraseMode ? .on : .off
        button.bezelColor=overlay.eraseMode ? accent : nil
        button.contentTintColor=overlay.eraseMode ? .black : nil
    }

    @objc func beginRegionErase() {
        guard !busy,let clip=targetClip else { return }
        if overlay.eraseMode { cancelRegionErase(); return }
        pauseForEditing(); clearSelection()
        if let p=project.placements.first(where:{$0.clip.id == clip.id}),!(p.start..<p.end).contains(current) { selectVideoClip(clip.id) }
        eraseSampleID=nil; eraseSampleColor=nil
        eraseClipID=clip.id; overlay.eraseMode=true; overlay.eraseRect=nil
        refreshRegionEraseButton()
        overlay.needsDisplay=true; overlay.window?.invalidateCursorRects(for:overlay); view.window?.makeFirstResponder(overlay)
        statusLabel.stringValue=L("框选要去除的文字；Delete 智能去字，Esc 取消")
    }
    func cancelRegionErase() {
        eraseSampleID=nil; eraseSampleColor=nil
        eraseClipID=nil; overlay.eraseMode=false; overlay.eraseRect=nil
        refreshRegionEraseButton()
        overlay.needsDisplay=true; overlay.window?.invalidateCursorRects(for:overlay)
    }
    /// The clip actually shown under the middle of `box` at the playhead: in a split screen that is the
    /// video in that cell, not the selected or main clip. The topmost visible layer wins.
    func clipShown(under box: CGRect) -> VideoClip? {
        let point=CGPoint(x:box.midX,y:box.midY)
        return project.renderPlacements.last { p in
            guard p.start<=current,current<p.end else { return false }
            let hidden=project.layers.first { $0.id == p.clip.id }?.hidden ?? project.isVideoHidden
            let cell=p.clip.frame.map { CGRect(x:$0.x,y:$0.y,width:$0.width,height:$0.height) } ?? CGRect(x:0,y:0,width:1,height:1)
            return !hidden && cell.contains(point)
        }?.clip
    }
    func applySelectedEraseRegion() {
        guard !busy,let box=overlay.eraseRect,let clip=clipShown(under:box) ?? project.allClips.first(where:{$0.id == eraseClipID}) else { return }
        // Smart repair needs no colour; the colour sampled at the drag start is offered for a manual solid fill.
        let region=VideoEraseRegion(x:box.minX,y:box.minY,width:box.width,height:box.height,sourceStart:clip.sourceStart,sourceEnd:clip.sourceEnd,color:eraseSampleColor,fill:.smart)
        editEraseRegion(region,clip:clip,isNew:true)
    }
    /// Replaces `clip`'s erase regions on the main track or on a video track.
    func replacingEraseRegions(_ regions: [VideoEraseRegion],of clip: VideoClip) throws -> Project {
        var next=project
        if let i=project.clips.firstIndex(where:{$0.id == clip.id}) {
            next.videoClips=project.clips; next.videoClips?[i].eraseRegions=regions.isEmpty ? nil : regions
        } else if let i=project.layers.firstIndex(where:{$0.id == clip.id}) {
            guard !project.layers[i].isLocked else { throw SubtitleError.invalid(L("视频轨道已锁定，请先解锁")) }
            next.videoLayers?[i].clip.eraseRegions=regions.isEmpty ? nil : regions
        } else { throw SubtitleError.invalid(L("素材或插入位置无效")) }
        try next.validate(); return next
    }
    func editEraseRegion(_ original: VideoEraseRegion,clip: VideoClip,isNew: Bool) {
        pauseForEditing()
        let alert=NSAlert(); alert.messageText=isNew ? L("去除选区文字") : L("编辑去字区域")
        alert.informativeText=L("智能修补每帧用选框四周的画面估算背景，只替换文字笔画，适合纹理或移动的背景；整块修补用周围画面填满整个选框；纯色适合单色字幕条。这是插值修补，不是 AI 修复或运动跟踪。时间相对于当前片段，Y 从底部计算。")
        let form=NSView(frame:NSRect(x:0,y:0,width:420,height:310))
        let values: [(String,Double)]=[(L("左侧 X %"),original.x*100),(L("底部 Y %"),original.y*100),(L("宽度 %"),original.width*100),(L("高度 %"),original.height*100),(L("开始 · 秒"),Double(max(clip.sourceStart,original.sourceStart)-clip.sourceStart)/1000),(L("结束 · 秒"),Double(min(clip.sourceEnd,original.sourceEnd)-clip.sourceStart)/1000)]
        var fields: [NSTextField]=[]
        for (i,value) in values.enumerated() {
            let title=label(value.0,size:12); title.frame=NSRect(x:0,y:278-i*34,width:155,height:24); form.addSubview(title)
            let field=NSTextField(string:String(format:"%.3f",value.1)); field.frame=NSRect(x:165,y:278-i*34,width:245,height:24); field.setAccessibilityLabel(value.0); form.addSubview(field); fields.append(field)
        }
        // Methods: smart, patch, solid with per-frame bottom colour, solid with a manual colour.
        let methods=[L("智能修补（只替换文字笔画）"),L("整块修补（用周围画面填满）"),L("纯色 · 自动取底边颜色"),L("纯色 · 手动颜色")]
        let methodTitle=label(L("处理方式"),size:12); methodTitle.frame=NSRect(x:0,y:60,width:155,height:24); form.addSubview(methodTitle)
        let color=NSColorWell(frame:NSRect(x:165,y:18,width:245,height:28)); color.color=original.color?.ns ?? NSColor(srgbRed:0.09,green:0.15,blue:0.55,alpha:1); form.addSubview(color)
        // The colour well only matters for a manual solid fill.
        let method=ActionPopUp(frame:NSRect(x:165,y:57,width:245,height:28),items:methods) {}
        method.actionBlock={ [weak method] in color.isEnabled=method?.indexOfSelectedItem == 3 }
        method.setAccessibilityLabel(L("处理方式")); form.addSubview(method)
        switch original.fillMode { case .smart: method.selectItem(at:0); case .patch: method.selectItem(at:1); case .solid: method.selectItem(at:original.color == nil ? 2 : 3) }
        color.isEnabled=method.indexOfSelectedItem == 3
        let title=label(L("手动背景色"),size:12); title.frame=NSRect(x:0,y:20,width:155,height:24); form.addSubview(title)
        alert.accessoryView=form; alert.addButton(withTitle:isNew ? L("去字") : L("应用")); alert.addButton(withTitle:L("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let numbers=fields.compactMap{Double($0.stringValue)}
        guard numbers.count == 6,numbers.allSatisfy({$0.isFinite && abs($0)<1e9}),numbers[4]>=0,numbers[5]<=Double(clip.duration)/1000 else { showError(SubtitleError.invalid(L("请输入有效坐标和片段内时间"))); return }
        var region=original
        region.x=numbers[0]/100; region.y=numbers[1]/100; region.width=numbers[2]/100; region.height=numbers[3]/100
        region.sourceStart=clip.sourceStart+Int64(numbers[4]*1000); region.sourceEnd=clip.sourceStart+Int64(numbers[5]*1000)
        var manual=RGBA(color.color); manual.a=1
        switch method.indexOfSelectedItem {
        case 0: region.fill = .smart
        case 1: region.fill = .patch
        case 2: region.fill = .solid; region.color=nil
        default: region.fill = .solid; region.color=manual
        }
        var regions=clip.eraseRegions ?? []
        if let j=regions.firstIndex(where:{$0.id == region.id}) { regions[j]=region } else { regions.append(region) }
        // This edit changes only appearance: preserve all existing subtitle boundaries and IDs.
        let next: Project
        do { next=try replacingEraseRegions(regions,of:clip) } catch { showError(error); return }
        commit(next,name:isNew ? L("添加区域去字") : L("修改区域去字"))
        if project == next { cancelRegionErase(); statusLabel.stringValue=L("已去除选区文字 · ⌘Z 撤销；视频剪辑菜单可管理去字区域") }
    }
    @objc func manageEraseRegions() {
        guard !busy,let clip=targetClip else { return }
        let regions=clip.eraseRegions ?? []
        guard !regions.isEmpty else { statusLabel.stringValue=L("此视频片段暂无去字区域，点击「区域去字」开始框选"); return }
        pauseForEditing()
        let alert=NSAlert(); alert.messageText=L("管理去字区域")
        let choice=NSPopUpButton(frame:NSRect(x:0,y:0,width:420,height:28))
        func kind(_ r: VideoEraseRegion) -> String { switch r.fillMode { case .smart: return L("智能修补"); case .patch: return L("整块修补"); case .solid: return r.color == nil ? L("自动背景色") : L("手动背景色") } }
        for (i,r) in regions.enumerated() { choice.addItem(withTitle:L("区域 {0} · {1} · {2}–{3} 秒", [String(describing: i+1), kind(r), String(describing: String(format:"%.2f",Double(r.sourceStart-clip.sourceStart)/1000)), String(describing: String(format:"%.2f",Double(r.sourceEnd-clip.sourceStart)/1000))])) }
        alert.accessoryView=choice; alert.addButton(withTitle:L("编辑")); alert.addButton(withTitle:L("删除区域")); alert.addButton(withTitle:L("取消"))
        let response=alert.runModal(),region=regions[max(0,choice.indexOfSelectedItem)]
        if response == .alertFirstButtonReturn { editEraseRegion(region,clip:clip,isNew:false) }
        else if response == .alertSecondButtonReturn {
            do { commit(try replacingEraseRegions(regions.filter { $0.id != region.id },of:clip),name:L("删除去字区域")) } catch { showError(error) }
        }
    }
}

/// Normalized bottom-left coordinates match the video overlay, including letterboxing.
enum RegionColorSampler {
    static func sample(_ image: CIImage, at point: CGPoint) -> RGBA {
        let extent=image.extent
        let x=extent.minX+min(extent.width-1,max(0,floor(point.x*extent.width)))
        let y=extent.minY+min(extent.height-1,max(0,floor(point.y*extent.height)))
        var pixel=[UInt8](repeating:0,count:4)
        CIContext().render(image,toBitmap:&pixel,rowBytes:4,bounds:CGRect(x:x,y:y,width:1,height:1),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
        return RGBA(Double(pixel[0])/255,Double(pixel[1])/255,Double(pixel[2])/255,1)
    }
}
