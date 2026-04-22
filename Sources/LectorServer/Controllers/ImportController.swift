import Vapor
import Fluent
import Foundation

struct ImportController: RouteCollection {
    private var tempDirectoryURL: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LectorTemp", isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    func boot(routes: RoutesBuilder) throws {
        let protected = routes.grouped(JWTMiddleware())
        let imports = protected.grouped("api", "import")
        
        imports.post("start", use: startUpload)
        imports.on(.POST, "chunk", body: .collect(maxSize: "20mb"), use: uploadChunk)
        imports.post("complete", use: completeUpload)
        imports.post("youtube", use: importYouTube)
        imports.delete("cancel", ":lectureID", use: cancelImport)
        imports.get("audio", ":filename", use: downloadAudioFile)
        imports.delete("audio", ":filename", use: deleteAudioFile)
    }

    @Sendable
    func startUpload(req: Request) async throws -> LectureDTO {
        let payload = try req.jwt.verify(as: UserPayload.self)
        let userID = UUID(uuidString: payload.subject.value)!
        
        struct StartData: Content { var filename: String }
        let data = try req.content.decode(StartData.self)
        
        let lecture = Lecture(title: data.filename, fullText: "", userID: userID, status: "uploading", progress: 0.0)
        try await lecture.save(on: req.db)
        
        let fileURL = tempDirectoryURL.appendingPathComponent("\(lecture.id!.uuidString).tmp")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
        
        return lecture.toDTO()
    }

    @Sendable
    func uploadChunk(req: Request) async throws -> HTTPStatus {
        let payload = try req.jwt.verify(as: UserPayload.self)
        let userID = UUID(uuidString: payload.subject.value)!
        
        let lectureID = try req.query.get(UUID.self, at: "lectureId")
        guard let lecture = try await Lecture.find(lectureID, on: req.db),
              lecture.$user.id == userID else {
            throw Abort(.forbidden)
        }
        
        guard let body = req.body.data else { throw Abort(.badRequest) }
        let fileURL = tempDirectoryURL.appendingPathComponent("\(lectureID.uuidString).tmp")
        
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let fileHandle = try FileHandle(forWritingTo: fileURL)
            fileHandle.seekToEndOfFile()
            fileHandle.write(Data(buffer: body))
            fileHandle.closeFile()
        } else {
            try Data(buffer: body).write(to: fileURL)
        }
        
        return .ok
    }

    @Sendable
    func completeUpload(req: Request) async throws -> HTTPStatus {
        let payload = try req.jwt.verify(as: UserPayload.self)
        let lectureID = try req.query.get(UUID.self, at: "lectureId")
        let language = try req.query.get(String.self, at: "lang")
        
        guard let lecture = try await Lecture.find(lectureID, on: req.db) else {
            throw Abort(.notFound)
        }
        
        let tmpURL = tempDirectoryURL.appendingPathComponent("\(lectureID.uuidString).tmp")
        let finalAudioURL = tempDirectoryURL.appendingPathComponent("\(lectureID.uuidString).m4a")
        try? FileManager.default.moveItem(at: tmpURL, to: finalAudioURL)
        
        lecture.status = "waiting_in_queue"
        lecture.progress = 0.0
        try await lecture.save(on: req.db)
        
        let app = req.application
        let transcriber = app.storage[TranscriptionActorKey.self]!
        
        Task {
            await app.transcriptionQueue.enqueue {
                print("--- [ОЧЕРЕДЬ] Начинаю расшифровку файла: \(lectureID) ---")
                do {
                    guard let l = try await Lecture.find(lectureID, on: app.db) else { return }
                    
                    l.status = "processing"
                    l.progress = 0.05
                    try await l.save(on: app.db)
                    
                    let audioData = try await transcriber.loadAudioFile(at: finalAudioURL)
                    
                    let result = try await transcriber.transcribeWithSegments(jobID: lectureID.uuidString, audioData: audioData, language: language) { prog, _ in
                        Task {
                            if let rec = try? await Lecture.find(lectureID, on: app.db), rec.status != "canceled" {
                                rec.progress = prog
                                try? await rec.save(on: app.db)
                            }
                        }
                    }
                    
                    if let finalCheck = try? await Lecture.find(lectureID, on: app.db), finalCheck.status == "canceled" {
                        print("--- [ОЧЕРЕДЬ] Файл \(lectureID) был отменен. ---")
                        return
                    }

                    l.fullText = result.fullText
                    l.segments = result.segments
                    l.status = "completed"
                    l.progress = 1.0
                    try await l.save(on: app.db)
                    
                    print("--- [ОЧЕРЕДЬ] Файл \(lectureID) успешно обработан! ---")
                } catch {
                    if let failL = try? await Lecture.find(lectureID, on: app.db) {
                        if failL.status != "canceled" {
                            print("--- [ОЧЕРЕДЬ] Ошибка файла \(lectureID): \(error) ---")
                            failL.status = "error"
                            try? await failL.save(on: app.db)
                        }
                    }
                }
                // Для загруженных файлов мы удаляем аудио, т.к. оно УЖЕ есть на телефоне пользователя
                try? FileManager.default.removeItem(at: finalAudioURL)
            }
        }
        
        return .ok
    }

    @Sendable
    func importYouTube(req: Request) async throws -> LectureDTO {
        let payload = try req.jwt.verify(as: UserPayload.self)
        let userID = UUID(uuidString: payload.subject.value)!
        
        struct YouTubeData: Content { var url: String; var lang: String }
        let data = try req.content.decode(YouTubeData.self)
        
        let lecture = Lecture(title: "Загрузка YouTube...", fullText: "", userID: userID, status: "waiting_in_queue", progress: 0.0)
        try await lecture.save(on: req.db)
        
        let lectureID = lecture.id!
        let app = req.application
        let transcriber = app.storage[TranscriptionActorKey.self]!
        
        Task {
            await app.transcriptionQueue.enqueue {
                print("--- [ОЧЕРЕДЬ] Начинаю импорт YouTube: \(lectureID) ---")
                
                let audioURL = tempDirectoryURL.appendingPathComponent("\(lectureID.uuidString).m4a")
                
                do {
                    guard let l = try await Lecture.find(lectureID, on: app.db) else { return }
                    
                    let title = await self.fetchYouTubeTitle(url: data.url)
                    let duration = await self.fetchYouTubeDuration(url: data.url)
                    
                    if duration > 7200 { throw Abort(.payloadTooLarge) }
                    
                    l.title = title.isEmpty ? "YouTube Видео" : title
                    l.status = "processing"
                    l.progress = 0.1
                    try await l.save(on: app.db)
                    
                    // Скачиваем аудио по определенному пути
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/yt-dlp")
                    process.arguments = ["-f", "bestaudio[ext=m4a]/bestaudio", "-o", audioURL.path, data.url]
                    try process.run()
                    process.waitUntilExit()
                    
                    if !FileManager.default.fileExists(atPath: audioURL.path) {
                        throw Abort(.internalServerError)
                    }
                    
                    let audioData = try await transcriber.loadAudioFile(at: audioURL)
                    
                    let result = try await transcriber.transcribeWithSegments(jobID: lectureID.uuidString, audioData: audioData, language: data.lang) { prog, _ in
                        Task {
                            if let rec = try? await Lecture.find(lectureID, on: app.db), rec.status != "canceled" {
                                rec.progress = prog
                                try? await rec.save(on: app.db)
                            }
                        }
                    }
                    
                    if let finalCheck = try? await Lecture.find(lectureID, on: app.db), finalCheck.status == "canceled" {
                        try? FileManager.default.removeItem(at: audioURL)
                        return
                    }

                    l.fullText = result.fullText
                    l.segments = result.segments
                    l.status = "completed"
                    l.progress = 1.0
                    try await l.save(on: app.db)

                    print("--- [ОЧЕРЕДЬ] YouTube \(lectureID) завершен! Файл ожидает скачивания ---")
                    
                } catch {
                    if let failL = try? await Lecture.find(lectureID, on: app.db) {
                        if failL.status != "canceled" {
                            print("--- [ОЧЕРЕДЬ] Ошибка YouTube \(lectureID): \(error) ---")
                            failL.status = "error"
                            try? await failL.save(on: app.db)
                        }
                    }
                    // Если произошла ошибка, подчищаем файл
                    try? FileManager.default.removeItem(at: audioURL)
                }
            }
        }
        
        return lecture.toDTO()
    }

    @Sendable
    func cancelImport(req: Request) async throws -> HTTPStatus {
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

        lecture.status = "canceled"
        try await lecture.save(on: req.db)

        if let transcriber = req.application.storage[TranscriptionActorKey.self] {
            await transcriber.cancelJob(jobID: lectureID.uuidString)
        }

        return .ok
    }

    private func fetchYouTubeDuration(url: String) async -> Int {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/yt-dlp")
        process.arguments = ["--get-duration", url]
        process.standardOutput = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let durStr = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let parts = durStr.components(separatedBy: ":").compactMap { Int($0) }
            if parts.count == 3 { return (parts[0] * 3600) + (parts[1] * 60) + parts[2] }
            else if parts.count == 2 { return (parts[0] * 60) + parts[1] }
            else if parts.count == 1 { return parts[0] }
            return 0
        } catch { return 0 }
    }

    private func fetchYouTubeTitle(url: String) async -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/yt-dlp")
        process.arguments = ["--get-title", url]
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    
    @Sendable
    func downloadAudioFile(req: Request) async throws -> Response {
        let filename = req.parameters.get("filename") ?? ""
        let fileURL = tempDirectoryURL.appendingPathComponent(filename)
        
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw Abort(.notFound, reason: "Аудиофайл не найден")
        }
        return req.fileio.streamFile(at: fileURL.path)
    }

    @Sendable
    func deleteAudioFile(req: Request) async throws -> HTTPStatus {
        let filename = req.parameters.get("filename") ?? ""
        let fileURL = tempDirectoryURL.appendingPathComponent(filename)
        
        try? FileManager.default.removeItem(at: fileURL)
        return .ok
    }
}
