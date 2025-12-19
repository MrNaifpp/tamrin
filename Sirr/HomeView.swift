//
//  HomeView.swift
//  Sirr
//
//  Created by فارس أبومالح on 05/05/1447 AH.
//

import SwiftUI

struct HomeView: View {
    var body: some View {
        TabView(selection: /*@START_MENU_TOKEN@*//*@PLACEHOLDER=Selection@*/.constant(1)/*@END_MENU_TOKEN@*/) {
            Tab("الرئيسة", systemImage: "house", value: 0) {
                NavigationStackTask()
                
            }
            Tab("الرئيسة", systemImage: "house", value: 1) {
                NavigationStackTask()
            }
            Tab(value: 1, role: .search) {
                ContentView()
            }
        }
    }
}

#Preview {
    HomeView()
}
