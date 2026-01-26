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
    @Namespace private var zoomNamespace
    @State private var currentPage: Int = 0
    @State private var path: [EventData] = []
    @State private var navigationPath = NavigationPath()
    @State private var selectedTab: Int = 0
    
    // Sample events data - can be replaced with actual data model
    let events: [EventData] = [
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
        ),
        EventData(
            name: "",
            date: "",
            image: .card4
        )
    ]
    
    init() {
            // Customize the dots color
            UIPageControl.appearance().currentPageIndicatorTintColor = .red  // current dot
            UIPageControl.appearance().pageIndicatorTintColor = .gray       // other dots
        }
    
    var body: some View {
        NavigationStack(path: $navigationPath) {
            GeometryReader { geometry in
                ZStack{
                    
                    Image(events[currentPage].image)
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .ignoresSafeArea()
                        .blur(radius: 16)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.3), value: currentPage)

                        

                    Color.black.opacity(0.3)
                        .frame(width: geometry.size.width, height: geometry.size.height+100)
                        .ignoresSafeArea()
                    
                    VStack {
                        NavigationBarView(title: "القادمة", onPlusButtonTap: {
                            navigationPath.append(NavigationDestination.newEvent)
                        })
                        
                        // Page View with swipeable cards
                        
                        
                        
                        TabView(selection: $currentPage) {
                            ForEach(Array(events.enumerated()), id: \.offset) { index, event in
                                VStack(spacing: 0) {
                                    Spacer(minLength: 18)
                                    
                                    NavigationLink(value: event) {
                                        NewActivtyCardView(
                                            eventName: event.name,
                                            eventDate: event.date,
                                            imageName: event.image
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
                        
                        Spacer()
                        
                        // Bottom Navigation Bar
                        // BottomNavigationBarView(selectedTab: $selectedTab)
                        //     .padding(.bottom, geometry.safeAreaInsets.bottom > 0 ? 0 : 8)
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

