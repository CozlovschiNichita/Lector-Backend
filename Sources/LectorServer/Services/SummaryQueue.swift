import Vapor

actor SummaryQueue {
    static let shared = SummaryQueue()
    
    private var isProcessing = false
    private var queue: [() async throws -> Void] = []

    func enqueue(task: @escaping () async throws -> Void) async {
        queue.append(task)
        if !isProcessing {
            await processNext()
        }
    }

    private func processNext() async {
        guard !queue.isEmpty else {
            isProcessing = false
            return
        }
        
        isProcessing = true
        let task = queue.removeFirst()
        
        do {
            try await task()
        } catch {
            print("--- [ОЧЕРЕДЬ] Ошибка при выполнении задачи: \(error) ---")
        }
        
        await processNext()
    }
}
