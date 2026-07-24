import SwiftUI
import PhotosUI

/// Profile / account page — the designer's AppSettingsView bound to
/// HomeStore. The demo-data reset affordance is dropped (no demo store here).
struct ProfileSettingsView: View {
    @Bindable var feed: HomeStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var position = ""
    @State private var customPosition = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var avatarData: Data?
    @State private var isEditing = false
    @State private var selectedDetent: PresentationDetent = .height(410)
    private let positions = ["حارس", "دفاع", "وسط", "هجوم", "مخصص"]

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                Group {
                    if isEditing { editorContent.transition(.move(edge: .leading).combined(with: .opacity)) }
                    else { overviewContent.transition(.move(edge: .trailing).combined(with: .opacity)) }
                }
                .padding(22)
            }
            .navigationTitle(isEditing ? "تعديل الحساب" : "حسابي")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isEditing ? "رجوع" : "إغلاق") {
                        if isEditing { withAnimation(.snappy) { isEditing = false; selectedDetent = .height(410) } }
                        else { dismiss() }
                    }
                }
            }
            .task(id: photoItem) { if let data = try? await photoItem?.loadTransferable(type: Data.self) { avatarData = data } }
            .onAppear {
                name = feed.profileName
                avatarData = feed.avatarData
                let saved = feed.playerPosition
                if positions.contains(saved) { position = saved } else if !saved.isEmpty { position = "مخصص"; customPosition = saved }
            }
        }
        .presentationDetents([.height(410), .large], selection: $selectedDetent)
        .presentationDragIndicator(.visible)
        .environment(\.layoutDirection, .rightToLeft)
    }

    private var profileAvatar: some View {
        Group {
            if let avatarData, let image = UIImage(data: avatarData) { Image(uiImage: image).resizable().scaledToFill() }
            else { Circle().fill(TamrinTheme.ink).overlay(Text(String(name.prefix(1))).font(TamrinFont.font(size: 32, weight: .bold)).foregroundStyle(.white)) }
        }
        .frame(width: 92, height: 92).clipShape(.circle)
    }

    private var overviewContent: some View {
        VStack(spacing: 18) {
            profileAvatar
            VStack(spacing: 3) {
                Text(name).font(TamrinFont.font(size: 27, weight: .bold))
                Text(feed.playerPosition.isEmpty ? "بدون مركز محدد" : feed.playerPosition)
                    .font(TamrinFont.font(size: 13, weight: .regular)).foregroundStyle(.secondary)
            }
            Button {
                withAnimation(.snappy) { isEditing = true; selectedDetent = .large }
            } label: {
                Label("تعديل حسابي", systemImage: "pencil")
                    .font(TamrinFont.font(size: 15, weight: .bold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.regular)

            Button(role: .destructive) {
                dismiss()
                feed.onLogout?()
            } label: {
                Label("تسجيل الخروج", systemImage: "rectangle.portrait.and.arrow.right")
                    .font(TamrinFont.font(size: 15, weight: .bold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.regular).tint(.red)
        }
    }

    private var editorContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                profileAvatar.overlay(alignment: .bottomLeading) {
                    Image(systemName: "camera.fill").frame(width: 34, height: 34).background(.regularMaterial, in: .circle)
                }
            }.frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 8) {
                Text("اسمك").font(TamrinFont.font(size: 13, weight: .medium)).foregroundStyle(.secondary)
                TextField("الاسم", text: $name).font(TamrinFont.font(size: 22, weight: .bold))
                    .padding(.horizontal, 20).frame(height: 60).background(TamrinTheme.secondary, in: .capsule)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("مركزك في الملعب").font(TamrinFont.font(size: 13, weight: .medium)).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92))], spacing: 8) {
                    ForEach(positions, id: \.self) { value in
                        Button { position = value; UISelectionFeedbackGenerator().selectionChanged() } label: {
                            Text(value).font(TamrinFont.font(size: 14, weight: .bold)).frame(maxWidth: .infinity).frame(height: 44)
                                .foregroundStyle(position == value ? .white : .primary)
                                .background(position == value ? TamrinTheme.ink : TamrinTheme.secondary, in: .capsule)
                        }.buttonStyle(.plain)
                    }
                }
                if position == "مخصص" {
                    TextField("اكتب مركزك", text: $customPosition).padding(.horizontal, 18).frame(height: 54).background(TamrinTheme.secondary, in: .capsule)
                }
            }
            Button("حفظ التغييرات") {
                feed.saveProfile(name: name, avatarData: avatarData, playerPosition: position == "مخصص" ? customPosition : position)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                dismiss()
            }
            .buttonStyle(PrimaryActionStyle())
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}
