import AppKit
import AVFoundation
import UniformTypeIdentifiers
import SubtitleCore

struct LocalVideoEntry {
    let url: URL
    let duration: Int64
    let image: CGImage?
}
final class LocalVideoScan {
    private let lock=NSLock()
    private var stopped=false
    func cancel() { lock.lock(); stopped=true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func videoURLs(in directory: URL) throws -> [URL] {
        _ = try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)
        let keys: [URLResourceKey]=[.isRegularFileKey,.isSymbolicLinkKey,.contentTypeKey]
        guard let entries=FileManager.default.enumerator(at:directory,includingPropertiesForKeys:keys,options:[.skipsHiddenFiles,.skipsPackageDescendants]) else { return [] }
        var urls:[URL]=[]
        for case let url as URL in entries {
            if isCancelled { return [] }
            guard let values=try? url.resourceValues(forKeys:Set(keys)),values.isSymbolicLink != true,values.isRegularFile == true,values.contentType?.conforms(to:.movie) == true else { continue }
            urls.append(url)
        }
        return urls.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
    func scan(_ directory: URL) throws -> [LocalVideoEntry] {
        var result:[LocalVideoEntry]=[]
        for url in try videoURLs(in:directory) {
            if isCancelled { break }
            autoreleasepool {
                let asset=AVURLAsset(url:url)
                guard !asset.tracks(withMediaType:.video).isEmpty else { return }
                let seconds=CMTimeGetSeconds(asset.duration)
                guard seconds.isFinite,seconds>0,seconds<1e9 else { return }
                let generator=AVAssetImageGenerator(asset:asset)
                generator.appliesPreferredTrackTransform=true; generator.maximumSize=CGSize(width:240,height:160)
                let image=try? generator.copyCGImage(at:.zero,actualTime:nil)
                result.append(LocalVideoEntry(url:url,duration:Int64(seconds*1000),image:image))
            }
        }
        return result
    }
}
extension EditorController {
    func chooseLocalLibraryDirectory() {
        let panel=NSOpenPanel(); panel.title=L("选择素材库目录")
        panel.canChooseFiles=false; panel.canChooseDirectories=true; panel.allowsMultipleSelection=false
        guard panel.runModal() == .OK,let url=panel.url else { return }
        UserDefaults.standard.set(url.path,forKey:"editor.localLibraryDirectory")
        reloadLocalLibrary()
    }
    func reloadLocalLibrary() {
        localLibraryJob?.cancel(); localLibraryJob=nil; localLibraryEntries=[]
        guard let path=UserDefaults.standard.string(forKey:"editor.localLibraryDirectory") else {
            localLibraryMessage=L("请在设置中选择本地素材库目录")
            if showsLocalLibrary { refreshMediaGrid() }; return
        }
        let job=LocalVideoScan(); localLibraryJob=job
        localLibraryMessage=L("正在递归扫描视频…")
        if showsLocalLibrary { refreshMediaGrid() }
        DispatchQueue.global(qos:.utility).async { [weak self] in
            do {
                let entries=try job.scan(URL(fileURLWithPath:path,isDirectory:true))
                DispatchQueue.main.async {
                    guard let self,self.localLibraryJob === job,!job.isCancelled else { return }
                    self.localLibraryEntries=entries; self.localLibraryMessage=L("此目录及子目录中没有可读取的视频")
                    if self.showsLocalLibrary { self.refreshMediaGrid() }
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self,self.localLibraryJob === job,!job.isCancelled else { return }
                    self.localLibraryMessage=L("无法读取素材库目录：{0}",[error.localizedDescription])
                    if self.showsLocalLibrary { self.refreshMediaGrid() }
                }
            }
        }
    }
    @objc func localVideoClicked(_ sender: MediaCard) {
        selectedLocalVideo=sender.fileURL; updateMediaGridSelection()
    }
    func refreshLocalLibraryGrid() {
        for view in mediaGrid.subviews { view.removeFromSuperview() }; mediaGrid.cards=[]
        let query=mediaSearch.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        for entry in localLibraryEntries where query.isEmpty || entry.url.lastPathComponent.localizedCaseInsensitiveContains(query) {
            let card=MediaCard(); card.fileURL=entry.url; card.filename=entry.url.lastPathComponent
            card.identifier=NSUserInterfaceItemIdentifier(entry.url.path)
            card.duration=String(format:"%02lld:%02lld",entry.duration/60000,(entry.duration/1000)%60)
            card.thumbnail=entry.image.map { NSImage(cgImage:$0,size:.zero) }
            card.isAdded=project.allClips.contains { URL(fileURLWithPath:$0.path).standardizedFileURL == entry.url.standardizedFileURL }
            card.isBordered=false; card.title=card.filename; card.toolTip=entry.url.path
            card.setAccessibilityLabel(card.filename+", "+card.duration)
            card.isEnabled = !busy; card.target=self; card.action=#selector(localVideoClicked(_:))
            card.doubleClick={[weak self] in _ = self?.appendMedia([entry.url]) }
            mediaGrid.cards.append(card); mediaGrid.addSubview(card)
        }
        if mediaGrid.cards.isEmpty {
            let message=label(query.isEmpty ? localLibraryMessage : L("没有匹配的视频"),size:12,color:muted)
            message.lineBreakMode = .byWordWrapping; message.maximumNumberOfLines=4
            message.frame=CGRect(x:8,y:10,width:max(100,tableScroll.contentSize.width-16),height:90)
            mediaGrid.addSubview(message)
        }
        updateMediaGridSelection()
        mediaGrid.arrange(width:tableScroll.contentSize.width,minimumHeight:tableScroll.contentSize.height)
    }
}
