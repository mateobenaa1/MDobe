import Foundation

struct ChatMessage: Identifiable {
    enum Role { case user, ai, info }
    let id = UUID()
    let role: Role
    var text: String
}
