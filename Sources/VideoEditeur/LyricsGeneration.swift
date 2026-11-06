import AppKit
import UniformTypeIdentifiers
import SubtitleCore

/// Transcription of a whole audio file; LRC export trims it to the clip's current source range.
struct AudioLyrics {
    var path: String
    var language: Language
    var cues: [Cue]
}

extension EditorController {
    /// A project holding only one audio clip (no video) generates lyrics instead of subtitles.
    var lyricsAudio: BackgroundMusic? {
        guard project.videoPath.isEmpty,project.allClips.isEmpty,project.music.count == 1 else { return nil }
        return project.music.first
    }
    var hasLyricsForAudio: Bool {
        guard let music=lyricsAudio,let lyrics=audioLyrics,lyrics.path == music.path else { return false }
        return !LRC.clipped(lyrics.cues,start:music.sourceStart,end:music.sourceEnd).isEmpty
    }

    func chooseAudioLanguage() -> Language? {
        let alert=NSAlert(); alert.messageText=L("生成字幕")
        alert.informativeText=L("选择音频语言；转写完成后可导出 LRC 歌词文件。")
        let box=NSView(frame:NSRect(x:0,y:0,width:430,height:40))
        let text=label(L("音频语言"),size:12); text.frame=NSRect(x:0,y:8,width:135,height:24); box.addSubview(text)
        let choice=NSPopUpButton(frame:NSRect(x:140,y:4,width:270,height:28))
        let languages: [Language]=[.fr,.en,.zh]
        choice.addItems(withTitles:languages.map(\.title))
        choice.selectItem(at:languages.firstIndex(of:audioLyrics?.language ?? project.generationLanguages?.source ?? .fr) ?? 0)
        box.addSubview(choice); alert.accessoryView=box
        alert.addButton(withTitle:L("生成")); alert.addButton(withTitle:L("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return languages[max(0,choice.indexOfSelectedItem)]
    }

    func generateLyrics(_ music: BackgroundMusic) {
        guard !busy,let language=chooseAudioLanguage() else { return }
        do { try ToolSettings.current.validate() } catch { showError(error); return }
        let job=GenerationJob(languages:GenerationLanguages(source:language,target:language))
        generation=job; player.pause(); setBusy(true)
        let audio=URL(fileURLWithPath:music.path)
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            do {
                let cues=try job.run(video:audio,duration:music.sourceDuration,status:{ message in
                    DispatchQueue.main.async { [weak self] in guard let self,self.generation === job else { return }; self.statusLabel.stringValue=message }
                },partial:{ _ in })
                guard !job.runner.isCancelled else { throw SubtitleError.invalid(L("任务已取消")) }
                DispatchQueue.main.async { [weak self] in
                    guard let self,self.generation === job else { return }
                    self.generation=nil; self.audioLyrics=AudioLyrics(path:music.path,language:language,cues:cues); self.setBusy(false)
                    guard let current=self.lyricsAudio,self.hasLyricsForAudio else { self.statusLabel.stringValue=L("所选音频范围内未识别到语音"); return }
                    self.statusLabel.stringValue=L("字幕已生成 · {0} 条", [String(LRC.clipped(cues,start:current.sourceStart,end:current.sourceEnd).count)])
                    self.exportLyrics(current)
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self,self.generation === job else { return }
                    self.generation=nil; self.setBusy(false)
                    self.statusLabel.stringValue=L("生成已停止")
                    if !job.runner.isCancelled { self.showError(error) }
                }
            }
        }
    }

    func exportLyrics(_ music: BackgroundMusic) {
        guard let lyrics=audioLyrics,lyrics.path == music.path else { statusLabel.stringValue=L("请先生成字幕"); return }
        let cues=LRC.clipped(lyrics.cues,start:music.sourceStart,end:music.sourceEnd)
        guard !cues.isEmpty else { statusLabel.stringValue=L("所选音频范围内未识别到语音"); return }
        let source=URL(fileURLWithPath:music.path)
        let stem=source.deletingPathExtension().lastPathComponent
        let panel=NSSavePanel(); panel.allowedContentTypes=[UTType(filenameExtension:"lrc") ?? .plainText]
        panel.nameFieldStringValue=(stem.isEmpty ? "Lyrics" : stem)+".lrc"; panel.title=L("导出 LRC 歌词")
        panel.directoryURL=UserDefaults.standard.string(forKey:"editor.videoOutputDirectory").map { URL(fileURLWithPath:$0,isDirectory:true) } ?? source.deletingLastPathComponent()
        guard panel.runModal() == .OK,let url=panel.url else { return }
        guard url.standardizedFileURL != source.standardizedFileURL else { showError(SubtitleError.invalid(L("不能覆盖源音频文件"))); return }
        do {
            try LRC.encode(cues,title:stem,length:music.duration).write(to:url,atomically:true,encoding:.utf8)
            UserDefaults.standard.set(url.deletingLastPathComponent().path,forKey:"editor.videoOutputDirectory")
            statusLabel.stringValue=L("导出完成：{0}", [url.lastPathComponent]); NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch { showError(error) }
    }
}
