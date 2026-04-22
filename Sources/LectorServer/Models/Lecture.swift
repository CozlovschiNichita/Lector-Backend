import Fluent
import Vapor

final class Lecture: Model, Content, @unchecked Sendable {
    static let schema = "lectures"
    
    @ID(key: .id)
    var id: UUID?

    @Field(key: "title")
    var title: String

    @Field(key: "full_text")
    var fullText: String
    
    @OptionalField(key: "summary")
    var summary: String?
    
    @OptionalField(key: "summary_history")
    var summaryHistory: [String]?

    @Parent(key: "user_id")
    var user: User

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?
    
    @OptionalParent(key: "folder_id")
    var folder: Folder?
    
    @Field(key: "status")
    var status: String
    
    @Field(key: "progress")
    var progress: Double

    @OptionalField(key: "segments")
    var segments: [TextSegment]?

        init() { }
    
    init(id: UUID? = nil, title: String, fullText: String, summary: String? = nil, userID: User.IDValue, status: String = "completed", progress: Double = 1.0) {
        self.id = id
        self.title = title
        self.fullText = fullText
        self.summary = summary
        self.$user.id = userID
        self.status = status
        self.progress = progress
    }
}

