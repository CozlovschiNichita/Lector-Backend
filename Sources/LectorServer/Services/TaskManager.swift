import Foundation

actor TaskManager {
    static let shared = TaskManager()
    
    private var tasks: [UUID: Task<Void, Never>] = [:]
    
    private init() {}

    func storeTask(_ task: Task<Void, Never>, for id: UUID) {
        tasks[id] = task
        print("--- [TASK MANAGER] Задача сохранена для лекции: \(id) ---")
    }

    func removeTask(for id: UUID) {
        tasks.removeValue(forKey: id)
        print("--- [TASK MANAGER] Задача удалена для лекции: \(id) ---")
    }

    func cancelTask(for id: UUID) {
        if let task = tasks[id] {
            task.cancel()
            tasks.removeValue(forKey: id)
            print("--- [TASK MANAGER] Задача ОСТАНОВЛЕНА для лекции: \(id) ---")
        }
    }
}
