import SwiftUI

// iPhone Duo's cover screen hosts navigation chrome in a vertical bar beside
// the sensor housing, and only native toolbar items move into it. A screen
// that draws its own floating buttons would put them under the camera, so on
// that screen it hands them to the toolbar instead:
//
//     .overlay(alignment: .topLeading) {
//         if !hasVerticalBar { closeButton.buttonStyle(...).padding(...) }
//     }
//     .toolbar {
//         if hasVerticalBar { ToolbarItem(placement: .cancellationAction) { closeButton } }
//     }
//
// The screen's outermost view adds `.verticalBarHost()` so those items have a
// navigation bar to live in. Everywhere else that bar stays hidden and the
// screen looks exactly as designed.

extension EnvironmentValues {
    /// True where the system places a vertical bar (iPhone Duo's cover
    /// screen). Always false before iOS 27.1 and on every other iPhone.
    ///
    /// Published by `verticalBarHost()` and `verticalBarAware()` from the
    /// system's `toolbarVerticalEdge`, which needs iOS 27.1 to read.
    @Entry var hasVerticalBar = false
}

extension View {
    /// Hosts a full-screen page's toolbar items in iPhone Duo's vertical bar.
    ///
    /// Wraps the page in a navigation stack whose bar is visible only where a
    /// vertical bar exists, and publishes that as `hasVerticalBar`. On a
    /// screen that already sits in a navigation stack, use
    /// `verticalBarAware()` on its root content instead.
    func verticalBarHost() -> some View {
        VerticalBarReader { hasVerticalBar in
            NavigationStack {
                self.verticalBarChrome(hasVerticalBar)
            }
            .environment(\.hasVerticalBar, hasVerticalBar)
        }
    }

    /// Publishes `hasVerticalBar` for a screen that already owns a navigation
    /// stack, and shows that stack's bar only where a vertical bar exists.
    /// Apply it inside the stack, on its root content.
    func verticalBarAware() -> some View {
        VerticalBarReader { hasVerticalBar in
            self.verticalBarChrome(hasVerticalBar)
                .environment(\.hasVerticalBar, hasVerticalBar)
        }
    }

    private func verticalBarChrome(_ hasVerticalBar: Bool) -> some View {
        toolbar(hasVerticalBar ? .automatic : .hidden, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
            // The stack is plumbing for the bar, not a surface: a page over a
            // blurred or zooming presentation must still see through it.
            .containerBackground(.clear, for: .navigation)
    }
}

private struct VerticalBarReader<Content: View>: View {
    @ViewBuilder let content: (Bool) -> Content

    var body: some View {
        if #available(iOS 27.1, *) {
            SystemEdge(content: content)
        } else {
            content(false)
        }
    }

    @available(iOS 27.1, *)
    private struct SystemEdge: View {
        /// Nil wherever the system never uses a vertical bar.
        @Environment(\.toolbarVerticalEdge) private var edge
        let content: (Bool) -> Content

        var body: some View { content(edge != nil) }
    }
}
