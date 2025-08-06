import Foundation
import NaturalLanguage
import os.log

/// 並行処理安全性のためのActor
actor TextProcessingActor {
    private var processingCount = 0
    private let maxConcurrentTasks = 1  // 同時実行を1つに制限
    
    func withSafeProcessing<T>(operation: () async throws -> T) async throws -> T {
        // 既に処理中の場合は待機
        while processingCount >= maxConcurrentTasks {
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms待機
        }
        
        processingCount += 1
        defer { processingCount -= 1 }
        
        return try await operation()
    }
}

/// テキスト処理サービス
///
/// 通話内容の自動要約生成、キーワード抽出、アクションアイテム識別、
/// 発言者識別、言語検出、品質評価を提供します。
final class TextProcessingService: TextProcessingServiceProtocol {
    
    // MARK: - Properties
    
    /// ログ出力用
    private let logger = Logger(subsystem: "com.telreq.app", category: "TextProcessing")
    
    /// 自然言語処理器
    private let languageRecognizer = NLLanguageRecognizer()
    private let tokenizer = NLTokenizer(unit: .word)
    // 注意: taggerは並行処理で安全ではないため、メソッド内で個別に作成
    
    /// Azure OpenAI Serviceの設定
    private let openAIConfig: AzureOpenAIConfig
    
    /// URLSession for API calls
    private let urlSession: URLSession
    
    /// 処理中フラグ（競合状態防止）
    private let processingActor = TextProcessingActor()
    
    /// 要約品質の閾値（設定から取得、デフォルトは0.7）
    private var summaryQualityThreshold: Double {
        return UserDefaults.standard.object(forKey: "summaryQualityThreshold") as? Double ?? 0.7
    }
    
    /// キーワード抽出の最大数
    private let maxKeywords = 20
    
    /// 設定から要約モードを取得
    private var summaryMode: String {
        return UserDefaults.standard.string(forKey: "summaryMode") ?? "rule_based_primary"
    }
    
    /// 設定からAI要約有効状態を取得
    private var aiSummaryEnabled: Bool {
        return UserDefaults.standard.object(forKey: "aiSummaryEnabled") as? Bool ?? true
    }
    
    /// 設定から最大要約文字数を取得
    private var maxSummaryLength: Int {
        return UserDefaults.standard.object(forKey: "maxSummaryLength") as? Int ?? 500
    }
    
    /// 設定からキーワード抽出有効状態を取得
    private var includeKeywords: Bool {
        return UserDefaults.standard.object(forKey: "includeKeywords") as? Bool ?? true
    }
    
    /// 設定からアクションアイテム抽出有効状態を取得
    private var includeActionItems: Bool {
        return UserDefaults.standard.object(forKey: "includeActionItems") as? Bool ?? true
    }
    
    /// 設定からカスタムプロンプト使用状態を取得
    private var useCustomPrompt: Bool {
        return UserDefaults.standard.object(forKey: "useCustomPrompt") as? Bool ?? false
    }
    
    /// 設定からカスタムシステムプロンプトを取得
    private var customSystemPrompt: String {
        return UserDefaults.standard.string(forKey: "customSystemPrompt") ?? ""
    }
    
    /// 設定からカスタム要約プロンプトを取得
    private var customSummaryPrompt: String {
        return UserDefaults.standard.string(forKey: "customSummaryPrompt") ?? ""
    }
    
    /// アクションアイテム検出のパターン
    private let actionPatterns = [
        // 日本語パターン
        "(?:(?:次回|来週|明日|後で|今度)(?:まで)?に)?(.{1,50}?)(?:し(?:て(?:おく|もらう|ください)|ます)|する|やる|実施|検討|確認|調査|準備|作成|送付|提出)(?:予定|必要|べき)?",
        "(.{1,50}?)を(?:お願い|依頼|頼む|任せる)",
        "(.{1,50}?)について(?:確認|調査|検討|相談)(?:し(?:て(?:もらう|ください)|ます)|する)",
        
        // 英語パターン
        "(?:need to|should|must|will|going to)\\s+(.{1,50}?)(?:\\.|$)",
        "(.{1,50}?)\\s+(?:by|before)\\s+(?:next|tomorrow|this|the)",
        "action\\s*:?\\s*(.{1,50}?)(?:\\.|$)",
        "todo\\s*:?\\s*(.{1,50}?)(?:\\.|$)"
    ]
    
    /// 発言者識別のパターン
    private let speakerPatterns = [
        // 「田中さん：」のようなパターン
        "^([\\p{L}\\p{N}]+(?:さん|様|氏|先生|部長|課長|主任)?)\\s*[：:：]",
        // 「Speaker 1:」のようなパターン
        "^(Speaker\\s*\\d+|話者\\s*\\d+)\\s*[：:：]",
        // 「A：」「B：」のようなパターン
        "^([A-Z])\\s*[：:：]"
    ]
    
    // MARK: - Initialization
    
    init(openAIConfig: AzureOpenAIConfig) {
        self.openAIConfig = openAIConfig
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30.0
        config.timeoutIntervalForResource = 60.0
        self.urlSession = URLSession(configuration: config)
        
        logger.info("TextProcessingService initialized")
    }
    
    
    // MARK: - TextProcessingServiceProtocol Implementation
    
    /// テキストを要約
    /// - Parameter text: 要約するテキスト
    /// - Returns: 生成された要約
    func summarizeText(_ text: String) async throws -> CallSummary {
        return try await processingActor.withSafeProcessing {
            return try await self.performTextSummarization(text)
        }
    }
    
    /// 実際の要約処理を実行
    private func performTextSummarization(_ text: String) async throws -> CallSummary {
        logger.info("🔄 Starting text summarization for text length: \(text.count)")
        
        // 空のテキストの場合はフォールバック要約を作成
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.warning("Empty text provided, creating fallback summary")
            return CallSummary(
                keyPoints: ["音声データなし"],
                summary: "音声認識データがありませんでした",
                duration: 0,
                participants: ["Unknown"],
                actionItems: [],
                tags: ["no-audio"],
                confidence: 0.0
            )
        }
        
        // メモリ使用量をチェックし、警告を出力
        let memoryUsage = AsyncDebugHelpers.shared.getMemoryUsage()
        if memoryUsage > 200.0 {
            logger.warning("⚠️ High memory usage before processing: \(String(format: "%.1f", memoryUsage)) MB")
        }
        
        let language = detectLanguage(in: text)
        let quality = evaluateTextQuality(text)
        
        logger.info("Detected language: \(language), Quality: \(quality)")
        
        var summaryText: String
        var confidence: Double
        
        // 設定に基づいた要約処理
        let currentSummaryMode = self.summaryMode
        let aiEnabled = self.aiSummaryEnabled
        
        logger.info("🔍 Summary mode: \(currentSummaryMode), AI enabled: \(aiEnabled), Quality: \(quality), Threshold: \(self.summaryQualityThreshold)")
        
        do {
            switch currentSummaryMode {
            case "rule_based_only":
                logger.info("📝 Rule-based only mode")
                let ruleSummary = generateRuleBasedSummary(text)
                summaryText = ruleSummary.text
                confidence = ruleSummary.confidence
                logger.info("📝 Rule-based summary completed")
                
            case "ai_only":
                if aiEnabled {
                    logger.info("🤖 AI-only mode")
                    let aiSummary = try await generateAzureOpenAISummary(text, language: language, config: openAIConfig)
                    summaryText = aiSummary.text
                    confidence = aiSummary.confidence
                    logger.info("✅ AI summary completed")
                } else {
                    logger.info("📝 AI disabled, falling back to rule-based")
                    let ruleSummary = generateRuleBasedSummary(text)
                    summaryText = ruleSummary.text
                    confidence = ruleSummary.confidence * 0.8
                    logger.info("📝 Fallback rule-based summary completed")
                }
                
            case "ai_primary":
                if aiEnabled {
                    logger.info("🤖 AI-primary mode")
                    let aiSummary = try await generateAzureOpenAISummary(text, language: language, config: openAIConfig)
                    summaryText = aiSummary.text
                    confidence = aiSummary.confidence
                    logger.info("✅ AI summary completed")
                } else {
                    logger.info("📝 AI disabled, using rule-based")
                    let ruleSummary = generateRuleBasedSummary(text)
                    summaryText = ruleSummary.text
                    confidence = ruleSummary.confidence
                    logger.info("📝 Rule-based summary completed")
                }
                
            default: // "rule_based_primary"
                logger.info("📝 Rule-based primary mode, quality check: \(quality) vs \(self.summaryQualityThreshold)")
                if quality > summaryQualityThreshold && aiEnabled {
                    logger.info("🤖 High quality + AI enabled, using AI summary")
                    let aiSummary = try await generateAzureOpenAISummary(text, language: language, config: openAIConfig)
                    summaryText = aiSummary.text
                    confidence = aiSummary.confidence
                    logger.info("✅ AI summary completed")
                } else {
                    logger.info("📝 Using rule-based summary (quality: \(quality), AI enabled: \(aiEnabled))")
                    let ruleSummary = generateRuleBasedSummary(text)
                    summaryText = ruleSummary.text
                    confidence = ruleSummary.confidence
                    logger.info("📝 Rule-based summary completed")
                }
            }
        } catch {
            // サイレントにフォールバック処理
            logger.info("🔄 Falling back to rule-based summary")
            let ruleSummary = generateRuleBasedSummary(text)
            summaryText = ruleSummary.text
            confidence = ruleSummary.confidence * 0.7 // 信頼度を下げる
            logger.info("📝 Fallback rule-based summary completed")
        }
        
        // 各タスクを設定に応じて安全に実行（エラーハンドリング付き）
        var keyPoints: [String]
        var keywords: [String]
        var actionItems: [String]
        var participants: [String]
        
        let shouldIncludeKeywords = self.includeKeywords
        let shouldIncludeActionItems = self.includeActionItems
        
        logger.info("🔍 Extraction settings - Keywords: \(shouldIncludeKeywords), ActionItems: \(shouldIncludeActionItems)")
        
        do {
            async let keyPointsTask = extractKeyPoints(from: text)
            async let keywordsTask: [String] = shouldIncludeKeywords ? self.extractKeywords(from: text) : []
            async let actionItemsTask: [String] = shouldIncludeActionItems ? self.extractActionItems(from: text) : []
            async let participantsTask = self.identifySpeakers(in: text)
            
            keyPoints = await keyPointsTask
            keywords = shouldIncludeKeywords ? (try await keywordsTask) : []
            actionItems = shouldIncludeActionItems ? (try await actionItemsTask) : []
            participants = try await participantsTask
            
            logger.info("📊 Extracted - Keywords: \(keywords.count), ActionItems: \(actionItems.count)")
            
        } catch {
            logger.warning("Some extraction tasks failed: \(error.localizedDescription), using fallback values")
            keyPoints = ["要約処理中にエラーが発生しました"]
            keywords = []
            actionItems = []
            participants = ["Unknown"]
        }
        
        let summary = CallSummary(
            keyPoints: keyPoints,
            summary: summaryText,
            duration: estimateTextDuration(text),
            participants: participants,
            actionItems: actionItems,
            tags: keywords,
            confidence: confidence
        )
        
        logger.info("Text summarization completed with confidence: \(confidence)")
        return summary
    }
    
    /// 通話データを構造化
    func structureCallData(_ text: String, metadata: CallMetadata) async throws -> StructuredCallData {
        logger.info("Structuring call data")
        
        let summary = try await summarizeText(text)
        
        let audioFileUrl = "audio://\(UUID().uuidString).m4a"
        
        return StructuredCallData(
            timestamp: metadata.startTime,
            duration: metadata.endTime.timeIntervalSince(metadata.startTime),
            participantNumber: extractPhoneNumber(from: text) ?? "Unknown",
            audioFileUrl: audioFileUrl,
            transcriptionText: text,
            summary: summary,
            metadata: metadata
        )
    }
    
    /// キーワードを抽出
    func extractKeywords(from text: String) async throws -> [String] {
        logger.info("Extracting keywords from text")
        
        // 入力テキストの検証
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.warning("extractKeywords: Empty text provided")
            return []
        }
        
        return await withTaskGroup(of: [String].self, returning: [String].self) { group in
            // 各タスクでエラーハンドリングを追加
            group.addTask {
                return self.extractKeywordsWithTFIDF(text)
            }
            
            group.addTask {
                return self.extractNamedEntities(text)
            }
            
            group.addTask {
                return self.extractImportantPhrases(text)
            }
            
            var allKeywords: Set<String> = []
            for await keywords in group {
                allKeywords.formUnion(keywords)
            }
            
            return Array(allKeywords)
                .filter { !$0.isEmpty && $0.count >= 2 }
                .sorted { $0.count > $1.count }
                .prefix(maxKeywords)
                .map { $0 }
        }
    }
    
    /// アクションアイテムを抽出
    func extractActionItems(from text: String) async throws -> [String] {
        logger.info("Extracting action items from text")
        
        var actionItems: [String] = []
        for pattern in actionPatterns {
            do {
                let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
                let matches = regex.matches(in: text, options: [], range: NSRange(text.startIndex..., in: text))
                for match in matches {
                    if match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) {
                        let actionItem = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !actionItem.isEmpty && actionItem.count > 3 {
                            actionItems.append(actionItem)
                        }
                    }
                }
            } catch {
                logger.warning("Failed to process action pattern: \(pattern)")
            }
        }
        
        let uniqueActions = Array(Set(actionItems))
            .sorted { $0.count > $1.count }
            .prefix(10)
        
        logger.info("Extracted \(uniqueActions.count) action items")
        return Array(uniqueActions)
    }
    
    /// 発言者を識別
    func identifySpeakers(in text: String) async throws -> [String] {
        logger.info("Identifying speakers in text")
        
        var speakers: Set<String> = []
        let lines = text.components(separatedBy: .newlines)
        
        for line in lines {
            for pattern in speakerPatterns {
                do {
                    let regex = try NSRegularExpression(pattern: pattern, options: [])
                    if let match = regex.firstMatch(in: line, options: [], range: NSRange(line.startIndex..., in: line)),
                       match.numberOfRanges > 1,
                       let range = Range(match.range(at: 1), in: line) {
                        let speaker = String(line[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !speaker.isEmpty {
                            speakers.insert(speaker)
                        }
                    }
                } catch {
                    logger.warning("Failed to process speaker pattern: \(pattern)")
                }
            }
        }
        
        logger.info("Identified \(speakers.count) speakers")
        return Array(speakers).sorted()
    }
    
    /// 言語を検出
    func detectLanguage(in text: String) -> String {
        languageRecognizer.processString(text)
        if let language = languageRecognizer.dominantLanguage {
            return language.rawValue
        }
        return "ja" // Default
    }
    
    /// テキストの品質を評価
    func evaluateTextQuality(_ text: String) -> Double {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return 0.0 }
        
        let lengthScore = min(Double(cleanText.count) / 1000.0, 1.0) * 0.2
        let sentenceEndCount = cleanText.components(separatedBy: CharacterSet(charactersIn: "。．.！？!?")).count - 1
        let sentenceScore = min(Double(sentenceEndCount) / 10.0, 1.0) * 0.3
        
        // スレッドセーフティのため、メソッド内で新しいtokenizer インスタンスを作成
        let localTokenizer = NLTokenizer(unit: .word)
        localTokenizer.string = cleanText
        let tokens = localTokenizer.tokens(for: cleanText.startIndex..<cleanText.endIndex)
        let uniqueTokens = Set(tokens.map { String(cleanText[$0]) })
        let vocabularyScore = Double(uniqueTokens.count) / Double(max(tokens.count, 1)) * 0.3
        
        let fillerWords = ["あー", "えー", "えーと", "そのー", "うーん", "uh", "um", "er"]
        var fillerCount = 0
        for filler in fillerWords {
            fillerCount += cleanText.components(separatedBy: filler).count - 1
        }
        let noiseScore = max(0.0, 1.0 - Double(fillerCount) / 20.0) * 0.2
        
        let finalScore = lengthScore + sentenceScore + vocabularyScore + noiseScore
        return min(max(finalScore, 0.0), 1.0)
    }
    
    // MARK: - Private Methods
    
    /// Azure OpenAIで要約を生成
    private func generateAzureOpenAISummary(
        _ text: String,
        language: String,
        config: AzureOpenAIConfig
    ) async throws -> SummaryResult {
        
        // 設定検証を緩和
        guard !config.apiKey.isEmpty else {
            logger.warning("⚠️ Azure OpenAI API key is empty, falling back to rule-based")
            throw AppError.invalidConfiguration
        }
        
        guard !config.deploymentName.isEmpty else {
            logger.warning("⚠️ Azure OpenAI deployment name is empty, falling back to rule-based")
            throw AppError.invalidConfiguration
        }
        
        guard config.endpoint.absoluteString.contains("openai.azure.com") else {
            logger.warning("⚠️ Azure OpenAI endpoint format invalid, falling back to rule-based")
            throw AppError.invalidConfiguration
        }
        
        logger.info("🔍 Azure OpenAI validation passed - Endpoint: \(config.endpoint), Deployment: \(config.deploymentName)")
        
        return try await AsyncDebugHelpers.shared.trackAsyncTask({
            try await self.performAzureOpenAIRequest(text, language: language, config: config)
        }, name: "AzureOpenAISummary", timeout: 15.0)
    }
    
    private func performAzureOpenAIRequest(
        _ text: String,
        language: String,
        config: AzureOpenAIConfig
    ) async throws -> SummaryResult {
        
        // メモリ使用量をチェック
        let memoryUsage = AsyncDebugHelpers.shared.getMemoryUsage()
        logger.info("📊 Memory usage before API call: \(String(format: "%.1f", memoryUsage)) MB")
        
        if memoryUsage > 150 {
            logger.warning("⚠️ High memory usage detected: \(String(format: "%.1f", memoryUsage)) MB")
        }
        
        let prompt = buildSummaryPrompt(text, language: language)
        let systemPrompt = getSystemPrompt(for: language)
        
        let url = config.endpoint.appendingPathComponent("/openai/deployments/\(config.deploymentName)/chat/completions")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "api-version", value: "2023-05-15")]
        
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "api-key")
        request.timeoutInterval = 10.0 // 10秒タイムアウト
        
        let requestBody: [String: Any] = [
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": prompt]
            ],
            "max_tokens": 300, // トークン数を制限してレスポンス時間を短縮
            "temperature": 0.3,
            "top_p": 0.9
        ]
        
        let requestData = try JSONSerialization.data(withJSONObject: requestBody)
        request.httpBody = requestData
        
        logger.info("🌐 Sending Azure OpenAI request - Payload size: \(requestData.count) bytes")
        
        // キャンセレーション対応のAPI呼び出し
        return try await withThrowingTaskGroup(of: SummaryResult.self) { group in
            // メインAPIリクエスト
            group.addTask {
                let (data, response) = try await self.urlSession.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw AppError.networkUnavailable
                }
                
                if httpResponse.statusCode != 200 {
                    let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                    self.logger.error("❌ Azure OpenAI API error (\(httpResponse.statusCode)): \(errorMessage)")
                    throw AppError.networkUnavailable
                }
                
                self.logger.info("📥 Received Azure OpenAI response - Size: \(data.count) bytes")
                return try self.parseAzureOpenAIResponse(data)
            }
            
            // タイムアウト監視（API呼び出し専用の短いタイムアウト）
            group.addTask {
                try await Task.sleep(nanoseconds: 8_000_000_000) // 8秒
                self.logger.warning("⏰ Azure OpenAI API call timed out")
                throw AppError.networkUnavailable
            }
            
            // 最初に完了した結果を返す
            guard let result = try await group.next() else {
                throw AppError.networkUnavailable
            }
            
            group.cancelAll()
            return result
        }
    }
    
    private func parseAzureOpenAIResponse(_ data: Data) throws -> SummaryResult {
        
        guard let jsonResponse = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.error("❌ Invalid JSON response from Azure OpenAI")
            throw AppError.invalidConfiguration
        }
        
        guard let choices = jsonResponse["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            
            logger.error("❌ Unexpected response format from Azure OpenAI")
            if let errorInfo = jsonResponse["error"] as? [String: Any] {
                logger.error("API Error: \(errorInfo)")
            }
            throw AppError.invalidConfiguration
        }
        
        let cleanContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if cleanContent.isEmpty {
            logger.warning("⚠️ Azure OpenAI returned empty content")
            throw AppError.invalidConfiguration
        }
        
        logger.info("✅ Successfully parsed Azure OpenAI response - Content length: \(cleanContent.count)")
        return SummaryResult(text: cleanContent, confidence: 0.9)
    }

    /// ルールベース要約を生成
    private func generateRuleBasedSummary(_ text: String) -> SummaryResult {
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: "。．.！？!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        guard !sentences.isEmpty else {
            return SummaryResult(text: "要約を生成できませんでした。", confidence: 0.1)
        }
        
        var selectedSentences: [String] = []
        if let first = sentences.first { selectedSentences.append(first) }
        if sentences.count > 2 { selectedSentences.append(sentences[sentences.count / 2]) }
        if let last = sentences.last, sentences.count > 1 { selectedSentences.append(last) }
        
        return SummaryResult(text: selectedSentences.joined(separator: " "), confidence: 0.6)
    }
    
    /// 要約プロンプトを構築
    private func buildSummaryPrompt(_ text: String, language: String) -> String {
        // カスタムプロンプトを使用する場合
        if useCustomPrompt && !customSummaryPrompt.isEmpty {
            return customSummaryPrompt.replacingOccurrences(of: "{text}", with: text)
        }
        
        // デフォルトプロンプトを使用
        let isJapanese = language.starts(with: "ja")
        let maxLength = self.maxSummaryLength
        
        if isJapanese {
            return "以下の通話内容を\(maxLength)文字以内で簡潔に要約してください。重要なポイント、決定事項、次のアクションを含めてください。\n\n通話内容:\n\(text)\n\n要約:"
        } else {
            return "Please provide a concise summary (within \(maxLength) words) of the following phone conversation. Include key points, decisions made, and next actions.\n\nConversation:\n\(text)\n\nSummary:"
        }
    }
    
    /// システムプロンプトを取得
    private func getSystemPrompt(for language: String) -> String {
        // カスタムプロンプトを使用する場合
        if useCustomPrompt && !customSystemPrompt.isEmpty {
            return customSystemPrompt
        }
        
        // デフォルトプロンプトを使用
        let isJapanese = language.starts(with: "ja")
        if isJapanese {
            return "あなたは電話会議の要約を専門とするアシスタントです。簡潔で分かりやすい要約を作成してください。"
        } else {
            return "You are an assistant specialized in summarizing phone conversations. Create concise and clear summaries."
        }
    }
    
    /// キーポイントを抽出
    private func extractKeyPoints(from text: String) async -> [String] {
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: "。．.！？!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 10 }
        
        let importantKeywords = ["決定", "合意", "確認", "重要", "問題", "課題", "対応", "方針", "計画", "予定", "decide", "agree", "important", "issue", "problem", "plan", "schedule"]
        
        var keyPoints: [String] = []
        for sentence in sentences {
            for keyword in importantKeywords where sentence.contains(keyword) {
                keyPoints.append(sentence)
                break
            }
        }
        return Array(keyPoints.prefix(5))
    }
    
    /// TF-IDFベースでキーワードを抽出
    private func extractKeywordsWithTFIDF(_ text: String) -> [String] {
        // 空文字列や無効な入力をチェック
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.warning("extractKeywordsWithTFIDF: Empty text provided")
            return []
        }
        
        // スレッドセーフティのため、メソッド内で新しいtokenizerインスタンスを作成
        let localTokenizer = NLTokenizer(unit: .word)
        localTokenizer.string = text
        
        let tokens = localTokenizer.tokens(for: text.startIndex..<text.endIndex)
        var wordCount: [String: Int] = [:]
        
        for token in tokens {
            let word = String(text[token]).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if word.count > 2 && !isStopWord(word) && !word.isEmpty {
                wordCount[word, default: 0] += 1
            }
        }
        
        return wordCount.sorted { $0.value > $1.value }.prefix(10).map { $0.key }
    }
    
    /// 固有名詞を抽出
    private func extractNamedEntities(_ text: String) -> [String] {
        // 空文字列や無効な入力をチェック
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.warning("extractNamedEntities: Empty text provided")
            return []
        }
        
        // スレッドセーフティのため、メソッド内で新しいtaggerインスタンスを作成
        let localTagger = NLTagger(tagSchemes: [.nameType])
        localTagger.string = text
        
        var entities: [String] = []
        
        localTagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType) { tag, range in
            if let tag = tag, tag == .personalName || tag == .organizationName || tag == .placeName {
                let entity = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !entity.isEmpty {
                    entities.append(entity)
                }
            }
            return true
        }
        
        return Array(Set(entities))
    }
    
    /// 重要語句を抽出
    private func extractImportantPhrases(_ text: String) -> [String] {
        // 空文字列や無効な入力をチェック
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.warning("extractImportantPhrases: Empty text provided")
            return []
        }
        
        // スレッドセーフティのため、メソッド内で新しいtaggerインスタンスを作成
        let localTagger = NLTagger(tagSchemes: [.lexicalClass])
        localTagger.string = text
        
        var phrases: [String] = []
        
        localTagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass) { tag, range in
            if tag == .noun {
                let word = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if word.count > 2 && !isStopWord(word) && !word.isEmpty {
                    phrases.append(word)
                }
            }
            return true
        }
        
        return Array(Set(phrases))
    }
    
    /// ストップワードかどうかを判定
    private func isStopWord(_ word: String) -> Bool {
        let stopWords: Set<String> = ["の", "は", "が", "を", "に", "で", "と", "から", "まで", "より", "です", "である", "します", "した", "the", "a", "an", "and", "or", "but", "in", "on", "at", "to", "for", "of", "with", "by", "is", "are", "was", "were"]
        return stopWords.contains(word.lowercased())
    }
    
    /// 電話番号を抽出
    private func extractPhoneNumber(from text: String) -> String? {
        let phonePattern = #"(\+?\d{1,4}[-.\s]?)?(\(?\d{1,4}\)?[-.\s]?)?[\d\-.\s]{7,10}"#
        if let range = text.range(of: phonePattern, options: .regularExpression) {
            return String(text[range])
        }
        return nil
    }
    
    /// テキストの推定発話時間を計算
    private func estimateTextDuration(_ text: String) -> TimeInterval {
        let language = detectLanguage(in: text)
        if language.starts(with: "ja") {
            return Double(text.count) / 400.0 * 60.0
        } else {
            // スレッドセーフティのため、メソッド内で新しいtokenizer インスタンスを作成
            let localTokenizer = NLTokenizer(unit: .word)
            localTokenizer.string = text
            let tokens = localTokenizer.tokens(for: text.startIndex..<text.endIndex)
            return Double(tokens.count) / 150.0 * 60.0
        }
    }
}

// MARK: - Supporting Types

/// 要約結果
private struct SummaryResult {
    let text: String
    let confidence: Double
}

// MARK: - Debug Support

#if DEBUG
extension TextProcessingService {
    
    /// デバッグ情報を出力
    func printDebugInfo(for text: String) {
        logger.debug("""
            TextProcessingService Debug Info:
            - Text Length: \(text.count)
            - Detected Language: \(self.detectLanguage(in: text))
            - Quality Score: \(self.evaluateTextQuality(text))
            - Azure OpenAI Configured: \(!self.openAIConfig.apiKey.isEmpty)
            """)
    }
}
#endif
