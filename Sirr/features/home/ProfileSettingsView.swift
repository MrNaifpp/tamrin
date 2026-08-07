import SwiftUI
import PhotosUI

/// Account sheet. Deliberately narrow in scope — a photo, a name and a pitch
/// position — so it fits on screen in one piece instead of the old
/// overview-then-editor pair that needed two detents and a mode switch.
///
/// Signing out lives in `AppSettingsView` next to account deletion, so the two
/// session-ending actions sit together instead of one hiding behind an editor.
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
    @State private var customPosition = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var avatarData: Data?
    @FocusState private var nameFocused: Bool

    private let positions = ["حارس", "دفاع", "وسط", "هجوم", "مخصص"]

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var resolvedPosition: String {
        position == "مخصص"
            ? customPosition.trimmingCharacters(in: .whitespacesAndNewlines)
            : position
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
        .task(id: photoItem) {
            if let data = try? await photoItem?.loadTransferable(type: Data.self) {
                avatarData = data
            }
        }
        .onAppear {
            name = feed.profileName
            avatarData = feed.avatarData
            let saved = feed.playerPosition
            if positions.contains(saved) {
                position = saved
            } else if !saved.isEmpty {
                position = "مخصص"
                customPosition = saved
            }
        }
    }

    private var form: some View {
        VStack(spacing: 20) {
            avatarPicker
            nameField
            positionPicker
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

    private var avatarPicker: some View {
        PhotosPicker(selection: $photoItem, matching: .images) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let avatarData, let image = UIImage(data: avatarData) {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else if let url = feed.avatarUrl.flatMap(URL.init(string:)) {
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
        .buttonStyle(.plain)
        .accessibilityLabel("صورة الحساب")
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

            if position == "مخصص" {
                TextField("اكتب مركزك", text: $customPosition)
                    .font(TamrinFont.font(size: 15, weight: .medium))
                    .padding(.horizontal, 18)
                    .frame(height: 50)
                    .background(TamrinTheme.secondary, in: .capsule)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.snappy(duration: 0.22), value: position)
    }

    private func save() {
        feed.saveProfile(
            name: trimmedName,
            avatarData: avatarData,
            playerPosition: resolvedPosition
        )
        Haptics.success()
        dismiss()
    }
}
