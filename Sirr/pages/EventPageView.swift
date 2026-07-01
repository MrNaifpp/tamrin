//
//  EventPageView.swift
//  Sirr
//
//  Created for Figma design implementation with swipeable page view
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

enum NavigationDestination: Hashable {
    case newEvent
}

struct EventPageView: View {
    var authVM: AuthViewModel? = nil
    @Binding var deepLinkEventId: UUID?
    @Namespace private var zoomNamespace
    @State private var currentPage: Int = 0
    @State private var path: [EventData] = []
    @State private var navigationPath = NavigationPath()
    @State private var selectedTab: Int = 0
    @State private var showEditProfileSheet = false
    @State private var events: [EventData] = []
    @State private var eventsLoading = false
    @State private var eventsError: String? = nil
    
    init(authVM: AuthViewModel? = nil, deepLinkEventId: Binding<UUID?> = .constant(nil)) {
        self.authVM = authVM
        self._deepLinkEventId = deepLinkEventId
    }
    
    var body: some View {
        NavigationStack(path: $navigationPath) {
            GeometryReader { geometry in
                ZStack {
                    if events.isEmpty && !eventsLoading {
                        // Empty state: gradient background, message, CTA
                        emptyStateBackground
                            .frame(
                                width: geometry.size.width,
                                height: geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom
                            )
                            .ignoresSafeArea(edges: .all)
                        emptyStateContent(geometry: geometry)
                    } else {
                        // Full-screen background image for current event (or default when loading)
                        eventBackgroundImage(currentPage: min(currentPage, events.count - 1))
                            .frame(
                                width: geometry.size.width,
                                height: geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom
                            )
                            .clipped()
                            .ignoresSafeArea(edges: .all)
                            .blur(radius: 8)
                            .transition(.opacity)
                            .animation(.easeInOut(duration: 0.3), value: currentPage)
                        Color.black.opacity(0.3)
                            .frame(
                                width: geometry.size.width,
                                height: geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom
                            )
                            .ignoresSafeArea(edges: .all)
                        VStack {
                            if eventsLoading && events.isEmpty {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(1.2)
                                Spacer()
                            } else if !events.isEmpty {
                                TabView(selection: $currentPage) {
                                    ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                                        VStack(spacing: 0) {
                                            Spacer(minLength: 18)
                                            NavigationLink(value: event) {
                                                NewActivtyCardView(
                                                    eventName: event.name,
                                                    eventDate: event.date,
                                                    imageURL: event.imageUrl,
                                                    imageName: .card1
                                                )
                                                .matchedTransitionSource(id: event.id, in: zoomNamespace)
                                                .frame(height: min(612, geometry.size.height * 0.75))
                                                .padding(.horizontal, 20)
                                            }
                                            .buttonStyle(.plain)
                                            Spacer(minLength: 20)
                                        }
                                        .frame(width: geometry.size.width)
                                        .tag(index)
                                    }
                                }
                                .tabViewStyle(.page(indexDisplayMode: .always))
                                .animation(.smooth, value: currentPage)
                                .onChange(of: currentPage) { _ in
                                    hapticMedium()
                                }
                            }
                            Spacer()
                        }
                        .ignoresSafeArea(.keyboard, edges: .top)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("القادمة") {
                        Task { await authVM?.logout() }
                    }
                    .font(.appTitle)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 8) {
                        Button {
                            navigationPath.append(NavigationDestination.newEvent)
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.primary)
                        }
                        Button {
                            showEditProfileSheet = true
                        } label: {
                            eventPageProfileAvatar
                        }
                    }
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .environment(\.layoutDirection, .rightToLeft)
            .onAppear {
                #if canImport(UIKit)
                UIPageControl.appearance().currentPageIndicatorTintColor = .red
                UIPageControl.appearance().pageIndicatorTintColor = .gray
                #endif
                Task {
                    await authVM?.loadCurrentProfile()
                    await loadEvents()
                }
            }
            // .task(id:) runs both when the view first appears with a value
            // already set (cold-launch / post-login mount) and whenever the id
            // changes later (warm tap). .onChange would miss the initial value.
            .task(id: deepLinkEventId) {
                guard let eventId = deepLinkEventId else { return }
                do {
                    let record = try await EventService.shared.getEventById(eventId)
                    let eventData = EventData.from(record: record)
                    navigationPath.append(eventData)
                } catch {
                    print("[DeepLink] Failed to load event: \(error.localizedDescription)")
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
                    NewEventView(onCreated: { newEvent in
                        // Pop the create form and open the newly created event's detail.
                        Task { await loadEvents() }
                        if !navigationPath.isEmpty { navigationPath.removeLast() }
                        navigationPath.append(newEvent)
                    })
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
        }
    }
}

// MARK: - Events loading & empty state
private extension EventPageView {
    func loadEvents() async {
        eventsLoading = true
        eventsError = nil
        defer { eventsLoading = false }
        do {
            let records = try await EventService.shared.getEventsForCurrentUser()
            events = records
                .map { EventData.from(record: $0) }
                .filter { (($0.endDate ?? $0.startDate)) >= Date() }
            if currentPage >= events.count && !events.isEmpty {
                currentPage = events.count - 1
            } else if events.isEmpty {
                currentPage = 0
            }
        } catch {
            eventsError = error.localizedDescription
            events = []
        }
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
            Text("لا توجد فعاليات")
                .font(.appTitle)
                .foregroundStyle(.white)
            Text("أنشئ فعالية أو انضم إلى واحدة")
                .font(.appBody)
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
            Button {
                navigationPath.append(NavigationDestination.newEvent)
            } label: {
                Text("إنشاء فعالية")
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

    @ViewBuilder
    func eventBackgroundImage(currentPage: Int) -> some View {
        if currentPage >= 0, currentPage < events.count,
           let resource = EventData.imageResource(for: events[currentPage].imageUrl) {
            Image(resource)
                .resizable()
                .scaledToFill()
                .aspectRatio(4/3, contentMode: .fill)
        } else if currentPage >= 0, currentPage < events.count,
                  let urlString = events[currentPage].imageUrl,
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

// MARK: - Haptics & Toolbar helpers
private extension EventPageView {
    func hapticMedium() {
        #if canImport(UIKit)
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()
        #endif
    }

    @ViewBuilder
    var eventPageProfileAvatar: some View {
        if let urlString = authVM?.currentProfile?.avatarUrl, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                case .failure, .empty:
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(Color.gray.opacity(0.7))
                @unknown default:
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(Color.gray.opacity(0.7))
                }
            }
            .frame(width: 28, height: 28)
            .clipShape(Circle())
        } else {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
                .foregroundStyle(Color.gray.opacity(0.7))
        }
    }
}

// MARK: - Bottom Navigation Bar
struct BottomNavigationBarView: View {
    @Binding var selectedTab: Int
    
    var body: some View {
        HStack(spacing: 0) {
            BottomNavItem(
                icon: "house.fill",
                title: "الرئيسية",
                isSelected: selectedTab == 0,
                action: { selectedTab = 0 }
            )
            
            BottomNavItem(
                icon: "calendar",
                title: "الفعاليات",
                isSelected: selectedTab == 1,
                action: { selectedTab = 1 }
            )
            
            BottomNavItem(
                icon: "person.fill",
                title: "الملف الشخصي",
                isSelected: selectedTab == 2,
                action: { selectedTab = 2 }
            )
        }
        .frame(height: 49)
        .background(.bar)
        .environment(\.layoutDirection, .rightToLeft)
    }
}

private struct BottomNavItem: View {
    let icon: String
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: {
            action()
            hapticLight()
        }) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .symbolVariant(isSelected ? .fill : .none)
                    .foregroundStyle(isSelected ? .blue : .secondary)
                
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? .blue : .secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
    
    private func hapticLight() {
        #if canImport(UIKit)
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
        #endif
    }
}

#Preview {
    EventPageView()
}
