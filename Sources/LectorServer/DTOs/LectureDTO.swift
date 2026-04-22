import Vapor

struct LectureDTO: Content {
    var id: UUID?
    var title: String
    var fullText: String
    var summary: String?
    var summaryHistory: [String]?
    var folderID: UUID?
    var createdAt: Date?
    var status: String?
    var progress: Double?
    var segments: [TextSegment]?
    var temporaryAudioURL: String?
}

struct UpdateLecturesRequest: Content {
    var lectureIDs: [UUID]
    var folderID: UUID?
    var newTitle: String?
    var fullText: String?
    var segments: [TextSegment]?
    var summaryHistory: [String]?
}
