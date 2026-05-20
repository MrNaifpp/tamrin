//
//  ScrollViewTest.swift
//  Sirr
//
//  Created by فارس أبومالح on 09/08/1447 AH.
//

import SwiftUI

struct ScrollViewTest: View {
    @State private var scrollID: UUID? = nil
    
    let items: [Item]
    
    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(items, id: \.id) { item in
                    item.color
                        .overlay {
                            Text(item.text)
                                .bold()
                        }
                        
                        .containerRelativeFrame(.horizontal) { float, x in
                            return float - 64
                        }
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 32)
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $scrollID)
    }
}

struct Item: Identifiable {
    var id: UUID = .init()
    var text: String
    var color: Color
}

#Preview {
    ScrollViewTest(
        items: [
            Item(text: "Hello", color: .red),
            Item(text: "World", color: .yellow),
            Item(text: "Test", color: .brown)
        ]
    )
}
