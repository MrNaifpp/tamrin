import SwiftUI
import UIKit

/// A transparent presentation keeps the account sheet in place. Only the card
/// transforms; the scrim and controls fade on the same animation clock.
struct PlayerCardZoomPresenter: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    @Binding var hidesThumbnail: Bool
    let card: PlayerCardView
    let reduceMotion: Bool
    var edit: (() -> Void)?

    func makeUIViewController(context: Context) -> PlayerCardZoomAnchor {
        PlayerCardZoomAnchor()
    }

    func updateUIViewController(_ anchor: PlayerCardZoomAnchor, context: Context) {
        anchor.request = { [weak anchor] in
            guard let anchor else { return }
            if isPresented {
                guard anchor.zoom == nil, let window = anchor.view.window else { return }
                var presenter = window.rootViewController
                while let next = presenter?.presentedViewController { presenter = next }
                guard let presenter, !presenter.isBeingDismissed else { return }
                let zoom = PlayerCardZoomController(card: card, source: anchor.view,
                                                   reduceMotion: reduceMotion, allowsEditing: edit != nil)
                anchor.zoom = zoom
                zoom.onShow = { hidesThumbnail = true }
                zoom.onClose = { wantsEdit in
                    hidesThumbnail = false
                    isPresented = false
                    anchor.zoom = nil
                    if wantsEdit { edit?() }
                }
                presenter.present(zoom, animated: false)
            } else {
                anchor.zoom?.close()
            }
        }
        // Present after the SwiftUI update has committed and the anchor has its
        // final window coordinates, not during a body evaluation.
        DispatchQueue.main.async { [weak anchor] in anchor?.request?() }
    }

    static func dismantleUIViewController(_ anchor: PlayerCardZoomAnchor, coordinator: ()) {
        anchor.request = nil
        anchor.zoom?.dismiss(animated: false)
    }
}

final class PlayerCardZoomAnchor: UIViewController {
    weak var zoom: PlayerCardZoomController?
    var request: (() -> Void)?

    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        request?()
    }
}

final class PlayerCardZoomController: UIViewController {
    private let cardHost: UIHostingController<PlayerCardView>
    private var controlsHost: UIHostingController<PlayerCardZoomControls>!
    private let scrim = UIView()
    private weak var source: UIView?
    private let reduceMotion: Bool
    private let allowsEditing: Bool
    private var hasOpened = false
    private var isClosing = false
    private var targetFrame = CGRect.zero
    var onShow: (() -> Void)?
    var onClose: ((Bool) -> Void)?

    init(card: PlayerCardView, source: UIView, reduceMotion: Bool, allowsEditing: Bool) {
        self.cardHost = UIHostingController(rootView: card)
        self.source = source
        self.reduceMotion = reduceMotion
        self.allowsEditing = allowsEditing
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        overrideUserInterfaceStyle = .dark
        isModalInPresentation = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.accessibilityViewIsModal = true
        scrim.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        scrim.alpha = 0
        view.addSubview(scrim)

        addChild(cardHost)
        cardHost.view.backgroundColor = .clear
        cardHost.safeAreaRegions = []
        view.addSubview(cardHost.view)
        cardHost.didMove(toParent: self)

        controlsHost = UIHostingController(rootView: PlayerCardZoomControls(
            close: { [weak self] in self?.close() },
            edit: allowsEditing ? { [weak self] in self?.close(wantsEdit: true) } : nil
        ))
        addChild(controlsHost)
        controlsHost.view.backgroundColor = .clear
        controlsHost.view.alpha = 0
        view.addSubview(controlsHost.view)
        controlsHost.didMove(toParent: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scrim.frame = view.bounds
        controlsHost.view.frame = view.bounds
        let top = view.safeAreaInsets.top + 64
        let bottom = view.bounds.height - view.safeAreaInsets.bottom - (allowsEditing ? 76 : 24)
        let width = max(1, min(view.bounds.width - 40, (bottom - top - 24) * PlayerCardView.aspectRatio))
        let size = CGSize(width: width, height: width / PlayerCardView.aspectRatio)
        targetFrame = CGRect(x: (view.bounds.width - size.width) / 2,
                             y: (top + bottom - size.height) / 2, width: size.width, height: size.height)
        // Set bounds/center so layout never overwrites an in-flight transform.
        cardHost.view.bounds = CGRect(origin: .zero, size: size)
        cardHost.view.center = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
        if !hasOpened { cardHost.view.transform = reduceMotion ? .identity : sourceTransform }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasOpened else { return }
        view.layoutIfNeeded()
        hasOpened = true
        cardHost.view.alpha = reduceMotion ? 0 : 1
        onShow?()
        UIView.animate(withDuration: reduceMotion ? 0.2 : 0.48, delay: 0,
                       usingSpringWithDamping: 1, initialSpringVelocity: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.cardHost.view.transform = .identity
            self.cardHost.view.alpha = 1
            self.scrim.alpha = 1
            self.controlsHost.view.alpha = 1
        } completion: { [weak self] _ in
            guard let self, !self.isClosing else { return }
            UIAccessibility.post(notification: .screenChanged, argument: self.controlsHost.view)
        }
    }

    private var sourceTransform: CGAffineTransform {
        guard let source, source.window != nil, targetFrame.width > 0 else { return .identity }
        let rect = source.convert(source.bounds, to: view)
        let scale = rect.width / targetFrame.width
        return CGAffineTransform(translationX: rect.midX - targetFrame.midX,
                                 y: rect.midY - targetFrame.midY).scaledBy(x: scale, y: scale)
    }

    func close(wantsEdit: Bool = false) {
        guard !isClosing else { return }
        isClosing = true
        view.isUserInteractionEnabled = false
        UIView.animate(withDuration: reduceMotion ? 0.18 : 0.4, delay: 0,
                       usingSpringWithDamping: 1, initialSpringVelocity: 0,
                       options: [.beginFromCurrentState]) {
            if self.reduceMotion { self.cardHost.view.alpha = 0 }
            else { self.cardHost.view.transform = self.sourceTransform }
            self.scrim.alpha = 0
            self.controlsHost.view.alpha = 0
        } completion: { [weak self] _ in
            guard let self else { return }
            self.dismiss(animated: false) { self.onClose?(wantsEdit) }
        }
    }
}

/// The controls layer, hosted in a navigation stack only on iPhone Duo's cover
/// screen. Everywhere else it stays the bare transparent layer it always was,
/// so nothing can paint over the card host beneath it.
private struct PlayerCardZoomControls: View {
    let close: () -> Void
    var edit: (() -> Void)?

    var body: some View {
        if #available(iOS 27.1, *) {
            SystemEdge(close: close, edit: edit)
        } else {
            PlayerCardZoomControlsLayer(close: close, edit: edit)
        }
    }

    @available(iOS 27.1, *)
    private struct SystemEdge: View {
        /// Nil wherever the system never uses a vertical bar.
        @Environment(\.toolbarVerticalEdge) private var edge
        let close: () -> Void
        var edit: (() -> Void)?

        var body: some View {
            if edge != nil {
                PlayerCardZoomControlsLayer(close: close, edit: edit)
                    .verticalBarHost()
            } else {
                PlayerCardZoomControlsLayer(close: close, edit: edit)
            }
        }
    }
}

private struct PlayerCardZoomControlsLayer: View {
    let close: () -> Void
    var edit: (() -> Void)?

    @Environment(\.hasVerticalBar) private var hasVerticalBar

    /// Floating, it carries its own glass disc; in the toolbar the system
    /// draws the glass.
    private func closeButton(floating: Bool) -> some View {
        Button(action: close) {
            let icon = Image(systemName: "xmark")
                .font(.system(size: 18, weight: .medium))
                .frame(width: 44, height: 44)
            if floating {
                icon.glassEffect(.regular.interactive(), in: .circle)
            } else {
                icon
            }
        }
        .accessibilityLabel("إغلاق البطاقة")
        .accessibilityIdentifier("player-card-close")
    }

    var body: some View {
        ZStack {
            Color.clear.contentShape(.rect).onTapGesture(perform: close)
                .accessibilityHidden(true)
            VStack {
                // Close sits on the trailing side in either language, like the
                // create page's top bar. On iPhone Duo's cover screen it would
                // sit under the camera, so it moves to the toolbar below.
                if !hasVerticalBar {
                    HStack {
                        Spacer()
                        closeButton(floating: true)
                            .buttonStyle(.plain)
                    }
                    .environment(\.layoutDirection, .tamrin)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                }
                Spacer()
                if let edit {
                    Button(action: edit) {
                        Label("تعديل البطاقة", systemImage: "pencil")
                            .font(TamrinFont.font(size: 17, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                    .environment(\.layoutDirection, .tamrin)
                    .accessibilityIdentifier("player-card-edit")
                }
            }
        }
        .toolbar {
            if hasVerticalBar {
                ToolbarItem(placement: .cancellationAction) { closeButton(floating: false) }
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .environment(\.colorScheme, .dark)
        .environment(\.locale, .tamrin)
        .accessibilityAction(.escape, close)
    }
}
