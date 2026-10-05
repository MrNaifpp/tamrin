import SwiftUI
import PhotosUI

/// A supplied PNG stands in for the future generation result. No network upload.
struct PlayerCardPage: View {
    @Bindable var feed: HomeStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stage: Stage = .instructions
    @State private var summary: PlayerRatingSummary?
    @State private var photoItem: PhotosPickerItem?
    @State private var portrait: UIImage?
    @State private var sourcePortrait: UIImage?
    @State private var placement = PlayerPortraitLayout.Placement(rect: CGRect(x: 0, y: 0, width: 1, height: 1))
    @State private var initialPlacement: PlayerPortraitLayout.Placement?
    @State private var framingMessage = ""
    @State private var showsPhotoPicker = false
    @State private var showsFraming = false
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var delay: Double = 30
    @State private var startedAt = Date()
    @State private var share: PlayerCardSharePayload?
    @State private var selectedDestination: PlayerCardShareDestination?
    @State private var showsShareOptions = false
    @State private var confirmsExit = false
    private enum Stage { case instructions, photo, processing, result, saved }

    private var name: String { feed.profileName.isEmpty ? String(localized: "لاعب") : feed.profileName }
    private var position: String {
        let value = summary?.position ?? ""
        return value.isEmpty ? feed.playerPosition : value
    }
    private var overall: Int { summary?.averageOverall ?? LineupStrength.neutral }
    private var scores: PlayerRatingScores { summary?.average ?? .neutral }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 24) {
                Group {
                    switch stage {
                    case .instructions: instructions
                    case .photo: photoSelection
                    case .processing: processing
                    case .result: result
                    case .saved: savedPreview
                    }
                }.id(stage).transition(.opacity.combined(with: .scale(scale: 0.96)))
                if let errorMessage {
                    Text(errorMessage).font(TamrinFont.footnote)
                        .foregroundStyle(.orange).multilineTextAlignment(.center)
                }
            }.padding(.horizontal, 24).padding(.vertical, stage == .result ? 16 : 28).frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .top) { topBar }
        .safeAreaInset(edge: .bottom) {
            if stage != .processing {
                bottomAction.padding(.horizontal, 24).padding(.vertical, 12)
            }
        }
        .environment(\.layoutDirection, .tamrin)
        .environment(\.locale, .tamrin)
        .environment(\.colorScheme, .dark)
        .interactiveDismissDisabled(stage == .processing)
        .task { summary = try? await feed.myPlayerRating() }
        .photosPicker(isPresented: $showsPhotoPicker, selection: $photoItem, matching: .images)
        .task(id: photoItem) {
            guard let photoItem else { return }
            isImporting = true
            showsFraming = false
            startedAt = Date()
            move(to: .processing)
            defer { if self.photoItem == photoItem { isImporting = false } }
            do {
                guard let data = try await photoItem.loadTransferable(type: Data.self) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                try Task.checkCancellation()
                try accept(data)
                try await Task.sleep(for: .seconds(delay))
                try Task.checkCancellation()
                move(to: .result)
                Haptics.success()
            } catch is CancellationError { }
            catch {
                move(to: .photo)
                errorMessage = String(localized: "تعذّر فتح الصورة. جرّب صورة أخرى أصغر من 25 ميجابايت.")
                self.photoItem = nil
            }
        }
        .sheet(item: $share) { PlayerCardShareSheet(payload: $0) }
        .confirmationDialog("إغلاق إنشاء البطاقة؟", isPresented: $confirmsExit, titleVisibility: .visible) {
            Button("إغلاق دون حفظ", role: .destructive) { dismiss() }
            Button("متابعة", role: .cancel) { }
        }
        .confirmationDialog("مشاركة البطاقة", isPresented: $showsShareOptions, presenting: selectedDestination) { destination in
            Button("اختيار \(destination.platform) من المشاركة") { export(destination) }
            Button("إلغاء", role: .cancel) { }
        } message: { destination in
            Text("سنجهّز البطاقة بمقاس \(destination.dimensions). في هذه النسخة اختر \(destination.platform) من ورقة المشاركة، أو احفظ الصورة واستخدمها في الستوري.")
        }
    }

    private var topBar: some View {
        ZStack {
            Text(stage == .saved ? String(localized: "معاينة بطاقتك") : stage == .result ? String(localized: "بطاقتك جاهزة") : String(localized: "أنشئ بطاقتك"))
                .font(TamrinFont.font(size: 17, weight: .bold))
            HStack {
                if stage == .result || stage == .photo {
                    Button {
                        if stage == .result { chooseAnotherPhoto() }
                        else { move(to: .instructions) }
                    } label: { Image(systemName: "chevron.backward").frame(width: 28, height: 28) }
                    .buttonStyle(.glass).buttonBorderShape(.circle)
                    .accessibilityLabel(stage == .result ? String(localized: "العودة لاختيار صورة أخرى") : String(localized: "رجوع"))
                }
                Spacer()
                Button {
                    if sourcePortrait != nil && stage != .saved { confirmsExit = true } else { dismiss() }
                } label: { Image(systemName: "xmark").frame(width: 28, height: 28) }
                .buttonStyle(.glass).buttonBorderShape(.circle).accessibilityLabel("إغلاق")
            }
        }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 12)
    }

    private var instructions: some View {
        VStack(spacing: 24) {
            card.frame(width: 220, height: 220 / PlayerCardView.aspectRatio).rotationEffect(.degrees(-3))
            Text("بطاقتك، بطريقتك").font(TamrinFont.font(size: 28, weight: .bold))
            Text("صورة واضحة لك، وبطاقة تحمل اسمك وتقييم زملائك.")
                .font(TamrinFont.body).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 16) {
                instruction("1", String(localized: "اختر صورة واضحة لشخص واحد."))
                instruction("2", String(localized: "PNG بخلفية شفافة يعطي أفضل نتيجة داخل البطاقة."))
                instruction("3", String(localized: "شاهد بطاقتك ثم شاركها مع أصحابك."))
            }
            Text("تجربة محلية: نضبط موضع الصورة على جهازك، ولن تُرسل إلى خدمة ذكاء اصطناعي.")
                .font(TamrinFont.footnote).foregroundStyle(.secondary)
        }.multilineTextAlignment(.center)
    }

    private var photoSelection: some View {
        VStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("تعليمات الصورة")
                    .font(TamrinFont.font(size: 16, weight: .bold))
                VStack(alignment: .leading, spacing: 2) {
                    photoInstruction(String(localized: "اختر صورة واضحة لشخص واحد."))
                    photoInstruction(String(localized: "تأكد من ظهور الوجه والرأس والكتفين بالكامل."))
                }
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(.white.opacity(0.06), in: .rect(cornerRadius: 24))

            VStack(spacing: 12) {
                Text("مثال للصورة المناسبة")
                    .font(TamrinFont.font(size: 18, weight: .medium))
                // A fixed bundled example, never the user's selected portrait.
                if let example = UIImage(named: "PlayerPhotoExample") {
                    Image(uiImage: example)
                        .resizable().scaledToFit()
                        .frame(maxWidth: 260, maxHeight: 340)
                        .clipShape(.rect(cornerRadius: 24))
                } else {
                    RoundedRectangle(cornerRadius: 24)
                        .fill(.white.opacity(0.04))
                        .frame(width: 240, height: 300)
                        .overlay {
                            Text("ستُضاف الصورة التوضيحية هنا")
                                .font(TamrinFont.footnote).foregroundStyle(.secondary)
                        }
                }
            }
        }
    }

    private var processing: some View {
        VStack(spacing: 24) {
            ZStack {
                card.frame(width: 220, height: 220 / PlayerCardView.aspectRatio).blur(radius: 18).opacity(0.22)
                PlayerCardParticles()
            }
            Text("نجهّز بطاقتك").font(TamrinFont.font(size: 26, weight: .bold))
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                let elapsed = context.date.timeIntervalSince(startedAt)
                VStack(spacing: 12) {
                    Text(elapsed < delay * 0.5 ? String(localized: "نرتّب الصورة داخل البطاقة…") : String(localized: "اللمسات الأخيرة…"))
                    Text("\(max(0, min(Int(elapsed), Int(delay)))) ثانية من \(Int(delay))")
                        .monospacedDigit().font(TamrinFont.footnote)
                }.foregroundStyle(.secondary)
            }
            Button("العودة لاختيار صورة أخرى") { chooseAnotherPhoto() }.font(TamrinFont.footnote)
        }.padding(.top, 35)
    }

    private var savedPreview: some View {
        VStack(spacing: 16) {
            card.frame(width: 220, height: 220 / PlayerCardView.aspectRatio)
            Text("شاركها، وخلّ أصحابك يشوفونها.").font(TamrinFont.body).foregroundStyle(.secondary)
            if summary?.averageOverall == nil {
                Text("الأرقام مبدئية إلى أن يتوفر تقييم زملائك.")
                    .font(TamrinFont.footnote).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(PlayerCardShareDestination.allCases) { destination in
                    Button { selectedDestination = destination; showsShareOptions = true } label: {
                        VStack(spacing: 5) {
                            Text(destination.title).font(TamrinFont.font(size: 14, weight: .medium))
                            Text(destination.dimensions).font(TamrinFont.font(size: 11, weight: .regular)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 8)
                    }.buttonStyle(.glass).controlSize(.small)
                }
            }
        }.multilineTextAlignment(.center)
    }

    private var result: some View {
        VStack(spacing: 20) {
            card.frame(width: 260, height: 260 / PlayerCardView.aspectRatio)
            if summary?.averageOverall == nil {
                Text("الأرقام مبدئية إلى أن يتوفر تقييم زملائك.")
                    .font(TamrinFont.footnote).foregroundStyle(.secondary)
            }
            if sourcePortrait != nil {
                DisclosureGroup("تعديل موضع الصورة", isExpanded: $showsFraming) {
                    VStack(spacing: 12) {
                        Text(framingMessage).font(TamrinFont.footnote).foregroundStyle(.secondary)
                        framingSlider(String(localized: "حجم اللاعب"), value: $placement.zoom, range: 0.5...2)
                        framingSlider(String(localized: "يمين ويسار"), value: $placement.horizontal, range: -0.4...0.4)
                        framingSlider(String(localized: "أعلى وأسفل"), value: $placement.vertical, range: -0.4...0.4)
                        Button("إعادة ضبط الموضع") {
                            if let initialPlacement { placement = initialPlacement }
                        }.font(TamrinFont.footnote)
                    }.padding(.top, 12)
                }
                .font(TamrinFont.body)
                .tint(.white)
                .onChange(of: placement) { _, _ in updateFraming() }
            }
        }
    }

    private var bottomAction: some View {
        Button {
            switch stage {
            case .instructions: move(to: .photo)
            case .photo: showsPhotoPicker = true
            case .result: finish()
            case .saved: dismiss()
            case .processing: break
            }
        } label: {
            Text(stage == .instructions ? String(localized: "خلّنا نبدأ") : stage == .photo ? String(localized: "اختر صورة") : stage == .result ? String(localized: "حفظ") : String(localized: "تم"))
                .font(TamrinFont.font(size: 17, weight: .medium))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(.white, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }

    private func chooseAnotherPhoto() {
        photoItem = nil // Cancels image loading / processing and allows picking the same photo again.
        isImporting = false
        showsFraming = false
        move(to: .photo)
    }

    private var card: some View {
        PlayerCardView(name: name, position: position, overall: overall, scores: scores,
                       portrait: portrait.map { Image(uiImage: $0) }, change: summary?.change)
    }
    private func photoInstruction(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("•")
                .font(TamrinFont.font(size: 18, weight: .medium))
            Text(text).multilineTextAlignment(.leading)
        }
        .font(TamrinFont.font(size: 14, weight: .medium))
    }

    private func instruction(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(TamrinFont.font(size: 17, weight: .bold)).foregroundStyle(.secondary)
            Text(text).font(TamrinFont.body).multilineTextAlignment(.leading)
        }
    }
    private func accept(_ data: Data) throws {
        guard let image = PlayerCardLibrary.decode(data) else { throw CocoaError(.fileReadCorruptFile) }
        sourcePortrait = image
        let detected = try? PlayerPortraitLayout.detect(in: image)
        placement = detected ?? PlayerPortraitLayout.centered(image)
        initialPlacement = placement
        framingMessage = detected != nil
            ? String(localized: "تم توحيد حجم الوجه وموضعه تلقائيًا. راجع الشعر والكتفين قبل المتابعة.")
            : String(localized: "لم نحدّد وجهًا واحدًا بوضوح. اضبط الحجم والموضع قبل المتابعة.")
        updateFraming()
        errorMessage = nil
    }
    private func framingSlider(_ title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(TamrinFont.footnote)
            Slider(value: value, in: range).accessibilityLabel(title)
                .environment(\.layoutDirection, .leftToRight)
        }
    }

    private func updateFraming() {
        guard let sourcePortrait else { return }
        portrait = PlayerPortraitLayout.render(sourcePortrait, placement: placement, width: 480)
    }

    private func move(to value: Stage) {
        errorMessage = nil
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.4)) { stage = value }
    }
    private func finish() {
        guard let id = feed.currentUserID, let sourcePortrait else {
            errorMessage = String(localized: "تعذّر تحديد الحساب لحفظ البطاقة. حاول مرة أخرى."); return
        }
        do {
            let finalPortrait = PlayerPortraitLayout.render(sourcePortrait, placement: placement)
            try PlayerCardLibrary.shared.save(finalPortrait, for: id)
            portrait = finalPortrait
            Haptics.success()
            move(to: .saved)
        } catch { errorMessage = String(localized: "تعذّر حفظ البطاقة على الجهاز. حاول مرة ثانية.") }
    }
    private func export(_ destination: PlayerCardShareDestination) {
        guard let portrait else { return }
        let renderer = ImageRenderer(content: PlayerCardExportView(name: name, position: position, overall: overall, scores: scores, portrait: portrait, size: destination.size, change: summary?.change))
        renderer.scale = 1
        if let image = renderer.uiImage { share = PlayerCardSharePayload(image: image) }
        else { errorMessage = String(localized: "تعذّر تجهيز المشاركة. حاول مرة أخرى.") }
    }

    #if DEBUG
    /// Deterministic Canvas states; these do not contact Supabase or a generation service.
    static func preview(_ screen: String, portrait: UIImage? = nil) -> PlayerCardPage {
        var page = PlayerCardPage(feed: .preview)
        page._stage = State(initialValue: screen == "saved" ? .saved : screen == "result" ? .result : screen == "processing" ? .processing : screen == "photo" ? .photo : .instructions)
        page._portrait = State(initialValue: portrait)
        page._delay = State(initialValue: 90)
        return page
    }
    #endif
}

#if DEBUG
#Preview("البطاقة · التعليمات") {
    PlayerCardPage.preview("instructions").background(Color.black.opacity(0.85))
}

#Preview("البطاقة · اختيار الصورة") {
    PlayerCardPage.preview("photo").background(Color.black.opacity(0.85))
}

#Preview("البطاقة · الانتظار") {
    PlayerCardPage.preview("processing").background(Color.black.opacity(0.85))
}

#Preview("البطاقة · النتيجة") {
    PlayerCardPage.preview("result").background(Color.black.opacity(0.85))
}
#endif
