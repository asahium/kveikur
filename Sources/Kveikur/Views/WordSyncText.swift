import KveikurCore
import SwiftUI

enum WordSyncText {
    /// The line with sung words in `sung`, the current word blending towards it, the rest in `unsung`.
    /// `time` is already offset-corrected.
    static func make(_ line: LyricLine, at time: TimeInterval, sung: Color, unsung: Color) -> Text {
        guard let words = line.words, !words.isEmpty else { return Text(line.text) }
        let fill = line.wordFill(at: time)
        return words.indices.reduce(Text(verbatim: "")) { acc, i in
            acc + Text(verbatim: words[i].text).foregroundColor(unsung.mix(with: sung, by: fill[i]))
        }
    }
}
