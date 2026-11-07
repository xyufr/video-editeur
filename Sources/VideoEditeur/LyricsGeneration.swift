import AppKit
import AVFoundation
import UniformTypeIdentifiers
import SubtitleCore

/// Audio-only projects: lyrics are ordinary subtitle cues on the timeline, timed against the audio clips,
/// so they can be played back and corrected before **Export** writes an LRC file.
extension EditorController {
    /// A video or an audio-only timeline that can play, generate subtitles and export.
    var hasTimelineMedia: Bool { !project.videoPath.isEmpty || project.isAudioOnly }
    var lyricsLanguages: [Language] {
        Language.allCases.filter { language in project.cues.contains { $0.trackID == nil && $0.language == language } }
    }

    func chooseAudioLanguage() -> GenerationOptions? {
        let alert=NSAlert(); alert.messageText=L("生成字幕")
        alert.informativeText=L("选择音频语言；字幕放在时间轴上供检查修改，点击导出生成 LRC 歌词文件。")+"\n"+L("可选：选择歌词 TXT（每行一句），按转写时间把每行放到时间轴对应位置。")
        let box=NSView(frame:NSRect(x:0,y:0,width:430,height:80))
        let text=label(L("音频语言"),size:12); text.frame=NSRect(x:0,y:48,width:135,height:24); box.addSubview(text)
        let choice=NSPopUpButton(frame:NSRect(x:140,y:44,width:270,height:28))
        let lyricsTitle=label(L("歌词文本"),size:12); lyricsTitle.frame=NSRect(x:0,y:8,width:135,height:24); box.addSubview(lyricsTitle)
        let fileName=NSTextField(labelWithString:L("未选择（仅转写）")); fileName.lineBreakMode = .byTruncatingMiddle
        fileName.textColor = .secondaryLabelColor; fileName.frame=NSRect(x:140,y:8,width:112,height:20); box.addSubview(fileName)
        var lyrics: [String]?
        let clear=ActionButton(L("清除"),action:{}); clear.frame=NSRect(x:352,y:4,width:58,height:28); clear.isHidden=true
        clear.actionBlock={ [weak clear] in lyrics=nil; fileName.stringValue=L("未选择（仅转写）"); clear?.isHidden=true }
        let pick=ActionButton(L("选择 TXT…"),action:{ [weak self] in
            let panel=NSOpenPanel(); panel.allowedContentTypes=[.plainText]; panel.allowsMultipleSelection=false
            panel.directoryURL=self?.project.music.first.map { URL(fileURLWithPath:$0.path).deletingLastPathComponent() }
            guard panel.runModal() == .OK,let url=panel.url else { return }
            do {
                var encoding=String.Encoding.utf8
                let content=try (try? String(contentsOf:url,encoding:.utf8)) ?? String(contentsOf:url,usedEncoding:&encoding)
                let lines=LyricAligner.lines(fromText:content)
                guard !lines.isEmpty else { throw SubtitleError.invalid(L("歌词文本为空")) }
                lyrics=lines; fileName.stringValue=L("{0} · {1} 行", [url.lastPathComponent, String(lines.count)]); clear.isHidden=false
            } catch { self?.showError(error) }
        })
        pick.frame=NSRect(x:252,y:4,width:98,height:28); box.addSubview(pick); box.addSubview(clear)
        let languages: [Language]=[.fr,.en,.zh]
        choice.addItems(withTitles:languages.map(\.title))
        choice.selectItem(at:languages.firstIndex(of:project.generationLanguages?.source ?? .fr) ?? 0)
        box.addSubview(choice); alert.accessoryView=box
        alert.addButton(withTitle:L("生成")); alert.addButton(withTitle:L("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let language=languages[max(0,choice.indexOfSelectedItem)]
        return GenerationOptions(languages:GenerationLanguages(source:language,target:language),filesOnly:false,lyrics:lyrics)
    }

    /// Audio clips at their timeline positions, so transcription times match the timeline.
    func audioTimeline(_ project: Project, useClipVolume: Bool) throws -> (AVMutableComposition,AVMutableAudioMix) {
        let composition=AVMutableComposition(); var parameters: [AVMutableAudioMixInputParameters]=[]
        func time(_ ms: Int64) -> CMTime { CMTime(value:ms,timescale:1000) }
        for music in project.music {
            let source=AVURLAsset(url:URL(fileURLWithPath:music.path))
            guard let track=source.tracks(withMediaType:.audio).first,
                  let target=composition.addMutableTrack(withMediaType:.audio,preferredTrackID:kCMPersistentTrackID_Invalid) else { throw SubtitleError.invalid(L("无法读取背景音乐：{0}",[music.path])) }
            try target.insertTimeRange(CMTimeRange(start:time(music.sourceStart),duration:time(music.duration)),of:track,at:time(music.start))
            let input=AVMutableAudioMixInputParameters(track:target); input.setVolume(useClipVolume ? Float(music.volume) : 1,at:.zero); parameters.append(input)
        }
        let mix=AVMutableAudioMix(); mix.inputParameters=parameters
        return (composition,mix)
    }
    func audioOnlyPlayerItem(_ project: Project) throws -> AVPlayerItem {
        let (composition,mix)=try audioTimeline(project,useClipVolume:true)
        let item=AVPlayerItem(asset:composition); item.audioMix=mix; return item
    }
    func audioTranscriptionInput(project: Project, job: GenerationJob) throws -> URL {
        try FileManager.default.createDirectory(at:job.directory,withIntermediateDirectories:true)
        let destination=job.directory.appendingPathComponent("timeline-audio.m4a")
        if FileManager.default.fileExists(atPath:destination.path) { return destination }
        DispatchQueue.main.async { [weak self] in self?.statusLabel.stringValue=L("正在混合剪辑音频…") }
        let (composition,mix)=try audioTimeline(project,useClipVolume:false)
        guard let session=AVAssetExportSession(asset:composition,presetName:AVAssetExportPresetAppleM4A) else { throw SubtitleError.invalid(L("无法创建剪辑音频")) }
        let temporary=job.directory.appendingPathComponent("timeline-audio-partial.m4a")
        try? FileManager.default.removeItem(at:temporary)
        defer { try? FileManager.default.removeItem(at:temporary) }
        session.outputURL=temporary; session.outputFileType = .m4a; session.audioMix=mix
        let done=DispatchSemaphore(value:0); session.exportAsynchronously{done.signal()}
        while done.wait(timeout:.now()+0.1) == .timedOut {
            if job.runner.isCancelled { session.cancelExport(); throw SubtitleError.invalid(L("音频准备已取消")) }
        }
        guard !job.runner.isCancelled,session.status == .completed else { throw session.error ?? SubtitleError.invalid(L("音频准备已取消或失败")) }
        try FileManager.default.moveItem(at:temporary,to:destination); return destination
    }

    /// Default LRC name: audio file name plus the lyrics language, e.g. `Song.fr.lrc`.
    static func lyricsFileName(stem: String, language: Language) -> String {
        (stem.isEmpty ? "Lyrics" : stem)+"."+language.rawValue+".lrc"
    }
    /// Writes the current timeline cues of one language; times start at the first audio clip.
    func exportLyrics() {
        let languages=lyricsLanguages
        guard !languages.isEmpty,let first=project.music.min(by:{ $0.start < $1.start }) else { statusLabel.stringValue=L("请先生成字幕"); return }
        let origin=first.start
        let source=URL(fileURLWithPath:first.path)
        let stem=source.deletingPathExtension().lastPathComponent
        let panel=NSSavePanel(); panel.allowedContentTypes=[UTType(filenameExtension:"lrc") ?? .plainText]
        panel.title=L("导出 LRC 歌词")
        panel.directoryURL=UserDefaults.standard.string(forKey:"editor.videoOutputDirectory").map { URL(fileURLWithPath:$0,isDirectory:true) } ?? source.deletingLastPathComponent()
        let preferred=project.generationLanguages?.source
        let selected=languages.firstIndex { $0 == preferred } ?? 0
        panel.nameFieldStringValue=Self.lyricsFileName(stem:stem,language:languages[selected])
        let choice=ActionPopUp(frame:NSRect(x:0,y:0,width:220,height:28),items:languages.map(\.title)) {}
        choice.selectItem(at:selected)
        // Switching language renames the suggestion unless the user already typed another name.
        choice.actionBlock={ [weak panel,weak choice] in
            guard let panel,let choice else { return }
            let next=languages[max(0,choice.indexOfSelectedItem)]
            if languages.contains(where:{ panel.nameFieldStringValue == Self.lyricsFileName(stem:stem,language:$0) }) { panel.nameFieldStringValue=Self.lyricsFileName(stem:stem,language:next) }
        }
        if languages.count>1 { panel.accessoryView=choice }
        guard panel.runModal() == .OK,let url=panel.url else { return }
        guard !project.music.contains(where:{ URL(fileURLWithPath:$0.path).standardizedFileURL == url.standardizedFileURL }) else { showError(SubtitleError.invalid(L("不能覆盖源音频文件"))); return }
        let language=languages[max(0,choice.indexOfSelectedItem)]
        let cues=LRC.clipped(project.cues.filter { $0.trackID == nil && $0.language == language },start:origin,end:project.duration)
        do {
            try LRC.encode(cues,title:stem,length:project.duration-origin).write(to:url,atomically:true,encoding:.utf8)
            UserDefaults.standard.set(url.deletingLastPathComponent().path,forKey:"editor.videoOutputDirectory")
            statusLabel.stringValue=L("导出完成：{0}", [url.lastPathComponent]); NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch { showError(error) }
    }
}

/// `--check-audio-lyrics audio-file`: a single audio import gives a playable audio-only timeline,
/// a timeline-aligned transcription input, and keeps lyric cues through a trim.
func runAudioLyricsChecks(audio: URL) throws {
    let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:dir) }
    let editor=EditorController(); _=editor.view
    guard editor.appendMedia([audio]),editor.project.isAudioOnly,let music=editor.project.music.first else { throw SubtitleError.invalid("Audio import did not create an audio-only project") }
    guard editor.project.duration == music.duration,music.volume == 1,editor.player.currentItem != nil,
          editor.hasTimelineMedia,editor.generateButton.isEnabled,!editor.exportButton.isEnabled else { throw SubtitleError.invalid("Audio-only timeline, playback or buttons wrong") }
    let input=try editor.prepareTranscriptionInput(project:editor.project,job:GenerationJob(directory:dir))
    let seconds=CMTimeGetSeconds(AVURLAsset(url:input).duration)
    guard abs(seconds*1000-Double(editor.project.duration))<100 else { throw SubtitleError.invalid("Transcription audio length \(seconds)s != timeline") }
    var next=editor.project; next.cues=[Cue(language:.en,start:0,end:music.duration,text:"hello")]
    editor.commit(next,name:"lyrics")
    guard editor.project.cues.count == 1,editor.exportButton.isEnabled,editor.lyricsLanguages == [.en] else { throw SubtitleError.invalid("Lyrics cues not accepted on the audio timeline") }
    next=editor.project; next.backgroundMusic![0].sourceEnd=music.duration/2; editor.commit(next,name:"trim")
    guard editor.project.duration == music.duration/2,editor.project.cues.first?.end == music.duration/2 else { throw SubtitleError.invalid("Trim did not follow the audio length") }
    guard editor.timelineScroll.hasHorizontalScroller else { throw SubtitleError.invalid("Audio-only timeline has no horizontal scroller") }
    let snapshot=FileManager.default.temporaryDirectory.appendingPathComponent("audio-language-dialog-\(InterfaceLanguage.current.rawValue).png")
    DispatchQueue.main.asyncAfter(deadline:.now()+0.2) {
        if let view=NSApp.modalWindow?.contentView,let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) {
            view.cacheDisplay(in:view.bounds,to:bitmap); try? bitmap.representation(using:.png,properties:[:])?.write(to:snapshot)
        }
        NSApp.stopModal(withCode:.alertFirstButtonReturn)
    }
    guard let options=editor.chooseAudioLanguage(),options.lyrics == nil,options.languages.source == options.languages.target else { throw SubtitleError.invalid("Audio language dialog default wrong") }
    print("DIALOG_SNAPSHOT \(snapshot.path)")
    guard EditorController.lyricsFileName(stem:"Nos Plus Belles années",language:.fr) == "Nos Plus Belles années.fr.lrc",EditorController.lyricsFileName(stem:"",language:.zh) == "Lyrics.zh.lrc" else { throw SubtitleError.invalid("LRC default name wrong") }
    print("AUDIO_LYRICS_OK duration \(music.duration) ms, input \(String(format:"%.2f",seconds)) s")
}
