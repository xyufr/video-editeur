import Foundation

public enum Language: String, Codable, CaseIterable { case fr, zh, en
    public var title: String { self == .fr ? L("法语") : (self == .en ? L("英语") : L("中文")) }
}

public struct GenerationLanguages: Codable, Equatable {
    public var source: Language
    public var target: Language
    public init(source: Language = .fr, target: Language = .zh) { self.source=source; self.target=target }
}
public struct RGBA: Codable, Equatable {
    public var r: Double; public var g: Double; public var b: Double; public var a: Double
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r=r; self.g=g; self.b=b; self.a=a }
    public static let white = RGBA(1,1,1), black = RGBA(0,0,0), clear = RGBA(0,0,0,0)
}
public enum SubtitleAlignment: String, Codable, CaseIterable { case left, center, right }
public struct SubtitleStyle: Codable, Equatable {
    /// Missing in older projects; centered by default.
    public var alignment: SubtitleAlignment? = nil
    public var textAlignment: SubtitleAlignment { alignment ?? .center }
    public var font: String = "PingFangSC-Semibold"
    /// Font size in a 1080-pixel-high reference frame.
    public var size: Double = 44
    /// Optional normalized text-box width; nil preserves legacy auto-fit layout.
    public var width: Double? = nil
    public var color: RGBA = .white
    public var outline: RGBA = .black
    public var outlineWidth: Double = 2
    public var background: RGBA = .clear
    /// nil automatically protects light text without an opaque background.
    public var readability: Bool? = nil
    public var enhancesReadability: Bool {
        readability ?? ((0.2126*color.r+0.7152*color.g+0.0722*color.b)>0.6 && background.a<0.5)
    }
    /// Center anchor, normalized in the visible video; y increases upwards.
    public var x: Double = 0.5
    public var y: Double = 0.17
    public init() {}
    public static func standard(_ language: Language) -> Self {
        var s = Self()
        s.font = language == .fr ? "AvenirNextCondensed-Regular" : "ArialMT"
        s.size = language == .zh ? 60 : 70
        s.width = 0.98
        if language == .zh { s.color = .black; s.background = RGBA(1,0.87,0.05); s.outlineWidth = 0; s.y = 0.075 }
        return s
    }
}
public struct Cue: Codable, Equatable, Identifiable {
    public var id: UUID
    public var trackID: UUID?
    public var language: Language
    public var start: Int64
    public var end: Int64
    public var text: String
    public var style: SubtitleStyle?
    public init(id: UUID = UUID(), language: Language, start: Int64, end: Int64, text: String, style: SubtitleStyle? = nil, trackID: UUID? = nil) {
        self.id=id; self.trackID=trackID; self.language=language; self.start=start; self.end=end; self.text=text; self.style=style
    }
}
public struct TextTrack: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var style: SubtitleStyle
    public init(name: String) {
        id=UUID(); self.name=name; style=SubtitleStyle(); style.font="ArialMT"; style.y=0.8
    }
}
public struct Project: Codable, Equatable {
    public var backgroundMusic: [BackgroundMusic]?
    public var playbackRate: Double?
    public var speed: Double { playbackRate ?? 1 }
    public var exportDuration: Int64 { Int64((Double(duration)/speed).rounded()) }
    public var muteVideoAudio: Bool?
    public var lockVideoTrack: Bool?
    public var hideVideoTrack: Bool?
    public var isVideoLocked: Bool { lockVideoTrack ?? false }
    public var isVideoHidden: Bool { hideVideoTrack ?? false }
    public var videoClips: [VideoClip]?
    public var videoLayers: [VideoLayer]?
    public var textTracks: [TextTrack]?
    public var tracks: [TextTrack] { textTracks ?? [] }
    public var version = 1
    public var videoPath = ""
    public var duration: Int64 = 0
    public var cues: [Cue] = []
    public var frenchStyle = SubtitleStyle.standard(.fr)
    public var chineseStyle = SubtitleStyle.standard(.zh)
    public var englishStyle: SubtitleStyle?
    public var showEnglish: Bool?
    public var generationLanguages: GenerationLanguages?
    public var subtitleLanguages: [Language] {
        let pair=generationLanguages ?? GenerationLanguages()
        var result=pair.source == pair.target ? [pair.source] : [pair.source,pair.target]
        for language in Language.allCases where cues.contains(where: { $0.trackID == nil && $0.language == language }) && !result.contains(language) { result.append(language) }
        return result
    }
    public var showFrench = true
    public var showChinese = true
    public init() {}
    public func style(for cue: Cue) -> SubtitleStyle { cue.style ?? tracks.first(where:{$0.id == cue.trackID})?.style ?? (cue.language == .fr ? frenchStyle : (cue.language == .en ? englishStyle ?? .standard(.en) : chineseStyle)) }
    public mutating func applyStyle(_ style: SubtitleStyle, to language: Language) {
        if language == .fr { frenchStyle=style } else if language == .en { englishStyle=style } else { chineseStyle=style }
        for index in cues.indices where cues[index].trackID == nil && cues[index].language == language { cues[index].style=nil }
    }
    public mutating func applyStyle(_ style: SubtitleStyle, for cue: Cue) {
        guard let id=cue.trackID else { applyStyle(style,to:cue.language); return }
        guard let index=textTracks?.firstIndex(where:{$0.id == id}) else { return }
        textTracks?[index].style=style
        for i in cues.indices where cues[i].trackID == id { cues[i].style=nil }
    }
    public func sameTrack(_ a: Cue,_ b: Cue) -> Bool {
        a.trackID == b.trackID && (a.trackID != nil || a.language == b.language)
    }
    public func visible(_ cue: Cue) -> Bool { cue.trackID != nil || visible(cue.language) }
    public func visible(_ language: Language) -> Bool { language == .fr ? showFrench : (language == .en ? showEnglish ?? true : showChinese) }
    public mutating func setVisible(_ visible: Bool, for language: Language) {
        switch language { case .fr: showFrench=visible; case .zh: showChinese=visible; case .en: showEnglish=visible }
    }
    public var displayedCues: [Cue] {
        cues.filter { visible($0) }.sorted { $0.start == $1.start ? $0.language.rawValue < $1.language.rawValue : $0.start < $1.start }
    }
    public func active(at ms: Int64) -> [Cue] { displayedCues.filter { $0.start <= ms && ms < $0.end } }
    public func allowedRange(for cue: Cue) -> ClosedRange<Int64> {
        let others = cues.filter { sameTrack($0,cue) && $0.id != cue.id }
        let lower = others.filter { $0.start < cue.start }.map(\.end).max() ?? 0
        let upper = others.filter { $0.start >= cue.start }.map(\.start).min() ?? duration
        return min(lower, upper)...upper
    }
    public func newCue(language: Language, at time: Int64, trackID: UUID? = nil) throws -> Cue {
        let start = max(0, time)
        guard start < duration else { throw SubtitleError.invalid(L("播放位置已在视频末尾")) }
        if let id=trackID, !tracks.contains(where:{$0.id == id}) { throw SubtitleError.invalid(L("文字轨道不存在")) }
        let track = cues.filter { $0.trackID == trackID && (trackID != nil || $0.language == language) }
        guard !track.contains(where: { $0.start <= start && start < $0.end }) else { throw SubtitleError.invalid(L("当前位置已有字幕，请移动播放头或调整字幕时间")) }
        let next = track.filter { $0.start >= start }.map(\.start).min() ?? duration
        let end = min(start + 2000, next, duration)
        guard end > start else { throw SubtitleError.invalid(L("当前位置没有可用时间区间")) }
        return Cue(language: language, start: start, end: end, text: trackID != nil ? "添加说明文字" : (language == .zh ? "新的中文字幕" : (language == .en ? "New subtitle" : "Nouveau sous-titre")), trackID:trackID)
    }
    public func validate() throws {
        guard speed.isFinite,(0.25...2).contains(speed) else { throw SubtitleError.invalid(L("播放速度必须在 0.25 到 2 倍之间")) }
        try validateMusic()
        try validateClips()
        try validateLayers()
        guard version == 1 else { throw SubtitleError.invalid(L("不支持的工程版本：{0}", [String(describing: version)])) }
        guard duration >= 0, Set(cues.map(\.id)).count == cues.count else { throw SubtitleError.invalid(L("工程时间或字幕 ID 无效")) }
        guard Set(tracks.map(\.id)).count == tracks.count,
              cues.allSatisfy({ c in c.trackID == nil || tracks.contains(where:{$0.id == c.trackID}) }) else { throw SubtitleError.invalid(L("文字轨道 ID 无效")) }
        let groups=Language.allCases.map { lang in cues.filter{$0.trackID == nil && $0.language == lang} } + tracks.map { track in cues.filter{$0.trackID == track.id} }
        for group in groups {
            var last: Int64 = 0
            for cue in group.sorted(by: { $0.start < $1.start }) {
                guard cue.start >= last, cue.end > cue.start, cue.end <= duration, !cue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw SubtitleError.invalid(L("字幕时间重叠、越界或内容为空"))
                }
                let s = style(for: cue)
                guard s.size.isFinite, (8...200).contains(s.size), s.x.isFinite, s.y.isFinite, (0...1).contains(s.x), (0...1).contains(s.y), s.outlineWidth.isFinite, (0...10).contains(s.outlineWidth) else { throw SubtitleError.invalid(L("字幕样式数值无效")) }
                if let width=s.width, !width.isFinite || !(0.1...1).contains(width) { throw SubtitleError.invalid(L("字幕宽度须在 10% 到 100% 之间")) }
                last = cue.end
            }
        }
    }
    public static func read(_ url: URL) throws -> Self {
        let p = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)); try p.validate(); return p
    }
    public func write(_ url: URL) throws {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
public enum SubtitleError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let text): return text } }
}
public enum SRT {
    public static func timestamp(_ ms: Int64) -> String {
        String(format: "%02lld:%02lld:%02lld,%03lld", ms/3600000, ms/60000%60, ms/1000%60, ms%1000)
    }
    public static func time(_ value: String) throws -> Int64 {
        let p = value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ".", with: ",").split(whereSeparator: { $0 == ":" || $0 == "," })
        guard p.count == 4, let h=Int64(p[0]), let m=Int64(p[1]), let s=Int64(p[2]), let ms=Int64(p[3]), h >= 0, (0..<60).contains(m), (0..<60).contains(s), (0..<1000).contains(ms), h < 100000 else { throw SubtitleError.invalid(L("无效时间：{0}", [String(describing: value)])) }
        return h*3600000+m*60000+s*1000+ms
    }
    public static func parse(_ source: String, language: Language) throws -> [Cue] {
        let source = source.replacingOccurrences(of: "\u{FEFF}", with: "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [Cue] = []; var lines: [String] = []
        func flush() throws {
            guard !lines.isEmpty else { return }
            guard lines.count >= 3, Int(lines[0].trimmingCharacters(in: .whitespaces)) != nil else { throw SubtitleError.invalid(L("SRT 条目格式错误")) }
            let times = lines[1].components(separatedBy: "-->")
            guard times.count == 2 else { throw SubtitleError.invalid(L("SRT 时间格式错误")) }
            let start = try time(times[0]), end = try time(times[1])
            let text = lines.dropFirst(2).joined(separator: language == .zh ? "，" : "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard end > start, start >= (cues.last?.end ?? 0), !text.isEmpty else { throw SubtitleError.invalid(L("SRT 包含重叠、空文本或无效时段")) }
            cues.append(Cue(language: language, start: start, end: end, text: text)); lines=[]
        }
        for line in source.components(separatedBy: "\n") { if line.trimmingCharacters(in: .whitespaces).isEmpty { try flush() } else { lines.append(line) } }
        try flush(); return cues
    }
    public static func encode(_ cues: [Cue]) -> String {
        cues.sorted { $0.start < $1.start }.enumerated().map { i,c in
            "\(i+1)\n\(timestamp(c.start)) --> \(timestamp(c.end))\n\(c.text)\n"
        }.joined(separator: "\n") + (cues.isEmpty ? "" : "\n")
    }
}
public struct Translation: Codable { public let id: UUID; public let text: String
    public init(id: UUID, text: String) { self.id=id; self.text=text }
}
public struct TranslationBatch: Codable { public let translations: [Translation] }
public enum Translator {
    /// Punctuation and numeric cues can legitimately have no Han characters.
    /// Only accept equivalent nonverbal content; never exempt French words.
    private static func nonverbalForm(_ text: String) -> String? {
        let normalized = text.precomposedStringWithCompatibilityMapping
        guard !normalized.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { return nil }
        let compact = normalized.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        // NFKC expands … into three dots; Chinese …… conventionally uses two.
        // Normalize ellipsis-only cues without relaxing checks for words or numbers.
        if compact.count >= 3,compact.allSatisfy({ $0 == "." }) { return "..." }
        return compact.isEmpty ? nil : String(String.UnicodeScalarView(compact))
    }
    public static func merge(_ translations: [Translation], source: [Cue], target: Language = .zh) throws -> [Cue] {
        guard translations.count == source.count, Set(translations.map(\.id)) == Set(source.map(\.id)), Set(translations.map(\.id)).count == translations.count else { throw SubtitleError.invalid(L("翻译返回缺失或重复的字幕 ID")) }
        let map = Dictionary(uniqueKeysWithValues: translations.map { ($0.id, $0.text) })
        return try source.map { cue in
            let text = map[cue.id]!.components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: target == .zh ? "，" : " ").trimmingCharacters(in: .whitespacesAndNewlines)
            let containsChinese = text.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) }
            let equivalentNonverbal = nonverbalForm(cue.text).map { $0 == nonverbalForm(text) } ?? false
            guard !text.isEmpty, target != .zh || containsChinese || equivalentNonverbal else {
                throw SubtitleError.invalid(L("字幕 {0} 的翻译为空或未包含中文，请重试该批次", [String(describing: SRT.timestamp(cue.start))]))
            }
            return Cue(language: target, start: cue.start, end: cue.end, text: text)
        }
    }
}
