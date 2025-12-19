//
//  NavigationStackTask.swift
//  Sirr
//
//  Created by فارس أبومالح on 10/05/1447 AH.
//

import SwiftUI

struct NavigationStackTask: View {
    @Namespace var namespace
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    ActivityCardView(name: "تمرين الشباب", date: "يوم الاربعاء", image: Image(.actnew))
                    NewActivtyCardView()
                    NavigationLink {
                        ActivityDetailsView()
                        .navigationTransition(.zoom(sourceID: "zoom", in: namespace))
                    } label: {
                        NewActivtyCardView()
                            .matchedTransitionSource(id: "zoom", in: namespace)
                    }

                }
                .padding(20)
                
            }
            .navigationTitle("القادمة")
        }
    }
    
}


#Preview {
    NavigationStackTask()
}
