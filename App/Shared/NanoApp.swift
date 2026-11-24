import NanoUI
import SwiftUI

@main
struct NanoApplication: App {
    var body: some Scene {
        WindowGroup("Nano") {
            NanoRootView()
                .preferredColorScheme(.dark)
                #if os(macOS)
                .frame(minWidth: 1120, minHeight: 720)
                #endif
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1380, height: 860)
        #endif
    }
}
