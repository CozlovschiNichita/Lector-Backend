import Vapor
import WhisperKit
import NIOCore
import Fluent
import JWT

actor SessionState {
    var audioBuffer: [Float] = []
    var lastRecognizedText: String = ""
    var fullTranscript: String = ""
    var fullSegments: [TextSegment] = []
    var processedTimeOffset: Double = 0.0
    let userID: UUID
    let language: String
    let sessionID: String = UUID().uuidString
    private var isTranscribing = false

    init(userID: UUID, language: String) {
        self.userID = userID
        self.language = language
    }

    func appendAudio(_ floats: [Float]) {
        audioBuffer.append(contentsOf: floats)
    }

    func extractLiveChunk() -> [Float]? {
        let chunkFrames = 16000 * 5
        let overlapFrames = 16000 * 1
        
        if audioBuffer.count >= chunkFrames {
            let chunk = Array(audioBuffer.prefix(chunkFrames))
            audioBuffer.removeFirst(chunkFrames - overlapFrames)
            return chunk
        }
        return nil
    }

    func processRemainingBuffer() -> [Float]? {
        guard !audioBuffer.isEmpty else { return nil }
        let chunk = audioBuffer
        audioBuffer.removeAll()
        return chunk
    }

    func tryStartTranscription() -> Bool {
        if isTranscribing { return false }
        isTranscribing = true
        return true
    }
    
    func finishTranscription() {
        isTranscribing = false
    }

    func appendToTranscript(newText: String, newSegments: [TextSegment]) -> String {
        let merged = mergeTranscriptions(old: lastRecognizedText, new: newText)
        if !merged.isEmpty {
            fullTranscript += (fullTranscript.isEmpty ? "" : " ") + merged
            lastRecognizedText = newText
            
            for seg in newSegments {
                let cleanSegText = cleanWhisperText(seg.text)
                if !cleanSegText.isEmpty {
                    let adjustedSegment = TextSegment(
                        text: cleanSegText,
                        startTime: processedTimeOffset + seg.startTime,
                        endTime: processedTimeOffset + seg.endTime
                    )
                    fullSegments.append(adjustedSegment)
                }
            }
        }
        return merged
    }
    
    func advanceTimeOffset() {
        processedTimeOffset += 4.0
    }

    func getFullTranscript() -> String {
        return fullTranscript
    }
}

func routes(_ app: Application) throws {
    
    // 1. СОКЕТЫ РЕГИСТРИРУЕМ ПЕРВЫМИ
    // Это исключает перехват маршрута контроллерами
    guard let transcriber = app.storage[TranscriptionActorKey.self] else { return }

    app.webSocket("ws", "transcribe", maxFrameSize: .init(integerLiteral: 1024 * 1024)) { req, ws in
        req.logger.notice("--- Попытка подключения к сокету ---")
        
        guard let token = try? req.query.get(String.self, at: "token"),
              let lang = try? req.query.get(String.self, at: "lang") else {
            req.logger.error("--- Ошибка сокета: Нет токена или языка в URL ---")
            _ = ws.close(code: .policyViolation)
            return
        }

        let payload: UserPayload
        do {
            payload = try req.jwt.verify(token, as: UserPayload.self)
        } catch {
            req.logger.error("--- Ошибка сокета: Невалидный JWT токен: \(error) ---")
            _ = ws.close(code: .policyViolation)
            return
        }

        guard let userID = UUID(uuidString: payload.subject.value) else {
            req.logger.error("--- Ошибка сокета: Неверный формат UUID пользователя ---")
            _ = ws.close(code: .policyViolation)
            return
        }

        req.logger.notice("--- WebSocket успешно открыт для пользователя: \(userID) ---")
        let state = SessionState(userID: userID, language: lang)

        ws.onBinary { [ws, state] _, byteBuffer in
            let readableBytes = byteBuffer.readableBytes
            guard readableBytes > 0, readableBytes % 4 == 0 else { return }
            
            let rawBytes = byteBuffer.getData(at: 0, length: readableBytes) ?? Data()
            let count = rawBytes.count / MemoryLayout<Float>.size
            let floats = rawBytes.withUnsafeBytes { pointer in
                Array(UnsafeBufferPointer(start: pointer.baseAddress?.assumingMemoryBound(to: Float.self), count: count))
            }
            
            Task {
                await state.appendAudio(floats)
                
                if await state.tryStartTranscription() {
                    Task { [ws, state] in
                        defer { Task { await state.finishTranscription() } }
                        
                        while let chunk = await state.extractLiveChunk() {
                            let language = await state.language
                            let sessionID = await state.sessionID // ПОЛУЧАЕМ ID
                            do {
                                // ПЕРЕДАЕМ ID СЮДА
                                let result = try await transcriber.transcribeWithSegments(jobID: sessionID, audioData: chunk, language: language, onProgress: { _, _ in })
                                let cleanText = cleanWhisperText(result.fullText)
                                
                                if !cleanText.isEmpty {
                                    let merged = await state.appendToTranscript(newText: cleanText, newSegments: result.segments)
                                    if !merged.isEmpty {
                                        if !ws.isClosed {
                                            try? await ws.send("[FINAL]" + merged)
                                        }
                                    }
                                }
                                await state.advanceTimeOffset()
                            } catch { }
                        }
                    }
                }
            }
        }

        ws.onText { [state] ws, text in
            if text == "FLUSH_BUFFER" {
                Task {
                    while await state.tryStartTranscription() == false {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                    if let chunk = await state.processRemainingBuffer() {
                        let language = await state.language
                        let sessionID = await state.sessionID // ПОЛУЧАЕМ ID
                        
                        // ПЕРЕДАЕМ ID СЮДА
                        if let result = try? await transcriber.transcribeWithSegments(jobID: sessionID, audioData: chunk, language: language, onProgress: { _, _ in }) {
                            let cleanText = cleanWhisperText(result.fullText)
                            if !cleanText.isEmpty {
                                let merged = await state.appendToTranscript(newText: cleanText, newSegments: result.segments)
                                if !merged.isEmpty && !ws.isClosed {
                                    try? await ws.send("[FINAL]" + merged)
                                }
                            }
                            await state.advanceTimeOffset()
                        }
                    }
                    await state.finishTranscription()
                }
            }
            else if text == "FINISH_AND_SAVE_LECTURE" {
                Task {
                    while await state.tryStartTranscription() == false {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                    }
                    
                    if let chunk = await state.processRemainingBuffer() {
                        let language = await state.language
                        let sessionID = await state.sessionID // ПОЛУЧАЕМ ID
                        
                        // ПЕРЕДАЕМ ID СЮДА
                        if let result = try? await transcriber.transcribeWithSegments(jobID: sessionID, audioData: chunk, language: language, onProgress: { _, _ in }) {
                            let cleanText = cleanWhisperText(result.fullText)
                            if !cleanText.isEmpty {
                                _ = await state.appendToTranscript(newText: cleanText, newSegments: result.segments)
                            }
                        }
                    }

                    let lecture = Lecture()
                    let finalTranscript = await state.fullTranscript
                    let finalSegments = await state.fullSegments
                    let currentUserID = await state.userID
                    
                    lecture.id = UUID()
                    lecture.title = "Лекция " + Date().formatted(date: .abbreviated, time: .shortened)
                    lecture.fullText = finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                    lecture.segments = finalSegments
                    lecture.$user.id = currentUserID
                    lecture.status = "completed"
                    lecture.progress = 1.0
                    
                    do {
                        try await lecture.save(on: req.db)
                        
                        if let lectureID = lecture.id?.uuidString {
                            try? await ws.send("SAVED_ID:\(lectureID)")
                        }
                    } catch {
                        print("--- [ERROR] ОШИБКА СОХРАНЕНИЯ: \(error) ---")
                    }
                    
                    await state.finishTranscription()
                }
            }
        }
    }
    
    // 2. КОНТРОЛЛЕРЫ РЕГИСТРИРУЕМ ПОСЛЕ СОКЕТА
    try app.register(collection: AuthController())
    try app.register(collection: LectureController())
    try app.register(collection: FolderController())
    try app.register(collection: ImportController())
}

func mergeTranscriptions(old: String, new: String) -> String {
    let cleanOld = old.lowercased().components(separatedBy: .punctuationCharacters).joined()
    let cleanNew = new.lowercased().components(separatedBy: .punctuationCharacters).joined()
    let oldWords = cleanOld.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
    let newWords = cleanNew.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
    
    guard !oldWords.isEmpty else { return new }
    
    for length in stride(from: min(oldWords.count, newWords.count, 5), to: 0, by: -1) {
        if oldWords.suffix(length).joined() == newWords.prefix(length).joined() {
            let actualNewWords = new.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            return actualNewWords.dropFirst(length).joined(separator: " ")
        }
    }
    return new
}

func cleanWhisperText(_ text: String) -> String {
    var cleaned = text
    cleaned = cleaned.replacingOccurrences(of: "<\\|.*?\\|>", with: "", options: .regularExpression)
    cleaned = cleaned.replacingOccurrences(of: "\\*.*?\\*", with: "", options: .regularExpression)
    cleaned = cleaned.replacingOccurrences(of: "\\(.*?\\)", with: "", options: .regularExpression)
    cleaned = cleaned.replacingOccurrences(of: "\\[.*?\\]", with: "", options: .regularExpression)
    
    let hallucinations = [
        "Субтитры сделал", "DimaTorzok", "Продолжение следует", "Продолжение следует...",
        "КОНЕЦ", "Конец", "конец", "Поехали", "Подпишитесь",
        "Amara.org", "Слышны звуки", "СПАСИБО", "Спасибо", "спасибо",
        "ПЕСНЯ", "Песня", "песня", "Спасибо за просмотр", "Спасибо за просмотр",
        "спасибо за просмотр", "ПЕЧАЛЬНАЯ МУЗЫКА СПОКОЙНАЯ МУЗЫКА", "ПОЕТ", "🎵", "🎶",
        "Субтитры сделал DimaTorzok", "Субтитры", "Thank you"
    ]
    
    for phrase in hallucinations {
        if cleaned.localizedCaseInsensitiveContains(phrase) { return "" }
    }
    
    return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
}
