import SwiftUI

struct EventData: Identifiable, Hashable {
    let id: UUID = UUID()
    let name: String
    let date: String
    let image: ImageResource
}

