import Fluent
import Vapor

final class User: Model, Content, Authenticatable, @unchecked Sendable {
    static let schema = "users"
    
    @ID(key: .id)
    var id: UUID?

    @Field(key: "email")
    var email: String

    @Field(key: "first_name")
    var firstName: String?

    @Field(key: "last_name")
    var lastName: String?

    @Field(key: "password_hash")
    var passwordHash: String

    @Field(key: "google_id")
    var googleID: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() { }

    init(id: UUID? = nil, email: String, firstName: String?, lastName: String?, passwordHash: String, googleID: String? = nil) {
        self.id = id
        self.email = email
        self.firstName = firstName
        self.lastName = lastName
        self.passwordHash = passwordHash
        self.googleID = googleID
    }
}
