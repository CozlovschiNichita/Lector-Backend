import Fluent

struct AddSummaryHistoryToLecture: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("lectures")
            .field("summary_history", .array(of: .string))
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("lectures")
            .deleteField("summary_history")
            .update()
    }
}
