import Vapor

struct TranscriptionQueueKey: StorageKey {
    typealias Value = TranscriptionQueue
}

actor TranscriptionQueue {
    private var previousTask: Task<Void, Error>?

    func enqueue(operation: @escaping @Sendable () async throws -> Void) {
        let current = previousTask // Запоминаем текущую задачу
        
        let newTask = Task {
            _ = await current?.result // Ждем, пока завершится предыдущая
            try await operation()     // Выполняем новую
        }
        
        previousTask = newTask // Обновляем ссылку (старая задача удалится из памяти)
    }
}

extension Application {
    var transcriptionQueue: TranscriptionQueue {
        get {
            if let queue = self.storage[TranscriptionQueueKey.self] {
                return queue
            }
            let new = TranscriptionQueue()
            self.storage[TranscriptionQueueKey.self] = new
            return new
        }
        set { self.storage[TranscriptionQueueKey.self] = newValue }
    }
}
