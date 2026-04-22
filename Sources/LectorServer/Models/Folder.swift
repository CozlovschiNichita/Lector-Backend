import Fluent
import Vapor

final class Folder: Model, Content, @unchecked Sendable {
    static let schema = "folders"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "name")
    var name: String
    
    @Field(key: "colorHex")
    var colorHex: String?

    @Parent(key: "user_id")
    var user: User

    @Children(for: \.$folder)
    var lectures: [Lecture]

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() { }

    init(id: UUID? = nil, name: String, userID: User.IDValue, colorHex: String? = nil) {
        self.id = id
        self.name = name
        self.$user.id = userID
        self.colorHex = colorHex
    }
}
