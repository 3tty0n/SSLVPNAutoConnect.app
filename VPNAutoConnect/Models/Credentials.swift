import Foundation

struct Credentials: Equatable {
    let username: String
    let password: String

    var isValid: Bool {
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty
    }
}
