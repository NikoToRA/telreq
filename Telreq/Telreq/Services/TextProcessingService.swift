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
    
    /// Azure OpenAI Serviceの設定
    private let openAIConfig: AzureOpenAIConfig
    
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
        logger.info("Starting text summarization for text length: \(text.count)")
        
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError.invalidConfiguration // or a more specific error
        }
        
        let language = detectLanguage(in: text)
        let quality = evaluateTextQuality(text)
        
        logger.info("Detected language: \(language), Quality: \(quality)")
        
        var summaryText: String
        var confidence: Double
        
        if quality > summaryQualityThreshold {
            let aiSummary = try await generateAzureOpenAISummary(text, language: language, config: openAIConfig)
            summaryText = aiSummary.text
            confidence = aiSummary.confidence
        } else {
            let ruleSummary = generateRuleBasedSummary(text)
            summaryText = ruleSummary.text
            confidence = ruleSummary.confidence
        }
        
        async let keyPointsTask = extractKeyPoints(from: text)
        async let keywordsTask = self.extractKeywords(from: text)
        async let actionItemsTask = self.extractActionItems(from: text)
        async let participantsTask = self.identifySpeakers(in: text)
        
        let summary = CallSummary(
            keyPoints: await keyPointsTask,
            summary: summaryText,
            duration: estimateTextDuration(text),
            participants: try await participantsTask,
            actionItems: try await actionItemsTask,
            tags: try await keywordsTask,
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
        
        return await withTaskGroup(of: [String].self) { group in
            group.addTask { self.extractKeywordsWithTFIDF(text) }
            group.addTask { self.extractNamedEntities(text) }
            group.addTask { self.extractImportantPhrases(text) }
            
            var allKeywords: Set<String> = []
            for await keywords in group {
                allKeywords.formUnion(keywords)
            }
            
            return Array(allKeywords)
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
        
        tokenizer.string = cleanText
        let tokens = tokenizer.tokens(for: cleanText.startIndex..<cleanText.endIndex)
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
        
        let prompt = buildSummaryPrompt(text, language: language)
        let systemPrompt = getSystemPrompt(for: language)
        
        var url = config.endpoint.appendingPathComponent("/openai/deployments/\(config.deploymentName)/chat/completions")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "api-version", value: "2023-05-15")]
        
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "api-key")
        
        let requestBody: [String: Any] = [
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": prompt]
            ],
            "max_tokens": 500,
            "temperature": 0.3,
            "top_p": 0.9
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        
        let (data, response) = try await urlSession.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw AppError.networkUnavailable
        }
        
        if let jsonResponse = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let choices = jsonResponse["choices"] as? [[String: Any]],
           let firstChoice = choices.first,
           let message = firstChoice["message"] as? [String: Any],
           let content = message["content"] as? String {
            return SummaryResult(text: content.trimmingCharacters(in: .whitespacesAndNewlines), confidence: 0.9)
        } else {
            throw AppError.invalidConfiguration
        }
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
        let isJapanese = language.starts(with: "ja")
        if isJapanese {
            return "以下の通話内容を200文字以内で簡潔に要約してください。重要なポイント、決定事項、次のアクションを含めてください。\n\n通話内容:\n\(text)\n\n要約:"
        } else {
            return "Please provide a concise summary (within 200 words) of the following phone conversation. Include key points, decisions made, and next actions.\n\nConversation:\n\(text)\n\nSummary:"
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
        tokenizer.string = text
        let tokens = tokenizer.tokens(for: text.startIndex..<text.endIndex)
        var wordCount: [String: Int] = [:]
        
        for token in tokens {
            let word = String(text[token]).lowercased()
            if word.count > 2 && !isStopWord(word) {
                wordCount[word, default: 0] += 1
            }
        }
        
        return wordCount.sorted { $0.value > $1.value }.prefix(10).map { $0.key }
    }
    
    /// 固有名詞を抽出
    private func extractNamedEntities(_ text: String) -> [String] {
        tagger.string = text
        var entities: [String] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType) { tag, range in
            if let tag = tag, tag == .personalName || tag == .organizationName || tag == .placeName {
                entities.append(String(text[range]))
            }
            return true
        }
        return Array(Set(entities))
    }
    
    /// 重要語句を抽出
    private func extractImportantPhrases(_ text: String) -> [String] {
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
