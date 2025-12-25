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

struct EventPageView: View {
    @State private var currentPage: Int = 0
    @State private var selectedEvent: EventData?
    @State private var showDetail: Bool = false
    
    // Sample events data - can be replaced with actual data model
    let events: [EventData] = [
        EventData(
            name: "اسم الفعالية",
            date: "يوم الثلاثاء، الساعة 6:00 م",
            image: .pic
        ),
        EventData(
            name: "التمرين",
            date: "يوم الاثنين",
            image: .actnew
        ),
        EventData(
            name: "التمرين الأسبوعي",
            date: "يوم السبت",
            image: .act
        )
    ]
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                VStack {
                    NavigationBarView(title: "القادمة")
                    
                    // Page View with swipeable cards
                    TabView(selection: $currentPage) {
                        ForEach(Array(events.enumerated()), id: \.offset) { index, event in
                            VStack(spacing: 0) {
                                Spacer(minLength: 18)
                                
                                NewActivtyCardView(
                                    eventName: event.name,
                                    eventDate: event.date,
                                    imageName: event.image
                                )
                                .frame(height: min(612, geometry.size.height * 0.75))
                                .padding(.horizontal, 20)
                                .onTapGesture {
                                    selectedEvent = event
                                    showDetail = true
                                }
                                
                                Spacer(minLength: 20)
                            }
                            .frame(width: geometry.size.width)
                            .tag(index)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .animation(.smooth, value: currentPage)
                    .onChange(of: currentPage) { _ in
                        hapticMedium()
                    }
                }
                .background(Color.white)
                .ignoresSafeArea(.keyboard)
                .allowsHitTesting(!showDetail)
                .blur(radius: showDetail ? 3 : 0)
                
                if showDetail {
                    Color.black.opacity(0.28)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
                
                // Detail overlay with hero effect
                if let selected = selectedEvent, showDetail {
                    EventHeroDetailView(
                        event: selected,
                        onClose: {
                            showDetail = false
                            selectedEvent = nil
                        },
                        onEnroll: {
                            // Hook for enroll action
                        }
                    )
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

#Preview {
    EventPageView()
}

