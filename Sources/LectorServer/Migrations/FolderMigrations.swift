import Fluent

struct CreateFolder: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("folders")
            .id()
            .field("name", .string, .required)
            .field("colorHex", .string)
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("folders").delete()
    }
}
