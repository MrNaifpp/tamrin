import SwiftUI
import UserNotifications

/// App-level settings, opened from the gear beside the profile capsule in the
/// side menu. Kept separate from `ProfileSettingsView`, which edits *who you
/// are*; this sheet is for how the app behaves, plus the two account-ending
/// actions. Every row here is backed by real behaviour — no placeholder
/// switches that pretend to do something.
struct AppSettingsView: View {
    @Bindable var feed: HomeStore

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage(Haptics.enabledKey) private var hapticsEnabled = true

    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var showLogoutConfirm = false
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    @State private var deleteError: String?

    /// One step lighter than `TamrinTheme.sheet` (0.953 / 0.12), kept local to
    /// this sheet rather than moved into the theme so the rest of the app's
    /// sheets stay on the shared ramp. The white rows still clear it.
    private static let sheetBackground = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.145, alpha: 1)
            : UIColor(white: 0.965, alpha: 1)
    })

    /// The toggle's on-state. Two steps up from system blue toward white, so
    /// the only saturated block on the sheet stops competing with the white
    /// rows it sits on.
    private static let selectedTint = Color(red: 0.34, green: 0.66, blue: 1.0)

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 26) {
                    section(title: "الحساب") {
                        accountRow
                    }

                    section(title: "التنبيهات") {
                        notificationsRow
                    }

                    section(title: "التطبيق") {
                        hapticsRow
                        rowDivider
                        versionRow
                    }

                    dangerZone
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 24)
                .sheetContentHeight()
            }
            .navigationTitle("الإعدادات")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("تم") { dismiss() }
                        .fontWeight(.semibold)
                        .disabled(isDeleting)
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .fittedSheet(
            allowsExpansion: true,
            includesNavigationBar: true,
            background: Self.sheetBackground
        )
        .interactiveDismissDisabled(isDeleting)
        .task { await refreshNotificationStatus() }
        // Coming back from the iOS Settings app is the usual way this changes,
        // and that is a foreground event, not a re-appear.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refreshNotificationStatus() } }
        }
        // `alert`, not `confirmationDialog`: inside a sheet the dialog is
        // presented as a popover anchored to the sheet's own bounds — it lands
        // at the top of the list, far from the button that was tapped, and the
        // popover form drops the cancel button entirely. For two actions that
        // end the session (one of them irreversible) the confirmation has to be
        // centred, modal, and show both choices.
        .alert("تسجيل الخروج؟", isPresented: $showLogoutConfirm) {
            Button("تسجيل الخروج", role: .destructive) {
                dismiss()
                feed.onLogout?()
            }
            Button("تراجع", role: .cancel) {}
        }
        .alert("حذف الحساب نهائيًا؟", isPresented: $showDeleteConfirm) {
            Button("حذف الحساب", role: .destructive) { deleteAccount() }
            Button("تراجع", role: .cancel) {}
        } message: {
            Text("سيُحذف حسابك وكل بياناتك: مجموعاتك، تمارينك، تسجيلاتك ومدفوعاتك. لا يمكن التراجع عن هذا الإجراء.")
        }
        .alert("تعذر حذف الحساب", isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )) {
            Button("حسنًا", role: .cancel) { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
    }

    // MARK: - Sections

    private func section<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(TamrinFont.font(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            // `card`, not `secondary`: grouped rows read as surfaces raised off
            // the sheet, so they take the lighter tone (pure white in light
            // mode) and the sheet stays the recessed one behind them — the same
            // relationship iOS uses for grouped lists.
            VStack(spacing: 0) {
                content()
            }
            .background(TamrinTheme.card, in: .rect(cornerRadius: 20, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Inset to the text column, the way a grouped list separates its rows.
    private var rowDivider: some View {
        Divider().padding(.leading, 58)
    }

    private var accountRow: some View {
        // Pushed onto this sheet's own stack rather than swapped for a sibling
        // sheet. The old hop dismissed الإعدادات before home presented حسابي, so
        // its إلغاء landed back on home and there was no way to return here.
        NavigationLink {
            ProfileSettingsView(feed: feed, isPushed: true)
        } label: {
            settingsRow(
                icon: "person.crop.circle",
                title: "حسابي",
                subtitle: feed.profileName.isEmpty ? "الاسم والصورة والمركز" : feed.profileName
            ) {
                Image(systemName: "chevron.forward")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("يفتح تعديل الاسم والصورة والمركز")
    }

    /// iOS owns this permission, so the row reports the system's answer and
    /// hands off: the first tap can still ask, afterwards only Settings can
    /// change it.
    private var notificationsRow: some View {
        Button {
            Task { await handleNotificationsTap() }
        } label: {
            settingsRow(
                icon: notificationStatus == .authorized ? "bell.badge" : "bell.slash",
                title: "الإشعارات",
                subtitle: notificationSubtitle
            ) {
                if notificationStatus == .notDetermined {
                    Text("تفعيل")
                        .font(TamrinFont.font(size: 13, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                } else {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityValue(notificationSubtitle)
        .accessibilityHint(
            notificationStatus == .notDetermined
                ? "يطلب إذن الإشعارات"
                : "يفتح إعدادات الإشعارات في النظام"
        )
    }

    private var hapticsRow: some View {
        Toggle(isOn: $hapticsEnabled) {
            rowLabel(
                icon: "hand.tap",
                title: "الاهتزاز",
                subtitle: "اهتزاز خفيف عند التسجيل والتأكيد"
            )
        }
        .tint(Self.selectedTint)
        .padding(.horizontal, 16)
        .frame(minHeight: 64)
        // Feel the setting you just changed — but only when switching it on,
        // since a buzz confirming "off" would contradict itself.
        .onChange(of: hapticsEnabled) { _, isOn in
            if isOn { Haptics.selection() }
        }
    }

    private var versionRow: some View {
        settingsRow(icon: "info.circle", title: "الإصدار", subtitle: nil) {
            Text(appVersion)
                .font(TamrinFont.font(size: 14, weight: .regular))
                .foregroundStyle(.secondary)
                // Version strings are Latin digits and parentheses; forcing LTR
                // keeps "1.0 (12)" from being reordered inside the RTL sheet.
                .environment(\.layoutDirection, .leftToRight)
        }
        .accessibilityElement(children: .combine)
    }

    /// Both actions end the session, so they sit together under the rest of the
    /// sheet where nothing is reached by accident. Delete is last and red.
    private var dangerZone: some View {
        VStack(spacing: 10) {
            // Filled rather than `.glass`: beside the red capsule below, a
            // borderless label read as a caption instead of a button.
            Button {
                showLogoutConfirm = true
            } label: {
                Label("تسجيل الخروج", systemImage: "rectangle.portrait.and.arrow.right")
                    .font(TamrinFont.font(size: 16, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    // The one control that goes the other way: recessed below
                    // the sheet rather than raised off it, so it reads as
                    // secondary to the white rows above without competing with
                    // the red capsule below.
                    .background(TamrinTheme.secondary, in: .capsule)
            }
            .buttonStyle(.plain)
            .disabled(isDeleting)

            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                HStack(spacing: 8) {
                    if isDeleting {
                        ProgressView().controlSize(.small).tint(.red)
                    } else {
                        Image(systemName: "trash")
                    }
                    Text(isDeleting ? "جارٍ الحذف…" : "حذف الحساب")
                }
                .font(TamrinFont.font(size: 16, weight: .bold))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Color.red.opacity(0.12), in: .capsule)
            }
            .buttonStyle(.plain)
            .disabled(isDeleting)
            .accessibilityHint("يحذف حسابك وكل بياناتك نهائيًا")

            Text("حذف الحساب نهائي ولا يمكن استرجاع بياناتك بعده.")
                .font(TamrinFont.font(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.top, 2)
        }
        .padding(.top, 6)
    }

    // MARK: - Row building blocks

    private func rowLabel(icon: String, title: String, subtitle: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(TamrinFont.font(size: 16, weight: .bold))
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(TamrinFont.font(size: 12, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)
        }
    }

    private func settingsRow<Trailing: View>(
        icon: String,
        title: String,
        subtitle: String?,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 8) {
            rowLabel(icon: icon, title: title, subtitle: subtitle)
            trailing()
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 64)
        .contentShape(.rect)
    }

    // MARK: - Actions

    private var notificationSubtitle: String {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral:
            return "مفعّلة"
        case .denied:
            return "موقوفة من إعدادات الجهاز"
        default:
            return "لم تُفعّل بعد"
        }
    }

    private func refreshNotificationStatus() async {
        notificationStatus = await UNUserNotificationCenter.current()
            .notificationSettings()
            .authorizationStatus
    }

    private func handleNotificationsTap() async {
        if notificationStatus == .notDetermined {
            await PushManager.shared.requestAuthorizationAndRegister()
            await refreshNotificationStatus()
        } else if let url = URL(string: UIApplication.openSettingsURLString) {
            await UIApplication.shared.open(url)
        }
    }

    private func deleteAccount() {
        guard let onDeleteAccount = feed.onDeleteAccount else {
            deleteError = "الحذف غير متاح في هذه النسخة."
            return
        }
        isDeleting = true
        Task {
            do {
                try await onDeleteAccount()
                // Auth state already flipped, so dismissing lands on login.
                isDeleting = false
                dismiss()
            } catch {
                isDeleting = false
                Haptics.error()
                deleteError = error.localizedDescription
            }
        }
    }
}

#Preview {
    AppSettingsView(feed: HomeStore.preview)
}
