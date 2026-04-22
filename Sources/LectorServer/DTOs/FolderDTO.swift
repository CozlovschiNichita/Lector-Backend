import Vapor

struct FolderDTO: Content {
    var id: UUID?
    var name: String
    var createdAt: Date?
    var colorHex: String?
}
