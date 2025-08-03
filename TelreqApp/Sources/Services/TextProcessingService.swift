import Foundation
import NaturalLanguage
import os.log

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
    private let tagger = NLTagger(tagSchemes: [.nameType, .lexicalClass])
    
    /// 要約生成のための外部API設定
    private var openAIAPIKey: String?
    private var azureOpenAIConfig: AzureOpenAIConfig?
    
    /// URLSession for API calls
    private let urlSession: URLSession
    
    /// 要約品質の閾値
    private let summaryQualityThreshold: Double = 0.7
    
    /// キーワード抽出の最大数
    private let maxKeywords = 20
    
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
    
    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30.0
        config.timeoutIntervalForResource = 60.0
        urlSession = URLSession(configuration: config)
        
        loadAPIConfigurations()
        logger.info("TextProcessingService initialized")
    }
    
    // MARK: - TextProcessingServiceProtocol Implementation
    
    /// テキストを要約
    /// - Parameter text: 要約するテキスト
    /// - Returns: 生成された要約
    func summarizeText(_ text: String) async throws -> CallSummary {
        logger.info("Starting text summarization for text length: \(text.count)")
        
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(
                domain: "TextProcessingService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Empty text provided for summarization"]
            )
        }
        
        do {
            // 言語を検出
            let language = detectLanguage(in: text)
            logger.info("Detected language: \(language)")
            
            // テキスト品質を評価
            let quality = evaluateTextQuality(text)
            logger.info("Text quality: \(quality)")
            
            // 複数の方法で要約を生成し、最適なものを選択
            var summaryText: String
            var confidence: Double
            
            if quality > summaryQualityThreshold {
                // 高品質テキストの場合、AI要約を使用
                if let aiSummary = try await generateAISummary(text, language: language) {
                    summaryText = aiSummary.text
                    confidence = aiSummary.confidence
                } else {
                    // AI要約が失敗した場合、ルールベース要約を使用
                    let ruleSummary = generateRuleBasedSummary(text)
                    summaryText = ruleSummary.text
                    confidence = ruleSummary.confidence
                }
            } else {
                // 低品質テキストの場合、ルールベース要約のみ
                let ruleSummary = generateRuleBasedSummary(text)
                summaryText = ruleSummary.text
                confidence = ruleSummary.confidence
            }
            
            // 並行してその他の情報を抽出
            async let keyPoints = extractKeyPoints(from: text)
            async let keywords = extractKeywords(from: text)
            async let actionItems = extractActionItems(from: text)
            async let participants = identifySpeakers(in: text)
            
            let extractedKeyPoints = try await keyPoints
            let extractedKeywords = try await keywords
            let extractedActionItems = try await actionItems
            let extractedParticipants = try await participants
            
            let summary = CallSummary(
                keyPoints: extractedKeyPoints,
                summary: summaryText,
                duration: estimateTextDuration(text),
                participants: extractedParticipants,
                actionItems: extractedActionItems,
                tags: extractedKeywords,
                confidence: confidence
            )
            
            logger.info("Text summarization completed with confidence: \(confidence)")
            return summary
            
        } catch {
            logger.error("Failed to summarize text: \(error.localizedDescription)")
            throw error
        }
    }
    
    /// 通話データを構造化
    /// - Parameters:
    ///   - text: 転写テキスト
    ///   - metadata: 通話メタデータ
    /// - Returns: 構造化された通話データ
    func structureCallData(_ text: String, metadata: CallMetadata) async throws -> StructuredCallData {
        logger.info("Structuring call data")
        
        do {
            // テキストを要約
            let summary = try await summarizeText(text)
            
            // 音声ファイルURLを生成（実際の実装では適切なURLを設定）
            let audioFileUrl = "audio://\(UUID().uuidString).m4a"
            
            let structuredData = StructuredCallData(
                timestamp: metadata.startTime,
                duration: metadata.endTime.timeIntervalSince(metadata.startTime),
                participantNumber: extractPhoneNumber(from: text) ?? "Unknown",
                audioFileUrl: audioFileUrl,
                transcriptionText: text,
                summary: summary,
                metadata: metadata
            )
            
            logger.info("Call data structured successfully")
            return structuredData
            
        } catch {
            logger.error("Failed to structure call data: \(error.localizedDescription)")
            throw error
        }
    }
    
    /// キーワードを抽出
    /// - Parameter text: 解析するテキスト
    /// - Returns: 抽出されたキーワード配列
    func extractKeywords(from text: String) async throws -> [String] {
        logger.info("Extracting keywords from text")
        
        return await withTaskGroup(of: [String].self) { group in
            // TF-IDF ベースの抽出
            group.addTask {
                return self.extractKeywordsWithTFIDF(text)
            }
            
            // 固有名詞の抽出
            group.addTask {
                return self.extractNamedEntities(text)
            }
            
            // 重要語句の抽出
            group.addTask {
                return self.extractImportantPhrases(text)
            }
            
            var allKeywords: Set<String> = []
            
            for await keywords in group {
                allKeywords.formUnion(keywords)
            }
            
            // 頻度と重要度でソートして上位を返す
            return Array(allKeywords)
                .sorted { keyword1, keyword2 in
                    let count1 = text.components(separatedBy: keyword1).count - 1
                    let count2 = text.components(separatedBy: keyword2).count - 1
                    return count1 > count2
                }
                .prefix(maxKeywords)
                .map { $0 }
        }
    }
    
    /// アクションアイテムを抽出
    /// - Parameter text: 解析するテキスト
    /// - Returns: 抽出されたアクションアイテム配列
    func extractActionItems(from text: String) async throws -> [String] {
        logger.info("Extracting action items from text")
        
        var actionItems: [String] = []
        
        for pattern in actionPatterns {
            do {
                let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
                let matches = regex.matches(in: text, options: [], range: NSRange(text.startIndex..., in: text))
                
                for match in matches {
                    if match.numberOfRanges > 1 {
                        let range = match.range(at: 1)
                        if let swiftRange = Range(range, in: text) {
                            let actionItem = String(text[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                            if !actionItem.isEmpty && actionItem.count > 3 {
                                actionItems.append(actionItem)
                            }
                        }
                    }
                }
            } catch {
                logger.warning("Failed to process action pattern: \(pattern)")
            }
        }
        
        // 重複を除去し、長さでソート
        let uniqueActions = Array(Set(actionItems))
            .sorted { $0.count > $1.count }
            .prefix(10)
        
        logger.info("Extracted \(uniqueActions.count) action items")
        return Array(uniqueActions)
    }
    
    /// 発言者を識別
    /// - Parameter text: 解析するテキスト
    /// - Returns: 識別された発言者配列
    func identifySpeakers(in text: String) async throws -> [String] {
        logger.info("Identifying speakers in text")
        
        var speakers: Set<String> = []
        let lines = text.components(separatedBy: .newlines)
        
        for line in lines {
            for pattern in speakerPatterns {
                do {
                    let regex = try NSRegularExpression(pattern: pattern, options: [])
                    let matches = regex.matches(in: line, options: [], range: NSRange(line.startIndex..., in: line))
                    
                    for match in matches {
                        if match.numberOfRanges > 1 {
                            let range = match.range(at: 1)
                            if let swiftRange = Range(range, in: line) {
                                let speaker = String(line[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                                if !speaker.isEmpty {
                                    speakers.insert(speaker)
                                }
                            }
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
    /// - Parameter text: 解析するテキスト
    /// - Returns: 検出された言語コード
    func detectLanguage(in text: String) -> String {
        languageRecognizer.processString(text)
        
        let dominantLanguage = languageRecognizer.dominantLanguage
        let confidence = languageRecognizer.languageHypotheses(withMaximum: 1).first?.value ?? 0.0
        
        if confidence > 0.5, let language = dominantLanguage {
            logger.info("Language detected: \(language.rawValue) with confidence: \(confidence)")
            return language.rawValue
        } else {
            logger.info("Language detection failed, defaulting to Japanese")
            return "ja"
        }
    }
    
    /// テキストの品質を評価
    /// - Parameter text: 評価するテキスト
    /// - Returns: 品質スコア（0.0-1.0）
    func evaluateTextQuality(_ text: String) -> Double {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !cleanText.isEmpty else { return 0.0 }
        
        var score: Double = 0.0
        
        // 長さのスコア（適切な長さであるかどうか）
        let lengthScore = min(Double(cleanText.count) / 1000.0, 1.0)
        score += lengthScore * 0.2
        
        // 文の完整性スコア（句読点があるかどうか）
        let sentenceEndCount = cleanText.components(separatedBy: CharacterSet(charactersIn: "。．.！？!?")).count - 1
        let sentenceScore = min(Double(sentenceEndCount) / 10.0, 1.0)
        score += sentenceScore * 0.3
        
        // 語彙の多様性スコア
        tokenizer.string = cleanText
        let tokens = tokenizer.tokens(for: cleanText.startIndex..<cleanText.endIndex)
        let uniqueTokens = Set(tokens.map { String(cleanText[$0]) })
        let vocabularyScore = Double(uniqueTokens.count) / Double(max(tokens.count, 1))
        score += vocabularyScore * 0.3
        
        // ノイズの少なさスコア（「あー」「えーと」などの除去）
        let fillerWords = ["あー", "えー", "えーと", "そのー", "うーん", "uh", "um", "er"]
        var fillerCount = 0
        for filler in fillerWords {
            fillerCount += cleanText.components(separatedBy: filler).count - 1
        }
        let noiseScore = max(0.0, 1.0 - Double(fillerCount) / 20.0)
        score += noiseScore * 0.2
        
        let finalScore = min(max(score, 0.0), 1.0)
        logger.info("Text quality evaluated: \(finalScore)")
        
        return finalScore
    }
    
    // MARK: - Private Methods
    
    /// API設定を読み込み
    private func loadAPIConfigurations() {
        // OpenAI API Key
        if let path = Bundle.main.path(forResource: "APIKeys", ofType: "plist"),
           let plist = NSDictionary(contentsOfFile: path),
           let apiKey = plist["OPENAI_API_KEY"] as? String {
            openAIAPIKey = apiKey
        }
        
        // Azure OpenAI設定
        if let path = Bundle.main.path(forResource: "AzureOpenAI", ofType: "plist"),
           let plist = NSDictionary(contentsOfFile: path) {
            azureOpenAIConfig = AzureOpenAIConfig(
                endpoint: plist["ENDPOINT"] as? String ?? "",
                apiKey: plist["API_KEY"] as? String ?? "",
                deploymentName: plist["DEPLOYMENT_NAME"] as? String ?? "gpt-35-turbo"
            )
        }
        
        logger.info("API configurations loaded")
    }
    
    /// AI要約を生成
    private func generateAISummary(_ text: String, language: String) async throws -> SummaryResult? {
        // Azure OpenAIを優先的に使用
        if let config = azureOpenAIConfig, !config.apiKey.isEmpty {
            return try await generateAzureOpenAISummary(text, language: language, config: config)
        }
        
        // フォールバックとしてOpenAI APIを使用
        if let apiKey = openAIAPIKey, !apiKey.isEmpty {
            return try await generateOpenAISummary(text, language: language, apiKey: apiKey)
        }
        
        logger.warning("No AI summary service available")
        return nil
    }
    
    /// Azure OpenAIで要約を生成
    private func generateAzureOpenAISummary(
        _ text: String,
        language: String,
        config: AzureOpenAIConfig
    ) async throws -> SummaryResult {
        
        let prompt = buildSummaryPrompt(text, language: language)
        
        let requestBody: [String: Any] = [
            "messages": [
                ["role": "system", "content": getSystemPrompt(for: language)],
                ["role": "user", "content": prompt]
            ],
            "max_tokens": 500,
            "temperature": 0.3,
            "top_p": 0.9
        ]
        
        guard let url = URL(string: "\(config.endpoint)/openai/deployments/\(config.deploymentName)/chat/completions?api-version=2023-05-15") else {
            throw NSError(domain: "TextProcessingService", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid Azure OpenAI URL"])
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        
        let (data, response) = try await urlSession.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw NSError(domain: "TextProcessingService", code: -3, userInfo: [NSLocalizedDescriptionKey: "Azure OpenAI API request failed"])
        }
        
        let jsonResponse = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        
        guard let choices = jsonResponse?["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw NSError(domain: "TextProcessingService", code: -4, userInfo: [NSLocalizedDescriptionKey: "Invalid Azure OpenAI response"])
        }
        
        return SummaryResult(text: content.trimmingCharacters(in: .whitespacesAndNewlines), confidence: 0.9)
    }
    
    /// OpenAIで要約を生成
    private func generateOpenAISummary(
        _ text: String,
        language: String,
        apiKey: String
    ) async throws -> SummaryResult {
        
        let prompt = buildSummaryPrompt(text, language: language)
        
        let requestBody: [String: Any] = [
            "model": "gpt-3.5-turbo",
            "messages": [
                ["role": "system", "content": getSystemPrompt(for: language)],
                ["role": "user", "content": prompt]
            ],
            "max_tokens": 500,
            "temperature": 0.3
        ]
        
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw NSError(domain: "TextProcessingService", code: -5, userInfo: [NSLocalizedDescriptionKey: "Invalid OpenAI URL"])
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        
        let (data, response) = try await urlSession.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw NSError(domain: "TextProcessingService", code: -6, userInfo: [NSLocalizedDescriptionKey: "OpenAI API request failed"])
        }
        
        let jsonResponse = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        
        guard let choices = jsonResponse?["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw NSError(domain: "TextProcessingService", code: -7, userInfo: [NSLocalizedDescriptionKey: "Invalid OpenAI response"])
        }
        
        return SummaryResult(text: content.trimmingCharacters(in: .whitespacesAndNewlines), confidence: 0.9)
    }
    
    /// ルールベース要約を生成
    private func generateRuleBasedSummary(_ text: String) -> SummaryResult {
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: "。．.！？!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        guard !sentences.isEmpty else {
            return SummaryResult(text: "要約を生成できませんでした。", confidence: 0.1)
        }
        
        // 最初と最後の文、および中間の重要そうな文を選択
        var selectedSentences: [String] = []
        
        if sentences.count > 0 {
            selectedSentences.append(sentences[0])
        }
        
        if sentences.count > 2 {
            let middleIndex = sentences.count / 2
            selectedSentences.append(sentences[middleIndex])
        }
        
        if sentences.count > 1 {
            selectedSentences.append(sentences[sentences.count - 1])
        }
        
        let summary = selectedSentences.joined(separator: " ")
        return SummaryResult(text: summary, confidence: 0.6)
    }
    
    /// 要約プロンプトを構築
    private func buildSummaryPrompt(_ text: String, language: String) -> String {
        let isJapanese = language.starts(with: "ja")
        
        if isJapanese {
            return """
            以下の通話内容を簡潔に要約してください。重要なポイント、決定事項、次のアクションを含めてください。

            通話内容:
            \(text)
            
            要約（200文字以内）:
            """
        } else {
            return """
            Please provide a concise summary of the following phone conversation. Include key points, decisions made, and next actions.

            Conversation:
            \(text)
            
            Summary (within 200 words):
            """
        }
    }
    
    /// システムプロンプトを取得
    private func getSystemPrompt(for language: String) -> String {
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
        
        // 重要そうなキーワードを含む文を抽出
        let importantKeywords = ["決定", "合意", "確認", "重要", "問題", "課題", "対応", "方針", "計画", "予定",
                                "decide", "agree", "important", "issue", "problem", "plan", "schedule"]
        
        var keyPoints: [String] = []
        
        for sentence in sentences {
            for keyword in importantKeywords {
                if sentence.contains(keyword) {
                    keyPoints.append(sentence)
                    break
                }
            }
        }
        
        return Array(keyPoints.prefix(5))
    }
    
    /// TF-IDFベースでキーワードを抽出
    private func extractKeywordsWithTFIDF(_ text: String) -> [String] {
        tokenizer.string = text
        let tokens = tokenizer.tokens(for: text.startIndex..<text.endIndex)
        
        var wordCount: [String: Int] = [:]
        
        for token in tokens {
            let word = String(text[token]).lowercased()
            if word.count > 2 && !isStopWord(word) {
                wordCount[word, default: 0] += 1
            }
        }
        
        // 頻度の高い順にソート
        return wordCount.sorted { $0.value > $1.value }
            .prefix(10)
            .map { $0.key }
    }
    
    /// 固有名詞を抽出
    private func extractNamedEntities(_ text: String) -> [String] {
        tagger.string = text
        
        var entities: [String] = []
        
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType) { tag, range in
            if let tag = tag {
                let entity = String(text[range])
                if tag == .personalName || tag == .organizationName || tag == .placeName {
                    entities.append(entity)
                }
            }
            return true
        }
        
        return Array(Set(entities))
    }
    
    /// 重要語句を抽出
    private func extractImportantPhrases(_ text: String) -> [String] {
        // 名詞句を抽出
        tagger.string = text
        
        var phrases: [String] = []
        
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass) { tag, range in
            if tag == .noun {
                let word = String(text[range])
                if word.count > 2 && !isStopWord(word) {
                    phrases.append(word)
                }
            }
            return true
        }
        
        return Array(Set(phrases))
    }
    
    /// ストップワードかどうかを判定
    private func isStopWord(_ word: String) -> Bool {
        let stopWords = ["の", "は", "が", "を", "に", "で", "と", "から", "まで", "より", "です", "である", "します", "した",
                        "the", "a", "an", "and", "or", "but", "in", "on", "at", "to", "for", "of", "with", "by", "is", "are", "was", "were"]
        return stopWords.contains(word.lowercased())
    }
    
    /// 電話番号を抽出
    private func extractPhoneNumber(from text: String) -> String? {
        do {
            let phonePattern = #"(\+?\d{1,4}[-.\s]?)?(\(?\d{1,4}\)?[-.\s]?)?[\d\-.\s]{7,10}"#
            let regex = try NSRegularExpression(pattern: phonePattern, options: [])
            let matches = regex.matches(in: text, options: [], range: NSRange(text.startIndex..., in: text))
            
            if let match = matches.first,
               let range = Range(match.range, in: text) {
                return String(text[range])
            }
        } catch {
            logger.warning("Failed to extract phone number: \(error.localizedDescription)")
        }
        
        return nil
    }
    
    /// テキストの推定発話時間を計算
    private func estimateTextDuration(_ text: String) -> TimeInterval {
        // 日本語：約400文字/分、英語：約150単語/分として計算
        let language = detectLanguage(in: text)
        
        if language.starts(with: "ja") {
            let charCount = text.count
            return Double(charCount) / 400.0 * 60.0
        } else {
            tokenizer.string = text
            let tokens = tokenizer.tokens(for: text.startIndex..<text.endIndex)
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

/// Azure OpenAI設定
private struct AzureOpenAIConfig {
    let endpoint: String
    let apiKey: String
    let deploymentName: String
}

// MARK: - Debug Support

#if DEBUG
extension TextProcessingService {
    
    /// デバッグ情報を出力
    func printDebugInfo(for text: String) {
        logger.debug("""
            TextProcessingService Debug Info:
            - Text Length: \(text.count)
            - Detected Language: \(detectLanguage(in: text))
            - Quality Score: \(evaluateTextQuality(text))
            - OpenAI API Available: \(openAIAPIKey != nil)
            - Azure OpenAI Available: \(azureOpenAIConfig != nil)
            """)
    }
}