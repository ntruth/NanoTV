import Foundation

// 把 stdin 里的每行名字做一次「大小写/全半角归一 + 繁体转简体」，
// 输出 JSON 字符串数组。构建数据库时用来合并同一女优的繁简写法。
let data = FileHandle.standardInput.readDataToEndOfFile()
let text = String(data: data, encoding: .utf8) ?? ""
let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
let output = lines.map { line -> String in
    let folded = line.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
    return folded.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? folded
}
if let encoded = try? JSONEncoder().encode(output) {
    FileHandle.standardOutput.write(encoded)
}
