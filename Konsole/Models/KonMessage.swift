import Foundation

struct KonMessage: Identifiable, Equatable {
    enum Role: Equatable {
        case user
        case kon
    }

    let id = UUID()
    let date = Date()
    let role: Role
    let text: String
    var actions: [String] = []
}
