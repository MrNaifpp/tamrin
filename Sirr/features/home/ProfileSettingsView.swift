import SwiftUI
import PhotosUI

/// Account sheet. Deliberately narrow in scope — a photo, a name and a pitch
/// position — so it fits on screen in one piece instead of the old
/// overview-then-editor pair that needed two detents and a mode switch.
///
/// Signing out lives in `AppSettingsView` next to account deletion, so the two
/// session-ending actions sit together instead of one hiding behind an editor —
/// and that screen is pushed from here, since the profile photo is now the one
/// way into everything about you and your copy of the app.
struct ProfileSettingsView: View {
    @Bindable var feed: HomeStore
    /// True when pushed onto the settings sheet's navigation stack rather than
    /// presented as its own sheet. A pushed copy must not build a second
    /// NavigationStack or apply its own detent, and it drops إلغاء because the
    /// system back button is already the way out.
    var isPushed: Bool = false
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var position = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var avatarData: Data?
    /// Set by «حذف الصورة». Distinct from `avatarData == nil`, which is also
    /// true for a profile that simply never had a photo — only this says the
    /// stored one should go.
    @State private var avatarRemoved = false
    @State private var showPhotoPicker = false
    @FocusState private var nameFocused: Bool

    private let positions = ["حارس", "دفاع", "وسط", "هجوم"]

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Group {
            if isPushed {
                form
            } else {
                NavigationStack { form }
                    .fittedSheet(includesNavigationBar: true)
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .task(id: photoItem) {
            guard let photoItem, let data = await photoItem.loadAvatarData() else { return }
            avatarData = data
            // Picking after removing is a change of mind, not both edits.
            avatarRemoved = false
        }
        .onAppear {
            name = feed.profileName
            avatarData = feed.avatarData
            // Dismissing without saving abandons the removal. This view is also
            // pushed inside the settings stack, where its state outlives a pop,
            // so a stale flag would delete the photo on an unrelated later save.
            avatarRemoved = false
            // A position stored before the four became the only choices —
            // anything typed by hand — is simply not preselected, so saving
            // replaces it with one of the four.
            let saved = feed.playerPosition
            if positions.contains(saved) { position = saved }
        }
    }

    private var form: some View {
        VStack(spacing: 20) {
            avatarPicker
            nameField
            positionPicker
            // Settings live behind the profile photo, one level in: how the app
            // behaves is a rarer errand than fixing your own name, and it has
            // no other door now that the group drawer is gone.
            if !isPushed { settingsLink }
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 18)
        // Measured before the expanding frame below, so the sheet's detent
        // follows the content rather than the NavigationStack. Still wanted when
        // pushed: the settings sheet reduces these heights with max() and allows
        // expansion, so it grows to fit this form and shrinks back on pop.
        .sheetContentHeight()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("حسابي")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Pushed, the system back button already returns to الإعدادات, and a
            // second affordance beside it would read as cancelling the whole
            // sheet rather than going back one level.
            if !isPushed {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إلغاء", role: .cancel) { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("حفظ") { save() }
                    .disabled(trimmedName.isEmpty)
                    .fontWeight(.semibold)
            }
        }
    }

    private var settingsLink: some View {
        NavigationLink {
            AppSettingsView(feed: feed, isPushed: true)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "gearshape")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28)

                Text("الإعدادات")
                    .font(TamrinFont.font(size: 17, weight: .medium))
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)

                Image(systemName: "chevron.forward")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity)
            .background(TamrinTheme.card, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityHint("التنبيهات والهابتك وتسجيل الخروج")
    }

    /// A photo to act on: one picked this session, or one already on the profile
    /// and not removed since the sheet opened.
    private var hasPhoto: Bool {
        avatarData != nil || (!avatarRemoved && feed.avatarUrl != nil)
    }

    /// With a photo on screen there are two things to do to it, so the tap opens
    /// a menu. With none there is only one, and a dropdown of a single item is
    /// a worse way to say "pick a photo" than the picker itself.
    @ViewBuilder
    private var avatarPicker: some View {
        if hasPhoto {
            Menu {
                Button("اختر صورة", systemImage: "photo") { showPhotoPicker = true }
                Button("حذف الصورة", systemImage: "trash", role: .destructive) {
                    withAnimation(.snappy(duration: 0.2)) {
                        avatarData = nil
                        photoItem = nil
                        avatarRemoved = true
                    }
                }
            } label: {
                avatarLabel
            }
            .buttonStyle(.plain)
            .accessibilityLabel("صورة الحساب")
            .accessibilityHint("يفتح خيارات تغيير الصورة أو حذفها")
        } else {
            Button {
                showPhotoPicker = true
            } label: {
                avatarLabel
            }
            .buttonStyle(.plain)
            .accessibilityLabel("إضافة صورة الحساب")
        }
    }

    private var avatarLabel: some View {
        ZStack(alignment: .bottomTrailing) {
                Group {
                    if let avatarData, let image = UIImage(data: avatarData) {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else if !avatarRemoved, let url = feed.avatarUrl.flatMap(URL.init(string:)) {
                        // Nothing picked this session, but a photo is already on
                        // the profile — show it rather than falling back to the
                        // initial the user thought they had replaced.
                        AsyncImage(url: url) { phase in
                            if case .success(let image) = phase {
                                image.resizable().scaledToFill()
                            } else {
                                Circle().fill(TamrinTheme.secondary)
                            }
                        }
                    } else {
                        Circle()
                            .fill(TamrinTheme.secondary)
                            .overlay {
                                Text(trimmedName.isEmpty ? "" : String(trimmedName.prefix(1)))
                                    .font(TamrinFont.font(size: 30, weight: .bold))
                                    .foregroundStyle(.primary)
                            }
                            .overlay {
                                if trimmedName.isEmpty {
                                    Image(systemName: "person.fill")
                                        .font(.system(size: 30, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                    }
                }
                .frame(width: 88, height: 88)
                .clipShape(.circle)

                Image(systemName: "camera.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(TamrinTheme.ink, in: .circle)
                    .overlay(Circle().strokeBorder(TamrinTheme.page, lineWidth: 2))
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("اسمك")
                .font(TamrinFont.font(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("الاسم", text: $name)
                .font(TamrinFont.font(size: 18, weight: .bold))
                .focused($nameFocused)
                .submitLabel(.done)
                .padding(.horizontal, 20)
                .frame(height: 56)
                .background(TamrinTheme.secondary, in: .capsule)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var positionPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("مركزك في الملعب")
                .font(TamrinFont.font(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8)], spacing: 8) {
                ForEach(positions, id: \.self) { value in
                    Button {
                        position = value
                        Haptics.selection()
                    } label: {
                        Text(value)
                            .font(TamrinFont.font(size: 14, weight: .bold))
                            .foregroundStyle(position == value ? .white : .primary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            // Accent, not `ink`: an ink chip is darker than the
                            // sheet in dark mode and reads as recessed.
                            .background(
                                position == value ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(TamrinTheme.secondary),
                                in: .capsule
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(position == value ? .isSelected : [])
                }
            }

        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.snappy(duration: 0.22), value: position)
    }

    /// `avatarData` alone can't tell "left alone" from "cleared" — it is nil in
    /// both cases — so the removal flag decides between them.
    private var avatarEdit: HomeStore.AvatarEdit {
        if let avatarData { return .replaced(avatarData) }
        return avatarRemoved ? .removed : .unchanged
    }

    private func save() {
        feed.saveProfile(
            name: trimmedName,
            avatar: avatarEdit,
            playerPosition: position
        )
        Haptics.success()
        dismiss()
    }
}
