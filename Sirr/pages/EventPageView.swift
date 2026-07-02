//
//  EventPageView.swift
//  Sirr
//
//  Created for Figma design implementation with swipeable page view
//

import SwiftUI

enum NavigationDestination: Hashable {
    case newEvent
    case upcoming
}

struct EventPageView: View {
    var authVM: AuthViewModel? = nil
    @ObservedObject var appState: AppState
    @Binding var deepLinkEventId: UUID?
    @Namespace private var zoomNamespace
    @State private var navigationPath = NavigationPath()
    @State private var showEditProfileSheet = false
    @State private var events: [EventData] = []
    @State private var eventsLoading = false
    @State private var eventsError: String? = nil
    @State private var workspaces: [WorkspaceRecord] = []
    @State private var workspacesLoaded = false
    @State private var showDrawer = false
    @State private var showCreateWorkspace = false
    @State private var settingsWorkspace: WorkspaceRecord?
    @State private var deepLinkError: String?

    private var currentWorkspace: WorkspaceRecord? {
        workspaces.first { $0.id == appState.currentWorkspaceId } ?? workspaces.first
    }

    init(authVM: AuthViewModel? = nil, appState: AppState, deepLinkEventId: Binding<UUID?> = .constant(nil)) {
        self.authVM = authVM
        self.appState = appState
        self._deepLinkEventId = deepLinkEventId
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            GeometryReader { geometry in
                ZStack {
                    if workspacesLoaded && workspaces.isEmpty {
                        emptyStateBackground
                            .frame(
                                width: geometry.size.width,
                                height: geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom
                            )
                            .ignoresSafeArea(edges: .all)
                        noWorkspaceContent
                    } else if events.isEmpty && !eventsLoading {
                        // Empty state: gradient background, message, CTA
                        emptyStateBackground
                            .frame(
                                width: geometry.size.width,
                                height: geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom
                            )
                            .ignoresSafeArea(edges: .all)
                        emptyStateContent(geometry: geometry)
                    } else {
                        // Static blurred backdrop from the next (soonest) workout.
                        nextEventBackground
                            .frame(
                                width: geometry.size.width,
                                height: geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom
                            )
                            .clipped()
                            .ignoresSafeArea(edges: .all)
                            .blur(radius: 8)
                        Color.black.opacity(0.3)
                            .frame(
                                width: geometry.size.width,
                                height: geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom
                            )
                            .ignoresSafeArea(edges: .all)
                        if eventsLoading && events.isEmpty {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(1.2)
                        } else if !events.isEmpty {
                            workoutFeed(geometry: geometry)
                        }
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top) {
                HomeHeaderView(
                    avatarUrl: authVM?.currentProfile?.avatarUrl,
                    showsGroupControls: currentWorkspace != nil,
                    onMenu: { withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { showDrawer = true } },
                    onUpcoming: { navigationPath.append(NavigationDestination.upcoming) },
                    onProfile: { showEditProfileSheet = true }
                )
            }
            .overlay {
                GroupsDrawer(
                    isPresented: $showDrawer,
                    workspaces: workspaces,
                    currentId: currentWorkspace?.id,
                    onSelect: { ws in
                        appState.currentWorkspaceId = ws.id
                    },
                    onNewWorkout: { navigationPath.append(NavigationDestination.newEvent) },
                    onNewGroup: { showCreateWorkspace = true },
                    onOpenSettings: {
                        if let ws = currentWorkspace { settingsWorkspace = ws }
                    }
                )
            }
            .environment(\.layoutDirection, .rightToLeft)
            .onAppear {
                Task {
                    await authVM?.loadCurrentProfile()
                }
            }
            // Reload whenever the current workspace changes (join/create/switch),
            // and on first appearance. loadEvents() normalizes a nil/stale id to
            // a real one, which re-fires this task once and then converges.
            .task(id: appState.currentWorkspaceId) {
                await loadEvents()
            }
            // .task(id:) runs both when the view first appears with a value
            // already set (cold-launch / post-login mount) and whenever the id
            // changes later (warm tap). .onChange would miss the initial value.
            .task(id: deepLinkEventId) {
                guard let eventId = deepLinkEventId else { return }
                do {
                    let record = try await EventService.shared.getEventById(eventId)
                    if let wsId = record.workspaceId, appState.currentWorkspaceId != wsId {
                        appState.currentWorkspaceId = wsId
                        await loadEvents()
                    }
                    let eventData = EventData.from(record: record)
                    navigationPath.append(eventData)
                } catch {
                    deepLinkError = "هذا التمرين في مجموعة خاصة.\nاطلب دعوة من صاحب المجموعة للانضمام."
                }
                deepLinkEventId = nil
            }
            .navigationDestination(for: EventData.self) { event in
                EventHeroDetailView(
                    event: event,
                    onClose: {
                        navigationPath.removeLast()
                    },
                    onEnroll: {
                        Task { await loadEvents() }
                    },
                    onDeleted: {
                        navigationPath.removeLast()
                        Task { await loadEvents() }
                    }
                )
                .navigationTransition(.zoom(sourceID: event.id, in: zoomNamespace))
            }
            .navigationDestination(for: NavigationDestination.self) { destination in
                switch destination {
                case .newEvent:
                    NewEventView(workspaceId: currentWorkspace?.id, onCreated: { newEvent in
                        // Pop the create form and open the newly created event's detail.
                        Task { await loadEvents() }
                        if !navigationPath.isEmpty { navigationPath.removeLast() }
                        navigationPath.append(newEvent)
                    })
                case .upcoming:
                    UpcomingScheduleView(events: events) { event in
                        navigationPath.append(event)
                    }
                }
            }
            .sheet(isPresented: $showEditProfileSheet) {
                EditProfileSheet(
                    authVM: authVM ?? AuthViewModel(),
                    isPresented: $showEditProfileSheet
                )
                .presentationDetents([.fraction(0.5)])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showCreateWorkspace) {
                CreateWorkspaceSheet { ws in
                    appState.currentWorkspaceId = ws.id
                    Task { await loadEvents() }
                }
                .presentationDetents([.fraction(0.45)])
                .presentationDragIndicator(.visible)
            }
            .sheet(item: $settingsWorkspace) { ws in
                WorkspaceSettingsSheet(
                    workspace: ws,
                    currentUserId: authVM?.currentProfile?.userId,
                    onChanged: { Task { await loadEvents() } },
                    onLeftOrDeleted: {
                        appState.currentWorkspaceId = nil
                        Task { await loadEvents() }
                    },
                    onLogout: {
                        Task { await authVM?.logout() }
                    }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .alert("تعذر فتح التمرين", isPresented: Binding(
                get: { deepLinkError != nil },
                set: { if !$0 { deepLinkError = nil } }
            )) {
                Button("حسنًا", role: .cancel) { deepLinkError = nil }
            } message: {
                Text(deepLinkError ?? "")
            }
        }
    }
}

// MARK: - Events loading & empty state
private extension EventPageView {
    /// Loads the workspace list, resolves the current workspace, then its events.
    func loadEvents() async {
        eventsLoading = true
        eventsError = nil
        defer { eventsLoading = false }
        do {
            workspaces = try await WorkspaceService.shared.getMyWorkspaces()
            workspacesLoaded = true
            guard let ws = currentWorkspace else {
                appState.currentWorkspaceId = nil
                events = []
                return
            }
            if appState.currentWorkspaceId != ws.id {
                appState.currentWorkspaceId = ws.id
            }
            let records = try await EventService.shared.getWorkspaceEvents(workspaceId: ws.id)
            events = records.map { EventData.from(record: $0) }
        } catch {
            eventsError = error.localizedDescription
            events = []
        }
    }

    /// Vertical full-page pager: one workout per page, snap scrolling.
    /// Label rides each page: التمرين الجاي on the first, التمارين القادمة after.
    func workoutFeed(geometry: GeometryProxy) -> some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                    VStack(alignment: .leading, spacing: 10) {
                        sectionLabel(index == 0 ? "التمرين الجاي" : "التمارين القادمة")
                        NavigationLink(value: event) {
                            NewActivtyCardView(
                                eventName: event.name,
                                eventDate: event.date,
                                imageURL: event.imageUrl,
                                imageName: .card1
                            )
                            .matchedTransitionSource(id: event.id, in: zoomNamespace)
                            .frame(maxHeight: .infinity)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .containerRelativeFrame(.vertical)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
    }

    func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.appSubheadline)
            .foregroundStyle(.white.opacity(0.95))
            .padding(.horizontal, 6)
    }

    var emptyStateBackground: some View {
        LinearGradient(
            gradient: Gradient(colors: [
                Color(red: 0.55, green: 0.23, blue: 0.36),
                Color(red: 0.10, green: 0.30, blue: 0.23)
            ]),
            startPoint: .top,
            endPoint: .bottom
        )
    }

    func emptyStateContent(geometry: GeometryProxy) -> some View {
        VStack(spacing: 24) {
            Spacer()
            Text("لا توجد تمارين في \(currentWorkspace?.name ?? "المجموعة")")
                .font(.appTitle)
                .foregroundStyle(.white)
            Text("أنشئ تمرينًا أو انضم إلى واحد")
                .font(.appBody)
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
            Button {
                navigationPath.append(NavigationDestination.newEvent)
            } label: {
                Text("إنشاء تمرين")
                    .font(.headline)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(RoundedRectangle(cornerRadius: 27, style: .continuous).fill(Color.white))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 48)
            .padding(.top, 16)
            Spacer()
        }
    }

    /// Zero-workspace onboarding: create one, or join via a friend's link.
    var noWorkspaceContent: some View {
        VStack(spacing: 16) {
            Spacer()
            Text("🏟️").font(.system(size: 56))
            Text("ابدأ مجموعتك الأولى")
                .font(.appTitle)
                .foregroundStyle(.white)
            Text("المجموعة لك ولأصحابك — أنشئ واحدة لشلّتك\nأو انضم برابط دعوة من صديق")
                .font(.appBody)
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
            // Centered like emptyStateContent: the ZStack's oversized background
            // sibling shifts children down, so bottom-anchored content clips.
            Button {
                showCreateWorkspace = true
            } label: {
                Text("إنشاء مجموعة")
                    .font(.headline)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(RoundedRectangle(cornerRadius: 27, style: .continuous).fill(Color.white))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 48)
            .padding(.top, 16)
            Text("عندك رابط دعوة؟ افتحه وسينقلك إلى هنا")
                .font(.appCaption)
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
        }
    }

    @ViewBuilder
    var nextEventBackground: some View {
        if let first = events.first, let resource = EventData.imageResource(for: first.imageUrl) {
            Image(resource)
                .resizable()
                .scaledToFill()
                .aspectRatio(4/3, contentMode: .fill)
        } else if let first = events.first,
                  let urlString = first.imageUrl,
                  urlString.hasPrefix("http"),
                  let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure, .empty:
                    Image(.card1).resizable().scaledToFill()
                @unknown default:
                    Image(.card1).resizable().scaledToFill()
                }
            }
            .aspectRatio(4/3, contentMode: .fill)
        } else {
            Image(.card1)
                .resizable()
                .scaledToFill()
                .aspectRatio(4/3, contentMode: .fill)
        }
    }
}

#Preview {
    EventPageView(appState: AppState())
}
