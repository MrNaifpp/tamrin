import SwiftUI

/// New-user / empty-state screens — the designer's WelcomeView + JoinTeamView
/// bound to HomeStore. Shown by DesignerHomeView when `feed.teams.isEmpty`
/// (fresh signup, or after deleting your last group): pick "create a group" or
/// "join by invite code". ProfileSetupView and ContactPicker from the designer's
/// OnboardingViews.swift are intentionally not ported here (ContactPicker already
/// lives in CreateTeamFlow.swift; profile setup isn't part of this increment).
struct WelcomeView: View {
    @Bindable var feed: HomeStore
    @State private var showCreate: Bool
    @State private var showJoin = false

    init(feed: HomeStore, startInCreateFlow: Bool = false) {
        self.feed = feed
        _showCreate = State(initialValue: startInCreateFlow)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackdrop()
                VStack(alignment: .leading, spacing: 0) {
                    HStack { BrandMark(size: 56); Spacer(); Text("تمرين").font(TamrinFont.headline) }.padding(.top, 12)
                    Spacer()
                    Text("حيّاك \(feed.profileName)")
                        .font(TamrinFont.display).tracking(-1)
                    Text("اختر كيف تبدأ، والباقي علينا.").font(.title3).foregroundStyle(.secondary).padding(.top, 8)
                    Spacer().frame(height: 34)
                    Button { showCreate = true } label: {
                        WelcomeChoiceCard(title: "أنشئ مجموعتك", subtitle: "رتّب روتين اللعب وادعُ الربع", symbol: "sparkles", dark: true)
                    }.buttonStyle(SpringCardPressStyle())
                    Button { showJoin = true } label: {
                        WelcomeChoiceCard(title: "انضم لمجموعة", subtitle: "ادخل برمز الدعوة ووفر مكانك", symbol: "link", dark: false)
                    }.buttonStyle(SpringCardPressStyle()).padding(.top, 12)
                    Spacer()
                    Text("مجموعاتك خاصة — ما يدخلها إلا بدعوة").font(.footnote).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity).padding(.bottom, 24)
                }
                .padding(.horizontal, 22)
            }
            .fullScreenCover(isPresented: $showCreate) { CreateTeamFlow(feed: feed, isPresented: $showCreate) }
            .sheet(isPresented: $showJoin) { JoinTeamView(feed: feed, isPresented: $showJoin) }
        }
    }
}

private struct WelcomeChoiceCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    let dark: Bool
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: symbol).font(.title2.bold()).frame(width: 54, height: 54)
                .background(dark ? TamrinTheme.lime : TamrinTheme.secondary, in: .circle)
                .foregroundStyle(TamrinTheme.ink)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(TamrinFont.title3)
                Text(subtitle).font(.subheadline).foregroundStyle(dark ? .white.opacity(0.6) : .secondary)
            }
            Spacer()
            Image(systemName: "chevron.left").font(.caption.bold()).opacity(0.55)
        }
        .foregroundStyle(dark ? .white : .primary)
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 104)
        .background(dark ? TamrinTheme.ink : TamrinTheme.glass, in: .rect(cornerRadius: 28))
        .overlay(RoundedRectangle(cornerRadius: 28).stroke(.white.opacity(0.8)))
        .shadow(color: .black.opacity(dark ? 0.14 : 0.04), radius: 22, y: 10)
    }
}

struct JoinTeamView: View {
    @Bindable var feed: HomeStore
    @Binding var isPresented: Bool
    @State private var code = ""
    @State private var invalid = false
    @State private var joining = false
    @State private var preview: WorkspaceInvitePreview?

    private var normalized: String { code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackdrop(intensity: 0.72)
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("انضم إلى مجموعة").font(TamrinFont.largeTitle)
                        Text("ألصق رمز الدعوة الذي وصلك من مشرف المجموعة.").foregroundStyle(.secondary)
                    }
                    TextField("رمز الانضمام", text: $code)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .font(.title2.monospaced().weight(.semibold)).multilineTextAlignment(.center)
                        .padding(18).background(TamrinTheme.glass, in: .rect(cornerRadius: 20))
                        .onChange(of: code) { _, _ in invalid = false }
                    if let preview {
                        VStack(alignment: .leading, spacing: 16) {
                            SectionEyebrow(text: "معاينة المجموعة")
                            HStack(spacing: 14) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 15).fill(.black)
                                    Image(systemName: "figure.soccer").foregroundStyle(.white)
                                }
                                .frame(width: 54, height: 54)
                                VStack(alignment: .leading) {
                                    Text(preview.name).font(TamrinFont.headline)
                                    Text("\(preview.memberCount) عضو" + (preview.ownerName.map { " · \($0)" } ?? ""))
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(20).background(TamrinTheme.glass, in: .rect(cornerRadius: 24)).overlay(RoundedRectangle(cornerRadius: 24).stroke(TamrinTheme.hairline))
                        .transition(.scale.combined(with: .opacity))
                    }
                    if invalid { Label("الرمز غير صحيح. تأكد منه وحاول مرة ثانية.", systemImage: "exclamationmark.circle.fill").foregroundStyle(.red).font(.subheadline) }
                    Button(preview?.isMember == true ? "أنت عضو بالفعل" : "الانضمام للمجموعة") {
                        joining = true
                        Task {
                            let ok = await feed.join(code: normalized)
                            joining = false
                            if ok { isPresented = false } else { invalid = true }
                        }
                    }
                    .buttonStyle(PrimaryActionStyle()).disabled(normalized.isEmpty || joining)
                    }.padding(24)
                }
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button { isPresented = false } label: { Image(systemName: "xmark") } } }
            .animation(.snappy, value: preview != nil)
            .task(id: normalized) { preview = await feed.invitePreview(code: normalized) }
        }
        .presentationDragIndicator(.visible)
    }
}
