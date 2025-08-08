import Foundation
import os.log

/// ToDo管理サービス
/// ToDoアイテムの保存、読み込み、管理を行う
@MainActor
class ToDoManager: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published var todos: [ToDoItem] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.telreq.app", category: "ToDoManager")
    private let offlineDataManager: OfflineDataManagerProtocol
    private let extractionService: ToDoExtractionService
    
    // MARK: - Computed Properties
    
    /// 未完了のToDo
    var incompleteTodos: [ToDoItem] {
        todos.filter { !$0.isCompleted }
    }
    
    /// 完了済みのToDo
    var completedTodos: [ToDoItem] {
        todos.filter { $0.isCompleted }
    }
    
    /// 優先度別のToDo
    var todosByPriority: [ToDoPriority: [ToDoItem]] {
        Dictionary(grouping: todos) { $0.priority }
    }
    
    /// カテゴリ別のToDo
    var todosByCategory: [ToDoCategory: [ToDoItem]] {
        Dictionary(grouping: todos) { $0.category }
    }
    
    // MARK: - Initialization
    
    init(
        offlineDataManager: OfflineDataManagerProtocol,
        extractionService: ToDoExtractionService
    ) {
        self.offlineDataManager = offlineDataManager
        self.extractionService = extractionService
    }
    
    // MARK: - Public Methods
    
    /// ToDoリストを読み込み
    func loadTodos() async {
        isLoading = true
        errorMessage = nil
        
        do {
            // ローカルストレージからToDo一覧を取得
            let savedTodos = try await loadSavedTodos()
            
            await MainActor.run {
                self.todos = savedTodos.sorted { $0.extractedAt > $1.extractedAt }
                self.isLoading = false
            }
            
            logger.info("Loaded \(savedTodos.count) ToDo items")
            
        } catch {
            await MainActor.run {
                self.errorMessage = "ToDoリストの読み込みに失敗しました: \(error.localizedDescription)"
                self.isLoading = false
            }
            logger.error("Failed to load todos: \(error.localizedDescription)")
        }
    }
    
    /// 通話記録からToDoを自動抽出・追加
    func extractAndAddTodos(from callData: StructuredCallData) async {
        do {
            let result = try await extractionService.extractToDos(from: callData)
            
            // 抽出されたToDoを追加
            for todo in result.todos {
                await addTodo(todo)
            }
            
            logger.info("Extracted and added \(result.todos.count) ToDos from call")
            
        } catch {
            await MainActor.run {
                self.errorMessage = "ToDoの抽出に失敗しました: \(error.localizedDescription)"
            }
            logger.error("Failed to extract todos: \(error.localizedDescription)")
        }
    }
    
    /// ToDoを追加
    func addTodo(_ todo: ToDoItem) async {
        do {
            // ローカルストレージに保存
            try await saveTodo(todo)
            
            await MainActor.run {
                // リストに追加して再ソート
                self.todos.append(todo)
                self.todos.sort { $0.extractedAt > $1.extractedAt }
            }
            
            logger.info("Added new ToDo: \(todo.content)")
            
        } catch {
            await MainActor.run {
                self.errorMessage = "ToDoの追加に失敗しました: \(error.localizedDescription)"
            }
            logger.error("Failed to add todo: \(error.localizedDescription)")
        }
    }
    
    /// ToDoを完了状態に変更
    func completeTodo(_ todoId: UUID) async {
        guard let index = todos.firstIndex(where: { $0.id == todoId }) else {
            logger.warning("ToDo not found: \(todoId)")
            return
        }
        
        var updatedTodo = todos[index]
        updatedTodo.markCompleted()
        
        do {
            try await updateTodo(updatedTodo)
            
            await MainActor.run {
                self.todos[index] = updatedTodo
            }
            
            logger.info("Completed ToDo: \(updatedTodo.content)")
            
        } catch {
            await MainActor.run {
                self.errorMessage = "ToDoの完了に失敗しました: \(error.localizedDescription)"
            }
            logger.error("Failed to complete todo: \(error.localizedDescription)")
        }
    }
    
    /// ToDoを未完了状態に戻す
    func uncompleteTodo(_ todoId: UUID) async {
        guard let index = todos.firstIndex(where: { $0.id == todoId }) else {
            logger.warning("ToDo not found: \(todoId)")
            return
        }
        
        var updatedTodo = todos[index]
        updatedTodo.markIncomplete()
        
        do {
            try await updateTodo(updatedTodo)
            
            await MainActor.run {
                self.todos[index] = updatedTodo
            }
            
            logger.info("Uncompleted ToDo: \(updatedTodo.content)")
            
        } catch {
            await MainActor.run {
                self.errorMessage = "ToDoの未完了化に失敗しました: \(error.localizedDescription)"
            }
            logger.error("Failed to uncomplete todo: \(error.localizedDescription)")
        }
    }
    
    /// ToDoを削除
    func deleteTodo(_ todoId: UUID) async {
        do {
            try await removeTodo(todoId)
            
            await MainActor.run {
                self.todos.removeAll { $0.id == todoId }
            }
            
            logger.info("Deleted ToDo: \(todoId)")
            
        } catch {
            await MainActor.run {
                self.errorMessage = "ToDoの削除に失敗しました: \(error.localizedDescription)"
            }
            logger.error("Failed to delete todo: \(error.localizedDescription)")
        }
    }
    
    /// ToDoにメモを追加
    func addNote(_ note: String, to todoId: UUID) async {
        guard let index = todos.firstIndex(where: { $0.id == todoId }) else {
            logger.warning("ToDo not found: \(todoId)")
            return
        }
        
        var updatedTodo = todos[index]
        updatedTodo.notes = note
        
        do {
            try await updateTodo(updatedTodo)
            
            await MainActor.run {
                self.todos[index] = updatedTodo
            }
            
            logger.info("Added note to ToDo: \(todoId)")
            
        } catch {
            await MainActor.run {
                self.errorMessage = "メモの追加に失敗しました: \(error.localizedDescription)"
            }
            logger.error("Failed to add note: \(error.localizedDescription)")
        }
    }
    
    /// 完了済みToDoを一括削除
    func clearCompletedTodos() async {
        let completedTodoIds = completedTodos.map { $0.id }
        
        for todoId in completedTodoIds {
            await deleteTodo(todoId)
        }
        
        logger.info("Cleared \(completedTodoIds.count) completed ToDos")
    }
    
    /// エラーメッセージをクリア
    func clearError() {
        errorMessage = nil
    }
    
    // MARK: - Private Methods
    
    /// 保存されたToDoを読み込み
    private func loadSavedTodos() async throws -> [ToDoItem] {
        // UserDefaultsからToDoリストを読み込み
        // 実際の実装では offlineDataManager を使用
        let key = "saved_todos"
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return []
        }
        
        let decoder = JSONDecoder()
        return try decoder.decode([ToDoItem].self, from: data)
    }
    
    /// ToDoを保存
    private func saveTodo(_ todo: ToDoItem) async throws {
        var currentTodos = try await loadSavedTodos()
        
        // 既存の同じIDのToDoを更新または新規追加
        if let index = currentTodos.firstIndex(where: { $0.id == todo.id }) {
            currentTodos[index] = todo
        } else {
            currentTodos.append(todo)
        }
        
        try await saveAllTodos(currentTodos)
    }
    
    /// ToDoを更新
    private func updateTodo(_ todo: ToDoItem) async throws {
        try await saveTodo(todo)
    }
    
    /// ToDoを削除
    private func removeTodo(_ todoId: UUID) async throws {
        var currentTodos = try await loadSavedTodos()
        currentTodos.removeAll { $0.id == todoId }
        try await saveAllTodos(currentTodos)
    }
    
    /// 全ToDoを保存
    private func saveAllTodos(_ todos: [ToDoItem]) async throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(todos)
        UserDefaults.standard.set(data, forKey: "saved_todos")
    }
}