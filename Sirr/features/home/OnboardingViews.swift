import SwiftUI

/// New-user / empty-state screens — the designer's WelcomeView + JoinTeamView
/// bound to HomeStore. Shown by DesignerHomeView when `feed.teams.isEmpty`
/// (fresh signup, or after deleting your last group): pick "create a group" or
/// "join by invite code". ProfileSetupView and ContactPicker from the designer's
/// OnboardingViews.swift are intentionally not ported here (the create-group
/// wizard invites by shareable link, not from contacts; profile setup isn't part
/// of this increment).
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
                    Text("اختر كيف تبدأ، والباقي علينا.").font(TamrinFont.title3).foregroundStyle(.secondary).padding(.top, 8)
                    Spacer().frame(height: 34)
                    Button { showCreate = true } label: {
                        WelcomeChoiceCard(title: "أنشئ مجموعتك", subtitle: "رتّب روتين اللعب وادعُ الربع", symbol: "sparkles", accent: TamrinTheme.lime)
                    }.buttonStyle(SpringCardPressStyle())
                    Button { showJoin = true } label: {
                        WelcomeChoiceCard(title: "انضم لمجموعة", subtitle: "ادخل برمز الدعوة ووفر مكانك", symbol: "link", accent: TamrinTheme.secondary)
                    }.buttonStyle(SpringCardPressStyle()).padding(.top, 12)
                    Spacer()
                    Text("مجموعاتك خاصة — ما يدخلها إلا بدعوة").font(TamrinFont.footnote).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity).padding(.bottom, 24)
                }
                .padding(.horizontal, 22)
            }
            .fullScreenCover(isPresented: $showCreate) { CreateTeamFlow(feed: feed, isPresented: $showCreate) }
            .sheet(isPresented: $showJoin) { JoinTeamView(feed: feed, isPresented: $showJoin) }
        }
    }
}

/// Both choices sit on the same surface — the ranking between them is carried
/// by the accent behind the glyph, not by one card being a black slab. Two
/// competing surfaces read as two unrelated controls.
private struct WelcomeChoiceCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    let accent: Color
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .bold))
                .frame(width: 50, height: 50)
                .background(accent, in: .circle)
                .foregroundStyle(TamrinTheme.ink)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(TamrinFont.title3)
                Text(subtitle).font(TamrinFont.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.left").font(.caption.bold()).opacity(0.55)
        }
        .foregroundStyle(.primary)
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 100)
        .background(TamrinTheme.glass, in: .rect(cornerRadius: 26))
        .shadow(color: .black.opacity(0.04), radius: 22, y: 10)
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
            VStack(alignment: .leading, spacing: 18) {
                Text("ألصق رمز الدعوة الذي وصلك من مشرف المجموعة.")
                    .font(TamrinFont.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextField("رمز الانضمام", text: $code)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(TamrinFont.font(size: 22, weight: .bold))
                .multilineTextAlignment(.center)
                .kerning(3)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
                .background(TamrinTheme.secondary, in: .rect(cornerRadius: 20, style: .continuous))
                .onChange(of: code) { _, _ in invalid = false }

            if let preview {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 15, style: .continuous).fill(TamrinTheme.ink)
                        Image(systemName: "figure.soccer").foregroundStyle(.white)
                    }
                    .frame(width: 48, height: 48)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(preview.name).font(TamrinFont.font(size: 16, weight: .bold))
                        Text(preview.memberCount.counted(.member) + (preview.ownerName.map { " · \($0)" } ?? ""))
                            .font(TamrinFont.font(size: 12, weight: .regular))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)
                }
                .padding(14)
                .background(TamrinTheme.card, in: .rect(cornerRadius: 22, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if invalid {
                Label("الرمز غير صحيح. تأكد منه وحاول مرة ثانية.", systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(TamrinFont.font(size: 13, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }

            TamrinActionButton(
                title: preview?.isMember == true ? "أنت عضو بالفعل" : "الانضمام للمجموعة",
                isLoading: joining
            ) {
                joining = true
                Task {
                    let ok = await feed.join(code: normalized)
                    joining = false
                    if ok { isPresented = false } else { invalid = true }
                }
            }
            .disabled(normalized.isEmpty || joining)
            .padding(.top, 2)
            }
            .padding(.horizontal, 22)
            .padding(.top, 14)
            .padding(.bottom, 18)
            // Measured before the expanding frame below, so the sheet's
            // detent follows the content rather than the NavigationStack.
            .sheetContentHeight()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle("انضم إلى مجموعة")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إلغاء", role: .cancel) { isPresented = false }
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .animation(.smooth(duration: 0.3), value: preview != nil)
        .animation(.smooth(duration: 0.3), value: invalid)
        .task(id: normalized) { preview = await feed.invitePreview(code: normalized) }
        .fittedSheet(includesNavigationBar: true)
    }
}
