import Foundation
import os.log

/// ToDo抽出サービス
/// 通話テキストからToDoアイテムを自動抽出する
@MainActor
class ToDoExtractionService: ObservableObject {
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.telreq.app", category: "ToDoExtraction")
    private let textProcessingService: TextProcessingServiceProtocol?
    
    // ToDo抽出用キーワードパターン
    private let todoKeywords = [
        // 直接的な依頼表現
        "してください", "お願いします", "やってください", "確認してください",
        "送ってください", "連絡してください", "準備してください", "検討してください",
        
        // 未来の予定・行動
        "します", "やります", "送ります", "確認します", "連絡します",
        "準備します", "検討します", "作成します", "手配します",
        
        // 期限・時間表現
        "までに", "まで", "〜日", "来週", "来月", "明日", "今度",
        "後で", "次回", "次に", "今後",
        
        // 作業・タスク関連
        "資料", "書類", "報告書", "企画書", "見積書", "契約書",
        "メール", "電話", "会議", "打ち合わせ", "ミーティング",
        "調整", "確認", "検討", "準備", "手配", "作成"
    ]
    
    // MARK: - Initialization
    
    init(textProcessingService: TextProcessingServiceProtocol? = nil) {
        self.textProcessingService = textProcessingService
    }
    
    // MARK: - Public Methods
    
    /// 通話テキストからToDoを抽出
    func extractToDos(
        from callData: StructuredCallData,
        method: ToDoExtractionMethod = .hybrid
    ) async throws -> ToDoExtractionResult {
        
        let startTime = Date()
        logger.info("Starting ToDo extraction from call: \(callData.id)")
        
        var extractedTodos: [ToDoItem] = []
        var confidence = 0.0
        
        switch method {
        case .aiKeywords:
            if let service = textProcessingService {
                extractedTodos = try await extractWithAI(callData, service: service)
                confidence = 0.85
            } else {
                logger.warning("AI service not available, falling back to pattern matching")
                extractedTodos = extractWithPatterns(callData)
                confidence = 0.65
            }
            
        case .patternMatching:
            extractedTodos = extractWithPatterns(callData)
            confidence = 0.70
            
        case .hybrid:
            // パターンマッチングで基本抽出
            let patternTodos = extractWithPatterns(callData)
            
            // AI抽出を試行
            var aiTodos: [ToDoItem] = []
            if let service = textProcessingService {
                do {
                    aiTodos = try await extractWithAI(callData, service: service)
                } catch {
                    logger.error("AI extraction failed: \(error.localizedDescription)")
                }
            }
            
            // 結果をマージして重複排除
            extractedTodos = mergeTodos(patternTodos, aiTodos)
            confidence = aiTodos.isEmpty ? 0.70 : 0.90
        }
        
        let processingTime = Date().timeIntervalSince(startTime)
        logger.info("ToDo extraction completed: \(extractedTodos.count) items in \(String(format: "%.2f", processingTime))s")
        
        return ToDoExtractionResult(
            todos: extractedTodos,
            confidence: confidence,
            processingTime: processingTime,
            extractionMethod: method
        )
    }
    
    // MARK: - Private Methods
    
    /// パターンマッチングによる抽出
    private func extractWithPatterns(_ callData: StructuredCallData) -> [ToDoItem] {
        let text = callData.transcriptionText
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: "。！？"))
        
        var todos: [ToDoItem] = []
        
        for sentence in sentences {
            let trimmedSentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedSentence.isEmpty else { continue }
            
            // キーワードマッチング
            let containsKeyword = todoKeywords.contains { keyword in
                trimmedSentence.contains(keyword)
            }
            
            if containsKeyword {
                let priority = determinePriority(from: trimmedSentence)
                let category = determineCategory(from: trimmedSentence)
                
                let todo = ToDoItem(
                    content: trimmedSentence,
                    extractedFrom: callData.id.uuidString,
                    participantNumber: callData.participantNumber,
                    callTimestamp: callData.timestamp,
                    priority: priority,
                    category: category
                )
                
                todos.append(todo)
            }
        }
        
        logger.debug("Pattern extraction found \(todos.count) ToDos")
        return todos
    }
    
    /// AIによる抽出
    private func extractWithAI(
        _ callData: StructuredCallData,
        service: TextProcessingServiceProtocol
    ) async throws -> [ToDoItem] {
        
        logger.debug("Starting AI-based ToDo extraction")
        
        // AI抽出はスキップ（actionItemsは削除済み）
        var todos: [ToDoItem] = []
        
        logger.debug("AI extraction found \(todos.count) ToDos")
        return todos
    }
    
    /// 優先度を判定
    private func determinePriority(from text: String) -> ToDoPriority {
        let urgentKeywords = ["緊急", "急ぎ", "すぐに", "至急", "今すぐ", "ASAP"]
        let highKeywords = ["重要", "大事", "優先", "先に", "まず"]
        let lowKeywords = ["時間があるとき", "余裕があるとき", "後で", "いつでも"]
        
        if urgentKeywords.contains(where: { text.contains($0) }) {
            return .urgent
        } else if highKeywords.contains(where: { text.contains($0) }) {
            return .high
        } else if lowKeywords.contains(where: { text.contains($0) }) {
            return .low
        } else {
            return .medium
        }
    }
    
    /// カテゴリを判定
    private func determineCategory(from text: String) -> ToDoCategory {
        let categoryKeywords: [ToDoCategory: [String]] = [
            .meeting: ["会議", "ミーティング", "打ち合わせ", "面談"],
            .followUp: ["フォロー", "確認", "進捗", "状況"],
            .document: ["資料", "書類", "報告書", "企画書", "見積書", "契約書"],
            .phone: ["電話", "連絡", "コール"],
            .email: ["メール", "送信", "返信"],
            .appointment: ["予定", "スケジュール", "日程", "調整"],
            .task: ["作業", "タスク", "実行", "処理"]
        ]
        
        for (category, keywords) in categoryKeywords {
            if keywords.contains(where: { text.contains($0) }) {
                return category
            }
        }
        
        return .general
    }
    
    /// ToDoリストをマージして重複排除
    private func mergeTodos(_ patternTodos: [ToDoItem], _ aiTodos: [ToDoItem]) -> [ToDoItem] {
        var mergedTodos = patternTodos
        
        for aiTodo in aiTodos {
            // 類似コンテンツの重複チェック
            let isDuplicate = mergedTodos.contains { existingTodo in
                let similarity = calculateSimilarity(aiTodo.content, existingTodo.content)
                return similarity > 0.8 // 80%以上の類似度で重複とみなす
            }
            
            if !isDuplicate {
                mergedTodos.append(aiTodo)
            }
        }
        
        return mergedTodos
    }
    
    /// テキストの類似度を計算（簡易版）
    private func calculateSimilarity(_ text1: String, _ text2: String) -> Double {
        let words1 = Set(text1.components(separatedBy: .whitespacesAndNewlines))
        let words2 = Set(text2.components(separatedBy: .whitespacesAndNewlines))
        
        let intersection = words1.intersection(words2)
        let union = words1.union(words2)
        
        guard !union.isEmpty else { return 0.0 }
        return Double(intersection.count) / Double(union.count)
    }
}