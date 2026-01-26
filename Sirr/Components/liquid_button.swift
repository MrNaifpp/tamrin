//import SwiftUI
//
//struct LiquidButton: View {
//    @State private var time: Float = 0
//
//    var body: some View {
//        TimelineView(.animation) { timeline in
//            let t = Float(timeline.date.timeIntervalSince1970)
//
//            Canvas { context, size in
//                context.addFilter(
//                    .distortionShader(
//                        ShaderLibrary.liquidWave(
//                            .float(t)
//                        ),
//                        maxSampleOffset: CGSize(width: 20, height: 20)
//                    )
//                )
//
//                context.draw(
//                    RoundedRectangle(cornerRadius: 30),
//                    with: .color(.blue)
//                )
//            }
//            .frame(width: 220, height: 64)
//            .overlay(
//                Text("Liquid")
//                    .font(.headline)
//                    .foregroundColor(.white)
//            )
//        }
//    }
//}
