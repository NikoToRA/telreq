import SwiftUI

/// ToDoリストビュー
/// 抽出されたToDoアイテムの一覧表示と管理機能を提供
struct ToDoListView: View {
    
    // MARK: - Properties
    
    @StateObject private var todoManager: ToDoManager
    @State private var selectedFilter: ToDoFilter = .all
    @State private var selectedSort: ToDoSort = .dateDescending
    @State private var showingCompletedTodos = false
    @State private var searchText = ""
    @State private var showingAddToDoSheet = false
    
    // MARK: - Initialization
    
    init(
        offlineDataManager: OfflineDataManagerProtocol,
        extractionService: ToDoExtractionService
    ) {
        self._todoManager = StateObject(
            wrappedValue: ToDoManager(
                offlineDataManager: offlineDataManager,
                extractionService: extractionService
            )
        )
    }
    
    // MARK: - Body
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // フィルター・ソートツールバー
                filterToolbar
                
                // ToDoリスト
                todoList
            }
            .navigationTitle("ToDoリスト")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button(action: {
                        showingAddToDoSheet = true
                    }) {
                        Image(systemName: "plus")
                    }
                    
                    Menu {
                        Picker("並び順", selection: $selectedSort) {
                            ForEach(ToDoSort.allCases, id: \.self) { sort in
                                Label(sort.displayName, systemImage: sort.iconName)
                                    .tag(sort)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                }
            }
            .searchable(text: $searchText, prompt: "ToDoを検索")
            .refreshable {
                await todoManager.loadTodos()
            }
        }
        .sheet(isPresented: $showingAddToDoSheet) {
            AddToDoSheet(todoManager: todoManager)
        }
        .alert("エラー", isPresented: .constant(todoManager.errorMessage != nil)) {
            Button("OK") {
                todoManager.clearError()
            }
        } message: {
            Text(todoManager.errorMessage ?? "")
        }
        .task {
            await todoManager.loadTodos()
        }
    }
    
    // MARK: - Subviews
    
    /// フィルター・ソートツールバー
    private var filterToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(ToDoFilter.allCases, id: \.self) { filter in
                    FilterChip(
                        title: filter.displayName,
                        count: todoCount(for: filter),
                        isSelected: selectedFilter == filter
                    ) {
                        selectedFilter = filter
                    }
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
        .background(Color(UIColor.systemBackground))
    }
    
    /// ToDoリスト
    private var todoList: some View {
        Group {
            if todoManager.isLoading {
                ProgressView("読み込み中...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredTodos.isEmpty {
                emptyStateView
            } else {
                List {
                    ForEach(groupedTodos.keys.sorted(), id: \.self) { section in
                        Section(header: sectionHeader(for: section)) {
                            ForEach(groupedTodos[section] ?? []) { todo in
                                ToDoRowView(
                                    todo: todo,
                                    onToggleComplete: { todoId in
                                        Task {
                                            if todo.isCompleted {
                                                await todoManager.uncompleteTodo(todoId)
                                            } else {
                                                await todoManager.completeTodo(todoId)
                                            }
                                        }
                                    },
                                    onDelete: { todoId in
                                        Task {
                                            await todoManager.deleteTodo(todoId)
                                        }
                                    }
                                )
                            }
                        }
                    }
                    
                    // 完了済みToDo一括削除ボタン
                    if !todoManager.completedTodos.isEmpty && showingCompletedTodos {
                        Section {
                            Button("完了済みToDoを一括削除") {
                                Task {
                                    await todoManager.clearCompletedTodos()
                                }
                            }
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }
    
    /// 空状態ビュー
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "checklist")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            
            Text("ToDoがありません")
                .font(.headline)
                .foregroundColor(.secondary)
            
            Text("通話から自動抽出されたToDoや\n手動で追加したToDoがここに表示されます")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Button("ToDoを追加") {
                showingAddToDoSheet = true
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    /// セクションヘッダー
    private func sectionHeader(for section: String) -> some View {
        HStack {
            Text(section)
                .font(.headline)
                .foregroundColor(.primary)
            
            Spacer()
            
            Text("\((groupedTodos[section] ?? []).count)件")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    // MARK: - Computed Properties
    
    /// フィルター済みToDo
    private var filteredTodos: [ToDoItem] {
        let todos = selectedFilter.filterTodos(todoManager.todos)
        let searched = searchText.isEmpty ? todos : todos.filter { todo in
            todo.content.localizedCaseInsensitiveContains(searchText) ||
            todo.participantNumber.contains(searchText)
        }
        
        return selectedSort.sortTodos(searched)
    }
    
    /// グループ化されたToDo
    private var groupedTodos: [String: [ToDoItem]] {
        switch selectedSort {
        case .priority:
            let grouped = Dictionary(grouping: filteredTodos) { $0.priority.displayName }
            return grouped
        case .category:
            let grouped = Dictionary(grouping: filteredTodos) { $0.category.displayName }
            return grouped
        default:
            return ["すべて": filteredTodos]
        }
    }
    
    /// フィルター別のToDo件数
    private func todoCount(for filter: ToDoFilter) -> Int {
        filter.filterTodos(todoManager.todos).count
    }
}

// MARK: - Supporting Views

/// フィルターチップ
struct FilterChip: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                if count > 0 {
                    Text("\(count)")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(isSelected ? Color.white.opacity(0.8) : Color.primary.opacity(0.2))
                        .cornerRadius(10)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(isSelected ? Color.accentColor : Color(UIColor.systemGray5))
            )
            .foregroundColor(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}

/// ToDo行ビュー
struct ToDoRowView: View {
    let todo: ToDoItem
    let onToggleComplete: (UUID) -> Void
    let onDelete: (UUID) -> Void
    
    @State private var showingDetail = false
    
    var body: some View {
        HStack(spacing: 12) {
            // チェックボックス
            Button(action: {
                onToggleComplete(todo.id)
            }) {
                Image(systemName: todo.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundColor(todo.isCompleted ? .green : .gray)
            }
            .buttonStyle(.plain)
            
            // ToDo内容
            VStack(alignment: .leading, spacing: 4) {
                Text(todo.content)
                    .font(.body)
                    .strikethrough(todo.isCompleted)
                    .foregroundColor(todo.isCompleted ? .secondary : .primary)
                    .lineLimit(2)
                
                HStack(spacing: 8) {
                    // 優先度バッジ
                    PriorityBadge(priority: todo.priority)
                    
                    // カテゴリアイコン
                    Label(todo.category.displayName, systemImage: todo.category.iconName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    // 抽出元通話の時間
                    Text(todo.relativeCallTime)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            showingDetail = true
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("削除", role: .destructive) {
                onDelete(todo.id)
            }
        }
        .sheet(isPresented: $showingDetail) {
            ToDoDetailView(todo: todo)
        }
    }
}

/// 優先度バッジ
struct PriorityBadge: View {
    let priority: ToDoPriority
    
    var body: some View {
        Text(priority.displayName)
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(priorityColor.opacity(0.2))
            .foregroundColor(priorityColor)
            .cornerRadius(4)
    }
    
    private var priorityColor: Color {
        switch priority {
        case .urgent:
            return .red
        case .high:
            return .orange
        case .medium:
            return .blue
        case .low:
            return .gray
        }
    }
}

// MARK: - Supporting Types

/// ToDoフィルター
enum ToDoFilter: String, CaseIterable {
    case all = "all"
    case incomplete = "incomplete"
    case completed = "completed"
    case urgent = "urgent"
    case today = "today"
    
    var displayName: String {
        switch self {
        case .all:
            return "すべて"
        case .incomplete:
            return "未完了"
        case .completed:
            return "完了済み"
        case .urgent:
            return "緊急"
        case .today:
            return "今日"
        }
    }
    
    func filterTodos(_ todos: [ToDoItem]) -> [ToDoItem] {
        switch self {
        case .all:
            return todos
        case .incomplete:
            return todos.filter { !$0.isCompleted }
        case .completed:
            return todos.filter { $0.isCompleted }
        case .urgent:
            return todos.filter { $0.priority == .urgent }
        case .today:
            return todos.filter { Calendar.current.isDateInToday($0.extractedAt) }
        }
    }
}

/// ToDoソート
enum ToDoSort: String, CaseIterable {
    case dateDescending = "date_desc"
    case dateAscending = "date_asc"
    case priority = "priority"
    case category = "category"
    
    var displayName: String {
        switch self {
        case .dateDescending:
            return "新しい順"
        case .dateAscending:
            return "古い順"
        case .priority:
            return "優先度順"
        case .category:
            return "カテゴリ順"
        }
    }
    
    var iconName: String {
        switch self {
        case .dateDescending:
            return "calendar.badge.minus"
        case .dateAscending:
            return "calendar.badge.plus"
        case .priority:
            return "exclamationmark.triangle"
        case .category:
            return "folder"
        }
    }
    
    func sortTodos(_ todos: [ToDoItem]) -> [ToDoItem] {
        switch self {
        case .dateDescending:
            return todos.sorted { $0.extractedAt > $1.extractedAt }
        case .dateAscending:
            return todos.sorted { $0.extractedAt < $1.extractedAt }
        case .priority:
            return todos.sorted { $0.priority.sortOrder < $1.priority.sortOrder }
        case .category:
            return todos.sorted { $0.category.displayName < $1.category.displayName }
        }
    }
}

// MARK: - Preview

#Preview {
    ToDoListView(
        offlineDataManager: MockOfflineDataManager(),
        extractionService: ToDoExtractionService()
    )
}

// MARK: - Mock for Preview

class MockOfflineDataManager: OfflineDataManagerProtocol {
    func saveLocalData(_ data: StructuredCallData) async throws {}
    func getLocalData(callId: String) async throws -> StructuredCallData? { return nil }
    func getAllLocalData() async throws -> [StructuredCallData] { return [] }
    func deleteLocalData(callId: String) async throws {}
    func getPendingSyncData() async throws -> [StructuredCallData] { return [] }
    func markSyncCompleted(callId: String) async throws {}
    func getStorageInfo() async throws -> LocalStorageInfo {
        return LocalStorageInfo(usedBytes: 0, availableBytes: 0, totalFiles: 0, pendingSyncCount: 0)
    }
    func clearCache() async throws {}
    func loadCallHistory(limit: Int, offset: Int) async throws -> [CallRecord] { return [] }
    func deleteCallRecord(_ id: String) async throws {}
    func loadCallDetails(_ callId: String) async throws -> StructuredCallData {
        throw AppError.callRecordNotFound
    }
}