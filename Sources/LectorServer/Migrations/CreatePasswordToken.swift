import Fluent

struct CreatePasswordToken: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("password_tokens")
            .id()
            .field("token", .string, .required)
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("expires_at", .datetime, .required)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("password_tokens").delete()
    }
}
