import AppKit
import AVFoundation
import SubtitleCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var pendingURL: URL?
    let editor=EditorController()
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance=NSAppearance(named:.darkAqua)
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:1440,height:900),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.delegate=self
        window.title=L("字幕工坊 · Video Éditeur"); window.minSize=NSSize(width:1140,height:760); window.contentViewController=editor; window.center(); window.makeKeyAndOrderFront(nil)
        let main=NSMenu()
        func menu(_ title: String) -> NSMenu { let item=NSMenuItem(); item.title=title; let submenu=NSMenu(title:title); item.submenu=submenu; main.addItem(item); return submenu }
        func item(_ menu: NSMenu,_ title: String,_ action: Selector,_ key: String,_ target: AnyObject?,shift: Bool=false) { let i=NSMenuItem(title:title,action:action,keyEquivalent:key); i.target=target; if shift { i.keyEquivalentModifierMask=[.command,.shift] }; menu.addItem(i) }
        let app=menu(L("字幕工坊")); item(app,L("设置…"),#selector(EditorController.showSettings),",",editor); app.addItem(.separator()); item(app,L("退出字幕工坊"),#selector(NSApplication.terminate(_:)),"q",NSApp)
        let languageItem=NSMenuItem(title:L("界面语言"),action:nil,keyEquivalent:"")
        let languageMenu=NSMenu(title:L("界面语言")); languageItem.submenu=languageMenu; app.addItem(languageItem)
        for (title,code) in [("中文","zh"),("English","en")] {
            let choice=NSMenuItem(title:title,action:#selector(changeInterfaceLanguage(_:)),keyEquivalent:""); choice.target=self; choice.representedObject=code
            choice.state=InterfaceLanguage.preferred.rawValue == code ? .on : .off; languageMenu.addItem(choice)
        }
        let file=menu(L("文件")); item(file,L("新建工程"),#selector(EditorController.newProject),"n",editor); item(file,L("导入视频…"),#selector(EditorController.importVideo),"o",editor); item(file,L("打开工程…"),#selector(EditorController.chooseProject),"o",editor,shift:true); item(file,L("保存工程…"),#selector(EditorController.saveProject),"s",editor)
        let edit=menu(L("编辑")); item(edit,L("撤销"),#selector(EditorController.undoAction),"z",editor); item(edit,L("重做"),#selector(EditorController.redoAction),"z",editor,shift:true)
        edit.addItem(.separator()); item(edit,L("剪切"),#selector(NSText.cut(_:)),"x",nil); item(edit,L("复制"),#selector(NSText.copy(_:)),"c",nil); item(edit,L("粘贴"),#selector(NSText.paste(_:)),"v",nil); item(edit,L("全选"),#selector(NSText.selectAll(_:)),"a",nil)
        let clips=menu(L("视频剪辑"))
        item(clips,L("添加素材…"),#selector(EditorController.appendVideos),"i",editor)
        item(clips,L("框选区域去字"),#selector(EditorController.beginRegionErase),"",editor)
        item(clips,L("管理去字区域…"),#selector(EditorController.manageEraseRegions),"",editor)
        item(clips,L("裁剪与特效…"),#selector(EditorController.editSelectedVideo),"e",editor)
        item(clips,L("在播放头分割素材"),#selector(EditorController.splitSelectedVideo),"b",editor)
        item(clips,L("视频片段前移"),#selector(EditorController.moveVideoEarlier),"",editor)
        item(clips,L("视频片段后移"),#selector(EditorController.moveVideoLater),"",editor)
        item(clips,L("删除素材片段"),#selector(EditorController.deleteSelectedVideo),"",editor)
        let playback=menu(L("播放")); item(playback,L("播放 / 暂停（空格）"),#selector(EditorController.togglePlay),"",editor)
        let windowMenu=menu(L("窗口")); item(windowMenu,L("最小化"),#selector(NSWindow.miniaturize(_:)),"m",nil); NSApp.windowsMenu=windowMenu
        NSApp.mainMenu=main; NSApp.activate(ignoringOtherApps:true)
        if let url=pendingURL { DispatchQueue.main.async { self.editor.openProject(url) }; pendingURL=nil }
    }
    @objc func changeInterfaceLanguage(_ sender: NSMenuItem) {
        guard let code=sender.representedObject as? String else { return }
        UserDefaults.standard.set(code,forKey:InterfaceLanguage.preferenceKey)
        for item in sender.menu?.items ?? [] { item.state=item === sender ? .on : .off }
        let alert=NSAlert(); alert.messageText=L("语言设置已保存"); alert.informativeText="语言更改将在下次启动时生效。\nRestart the app to apply the language change."; alert.addButton(withTitle:L("好")); alert.runModal()
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url=urls.first else { return }; if window != nil { editor.openProject(url) } else { pendingURL=url }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(sender)
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if editor.busy {
            let alert=NSAlert(); alert.messageText=L("任务正在进行"); alert.informativeText=L("退出会取消当前任务，已完成字幕仍会保存。"); alert.addButton(withTitle:L("取消任务并退出")); alert.addButton(withTitle:L("继续工作"))
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        guard editor.confirmSaveBeforeClosing() else { return .terminateCancel }
        editor.generation?.cancel(); editor.exporter?.cancel()
        editor.autosave?.cancel()
        editor.persistNow(); return .terminateNow
    }
}

// CLI smoke-test hooks exercise the same renderer, exporter and generation pipeline as the app.
if CommandLine.arguments.contains("--check-srt-output") {
    do { try runSubtitleFileOutputChecks(); exit(0) } catch { fputs("\(error)\n",stderr); exit(1) }
} else if CommandLine.arguments.contains("--check-timeline-file-drop") {
    _=NSApplication.shared
    do { try runTimelineFileDropChecks(); exit(0) } catch { fputs("\(error)\n",stderr); exit(1) }
} else if CommandLine.arguments.contains("--check-multilingual") {
    _=NSApplication.shared
    do { try runMultilingualChecks(); exit(0) } catch { fputs("\(error)\n",stderr); exit(1) }
} else if CommandLine.arguments.contains("--check-codex-path") {
    do { try runCodexPathChecks(); exit(0) } catch { fputs("\(error)\n",stderr); exit(1) }
} else if CommandLine.arguments.contains("--check-close") {
    _=NSApplication.shared
    do { try runCloseChecks(); exit(0) } catch { fputs("\(error)\n",stderr); exit(1) }
} else if CommandLine.arguments.contains("--check-startup") {
    _=NSApplication.shared
    let editor=EditorController()
    _=editor.view
    RunLoop.current.run(until:Date().addingTimeInterval(0.2))
    guard editor.project == Project(), editor.projectURL == nil,
          editor.retryDirectory == nil, editor.player.currentItem == nil,
          editor.timeline.subtitleRowCount == 0, editor.selected == nil else {
        fputs("Startup did not create an empty project\n",stderr); exit(1)
    }
    print("STARTUP_OK blank project, no media, no retry, hidden subtitle rows")
    exit(0)
} else if CommandLine.arguments.count >= 3,CommandLine.arguments[1] == "--check-music" {
    do { try runMusicChecks(directory:URL(fileURLWithPath:CommandLine.arguments[2])); exit(0) } catch { print(error); exit(1) }
} else if CommandLine.arguments.contains("--check-region-color") {
    do { try runRegionColorChecks(); exit(0) } catch { print(error); exit(1) }
} else if CommandLine.arguments.contains("--check-subtitle-alignment") {
    do { try runSubtitleAlignmentChecks(); exit(0) } catch { print(error); exit(1) }
} else if CommandLine.arguments.count >= 4,CommandLine.arguments[1] == "--smoke-erase" {
    _=NSApplication.shared
    do { try runRegionEraseChecks(source:URL(fileURLWithPath:CommandLine.arguments[2]),destination:URL(fileURLWithPath:CommandLine.arguments[3])) } catch { fputs("\(error)\n",stderr); exit(1) }
 } else if CommandLine.arguments.count >= 3,CommandLine.arguments[1] == "--smoke-multitrack" {
    _=NSApplication.shared
    do { try runMultiTrackChecks(directory:URL(fileURLWithPath:CommandLine.arguments[2])) } catch { fputs("\(error)\n",stderr); exit(1) }
} else if CommandLine.arguments.count >= 3,CommandLine.arguments[1] == "--smoke-editing" {
    _=NSApplication.shared
    do { try runEditingChecks(directory:URL(fileURLWithPath:CommandLine.arguments[2])) } catch { fputs("\(error)\n",stderr); exit(1) }
} else if CommandLine.arguments.count >= 4,CommandLine.arguments[1] == "--smoke-services" {
    _=NSApplication.shared
    do { try runServiceChecks(video:URL(fileURLWithPath:CommandLine.arguments[2]),directory:URL(fileURLWithPath:CommandLine.arguments[3])) } catch { fputs("\(error)\n",stderr); exit(1) }
} else if CommandLine.arguments.count >= 4,["--smoke-export","--smoke-export-hidden"].contains(CommandLine.arguments[1]) {
    let source=URL(fileURLWithPath:CommandLine.arguments[2]),destination=URL(fileURLWithPath:CommandLine.arguments[3])
    let asset=AVURLAsset(url:source); var p=Project(); p.videoPath=source.path; p.duration=Int64(CMTimeGetSeconds(asset.duration)*1000)
    p.cues=[Cue(language:.fr,start:0,end:min(1500,p.duration),text:"Bonjour ! Une nouvelle histoire."),Cue(language:.zh,start:0,end:min(1500,p.duration),text:L("你好 一段新的故事")),Cue(language:.zh,start:min(1500,p.duration),end:p.duration,text:L("让每一句话 都被看见"))].filter{$0.end>$0.start}
    if CommandLine.arguments.count >= 5 { p.playbackRate=Double(CommandLine.arguments[4]) }
    if CommandLine.arguments[1] == "--smoke-export-hidden" { p.hideVideoTrack=true; p.cues=[] }
    let app=NSApplication.shared; _=app
    do { try VideoExporter().run(project:p,destination:destination) { _ in }; print("EXPORT_OK \(destination.path)") } catch { fputs("\(error)\n",stderr); exit(1) }
} else if CommandLine.arguments.count >= 4,CommandLine.arguments[1] == "--smoke-generate" {
    let source=URL(fileURLWithPath:CommandLine.arguments[2]),directory=URL(fileURLWithPath:CommandLine.arguments[3])
    do {
        let duration=Int64(CMTimeGetSeconds(AVURLAsset(url:source).duration)*1000)
        let cues=try GenerationJob(directory:directory).run(video:source,duration:duration,status:{print($0)},partial:{print("PARTIAL \($0.count)")})
        print("GENERATION_OK \(cues.count)")
    } catch { fputs("\(error)\n",stderr); exit(1) }
} else {
    let app=NSApplication.shared; let delegate=AppDelegate(); app.delegate=delegate; app.setActivationPolicy(.regular); app.run()
}
