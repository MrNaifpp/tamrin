import SwiftUI
import ContactsUI
import PhotosUI

struct ProfileSetupView: View {
    @Bindable var store: TamrinStore
    @State private var name = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var avatarData: Data?
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    welcomeHero

                    VStack(spacing: 18) {
                        PhotosPicker(selection: $photoItem, matching: .images) {
                            ZStack(alignment: .bottomTrailing) {
                                Group {
                                    if let avatarData, let image = UIImage(data: avatarData) {
                                        Image(uiImage: image).resizable().scaledToFill()
                                    } else {
                                        Circle().fill(Color(.systemGray5))
                                            .overlay(Image(systemName: "person.fill").font(.system(size: 35)).foregroundStyle(.white))
                                    }
                                }
                                .frame(width: 78, height: 78)
                                .clipShape(.circle)

                                Image(systemName: "camera.fill")
                                    .font(.caption.bold())
                                    .foregroundStyle(.white)
                                    .frame(width: 28, height: 28)
                                    .background(TamrinTheme.brandGreen, in: .circle)
                                    .overlay(Circle().stroke(Color(.systemGroupedBackground), lineWidth: 3))
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("اختيار الصورة الشخصية")

                        VStack(spacing: 5) {
                            Text("كمّل ملفك الشخصي").font(TamrinFont.title2)
                            Text("اسمك وصورتك هي اللي بيشوفونها أعضاء المجموعة.")
                                .font(.subheadline).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }

                        TextField("وش نناديك؟", text: $name)
                            .textContentType(.name)
                            .submitLabel(.done)
                            .focused($focused)
                            .font(TamrinFont.title3)
                            .tamrinCapsuleField(focused: focused)
                            .onSubmit(save)

                        Button("يلا نبدأ", action: save)
                            .buttonStyle(PrimaryActionStyle())
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .padding(.bottom, 28)
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .onChange(of: photoItem) { _, item in Task { avatarData = try? await item?.loadTransferable(type: Data.self) } }
    }

    private var welcomeHero: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.80, green: 0.95, blue: 0.86), .white, Color(red: 0.96, green: 0.98, blue: 0.86)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 18) {
                HStack(spacing: 34) {
                    Image(systemName: "figure.tennis").foregroundStyle(TamrinTheme.brandGreen).rotationEffect(.degrees(-12))
                    Image(systemName: "soccerball").foregroundStyle(.blue).offset(y: 20)
                    Image(systemName: "figure.run").foregroundStyle(.orange).offset(y: -8)
                }
                .font(.system(size: 34, weight: .medium))
                .padding(.top, 44)

                VStack(spacing: 2) {
                    Text("تمرين").font(TamrinFont.headline).foregroundStyle(.secondary)
                    Text("تجربة مثالية\nلإدارة التمارين")
                        .font(TamrinFont.font(size: 36, weight: .bold))
                        .multilineTextAlignment(.center)
                    Text("تبدأ من هنا")
                        .font(TamrinFont.font(size: 36, weight: .bold))
                        .foregroundStyle(TamrinTheme.brandGreen)
                }
                .padding(.bottom, 36)
            }
        }
        .frame(minHeight: 390)
        .clipShape(.rect(bottomLeadingRadius: 34, bottomTrailingRadius: 34))
    }

    private func save() {
        store.saveProfile(name: name, avatarData: avatarData)
    }
}

struct WelcomeView: View {
    @Bindable var store: TamrinStore
    @State private var showCreate: Bool
    @State private var showJoin = false

    init(store: TamrinStore, startInCreateFlow: Bool = false) {
        self.store = store
        _showCreate = State(initialValue: startInCreateFlow)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackdrop()
                VStack(alignment: .leading, spacing: 0) {
                    HStack { BrandMark(size: 56); Spacer(); Text("تمرين").font(TamrinFont.headline) }.padding(.top, 12)
                    Spacer()
                    Text("حيّاك \(store.profile?.name ?? "")")
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
                    Text("للتجربة السريعة استخدم الرمز MOVE24").font(.footnote).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity).padding(.bottom, 24)
                }
                .padding(.horizontal, 22)
            }
            .fullScreenCover(isPresented: $showCreate) { CreateTeamFlow(store: store, isPresented: $showCreate) }
            .sheet(isPresented: $showJoin) { JoinTeamView(store: store, isPresented: $showJoin) }
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
    @Bindable var store: TamrinStore
    @Binding var isPresented: Bool
    @State private var code = ""
    @State private var invalid = false

    private var normalized: String { code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
    private var previewTeam: Team? { store.teams.first { $0.inviteCode == normalized } }
    private var isDemo: Bool { normalized == "MOVE24" }

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
                    if isDemo || previewTeam != nil {
                        VStack(alignment: .leading, spacing: 16) {
                            SectionEyebrow(text: "معاينة المجموعة")
                            HStack(spacing: 14) {
                                if let previewTeam {
                                    TeamAvatarView(team: previewTeam, size: 54, cornerRadiusRatio: 15 / 54)
                                } else {
                                    ZStack { RoundedRectangle(cornerRadius: 15).fill(.black); Text("ر").font(TamrinFont.title2).foregroundStyle(.white) }
                                        .frame(width: 54, height: 54)
                                }
                                VStack(alignment: .leading) {
                                    Text(previewTeam?.name ?? "رفاق الملعب").font(TamrinFont.headline)
                                    Text(isDemo ? "كورة الثلاثاء · يومان أسبوعياً" : "مجموعة تمرين").font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(20).background(TamrinTheme.glass, in: .rect(cornerRadius: 24)).overlay(RoundedRectangle(cornerRadius: 24).stroke(TamrinTheme.hairline))
                        .transition(.scale.combined(with: .opacity))
                    }
                    if invalid { Label("الرمز غير صحيح. جرّب MOVE24.", systemImage: "exclamationmark.circle.fill").foregroundStyle(.red).font(.subheadline) }
                    Button("الانضمام للمجموعة") {
                        if store.join(code: normalized) { isPresented = false } else { invalid = true }
                    }
                    .buttonStyle(PrimaryActionStyle()).disabled(normalized.isEmpty)
                    }.padding(24)
                }
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button { isPresented = false } label: { Image(systemName: "xmark") } } }
            .animation(.snappy, value: isDemo || previewTeam != nil)
        }
        .presentationDragIndicator(.visible)
    }
}

struct ContactPicker: UIViewControllerRepresentable {
    @Binding var names: [String]
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController(); picker.delegate = context.coordinator
        picker.predicateForEnablingContact = NSPredicate(value: true); return picker
    }
    func updateUIViewController(_ uiViewController: CNContactPickerViewController, context: Context) {}

    final class Coordinator: NSObject, CNContactPickerDelegate {
        var parent: ContactPicker
        init(parent: ContactPicker) { self.parent = parent }
        func contactPicker(_ picker: CNContactPickerViewController, didSelect contacts: [CNContact]) {
            let formatter = CNContactFormatter()
            let newNames = contacts.compactMap { formatter.string(from: $0) }.filter { !$0.isEmpty }
            parent.names = Array(Set(parent.names + newNames)).sorted(); parent.dismiss()
        }
    }
}
