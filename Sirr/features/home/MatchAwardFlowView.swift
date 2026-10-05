import SwiftUI
import Combine

struct MatchAwardFlowView: View {
    @State private var model: MatchAwardModel
    @State private var nominated: [UUID] = []
    @State private var focusedID: UUID?
    @State private var isChangingVote = false
    @Namespace private var cardTransition
    @State private var confirmsNomination = false
    @State private var workspaceID: UUID?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    private let accent = Color.white
    private let artName: String

    init(eventID: UUID, model: MatchAwardModel? = nil, artName: String = "ExerciseArt1") {
        self.artName = artName
        #if DEBUG
        _model = State(initialValue: model ?? (eventID == HomeDebugMemberFixture.matchAwardEventID
            ? MatchAwardModel.scenarioModel : MatchAwardModel(eventID: eventID)))
        #else
        _model = State(initialValue: model ?? MatchAwardModel(eventID: eventID))
        #endif
    }

    var body: some View {
        NavigationStack {
            ZStack {
                backdrop
                if let award = model.award {
                    content(award)
                        .animation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.85), value: chosenPlayer(award)?.id)
                } else if model.isLoading {
                    ProgressView().tint(accent)
                } else {
                    ContentUnavailableView {
                        Label("رجل المباراة", systemImage: "trophy")
                    } description: {
                        Text(model.error ?? String(localized: "تعذّر تحميل التصويت"))
                    } actions: {
                        Button("إعادة المحاولة") { Task { await model.load() } }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إغلاق", systemImage: "xmark") { dismiss() }.tint(.white)
                }
                ToolbarItem(placement: .principal) {
                    Text(model.award?.title ?? String(localized: "رجل المباراة"))
                        .font(TamrinFont.font(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.65))
                }
                #if DEBUG
                if model.eventID == HomeDebugMemberFixture.matchAwardEventID {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            if model.award?.status == .open {
                                Button("إنهاء التصويت التجريبي") { model.finishDemo() }
                            }
                            Button("إعادة التجربة من البداية") {
                                nominated = []
                                isChangingVote = false
                                model.resetScenario()
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }.accessibilityLabel("خيارات التجربة")
                    }
                }
                #endif
                ToolbarItem(placement: .topBarTrailing) {
                    Button("تحديث", systemImage: "arrow.clockwise") { Task { await model.load() } }
                        .tint(accent).disabled(model.isLoading || model.isSaving)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let award = model.award { bottomAction(award) }
            }
        }
        .preferredColorScheme(.dark)
        .environment(\.layoutDirection, .tamrin)
        .task { await model.load() }
        .task(id: model.eventID) {
            guard !model.isDemo else { return }
            if let event = try? await EventService.shared.getEventById(model.eventID) {
                workspaceID = event.workspaceId
            }
        }
        .task(id: model.award?.closesAt) {
            guard !model.isDemo, let close = model.award?.closesAt, close > .now else { return }
            do { try await Task.sleep(for: .seconds(close.timeIntervalSinceNow + 0.2)) }
            catch { return }
            await model.load()
        }
        .onReceive(NotificationCenter.default.publisher(for: .eventPushReceived)) { _ in
            Task { await model.load() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.load() } }
        }
        .onChange(of: model.award?.status) { _, _ in
            focusedID = model.award.flatMap { initialCardID($0) }
        }
        .confirmationDialog("نشر المرشحين الثلاثة؟", isPresented: $confirmsNomination, titleVisibility: .visible) {
            Button("نشر وفتح التصويت") { Task { await model.nominate(nominated) } }
        } message: {
            Text("سيصل تنبيه للاعبين المسجلين. يستمر التصويت 24 ساعة، ولا يمكن تغيير المرشحين بعد النشر.")
        }
    }

    @ViewBuilder
    private var backdrop: some View {
        if model.award?.status == .nomination {
            GeometryReader { proxy in
                ZStack {
                    Image(exerciseArt: artName)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .blur(radius: 26, opaque: true)
                    Color.black.opacity(0.46)
                }
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)
        } else {
            playerBackdrop
        }
    }

    private var playerBackdrop: some View {
        GeometryReader { proxy in
            ZStack {
                Color(white: 0.12)
                if let award = model.award,
                   let player = award.players.first(where: { $0.id == (chosenPlayer(award)?.id ?? focusedID ?? initialCardID(award)) }) {
                    MatchAwardPlayerCard(player: player, isDemo: model.isDemo, backgroundOnly: true)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .blur(radius: 38)
                        .scaleEffect(1.15)
                        .id(player.id)
                        .transition(.opacity)
                }
                Color.black.opacity(0.56)
                LinearGradient(colors: [.black.opacity(0.12), .clear, .black.opacity(0.3)],
                               startPoint: .top, endPoint: .bottom)
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: focusedID)
        }.ignoresSafeArea().accessibilityHidden(true)
    }

    @ViewBuilder
    private func content(_ award: MatchAward) -> some View {
        if award.status == .nomination {
            nomination(award)
        } else if let player = chosenPlayer(award) {
            chosenCard(player)
        } else if award.status == .open || award.status == .closed {
            ballot(award)
        } else {
            ContentUnavailableView("التصويت غير متاح", systemImage: "trophy",
                description: Text("يبدأ الترشيح بعد نهاية التمرين بخمس دقائق."))
        }
    }

    private func heading(_ title: String, subtitle: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "trophy.fill").font(.system(size: 28)).foregroundStyle(accent)
            Text(title).font(TamrinFont.font(size: 32, weight: .bold)).foregroundStyle(.white)
            Text(subtitle).font(TamrinFont.font(size: 14, weight: .regular))
                .foregroundStyle(.white.opacity(0.58)).multilineTextAlignment(.center)
        }.padding(.horizontal, 24).padding(.top, 12)
    }

    private func nomination(_ award: MatchAward) -> some View {
        ScrollView {
            VStack(spacing: 26) {
                heading(String(localized: "من صنع الفارق؟"), subtitle: award.canNominate
                    ? String(localized: "رشّح ثلاثة لاعبين، وخلّ الاختيار للفريق.")
                    : String(localized: "بانتظار ترشيحات المشرف. يلزم وجود ثلاثة لاعبين مسجلين على الأقل."))
                if award.canNominate {
                    HStack(spacing: 12) {
                        ForEach(0..<3) { index in
                            let player = nominated.indices.contains(index)
                                ? award.players.first { $0.id == nominated[index] } : nil
                            VStack(spacing: 8) {
                                ZStack {
                                    Circle().strokeBorder(accent.opacity(0.18), lineWidth: 3)
                                    if let player {
                                        MemberAvatar(name: player.name, size: 56, imageUrl: player.avatarURL)
                                    } else {
                                        Text("\(index + 1)").font(TamrinFont.font(size: 22, weight: .medium)).foregroundStyle(accent)
                                    }
                                }.frame(width: 64, height: 64)
                                Text(player?.name.components(separatedBy: " ").first ?? String(localized: "مرشّح"))
                                    .font(TamrinFont.font(size: 12, weight: .medium)).lineLimit(1)
                            }.frame(maxWidth: .infinity)
                        }
                    }.padding(.horizontal, 32)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(award.players) { player in nominationTile(player) }
                    }.padding(.horizontal, 20)
                }
            }.padding(.bottom, 20)
        }
    }

    private func nominationTile(_ player: MatchAwardPlayer) -> some View {
        let selected = nominated.contains(player.id)
        return Button {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
                if selected { nominated.removeAll { $0 == player.id } }
                else if nominated.count < 3 { nominated.append(player.id) }
            }
            Haptics.selection()
        } label: {
            VStack(spacing: 10) {
                HStack {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? accent : .white.opacity(0.25))
                    Spacer()
                    Text(PlayerCardView.positionTitle(player.position)).font(TamrinFont.font(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                }
                MemberAvatar(name: player.name, size: 70, imageUrl: player.avatarURL)
                Text(player.name).font(TamrinFont.font(size: 15, weight: .bold))
                    .foregroundStyle(.white).lineLimit(2).frame(height: 42)
            }
            .padding(14).frame(maxWidth: .infinity)
            .background(selected ? accent.opacity(0.12) : .white.opacity(0.04), in: .rect(cornerRadius: 24))
            .scaleEffect(selected && !reduceMotion ? 0.97 : 1)
        }
        .buttonStyle(.plain)
        .disabled(!selected && nominated.count == 3)
        .accessibilityLabel(player.name)
        .accessibilityValue(selected ? String(localized: "مرشّح") : String(localized: "غير محدد"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func chosenPlayer(_ award: MatchAward) -> MatchAwardPlayer? {
        guard award.status == .open, !isChangingVote, let votedID = award.myVoteId else { return nil }
        return award.players.first { $0.id == votedID }
    }

    // Figma 624:23186: two centered lines, 28 bold / 20 medium, 8pt gap.
    private func votingHeading(_ title: String) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(TamrinFont.font(size: 28, weight: .bold))
                .foregroundStyle(.white)
            Text("لرجل المباراة")
                .font(TamrinFont.font(size: 20, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
        }
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .combine)
    }

    private func chosenCard(_ player: MatchAwardPlayer) -> some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 18) {
                    votingHeading(String(localized: "تصويتك")).padding(.top, 20)
                    Spacer(minLength: 12)
                    let width = min(280, proxy.size.width * 0.72, max(180, (proxy.size.height - 245) * PlayerCardView.aspectRatio))
                    MatchAwardPlayerCard(player: player, workspaceID: workspaceID, isDemo: model.isDemo)
                        .frame(width: width, height: width / PlayerCardView.aspectRatio)
                        .matchedGeometryEffect(id: player.id, in: cardTransition)
                        .shadow(color: .white.opacity(0.12), radius: 32)
                    VStack(spacing: 10) {
                        Text(player.name)
                            .font(TamrinFont.font(size: 24, weight: .bold))
                        Label("تصويتك · بانتظار النتائج", systemImage: "checkmark.circle")
                            .font(TamrinFont.font(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .padding(.top, 8)
                    Spacer(minLength: 16)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                .padding(.bottom, 12)
            }.scrollIndicators(.hidden)
        }
        .accessibilityElement(children: .contain)
    }

    private func ballot(_ award: MatchAward) -> some View {
        GeometryReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 18) {
                    Group {
                        if award.status == .closed {
                            Text(resultTitle(award))
                                .font(TamrinFont.font(size: 26, weight: .bold)).foregroundStyle(.white)
                        } else {
                            votingHeading(String(localized: "صوت"))
                        }
                    }.padding(.top, 16)
                    Spacer(minLength: 20)
                    let cardWidth = min(240, proxy.size.width * 0.60)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 16) {
                            ForEach(award.players) { player in
                                VStack(spacing: 12) {
                                    MatchAwardPlayerCard(player: player, workspaceID: workspaceID, isDemo: model.isDemo)
                                        .frame(width: cardWidth, height: cardWidth / PlayerCardView.aspectRatio)
                                        .matchedGeometryEffect(id: player.id, in: cardTransition)
                                        .overlay(alignment: .top) {
                                            if award.winners.contains(where: { $0.id == player.id }) {
                                                Label("رجل المباراة", systemImage: "trophy.fill")
                                                    .font(TamrinFont.font(size: 13, weight: .bold))
                                                    .padding(.horizontal, 14).padding(.vertical, 9)
                                                    .foregroundStyle(.black).background(accent, in: .capsule)
                                                    .offset(y: -10)
                                            }
                                        }
                                    if let votes = player.votes, award.status == .closed {
                                        Text("\(votes) أصوات").font(TamrinFont.font(size: 15, weight: .bold)).foregroundStyle(accent)
                                    }
                                }
                                .frame(width: cardWidth)
                                .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                                    content
                                        .scaleEffect(reduceMotion ? 1 : (phase.isIdentity ? 1 : 0.833))
                                        .opacity(phase.isIdentity ? 1 : 0.4)
                                        .rotation3DEffect(.degrees(reduceMotion ? 0 : phase.value * -9), axis: (x: 0, y: 1, z: 0))
                                }
                                .id(player.id)
                            }
                        }.scrollTargetLayout().padding(.vertical, 14)
                    }
                    .contentMargins(.horizontal, (proxy.size.width - cardWidth) / 2, for: .scrollContent)
                    .scrollTargetBehavior(.viewAligned)
                    .scrollPosition(id: $focusedID, anchor: .center)
                    // Physical swipe geometry is LTR; each card keeps its own Arabic typography.
                    .environment(\.layoutDirection, .leftToRight)
                    .onAppear { if focusedID == nil { focusedID = initialCardID(award) } }
                    .onChange(of: focusedID) { _, _ in Haptics.selection() }
                    HStack(spacing: 7) {
                        ForEach(award.players) { player in
                            Capsule().fill(focusedID == player.id ? accent : .white.opacity(0.2))
                                .frame(width: focusedID == player.id ? 22 : 6, height: 6)
                        }
                    }.environment(\.layoutDirection, .leftToRight).accessibilityHidden(true)
                    if award.status == .open, let closes = award.closesAt {
                        HStack(spacing: 5) {
                            Text("ينتهي")
                            Text(closes, style: .relative)
                        }.font(TamrinFont.font(size: 12, weight: .regular)).foregroundStyle(.white.opacity(0.45))
                    }
                    Spacer(minLength: 24)
                }.frame(minHeight: proxy.size.height).padding(.bottom, 16)
            }.scrollIndicators(.hidden)
        }
    }

    private func initialCardID(_ award: MatchAward) -> UUID? {
        if let voted = award.myVoteId { return voted }
        if let winner = award.winners.first { return winner.id }
        return award.players.count > 1 ? award.players[1].id : award.players.first?.id
    }

    private func resultTitle(_ award: MatchAward) -> String {
        if award.winners.isEmpty { return String(localized: "انتهى التصويت") }
        return award.winners.count > 1 ? String(localized: "نجوم المباراة") : String(localized: "نجمها باختياركم")
    }

    private func bottomAction(_ award: MatchAward) -> some View {
        VStack(spacing: 10) {
            if let error = model.error {
                Text(error).font(TamrinFont.font(size: 12, weight: .medium)).foregroundStyle(.orange).multilineTextAlignment(.center)
            }
            if let message = model.confirmation, award.status == .nomination {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(TamrinFont.font(size: 12, weight: .medium)).foregroundStyle(accent)
            }
            if award.canNominate {
                actionButton(String(localized: "نشر المرشحين · \(nominated.count)/3"), disabled: nominated.count != 3) { confirmsNomination = true }
                Text("التصويت سرّي. النتيجة تظهر بعد 24 ساعة.").font(TamrinFont.font(size: 12, weight: .regular)).foregroundStyle(.white.opacity(0.5))
            } else if let chosen = chosenPlayer(award) {
                actionButton(String(localized: "تم")) { dismiss() }
                if award.canVote {
                    Button("تغيير اختياري") {
                        focusedID = chosen.id
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) {
                            isChangingVote = true
                        }
                    }
                    .font(TamrinFont.font(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.vertical, 6)
                }
            } else if award.status == .open {
                let player = award.players.first { $0.id == focusedID } ?? award.players.first
                let alreadySelected = award.myVoteId == player?.id
                let playerName = player?.name ?? String(localized: "اللاعب")
                MatchAwardHoldButton(
                    title: alreadySelected ? String(localized: "تصويتك ✓") : String(localized: "صوّت لـ \(playerName)"),
                    disabled: !award.canVote || alreadySelected || player == nil,
                    isSaving: model.isSaving
                ) {
                    if let player {
                        Task {
                            if await model.vote(player.id) {
                                focusedID = player.id
                                withAnimation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.85)) {
                                    isChangingVote = false
                                }
                            }
                        }
                    }
                }
                .id(player?.id)
                if isChangingVote {
                    Button("الاحتفاظ باختياري السابق") {
                        focusedID = award.myVoteId
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) { isChangingVote = false }
                    }
                    .font(TamrinFont.font(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .disabled(model.isSaving)
                }
                if !award.canVote {
                    Text("التصويت للمسجلين في الموعد فقط")
                        .font(TamrinFont.font(size: 12, weight: .regular)).foregroundStyle(.secondary)
                }
            } else if award.status == .closed {
                Text(award.totalVotes == 0 ? String(localized: "لم تُسجّل أصوات هذه المرة.") : String(localized: "\(award.totalVotes ?? 0) أصوات · شكرًا لكل من شارك"))
                    .font(TamrinFont.font(size: 14, weight: .medium)).foregroundStyle(accent)
                actionButton(String(localized: "تم")) { dismiss() }
            }
            #if DEBUG
            if model.isDemo, award.status == .open, chosenPlayer(award) == nil {
                Button("تجربة: إنهاء التصويت وعرض النتيجة") { withAnimation { model.finishDemo() } }
                    .font(TamrinFont.font(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.45))
            }
            #endif
        }.padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 12)
            .frame(maxWidth: .infinity)
    }

    private func actionButton(_ title: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        TamrinActionButton(title: title, isLoading: model.isSaving,
                           prominent: false, action: action)
            .disabled(disabled || model.isSaving)
    }
}

private struct MatchAwardPlayerCard: View {
    let player: MatchAwardPlayer
    var workspaceID: UUID?
    var isDemo = false
    var backgroundOnly = false
    @State private var localPortrait: UIImage?
    @State private var rating: PlayerRatingSummary?

    private var demoAsset: String? {
        guard isDemo else { return nil }
        switch player.name {
        case "أحمد رشوان": return "MatchAwardDemoAhmed"
        case "لؤي الزهراني": return "MatchAwardDemoLoai"
        case "مراد الجهني": return "MatchAwardDemoMorad"
        default: return nil
        }
    }
    private var demoScores: PlayerRatingScores? {
        switch demoAsset {
        case "MatchAwardDemoAhmed": return PlayerRatingScores(pace: 71, passing: 61, shooting: 63, stamina: 78, defending: 89, awareness: 63)
        case "MatchAwardDemoLoai": return PlayerRatingScores(pace: 81, passing: 86, shooting: 91, stamina: 77, defending: 62, awareness: 85)
        case "MatchAwardDemoMorad": return PlayerRatingScores(pace: 90, passing: 82, shooting: 84, stamina: 81, defending: 71, awareness: 83)
        default: return nil
        }
    }
    var body: some View {
        Group {
            if let demoAsset {
                card(Image(demoAsset))
            } else if let localPortrait {
                card(Image(uiImage: localPortrait))
            } else if let raw = player.portraitURL, let url = URL(string: raw) {
                AsyncImage(url: url) { phase in
                    card(phase.image)
                }
            } else {
                card(nil)
            }
        }
        .task(id: player.id) {
            localPortrait = PlayerCardLibrary.shared.portrait(for: player.userId)
            #if DEBUG
            // Demo portraits stay in the bundle and never generate paid images.
            if localPortrait == nil, let raw = player.avatarURL, let url = URL(string: raw), url.isFileURL {
                localPortrait = UIImage(contentsOfFile: url.path)
            }
            #endif
        }
        .task(id: workspaceID) {
            guard !backgroundOnly, !isDemo, let workspaceID, let userID = player.userId else { return }
            rating = try? await RatingService.shared.getPlayerRating(workspaceId: workspaceID, userId: userID)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("بطاقة \(player.name)، \(PlayerCardView.positionTitle(player.position))")
    }
    @ViewBuilder
    private func card(_ portrait: Image?) -> some View {
        if backgroundOnly {
            GeometryReader { proxy in
                ZStack {
                    Color(white: 0.96)
                    if let portrait {
                        portrait.resizable().scaledToFill()
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipped()
                    }
                }
            }
        } else {
        PlayerCardView(name: player.name, position: player.position,
            overall: demoScores != nil ? (demoAsset == "MatchAwardDemoAhmed" ? 74 : 82) : (rating?.averageOverall ?? 50),
            scores: demoScores ?? rating?.average ?? .neutral,
            portrait: portrait, showsScores: demoScores != nil || rating?.average != nil,
            portraitRect: demoAsset != nil ? CGRect(x: 0.1, y: 0.045, width: 0.8, height: 0.875) : nil)
            .overlay {
                if portrait == nil {
                    Image(systemName: "person.fill")
                        .resizable().scaledToFit().foregroundStyle(.black.opacity(0.08))
                        .padding(60).offset(y: -20).allowsHitTesting(false)
                }
            }
    }
    }
}
