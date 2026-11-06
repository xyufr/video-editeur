import Foundation

/// LRC lyrics: one `[mm:ss.xx]` line per cue, with a blank timestamp where a cue ends before the next starts.
public enum LRC {
    /// Minutes are not wrapped, so audio longer than an hour stays monotonic.
    public static func timestamp(_ ms: Int64) -> String {
        let value=max(0,ms)
        return String(format:"[%02lld:%02lld.%02lld]",value/60000,value/1000%60,value%1000/10)
    }
    public static func encode(_ cues: [Cue], title: String? = nil, length: Int64? = nil) -> String {
        var lines: [String]=[]
        if let title,!title.isEmpty { lines.append("[ti:\(title.replacingOccurrences(of:"\n",with:" "))]") }
        if let length,length>0 { lines.append(String(format:"[length:%02lld:%02lld]",length/60000,length/1000%60)) }
        let sorted=cues.sorted { $0.start < $1.start }
        for (index,cue) in sorted.enumerated() {
            let text=cue.text.components(separatedBy:.newlines).map { $0.trimmingCharacters(in:.whitespaces) }.filter { !$0.isEmpty }.joined(separator:" ")
            lines.append(timestamp(cue.start)+text)
            let next=index+1<sorted.count ? sorted[index+1].start : nil
            if next.map({ $0 > cue.end }) ?? true { lines.append(timestamp(cue.end)) }
        }
        return lines.joined(separator:"\n")+"\n"
    }
    /// Cues timed against the whole source file, limited to the kept range `[start, end)` and shifted to start at zero.
    public static func clipped(_ cues: [Cue], start: Int64, end: Int64) -> [Cue] {
        cues.compactMap { cue in
            guard cue.end>start,cue.start<end else { return nil }
            var value=cue; value.start=max(cue.start,start)-start; value.end=min(cue.end,end)-start
            return value.end>value.start ? value : nil
        }
    }
}
