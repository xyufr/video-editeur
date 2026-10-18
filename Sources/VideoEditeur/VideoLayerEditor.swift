import AppKit
import SubtitleCore

extension EditorController {
    func editVideoTrack(_ id: UUID,_ action: Int) {
        guard !busy,let i=project.layerTracks.firstIndex(where:{$0[0].trackIdentifier == id}),!project.layerTracks[i][0].isLocked else { return }
        var tracks=project.layerTracks
        if action == 0 { tracks.remove(at:i) }
        else {
            let j=i+(action == 1 ? -1 : 1)
            guard tracks.indices.contains(j),!tracks[j][0].isLocked else { return }; tracks.swapAt(i,j)
        }
        pauseForEditing()
        do { commit(try project.replacingLayers(tracks.flatMap{$0}),name:action == 0 ? L("删除轨道") : L("调整视频顺序")) } catch { showError(error) }
    }
    func toggleLayerTrackControl(_ id: UUID,_ control: Int) {
        guard !busy,let track=project.layers.first(where:{$0.trackIdentifier == id}) else { return }
        pauseForEditing(); var next=project
        for i in next.layers.indices where next.layers[i].trackIdentifier == id {
            switch control {
            case 0: next.videoLayers?[i].locked = !track.isLocked
            case 1: next.videoLayers?[i].hidden = !track.hidden
            case 2: next.videoLayers?[i].muted = !track.muted
            default: return
            }
        }
        commit(next,name:[L("锁定视频轨道"),L("隐藏视频轨道"),L("静音原视频")][control])
    }
    var targetLayer: VideoLayer? { project.layers.first{$0.id == selectedClip} }
    /// `canvas` also changes the project-wide frame shape in the same undo step.
    func updateVideoLayer(_ layer: VideoLayer,canvas: CanvasAspect?=nil,original: VideoLayer?=nil) {
        guard !busy,let i=project.layers.firstIndex(where:{$0.id == layer.id}),!project.layers[i].isLocked else { return }
        pauseForEditing()
        do {
            var next=try project.replacingLayer(layer)
            if let canvas { try applyCanvas(canvas,to:&next,clip:layer.clip,original:(original ?? layer).clip) }
            commit(next,name:L("编辑视频轨道")); refresh()
        } catch { showError(error); refresh() }
    }
    func editVideoLayer(_ original: VideoLayer) {
        guard !original.isLocked else { return }; pauseForEditing()
        let alert=NSAlert(); alert.messageText=L("视频剪辑与特效")
        alert.informativeText=L("片段按绝对时间放置；同轨片段不能重叠，上方轨道覆盖下方。")
        let values:[(String,Double)]=[(L("开始 · 秒"),Double(original.start)/1000),(L("源视频起点"),Double(original.clip.sourceStart)/1000),(L("源视频终点"),Double(original.clip.sourceEnd)/1000),(L("淡入"),Double(original.clip.effects.fadeIn)/1000),(L("淡出"),Double(original.clip.effects.fadeOut)/1000),(L("亮度（-1～1）"),original.clip.effects.brightness),(L("对比度（0～2）"),original.clip.effects.contrast),(L("饱和度（0～2）"),original.clip.effects.saturation)]
        let form=NSView(frame:NSRect(x:0,y:0,width:410,height:300)); var fields:[NSTextField]=[]
        for (i,value) in values.enumerated() {
            let title=label(value.0,size:12); title.frame=NSRect(x:0,y:268-i*36,width:180,height:24); form.addSubview(title)
            let field=NSTextField(string:String(format:"%.3f",value.1)); field.frame=NSRect(x:190,y:268-i*36,width:210,height:24)
            field.setAccessibilityLabel(value.0); form.addSubview(field); fields.append(field)
        }
        let frameControls=FrameControls(adding:form,clip:original.clip,canvas:project.canvas)
        alert.accessoryView=form; alert.addButton(withTitle:L("应用")); alert.addButton(withTitle:L("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let n=fields.compactMap{Double($0.stringValue)}
        guard n.count==8,n.allSatisfy({$0.isFinite && abs($0)<1e6}),let crop=frameControls.selectedCrop else { showError(SubtitleError.invalid(L("请输入有效数值"))); return }
        var layer=original; layer.start=Int64(n[0]*1000); layer.clip.sourceStart=Int64(n[1]*1000); layer.clip.sourceEnd=Int64(n[2]*1000)
        layer.clip.effects.fadeIn=Int64(n[3]*1000); layer.clip.effects.fadeOut=Int64(n[4]*1000)
        layer.clip.effects.brightness=n[5]; layer.clip.effects.contrast=n[6]; layer.clip.effects.saturation=n[7]
        layer.clip.frame=frameControls.selectedFrame; layer.clip.crop=crop
        updateVideoLayer(layer,canvas:frameControls.selectedCanvas,original:original)
    }
    func cutVideoLayer(_ layer: VideoLayer,removeBefore: Bool?=nil) {
        guard !busy,!layer.isLocked else { return }; pauseForEditing()
        do { commit(try project.cuttingLayer(layer.id,at:current,removeBefore:removeBefore),name:L("编辑视频轨道")) } catch { showError(error) }
    }
}
