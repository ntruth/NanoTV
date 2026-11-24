import CoreImage
import SwiftUI

/// 跨 macOS 与 Apple TV 原生高清无锯齿二维码渲染视图（零平台 UIKit/AppKit 分支依赖）
public struct NanoQRCodeView: View {
    public let content: String
    public var size: CGFloat

    public init(content: String, size: CGFloat = 186) {
        self.content = content
        self.size = size
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white)
                .frame(width: size + 24, height: size + 24)

            if let cgImg = Self.generateQRCodeCGImage(from: content) {
                Image(decorative: cgImg, scale: 1.0)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
            } else {
                ProgressView()
            }
        }
    }

    public static func generateQRCodeCGImage(from string: String) -> CGImage? {
        guard !string.isEmpty,
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let outputImage = filter.outputImage else { return nil }
        let context = CIContext(options: nil)
        return context.createCGImage(outputImage, from: outputImage.extent)
    }
}
