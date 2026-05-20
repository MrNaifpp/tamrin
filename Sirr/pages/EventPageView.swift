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

#if os(iOS)

enum NavigationDestination: Hashable {
    case newEvent
}

struct EventPageView: View {
    @State private var scrollPosition: UUID?
    @Namespace private var zoomNamespace
    @State private var currentPage: Int = 0
    @State private var navigationPath = NavigationPath()
    
    private let events: [EventData] = [
        EventData(
            name: "اسم الفعالية",
            date: "يوم الثلاثاء، الساعة 6:00 م",
            image: .card1
        ),
        EventData(
            name: "",
            date: "",
            image: .card2
        ),
        EventData(
            name: "",
            date: "",
            image: .card3
        )
    ]
    
    init() {
        #if canImport(UIKit)
        UIPageControl.appearance().currentPageIndicatorTintColor = .red
        UIPageControl.appearance().pageIndicatorTintColor = .gray
        #endif
    }
    
    var body: some View {
        NavigationStack(path: $navigationPath) {
            GeometryReader { geometry in
                let activeEvent = events[safe: currentPage] ?? events[0]
                
                ZStack {
                    Image(activeEvent.image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .ignoresSafeArea()
                        .blur(radius: 34)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.28), value: currentPage)
                    
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.black.opacity(0.14),
                                    Color.black.opacity(0.24),
                                    Color.black.opacity(0.34)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .ignoresSafeArea()
                    
                    VStack() {
                        header
                            .padding(.horizontal, 24)
//                            .padding(.top, max(geometry.safeAreaInsets.top, 20) + 10)
                        
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 12) {
                                ForEach(events) { event in
                                    NavigationLink(value: event) {
                                        NewActivtyCardView(
                                            eventName: event.name,
                                            eventDate: event.date,
                                            imageName: event.image
                                        )
                                        .matchedTransitionSource(id: event.id, in: zoomNamespace)
                                        .frame(width: min(362, geometry.size.width - 40), height: 612)
                                        .shadow(color: .black.opacity(0.25), radius: 30, y: 8)
                                    }
                                    .buttonStyle(.plain)
                                    .id(event.id)
                                }
                            }
                            .padding(.horizontal, 20)
                            .scrollTargetLayout()
                        }
                        .scrollTargetBehavior(.viewAligned)
                        .scrollPosition(id: $scrollPosition)
                        .scrollIndicators(.hidden)
                        .padding(.top, 36)
                        .safeAreaPadding(.bottom, 24)
                        .onAppear {
                            if scrollPosition == nil {
                                scrollPosition = events.first?.id
                            }
                        }
                        .onChange(of: scrollPosition) { _, newValue in
                            guard
                                let newValue,
                                let newIndex = events.firstIndex(where: { $0.id == newValue }),
                                newIndex != currentPage
                            else { return }
                            
                            currentPage = newIndex
                            hapticMedium()
                        }
                        
                        Spacer(minLength: 0)
                    }
                    .ignoresSafeArea(.keyboard, edges: .top)
                }
            }
            .navigationDestination(for: EventData.self) { event in
                EventHeroDetailView(
                    event: event,
                    onClose: {
                        navigationPath.removeLast()
                    },
                    onEnroll: {
                        // Hook for enroll action
                    }
                )
                .navigationTransition(.zoom(sourceID: event.id, in: zoomNamespace))
            }
            .navigationDestination(for: NavigationDestination.self) { destination in
                switch destination {
                case .newEvent:
                    NewEventView()
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .environment(\.layoutDirection, .rightToLeft)
    }
    
    private var header: some View {
        HStack(alignment: .center) {
            HStack(spacing: 6) {
                Text("القادمة")
                    .font(.system(size: 32))
                    .fontWeight(.semibold)
//                    .font(size: 32, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.top, 2)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.top, 2)
            }
            
            Spacer(minLength: 12)

            HStack(spacing: 8) {
                Button {
                    navigationPath.append(NavigationDestination.newEvent)
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.black.opacity(0.20))
                        
                        Circle()
                            .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                        
                        Image(systemName: "plus")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 44, height: 44)
                    .shadow(color: .black.opacity(0.1), radius: 20)
                }
                .buttonStyle(.plain)

                Circle()
                    .fill(Color.white.opacity(0.32))
                    .frame(width: 40, height: 40)
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.white)
                    }
            }
        }
    }
}

// MARK: - Haptics
private extension EventPageView {
    func hapticMedium() {
        #if canImport(UIKit)
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()
        #endif
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
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
#else
struct EventPageView: View {
    var body: some View {
        ContentUnavailableView(
            "واجهة iOS فقط",
            systemImage: "iphone",
            description: Text("هذه الشاشة الأصلية أبقيناها لأجهزة iPhone، بينما النسخة المكتبية انتقلت إلى واجهة Desktop الجديدة.")
        )
    }
}

#Preview {
    EventPageView()
}
#endif
