import Foundation

// MARK: - ToDo Models

/// ToDoアイテム
struct ToDoItem: Codable, Identifiable {
    let id: UUID
    var content: String
    let extractedFrom: String // 抽出元の通話ID
    let participantNumber: String
    let callTimestamp: Date
    let extractedAt: Date
    var priority: ToDoPriority
    var category: ToDoCategory
    var isCompleted: Bool
    var completedAt: Date?
    var notes: String?
    
    init(
        id: UUID = UUID(),
        content: String,
        extractedFrom: String,
        participantNumber: String,
        callTimestamp: Date,
        extractedAt: Date = Date(),
        priority: ToDoPriority = .medium,
        category: ToDoCategory = .general,
        isCompleted: Bool = false,
        notes: String? = nil
    ) {
        self.id = id
        self.content = content
        self.extractedFrom = extractedFrom
        self.participantNumber = participantNumber
        self.callTimestamp = callTimestamp
        self.extractedAt = extractedAt
        self.priority = priority
        self.category = category
        self.isCompleted = isCompleted
        self.completedAt = nil
        self.notes = notes
    }
    
    /// ToDoを完了状態にする
    mutating func markCompleted() {
        isCompleted = true
        completedAt = Date()
    }
    
    /// ToDoを未完了状態にする
    mutating func markIncomplete() {
        isCompleted = false
        completedAt = nil
    }
}

/// ToDo優先度
enum ToDoPriority: String, Codable, CaseIterable {
    case low = "low"
    case medium = "medium"
    case high = "high"
    case urgent = "urgent"
    
    var displayName: String {
        switch self {
        case .low:
            return "低"
        case .medium:
            return "中"
        case .high:
            return "高"
        case .urgent:
            return "緊急"
        }
    }
    
    var color: String {
        switch self {
        case .low:
            return "gray"
        case .medium:
            return "blue"
        case .high:
            return "orange"
        case .urgent:
            return "red"
        }
    }
    
    var sortOrder: Int {
        switch self {
        case .urgent:
            return 0
        case .high:
            return 1
        case .medium:
            return 2
        case .low:
            return 3
        }
    }
}

/// ToDoカテゴリ
enum ToDoCategory: String, Codable, CaseIterable {
    case general = "general"
    case meeting = "meeting"
    case followUp = "follow_up"
    case document = "document"
    case phone = "phone"
    case email = "email"
    case task = "task"
    case appointment = "appointment"
    
    var displayName: String {
        switch self {
        case .general:
            return "一般"
        case .meeting:
            return "会議"
        case .followUp:
            return "フォローアップ"
        case .document:
            return "資料作成"
        case .phone:
            return "電話連絡"
        case .email:
            return "メール送信"
        case .task:
            return "作業"
        case .appointment:
            return "予定調整"
        }
    }
    
    var iconName: String {
        switch self {
        case .general:
            return "list.bullet"
        case .meeting:
            return "person.3"
        case .followUp:
            return "arrow.clockwise"
        case .document:
            return "doc"
        case .phone:
            return "phone"
        case .email:
            return "envelope"
        case .task:
            return "checkmark.square"
        case .appointment:
            return "calendar"
        }
    }
}

/// ToDo抽出結果
struct ToDoExtractionResult {
    let todos: [ToDoItem]
    let confidence: Double
    let processingTime: TimeInterval
    let extractionMethod: ToDoExtractionMethod
}

/// ToDo抽出方法
enum ToDoExtractionMethod: String, Codable {
    case aiKeywords = "ai_keywords"
    case patternMatching = "pattern_matching"
    case hybrid = "hybrid"
    
    var displayName: String {
        switch self {
        case .aiKeywords:
            return "AIキーワード抽出"
        case .patternMatching:
            return "パターンマッチング"
        case .hybrid:
            return "ハイブリッド"
        }
    }
}

// MARK: - Extensions

extension ToDoItem {
    /// 表示用の相対日時
    var relativeCallTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        return formatter.localizedString(for: callTimestamp, relativeTo: Date())
    }
    
    /// 参加者番号のマスク表示
    var maskedParticipantNumber: String {
        guard participantNumber.count > 4 else { return participantNumber }
        let prefix = String(participantNumber.prefix(3))
        let suffix = String(participantNumber.suffix(4))
        return "\(prefix)****\(suffix)"
    }
    
    /// 完了までの経過時間
    var timeToComplete: TimeInterval? {
        guard let completedAt = completedAt else { return nil }
        return completedAt.timeIntervalSince(extractedAt)
    }
}

extension Array where Element == ToDoItem {
    /// 未完了のToDoのみを取得
    var incomplete: [ToDoItem] {
        return self.filter { !$0.isCompleted }
    }
    
    /// 完了済みのToDoのみを取得
    var completed: [ToDoItem] {
        return self.filter { $0.isCompleted }
    }
    
    /// 優先度でソート
    var sortedByPriority: [ToDoItem] {
        return self.sorted { $0.priority.sortOrder < $1.priority.sortOrder }
    }
    
    /// 日時でソート（新しい順）
    var sortedByDate: [ToDoItem] {
        return self.sorted { $0.extractedAt > $1.extractedAt }
    }
    
    /// カテゴリでグループ化
    var groupedByCategory: [ToDoCategory: [ToDoItem]] {
        return Dictionary(grouping: self) { $0.category }
    }
    
    /// 優先度でグループ化
    var groupedByPriority: [ToDoPriority: [ToDoItem]] {
        return Dictionary(grouping: self) { $0.priority }
    }
}