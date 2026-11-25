import Foundation

/// 纯字符串的 ffmpeg 滤镜构造：不依赖 App 的 VideoSupport。
public enum PlaybackFilters {
    /// 去隔行：隔行源（1080i / DVD）重编码前必须先还原成逐行，否则画面留梳齿。
    /// `mode=send_frame` 保持帧率不变（50i → 25p 由源帧率决定，不会翻倍）。
    public static let deinterlaceChain = "bwdif=mode=send_frame:parity=auto:deint=all"

    /// HDR → SDR 色调映射的滤镜链（不含 `-vf`，方便和字幕烧录合并成同一条）。
    /// 只适用于 PQ / HLG：zscale 无法应用杜比视界的 DOVI RPU。
    public static let hdrToneMapChain = "zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,"
        + "tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p"

    /// libplacebo 版本：能应用 DOVI RPU，bt.2390 比 hable 更接近片源观感。
    /// 需要 ffmpeg 带 libplacebo（Vulkan / MoltenVK）。
    public static let libplaceboToneMapChain = "libplacebo=apply_dolbyvision=1:tonemapping=bt.2390"
        + ":colorspace=bt709:color_primaries=bt709:color_trc=bt709:format=yuv420p"

    /// 选色调映射滤镜链：有 libplacebo 优先；杜比视界没有 libplacebo 时返回 nil，
    /// 宁可保持原样封装，也不要把错误的颜色烘进转码结果。
    ///
    /// 传入输出尺寸时让 libplacebo 在 GPU 里顺便缩放：4K60 这类高像素率片源降档后，
    /// 编码与回读的像素量一起下降，边播边转才能稳定跑在实时以上。
    ///
    /// `inputColor` 会先经 `setparams` 写回帧：ffmpeg 9 对只有容器层色彩标记、
    /// 码流 VUI 缺字段的片源不会把色彩信息挂到解码帧上，zscale 会直接报
    /// `no path between colorspaces`；先补元数据再转换即可。
    public static func toneMapChain(dolbyVision: Bool,
                                    supportsLibplacebo: Bool,
                                    outputWidth: Int? = nil,
                                    outputHeight: Int? = nil,
                                    inputColor: VideoColorInfo = VideoColorInfo()) -> String? {
        let prefix = colorParameterPrefix(inputColor)
        if supportsLibplacebo {
            var options: [String] = []
            if let outputWidth, let outputHeight {
                options += ["w=\(outputWidth)", "h=\(outputHeight)"]
            }
            options += ["apply_dolbyvision=1", "tonemapping=bt.2390",
                        "colorspace=bt709", "color_primaries=bt709", "color_trc=bt709",
                        "format=yuv420p"]
            return prefix + "libplacebo=" + options.joined(separator: ":")
        }
        guard !dolbyVision else { return nil }
        guard let outputHeight else { return prefix + hdrToneMapChain }
        return prefix + "scale=-2:\(outputHeight)," + hdrToneMapChain
    }

    /// 把探测到的色彩参数写成帧元数据；没有可用字段时返回空串。
    private static func colorParameterPrefix(_ color: VideoColorInfo) -> String {
        func normalized(_ value: String?) -> String? {
            guard let value = value?.lowercased(), !value.isEmpty,
                  value != "unknown", value != "reserved" else { return nil }
            return value
        }
        var parts: [String] = []
        if let value = normalized(color.primaries) { parts.append("color_primaries=\(value)") }
        if let value = normalized(color.transfer) { parts.append("color_trc=\(value)") }
        if let value = normalized(color.matrix) { parts.append("colorspace=\(value)") }
        if let value = normalized(color.range) { parts.append("range=\(value)") }
        guard !parts.isEmpty else { return "" }
        return "setparams=" + parts.joined(separator: ":") + ","
    }

    /// ffmpeg 的 subtitles 烧录滤镜；路径里的反斜杠、冒号与单引号必须转义。
    /// 文本字幕（srt / ass / vtt / ssa）由 libass 渲染；PGS / SUP 取决于内置 ffmpeg 的解码能力。
    public static func subtitleBurnFilter(_ url: URL) -> String {
        let escaped = url.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ":", with: "\\:")
            .replacingOccurrences(of: "'", with: "\\'")
        return "subtitles=filename='\(escaped)'"
    }
}
