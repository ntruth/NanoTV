import QuartzCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
#if canImport(Libmpv)
import Libmpv
#endif

/// MPVKit 硬件渲染画布视图（macOS 绑定 NSView/CAMetalLayer，tvOS 绑定 UIView/CAMetalLayer）
public struct MPVHardwareSurfaceView: View {
    public let controller: NanoPlayerController

    public init(controller: NanoPlayerController) {
        self.controller = controller
    }

    public var body: some View {
        #if os(macOS)
        MacMPVContainerRepresentable(controller: controller)
        #else
        TVMPVContainerRepresentable(controller: controller)
        #endif
    }
}

#if os(macOS)
private struct MacMPVContainerRepresentable: NSViewRepresentable {
    let controller: NanoPlayerController

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer = CAMetalLayer()
        view.layer?.backgroundColor = CGColor.black
        controller.attachNativeRenderSurface(UnsafeMutableRawPointer(Unmanaged.passUnretained(view).toOpaque()))
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
#else
private struct TVMPVContainerRepresentable: UIViewRepresentable {
    let controller: NanoPlayerController

    func makeUIView(context: Context) -> UIView {
        let view = MPVMetalUIView()
        view.backgroundColor = .black
        if let metalLayer = view.layer as? CAMetalLayer {
            controller.attachNativeRenderSurface(UnsafeMutableRawPointer(Unmanaged.passUnretained(metalLayer).toOpaque()))
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

private final class MPVMetalUIView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
}
#endif
