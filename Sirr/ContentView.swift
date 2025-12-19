//
//  ContentView.swift
//  Sirr
//
//  Created by فارس أبومالح on 07/04/1447 AH.
//

import SwiftUI

struct ContentView: View {
    @State var number: Int = 29
    @State var isbig: Bool = false
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Text("number is \(number)")
                    .foregroundStyle(Color.red)
                    .bold()
                    .padding(.all,12)
                    .background(Color.background)
                    .cornerRadius(12)
                    .shadow(radius: 20, x: 0, y: 0)
                    .contentTransition(.numericText())
                    .animation(.smooth, value: number)
                    .animation(.bouncy, value: isbig)
                    .scaleEffect(isbig ? 2 : 1)
                ActivityCardView(name: "التمرين", date: "يوم الاثنين", image: Image(.actnew))
                ActivityCardView(name: "التمرين الأسبوعي", date: "يوم السبت", image: Image(.act))
                NewActivtyCardView()

                HStack {
                    
                    Image(systemName: "plus")
                        .onTapGesture {
                            number = number + 1
                        }
                    Image(systemName: "minus")
                        .onTapGesture {
                            number = number - 1
                        }
                    Image(systemName: "xmark")
                        .onTapGesture {
                            if isbig {
                                isbig = false
                            }
                            else {
                                isbig = true
                            }
                        }
                    
                }
            }
            .padding(20)

        }

        
    }
}

#Preview {
    ContentView()
}
