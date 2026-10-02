import AppKit
import SubtitleCore

/// Stage a complete pair in the video output folder; never replace an existing file.
enum SubtitleFileOutput {
    static func outputNames(stem: String, languages: GenerationLanguages) -> [String] {
        languages.source == languages.target
            ? [stem+".source."+languages.source.rawValue+".srt",stem+".target."+languages.target.rawValue+".srt"]
            : [stem+"."+languages.source.rawValue+".srt",stem+"."+languages.target.rawValue+".srt"]
    }
    static func write(cues: [Cue], languages: GenerationLanguages, project: Project, destination: URL) throws -> [URL] {
        let source=cues.filter { $0.trackID == nil && $0.language == languages.source }
        let target=cues.filter { $0.trackID == nil && $0.language == languages.target }
        guard !source.isEmpty,!target.isEmpty else { throw SubtitleError.invalid(L("字幕文件内容不完整")) }
        let rawStem=URL(fileURLWithPath:project.videoPath).deletingPathExtension().lastPathComponent
        let stem=rawStem.isEmpty ? "Subtitles" : rawStem
        let identifier=UUID().uuidString
        let staging=destination.appendingPathComponent(".subtitles-"+identifier,isDirectory:true)
        try FileManager.default.createDirectory(at:staging,withIntermediateDirectories:false)
        defer { try? FileManager.default.removeItem(at:staging) }
        var names=outputNames(stem:stem,languages:languages), suffix=2
        while names.contains(where: { FileManager.default.fileExists(atPath:destination.appendingPathComponent($0).path) }) {
            names=Self.outputNames(stem:stem+"-\(suffix)",languages:languages); suffix += 1
        }
        for (index,items) in [source,target].enumerated() {
            let timed=items.map { cue -> Cue in
                var result=cue
                result.start=Int64((Double(cue.start)/project.speed).rounded())
                result.end=max(result.start+1,Int64((Double(cue.end)/project.speed).rounded()))
                return result
            }
            try SRT.encode(timed).write(to:staging.appendingPathComponent(names[index]),atomically:true,encoding:.utf8)
        }
        var committed: [URL]=[]
        do {
            for name in names {
                let output=destination.appendingPathComponent(name)
                try FileManager.default.moveItem(at:staging.appendingPathComponent(name),to:output)
                committed.append(output)
            }
            return committed
        } catch {
            for url in committed { try? FileManager.default.removeItem(at:url) }
            throw error
        }
    }
}

extension EditorController {
    var videoOutputDirectory: URL {
        if let path=UserDefaults.standard.string(forKey:"editor.videoOutputDirectory") { return URL(fileURLWithPath:path,isDirectory:true) }
        return URL(fileURLWithPath:project.videoPath).deletingLastPathComponent()
    }

    func generateSubtitleFiles(languages: GenerationLanguages) {
        do { try ToolSettings.current.validate() } catch { showError(error); return }
        let destination=videoOutputDirectory
        let snapshot=project
        // This separate cache never feeds partial file-only results into the project.
        let job=GenerationJob(directory:subtitleFileRetry(languages:languages) ?? supportDirectory.appendingPathComponent("Jobs/\(UUID().uuidString)"),languages:languages)
        subtitleFileRetryDirectory=job.directory
        generation=job; player.pause(); setBusy(true)
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            do {
                guard let self else { return }
                let input=try self.prepareTranscriptionInput(project:snapshot,job:job)
                let result=try job.run(video:input,duration:snapshot.duration,status:{ message in
                    DispatchQueue.main.async { [weak self] in guard let self,self.generation === job else { return }; self.statusLabel.stringValue=message }
                },partial:{ _ in })
                guard !job.runner.isCancelled else { throw SubtitleError.invalid(L("任务已取消")) }
                let urls=try SubtitleFileOutput.write(cues:result,languages:languages,project:snapshot,destination:destination)
                DispatchQueue.main.async { [weak self] in
                    guard let self,self.generation === job else { return }
                    self.generation=nil; self.subtitleFileRetryDirectory=nil; self.setBusy(false)
                    self.statusLabel.stringValue=L("字幕文件已保存：{0}",[urls[0].deletingLastPathComponent().path])
                    NSWorkspace.shared.activateFileViewerSelecting(urls)
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self,self.generation === job else { return }
                    self.generation=nil; self.setBusy(false)
                    self.statusLabel.stringValue=L("字幕文件生成已停止，可重新选择文件模式重试")
                    if !job.runner.isCancelled { self.showError(error) }
                }
            }
        }
    }
    private func subtitleFileRetry(languages: GenerationLanguages) -> URL? {
        guard let folder=subtitleFileRetryDirectory,
              let data=try? Data(contentsOf:folder.appendingPathComponent("languages.json")),
              let cached=try? JSONDecoder().decode(GenerationLanguages.self,from:data),cached == languages,
              subtitleFileRetryProject == project else {
            subtitleFileRetryProject=project
            return nil
        }
        return folder
    }
}
