//
//  WindowBackground.swift
//  Sirr
//
//  The colour behind everything.
//
//  A zoom presentation does not just cover the page it came from — it scales
//  that page down and slides it back, and for those few frames whatever sits
//  behind it is on screen. That is the window, and a window nobody has painted
//  is white, which is why every card that opened flashed a bright frame around
//  the artwork. Painting it once, at the root, fixes it everywhere the
//  transition is used: the home feed's cards, the exercise page, the lineup.
//

import SwiftUI

private struct WindowBackgroundPainter: UIViewRepresentable {
    let color: UIColor

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // The window is not attached while the view is being made, so the paint
        // happens after this layout pass rather than during it.
        DispatchQueue.main.async {
            guard let window = uiView.window else { return }
            window.backgroundColor = color
            // The root controller's view is the other thing a scaled-down
            // presentation can reveal an edge of.
            window.rootViewController?.view.backgroundColor = color
        }
    }
}

extension View {
    /// Paints the window this view is in. Applied once at the root.
    func tamrinWindowBackground(
        _ color: Color = TamrinTheme.surfaceFloor
    ) -> some View {
        background(WindowBackgroundPainter(color: UIColor(color)))
    }
}
