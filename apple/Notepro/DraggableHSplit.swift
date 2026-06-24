import SwiftUI
import AppKit

/// HStack-based horizontal splitter with a fully draggable divider. Replaces
/// SwiftUI's HSplitView, which silently refuses to drag when one of its
/// children hosts an NSViewRepresentable (WKWebView, PDFView) — the AppKit
/// view eats mouse events near the 1px divider edge and the split appears
/// locked.
///
/// The divider here is a wider invisible hit zone (8 pt) carrying its own
/// resize cursor + DragGesture, so it always responds regardless of what's
/// rendered beside it. `storageKey` persists the split ratio across launches.
struct DraggableHSplit<L: View, R: View>: View {
    let storageKey: String
    let minLeft: CGFloat
    let minRight: CGFloat
    @ViewBuilder let left: () -> L
    @ViewBuilder let right: () -> R

    @AppStorage private var ratio: Double
    @State private var dragStartWidth: CGFloat? = nil  // px width of left side at drag start

    init(storageKey: String, defaultRatio: Double = 0.55,
         minLeft: CGFloat = 280, minRight: CGFloat = 260,
         @ViewBuilder left: @escaping () -> L,
         @ViewBuilder right: @escaping () -> R) {
        self.storageKey = storageKey
        self.minLeft = minLeft
        self.minRight = minRight
        self.left = left
        self.right = right
        self._ratio = AppStorage(wrappedValue: defaultRatio, storageKey)
    }

    var body: some View {
        GeometryReader { geo in
            let totalW = geo.size.width
            let savedW = totalW * CGFloat(ratio)
            let leftW = max(minLeft, min(totalW - minRight, savedW))
            HStack(spacing: 0) {
                left().frame(width: leftW).frame(maxHeight: .infinity)
                divider(totalW: totalW, currentLeftW: leftW)
                right().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func divider(totalW: CGFloat, currentLeftW: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(Color(NSColor.separatorColor))
                .frame(width: 1)
            // Wide invisible hit zone — without this the 1px line is nearly
            // impossible to grab, especially with AppKit views beside it.
            Color.clear
                .frame(width: 8)
                .contentShape(Rectangle())
                .onHover { hovering in
                    if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            // Capture the starting width on first move so the
                            // delta is relative to where the drag began, not
                            // relative to the saved ratio.
                            if dragStartWidth == nil { dragStartWidth = currentLeftW }
                            guard let start = dragStartWidth else { return }
                            let proposed = max(minLeft, min(totalW - minRight, start + v.translation.width))
                            ratio = Double(proposed / totalW)
                        }
                        .onEnded { _ in dragStartWidth = nil }
                )
        }
        .frame(width: 8, alignment: .center)
    }
}
