import Foundation

/// Places the lines of a known lyrics text on the timeline using the times of a speech transcription.
/// Words are matched with a semi-global sequence alignment (accents/case ignored, CJK per character);
/// a transcribed word's time is interpolated inside its cue by character length. Lines without any
/// matched word share the time between their timed neighbours by length.
public enum LyricAligner {
    /// Non-empty lines of a lyrics text file; leading `[mm:ss.xx]`/`[tag:value]` LRC tags are removed.
    public static func lines(fromText text: String) -> [String] {
        let tag=try! NSRegularExpression(pattern:#"^(\s*\[[^\]]*\])+"#)
        return text.replacingOccurrences(of:"\u{FEFF}",with:"").components(separatedBy:.newlines).compactMap { raw in
            let ns=raw as NSString
            let stripped=tag.stringByReplacingMatches(in:raw,range:NSRange(location:0,length:ns.length),withTemplate:"")
            let line=stripped.trimmingCharacters(in:.whitespaces)
            return line.isEmpty ? nil : line
        }
    }

    static func tokens(_ text: String) -> [String] {
        let folded=text.folding(options:[.caseInsensitive,.diacriticInsensitive,.widthInsensitive],locale:Locale(identifier:"en_US_POSIX"))
        var result: [String]=[], word=""
        func flush() { if !word.isEmpty { result.append(word); word="" } }
        for scalar in folded.unicodeScalars {
            if isCJK(scalar) { flush(); result.append(String(scalar)) }
            else if CharacterSet.alphanumerics.contains(scalar) { word.unicodeScalars.append(scalar) }
            else { flush() }
        }
        flush(); return result
    }
    static func isCJK(_ s: Unicode.Scalar) -> Bool {
        (0x3040...0x30FF).contains(s.value) || (0x3400...0x4DBF).contains(s.value) || (0x4E00...0x9FFF).contains(s.value) || (0xF900...0xFAFF).contains(s.value) || (0xAC00...0xD7AF).contains(s.value)
    }
    static func similar(_ a: String, _ b: String) -> Bool {
        guard min(a.count,b.count)>=4 else { return false }
        let x=Array(a), y=Array(b)
        var previous=Array(0...y.count)
        for i in 1...x.count {
            var row=[i]+Array(repeating:0,count:y.count)
            for j in 1...y.count { row[j]=min(previous[j]+1,row[j-1]+1,previous[j-1]+(x[i-1] == y[j-1] ? 0 : 1)) }
            previous=row
        }
        return Double(previous[y.count]) <= Double(max(x.count,y.count))*0.34
    }

    /// Returns one cue per lyric line, in order, non-overlapping and within `[lower, upper)`.
    public static func align(lines: [String], transcription: [Cue], language: Language, lower: Int64 = 0, upper: Int64) -> [Cue] {
        guard upper>lower,!lines.isEmpty else { return [] }
        // Transcribed words with interpolated times.
        var heard: [(token: String,start: Int64,end: Int64)]=[]
        for cue in transcription.sorted(by:{ $0.start < $1.start }) {
            let words=tokens(cue.text); let total=max(1,words.reduce(0) { $0+$1.count })
            var used=0
            for word in words {
                let a=cue.start+(cue.end-cue.start)*Int64(used)/Int64(total); used+=word.count
                heard.append((word,a,cue.start+(cue.end-cue.start)*Int64(used)/Int64(total)))
            }
        }
        var written: [(token: String,line: Int)]=[]
        for (index,line) in lines.enumerated() { for token in tokens(line) { written.append((token,index)) } }
        var starts=[Int64?](repeating:nil,count:lines.count), ends=[Int64?](repeating:nil,count:lines.count)
        let n=written.count, m=heard.count
        if n>0,m>0 {
            // Semi-global alignment: skipping transcription at either end is free.
            let width=m+1
            var score=[Int32](repeating:0,count:(n+1)*width), move=[UInt8](repeating:0,count:(n+1)*width)
            for i in 1...n { score[i*width]=Int32(-i); move[i*width]=1 }
            for j in 1...m { move[j]=2 }
            for i in 1...n {
                for j in 1...m {
                    let a=written[i-1].token, b=heard[j-1].token
                    let pair: Int32=a == b ? 3 : (similar(a,b) ? 1 : -1)
                    let diagonal=score[(i-1)*width+j-1]+pair
                    let up=score[(i-1)*width+j]-1
                    let left=score[i*width+j-1]-(i == n ? 0 : 1)
                    if diagonal>=up && diagonal>=left { score[i*width+j]=diagonal; move[i*width+j]=pair>0 ? 3 : 4 }
                    else if up>=left { score[i*width+j]=up; move[i*width+j]=1 }
                    else { score[i*width+j]=left; move[i*width+j]=2 }
                }
            }
            var i=n, j=m
            while i>0 && j>0 {
                switch move[i*width+j] {
                case 3:
                    let line=written[i-1].line, word=heard[j-1]
                    starts[line]=min(starts[line] ?? word.start,word.start); ends[line]=max(ends[line] ?? word.end,word.end)
                    i-=1; j-=1
                case 4: i-=1; j-=1
                case 1: i-=1
                default: j-=1
                }
            }
        }
        // Keep matched lines in order; a line whose match runs backwards is treated as unmatched.
        var lastEnd=lower
        for index in lines.indices {
            guard let s=starts[index],let e=ends[index] else { continue }
            if s<lastEnd || s>=upper { starts[index]=nil; ends[index]=nil; continue }
            ends[index]=min(e,upper); lastEnd=ends[index]!
        }
        // Unmatched runs share the gap between timed neighbours by text length.
        var index=0
        while index<lines.count {
            guard starts[index] == nil else { index+=1; continue }
            var stop=index; while stop<lines.count && starts[stop] == nil { stop+=1 }
            let from=index>0 ? ends[index-1]! : lower, to=stop<lines.count ? starts[stop]! : upper
            let weights=(index..<stop).map { Int64(max(1,lines[$0].count)) }, total=weights.reduce(0,+)
            var cursor=from, acc: Int64=0
            for (k,line) in (index..<stop).enumerated() {
                acc+=weights[k]
                let next=from+(to-from)*acc/total
                starts[line]=cursor; ends[line]=next; cursor=next
            }
            index=stop
        }
        var cues: [Cue]=[], previous=lower
        for (index,text) in lines.enumerated() {
            let start=max(starts[index]!,previous), end=min(max(ends[index]!,start+1),upper)
            guard start<end else { continue }
            cues.append(Cue(language:language,start:start,end:end,text:text)); previous=end
        }
        return cues
    }
}
