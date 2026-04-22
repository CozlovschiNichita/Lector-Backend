@preconcurrency import WhisperKit
import Vapor
import Foundation
import AVFoundation

struct WhisperWrapper: @unchecked Sendable {
    let model: WhisperKit
}

struct TextSegment: Codable {
    var id: String = UUID().uuidString
    var text: String
    let startTime: Double
    let endTime: Double
}

struct TranscriptionResult: Codable {
    let fullText: String
    let segments: [TextSegment]
}

// Потокобезопасный класс для отслеживания отмененных задач
final class JobTracker: @unchecked Sendable {
    private var lock = NSLock()
    private var cancelledJobs: Set<String> = []
    
    // Хранилище замыканий, которые "убивают" системный процесс
    private var cancelBlocks: [String: () -> Void] = [:]
    
    func cancel(jobID: String) {
        lock.lock()
        defer { lock.unlock() }
        cancelledJobs.insert(jobID)
        // Мгновенно убиваем Swift Task
        cancelBlocks[jobID]?()
    }
    
    func isCancelled(jobID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledJobs.contains(jobID)
    }
    
    func remove(jobID: String) {
        lock.lock()
        defer { lock.unlock() }
        cancelledJobs.remove(jobID)
        cancelBlocks.removeValue(forKey: jobID)
    }
    
    func registerTask(jobID: String, cancelBlock: @escaping () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        cancelBlocks[jobID] = cancelBlock
    }
}

actor TranscriptionActor {
    private var wrapper: WhisperWrapper?
    private var isModelLoading = false
    private let jobTracker = JobTracker()

    func loadModel() async {
        guard wrapper == nil, !isModelLoading else { return }
        isModelLoading = true
        print("--- [STARTUP] Инициализация WhisperKit... ---")
        do {
            let config = WhisperKitConfig(model: "whisper-large-v3")
            let model = try await WhisperKit(config)
            self.wrapper = WhisperWrapper(model: model)
            print("--- СЕРВЕР ГОТОВ: whisper-large-v3 ---")
        } catch {
            print("[ERROR] Ошибка модели: \(error.localizedDescription)")
        }
        isModelLoading = false
    }
    
    func cancelJob(jobID: String) {
        jobTracker.cancel(jobID: jobID)
    }

    func transcribeWithSegments(jobID: String, audioData: [Float], language: String?, onProgress: @Sendable @escaping (Double, String) async -> Void) async throws -> TranscriptionResult {
        guard let model = self.wrapper?.model else {
            throw Abort(.internalServerError, reason: "Модель еще в процессе подготовки...")
        }
        
        defer {
            jobTracker.remove(jobID: jobID)
        }

        var options = DecodingOptions()
        options.task = .transcribe
        if let lang = language {
            options.language = lang
        }
        options.temperatureFallbackCount = 0

        let audioDurationSeconds = Double(audioData.count) / 16000.0
        var lastLoggedWindowId = -1
        let tracker = self.jobTracker
        var isAbortLogged = false
        
        // оборачиваем процесс в отменяемый SWIFT TASK
        let transcriptionTask = Task {
            try await model.transcribe(audioArray: audioData, decodeOptions: options) { progress in
                
                if tracker.isCancelled(jobID: jobID) || Task.isCancelled {
                    if !isAbortLogged {
                        print("--- [АБОРТ] Задача \(jobID) жестко прервана. Убиваем процесс... ---")
                        isAbortLogged = true
                    }
                    return false
                }
                
                let currentSeconds = Double(progress.windowId) * 30.0
                var calculatedProgress = currentSeconds / audioDurationSeconds
                if calculatedProgress > 0.95 { calculatedProgress = 0.95 }

                if progress.windowId != lastLoggedWindowId {
                    print("--- [PROGRESS] Окно \(progress.windowId) (\(String(format: "%.0f", currentSeconds))с из \(String(format: "%.0f", audioDurationSeconds))с) ---> \(Int(calculatedProgress * 100))%")
                    lastLoggedWindowId = progress.windowId
                }

                let liveText = progress.text.replacingOccurrences(of: "<\\|.*?\\|>", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)

                Task {
                    await onProgress(calculatedProgress, liveText)
                }
                
                return true
            }
        }
        
        // Регистрируем кнопку "УБИТЬ ПРОЦЕСС" для этого jobID
        tracker.registerTask(jobID: jobID) {
            transcriptionTask.cancel()
        }

        do {
            // Запускаем и ждем
            let results = try await transcriptionTask.value
            
            // Если вышли из цикла по отмене
            if tracker.isCancelled(jobID: jobID) || transcriptionTask.isCancelled {
                throw Abort(.custom(code: 499, reasonPhrase: "Cancelled by user"))
            }
            
            var allSegments: [TextSegment] = []
            var fullText = ""
            
            if let result = results.first {
                fullText = cleanWhisperTokens(result.text)
                for segment in result.segments {
                    let segText = cleanWhisperTokens(segment.text)
                    if !segText.isEmpty {
                        allSegments.append(TextSegment(text: segText, startTime: Double(segment.start), endTime: Double(segment.end)))
                    }
                }
            }
            
            await onProgress(1.0, fullText)
            return TranscriptionResult(fullText: fullText, segments: allSegments)
            
        } catch {
            // Если WhisperKit выбросит CancellationError из-за убитого потока, ловим его здесь:
            if tracker.isCancelled(jobID: jobID) || transcriptionTask.isCancelled {
                throw Abort(.custom(code: 499, reasonPhrase: "Cancelled by user"))
            }
            throw error
        }
    }

    func transcribe(jobID: String, audioData: [Float], language: String?, onProgress: @Sendable @escaping (Double, String) async -> Void) async throws -> String {
        let result = try await transcribeWithSegments(jobID: jobID, audioData: audioData, language: language, onProgress: onProgress)
        return result.fullText
    }

    func loadAudioFile(at url: URL) async throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let nativeFormat = file.processingFormat

        guard let nativeBuffer = AVAudioPCMBuffer(pcmFormat: nativeFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw Abort(.internalServerError)
        }
        try file.read(into: nativeBuffer)

        if nativeFormat.sampleRate == 16000 && nativeFormat.channelCount == 1 {
            return Array(UnsafeBufferPointer(start: nativeBuffer.floatChannelData![0], count: Int(nativeBuffer.frameLength)))
        }

        guard let converter = AVAudioConverter(from: nativeFormat, to: format) else { throw Abort(.internalServerError) }
        let ratio = nativeFormat.sampleRate / 16000
        let targetCapacity = AVAudioFrameCount(Double(nativeBuffer.frameLength) / ratio)
        guard let targetBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: targetCapacity) else { throw Abort(.internalServerError) }

        struct SBuffer: @unchecked Sendable { let b: AVAudioPCMBuffer }
        let sb = SBuffer(b: nativeBuffer)
        var err: NSError?

        converter.convert(to: targetBuffer, error: &err) { _, outStatus in
            outStatus.pointee = .haveData
            return sb.b
        }

        return Array(UnsafeBufferPointer(start: targetBuffer.floatChannelData![0], count: Int(targetBuffer.frameLength)))
    }
    
    private func cleanWhisperTokens(_ text: String) -> String {
        return text.replacingOccurrences(of: "<\\|.*?\\|>", with: "", options: .regularExpression)
                   .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
