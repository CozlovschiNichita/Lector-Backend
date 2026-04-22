import Fluent

struct CreateLecture: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("lectures")
            .id()
            .field("title", .string, .required)
            .field("full_text", .string, .required)
            .field("summary", .string)
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("created_at", .datetime)
            .field("folder_id", .uuid, .references("folders", "id", onDelete: .setNull))
            .field("status", .string, .required, .custom("DEFAULT 'completed'"))
            .field("progress", .double, .required, .custom("DEFAULT 1.0"))
            .field("segments", .custom("jsonb[]"))
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("lectures").delete()
    }
}
