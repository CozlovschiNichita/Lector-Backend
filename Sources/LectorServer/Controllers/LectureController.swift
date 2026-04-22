import Vapor
import Fluent
import Foundation

struct LectureController: RouteCollection {
    
    func boot(routes: RoutesBuilder) throws {
        let protected = routes.grouped(JWTMiddleware())
        let lectures = protected.grouped("api", "lectures")
        let legacyLectures = protected.grouped("lectures")
        
        lectures.get(use: getAll)
        lectures.get(":lectureID", use: getOne)
        lectures.delete(":lectureID", use: delete)
        lectures.post(":lectureID", "summarize", use: summarize)
        
        lectures.patch("batch", use: updateBatch)
        legacyLectures.patch("batch", use: updateBatch)
    }

    @Sendable
    func getAll(req: Request) async throws -> [LectureDTO] {
        let payload = try req.jwt.verify(as: UserPayload.self)
        guard let userID = UUID(uuidString: payload.subject.value) else {
            throw Abort(.unauthorized)
        }

        let lectures = try await Lecture.query(on: req.db)
            .filter(\.$user.$id == userID)
            .sort(\.$createdAt, .descending)
            .all()

        return lectures.map { $0.toDTO() }
    }
    
    @Sendable
    func getOne(req: Request) async throws -> LectureDTO {
        let payload = try req.jwt.verify(as: UserPayload.self)
        guard let userID = UUID(uuidString: payload.subject.value),
              let lectureID = req.parameters.get("lectureID", as: UUID.self) else {
            throw Abort(.badRequest)
        }

        guard let lecture = try await Lecture.query(on: req.db)
            .filter(\.$id == lectureID)
            .filter(\.$user.$id == userID)
            .first() else {
            throw Abort(.notFound)
        }

        return lecture.toDTO()
    }

    @Sendable
    func delete(req: Request) async throws -> HTTPStatus {
        let payload = try req.jwt.verify(as: UserPayload.self)
        guard let userID = UUID(uuidString: payload.subject.value),
              let lectureID = req.parameters.get("lectureID", as: UUID.self) else {
            throw Abort(.badRequest)
        }

        guard let lecture = try await Lecture.query(on: req.db)
            .filter(\.$id == lectureID)
            .filter(\.$user.$id == userID)
            .first() else {
            throw Abort(.notFound)
        }
        
        await TaskManager.shared.cancelTask(for: lectureID)
        
        try await lecture.delete(on: req.db)
        return .noContent
    }

    @Sendable
    func summarize(req: Request) async throws -> LectureDTO {
        let payload = try req.jwt.verify(as: UserPayload.self)
        guard let userID = UUID(uuidString: payload.subject.value),
              let lectureID = req.parameters.get("lectureID", as: UUID.self) else {
            throw Abort(.badRequest)
        }

        guard let lecture = try await Lecture.query(on: req.db)
            .filter(\.$id == lectureID)
            .filter(\.$user.$id == userID)
            .first() else {
            throw Abort(.notFound)
        }

        // Сразу меняем статус на "в обработке" и сохраняем
        lecture.status = "processing"
        try await lecture.save(on: req.db)
        
        let lang = req.query[String.self, at: "lang"] ?? "ru"
        
        // Отправляем тяжелую задачу в очередь (не блокируя текущий ответ)
        Task {
            await SummaryQueue.shared.enqueue {
                do {
                    let summarizer = SummarizerService()
                    let summaryText = try await summarizer.generateSummary(for: lecture.fullText, client: req.client, language: lang)
                    
                    // По завершении обновляем данные
                    lecture.summary = summaryText
                    lecture.status = "completed"
                    
                    var history = lecture.summaryHistory ?? []
                    history.append(summaryText)
                    lecture.summaryHistory = history
                    
                    try await lecture.save(on: req.db)
                } catch {
                    req.logger.error("Ошибка при генерации конспекта: \(error)")
                    lecture.status = "error"
                    try? await lecture.save(on: req.db)
                }
            }
        }

        // Мгновенно возвращаем DTO клиенту
        return lecture.toDTO()
    }
    
    @Sendable
    func updateBatch(req: Request) async throws -> HTTPStatus {
        let payload = try req.jwt.verify(as: UserPayload.self)
        guard let userID = UUID(uuidString: payload.subject.value) else { throw Abort(.unauthorized) }
        
        let updateData = try req.content.decode(UpdateLecturesRequest.self)
        
        let lecturesToUpdate = try await Lecture.query(on: req.db)
            .filter(\.$id ~~ updateData.lectureIDs)
            .filter(\.$user.$id == userID)
            .all()
        
        for lecture in lecturesToUpdate {
            if let newTitle = updateData.newTitle { lecture.title = newTitle }
            if let newText = updateData.fullText { lecture.fullText = newText }
            if let newSegments = updateData.segments { lecture.segments = newSegments }
            
            if let newSummaryHistory = updateData.summaryHistory {
                lecture.summaryHistory = newSummaryHistory
                lecture.summary = newSummaryHistory.last
            }
            
            if let fID = updateData.folderID {
                lecture.$folder.id = fID
            }
            
            try await lecture.save(on: req.db)
        }
        
        return .ok
    }
}

extension Lecture {
    func toDTO() -> LectureDTO {
        let downloadURL = self.status == "completed" ? "https://api.vtuza.us/api/import/audio/\(self.id?.uuidString ?? "").m4a" : nil
        
        return LectureDTO(
            id: self.id ?? UUID(),
            title: self.title,
            fullText: self.fullText,
            summary: self.summary,
            summaryHistory: self.summaryHistory,
            folderID: self.$folder.id,
            createdAt: self.createdAt,
            status: self.status,
            progress: self.progress,
            segments: self.segments,
            temporaryAudioURL: downloadURL
        )
    }
}
