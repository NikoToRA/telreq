import Foundation
import Speech
import AVFoundation
import os.log

/// 音声認識サービス
/// 
/// iOS Speech Frameworkをプライマリとし、Google Speech-to-Text APIをフォールバックとして
/// リアルタイム音声認識とバッチ処理、言語自動検出を提供します。
final class SpeechRecognitionService: NSObject, SpeechRecognitionServiceProtocol {
    
    // MARK: - Properties
    
    /// デリゲート
    weak var delegate: SpeechRecognitionDelegate?
    
    /// 現在の認識方法
    private(set) var currentMethod: TranscriptionMethod = .iosSpeech
    
    /// 認識精度（0.0-1.0）
    private(set) var confidence: Double = 0.0
    
    /// サポートする言語一覧
    var supportedLanguages: [String] {
        return SFSpeechRecognizer.supportedLocales().map { $0.identifier }
    }
    
    /// iOS Speech Recognition関連
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    
    /// 音声認識設定
    private var preferredLanguage: String = "ja-JP"
    private var fallbackLanguages: [String] = ["en-US", "en-GB"]
    
    /// Google Speech-to-Text関連
    private var googleAPIKey: String?
    private var urlSession: URLSession
    
    /// 認識タイムアウト設定
    private let recognitionTimeout: TimeInterval = 30.0
    private var timeoutTimer: Timer?
    
    /// 音声バッファ管理
    private var audioBufferQueue: [AVAudioPCMBuffer] = []
    private let maxBufferCount = 10
    
    /// ログ出力用
    private let logger = Logger(subsystem: "com.telreq.app", category: "SpeechRecognition")
    
    /// リアルタイム認識用の累積テキスト
    private var accumulatedText: String = ""
    
    /// 認識処理中フラグ
    private var isRecognizing: Bool = false
    
    // MARK: - Initialization
    
    override init() {
        // URLSession設定
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30.0
        config.timeoutIntervalForResource = 60.0
        urlSession = URLSession(configuration: config)
        
        super.init()
        
        setupSpeechRecognizer()
        loadGoogleAPIKey()
        
        logger.info("SpeechRecognitionService initialized")
    }
    
    deinit {
        stopRecognition()
        logger.info("SpeechRecognitionService deinitialized")
    }
    
    // MARK: - SpeechRecognitionServiceProtocol Implementation
    
    /// 音声認識を開始（バッチ処理）
    /// - Parameter audioBuffer: 音声バッファ
    /// - Returns: 認識結果テキスト
    func startRecognition(audioBuffer: AVAudioPCMBuffer) async throws -> String {
        logger.info("Starting batch speech recognition")
        
        guard !isRecognizing else {
            logger.warning("Recognition already in progress")
            throw NSError(
                domain: "SpeechRecognitionService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Recognition already in progress"]
            )
        }
        
        isRecognizing = true
        defer { isRecognizing = false }
        
        do {
            // iOS Speech Frameworkで認識を試行
            let result = try await recognizeWithiOSSpeech(audioBuffer: audioBuffer)
            currentMethod = .iosSpeech
            confidence = result.confidence
            
            logger.info("iOS Speech recognition completed with confidence: \(confidence)")
            return result.text
            
        } catch {
            logger.warning("iOS Speech recognition failed: \(error.localizedDescription)")
            
            // Google Speech-to-Textにフォールバック
            if let googleResult = try await recognizeWithGoogleSpeech(audioBuffer: audioBuffer) {
                currentMethod = .googleSpeech
                confidence = googleResult.confidence
                
                logger.info("Google Speech recognition completed with confidence: \(confidence)")
                return googleResult.text
            } else {
                logger.error("Both iOS and Google speech recognition failed")
                throw AppError.speechRecognitionFailed(underlying: error)
            }
        }
    }
    
    /// 音声認識を停止
    func stopRecognition() {
        logger.info("Stopping speech recognition")
        
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        
        isRecognizing = false
        accumulatedText = ""
        audioBufferQueue.removeAll()
        
        logger.info("Speech recognition stopped")
    }
    
    /// バックアップサービスに切り替え
    func switchToBackupService() async throws {
        logger.info("Switching to backup service")
        
        stopRecognition()
        
        // 現在のサービスに応じて切り替え
        switch currentMethod {
        case .iosSpeech:
            currentMethod = .googleSpeech
            logger.info("Switched to Google Speech-to-Text")
            
        case .googleSpeech:
            currentMethod = .iosSpeech
            logger.info("Switched to iOS Speech Framework")
            
        case .hybridProcessing:
            // ハイブリッド処理の場合は最も信頼性の高い方法を選択
            currentMethod = .iosSpeech
            logger.info("Switched to iOS Speech Framework from hybrid")
        }
    }
    
    /// リアルタイム音声認識を開始
    func startRealtimeRecognition() async throws {
        logger.info("Starting realtime speech recognition")
        
        // 権限チェック
        guard await checkSpeechRecognitionPermission() else {
            logger.error("Speech recognition permission denied")
            throw AppError.speechRecognitionUnavailable
        }
        
        // 既存の認識タスクを停止
        stopRecognition()
        
        do {
            // iOS Speech Recognizerを設定
            guard let recognizer = speechRecognizer, recognizer.isAvailable else {
                logger.error("Speech recognizer not available")
                throw AppError.speechRecognitionUnavailable
            }
            
            // 認識リクエストを作成
            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let request = recognitionRequest else {
                throw NSError(
                    domain: "SpeechRecognitionService",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to create recognition request"]
                )
            }
            
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = false
            
            // 認識タスクを開始
            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                self?.handleRealtimeRecognitionResult(result: result, error: error)
            }
            
            // タイムアウトタイマーを設定
            startTimeoutTimer()
            
            isRecognizing = true
            logger.info("Realtime speech recognition started")
            
        } catch {
            logger.error("Failed to start realtime recognition: \(error.localizedDescription)")
            throw error
        }
    }
    
    // MARK: - Public Methods
    
    /// 音声バッファをリアルタイム認識に追加
    /// - Parameter audioBuffer: 音声バッファ
    func addAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard isRecognizing, let request = recognitionRequest else { return }
        
        // バッファをキューに追加
        audioBufferQueue.append(audioBuffer)
        
        // キューサイズ制限
        if audioBufferQueue.count > maxBufferCount {
            audioBufferQueue.removeFirst()
        }
        
        // 認識リクエストにバッファを送信
        request.append(audioBuffer)
    }
    
    /// 言語を設定
    /// - Parameter language: 言語コード（例: "ja-JP", "en-US"）
    func setPreferredLanguage(_ language: String) {
        preferredLanguage = language
        setupSpeechRecognizer()
        logger.info("Preferred language set to: \(language)")
    }
    
    /// 言語を自動検出
    /// - Parameter audioBuffer: 音声バッファ
    /// - Returns: 検出された言語コード
    func detectLanguage(from audioBuffer: AVAudioPCMBuffer) async -> String? {
        logger.info("Detecting language from audio")
        
        // 複数言語で認識を試行し、最も信頼度の高い結果の言語を返す
        var bestLanguage: String?
        var bestConfidence: Double = 0.0
        
        let testLanguages = [preferredLanguage] + fallbackLanguages
        
        for language in testLanguages {
            if let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)),
               recognizer.isAvailable {
                
                do {
                    let result = try await recognizeWithiOSSpeech(
                        audioBuffer: audioBuffer,
                        language: language
                    )
                    
                    if result.confidence > bestConfidence {
                        bestConfidence = result.confidence
                        bestLanguage = language
                    }
                    
                } catch {
                    logger.debug("Language detection failed for \(language): \(error.localizedDescription)")
                }
            }
        }
        
        logger.info("Detected language: \(bestLanguage ?? "unknown") with confidence: \(bestConfidence)")
        return bestLanguage
    }
    
    // MARK: - Private Methods
    
    /// Speech Recognizerを設定
    private func setupSpeechRecognizer() {
        let locale = Locale(identifier: preferredLanguage)
        speechRecognizer = SFSpeechRecognizer(locale: locale)
        speechRecognizer?.delegate = self
        
        logger.info("Speech recognizer set up for locale: \(locale.identifier)")
    }
    
    /// Google APIキーを読み込み
    private func loadGoogleAPIKey() {
        // 実装例：Info.plistから読み込み
        if let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
           let plist = NSDictionary(contentsOfFile: path),
           let apiKey = plist["GOOGLE_SPEECH_API_KEY"] as? String {
            googleAPIKey = apiKey
            logger.info("Google API key loaded successfully")
        } else {
            logger.warning("Google API key not found - Google Speech-to-Text will be unavailable")
        }
    }
    
    /// 音声認識権限をチェック
    private func checkSpeechRecognitionPermission() async -> Bool {
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
    
    /// iOS Speech Frameworkで認識
    private func recognizeWithiOSSpeech(
        audioBuffer: AVAudioPCMBuffer,
        language: String? = nil
    ) async throws -> SpeechRecognitionResult {
        
        let targetLanguage = language ?? preferredLanguage
        let locale = Locale(identifier: targetLanguage)
        
        guard let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.isAvailable else {
            throw AppError.speechRecognitionUnavailable
        }
        
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.append(audioBuffer)
        request.endAudio()
        
        return try await withCheckedThrowingContinuation { continuation in
            recognizer.recognitionTask(with: request) { result, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let result = result, result.isFinal else { return }
                
                let recognitionResult = SpeechRecognitionResult(
                    text: result.bestTranscription.formattedString,
                    confidence: Double(result.bestTranscription.averageConfidence),
                    method: .iosSpeech,
                    language: targetLanguage,
                    processingTime: 0.0, // iOS SDKでは取得不可
                    segments: result.bestTranscription.segments.map { segment in
                        SpeechSegment(
                            text: segment.substring,
                            startTime: segment.timestamp,
                            endTime: segment.timestamp + segment.duration,
                            confidence: Double(segment.confidence),
                            speakerId: nil
                        )
                    }
                )
                
                continuation.resume(returning: recognitionResult)
            }
        }
    }
    
    /// Google Speech-to-Textで認識
    private func recognizeWithGoogleSpeech(audioBuffer: AVAudioPCMBuffer) async throws -> SpeechRecognitionResult? {
        guard let apiKey = googleAPIKey else {
            logger.warning("Google API key not available")
            return nil
        }
        
        logger.info("Starting Google Speech-to-Text recognition")
        
        // 音声データをBase64エンコード
        guard let audioData = audioBufferToData(audioBuffer) else {
            throw NSError(
                domain: "SpeechRecognitionService",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Failed to convert audio buffer to data"]
            )
        }
        
        let base64Audio = audioData.base64EncodedString()
        
        // リクエストボディを作成
        let requestBody: [String: Any] = [
            "config": [
                "encoding": "LINEAR16",
                "sampleRateHertz": Int(audioBuffer.format.sampleRate),
                "languageCode": preferredLanguage,
                "alternativeLanguageCodes": fallbackLanguages,
                "enableAutomaticPunctuation": true,
                "enableWordConfidence": true,
                "enableWordTimeOffsets": true
            ],
            "audio": [
                "content": base64Audio
            ]
        ]
        
        // HTTPリクエストを作成
        guard let url = URL(string: "https://speech.googleapis.com/v1/speech:recognize?key=\(apiKey)") else {
            throw NSError(
                domain: "SpeechRecognitionService",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Invalid Google API URL"]
            )
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        
        // リクエスト実行
        let (data, response) = try await urlSession.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw NSError(
                domain: "SpeechRecognitionService",
                code: -5,
                userInfo: [NSLocalizedDescriptionKey: "Google API request failed"]
            )
        }
        
        // レスポンス解析
        let jsonResponse = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        
        guard let results = jsonResponse?["results"] as? [[String: Any]],
              let firstResult = results.first,
              let alternatives = firstResult["alternatives"] as? [[String: Any]],
              let bestAlternative = alternatives.first,
              let transcript = bestAlternative["transcript"] as? String else {
            
            logger.warning("No recognition results from Google API")
            return nil
        }
        
        let confidence = bestAlternative["confidence"] as? Double ?? 0.0
        
        // セグメント情報を解析
        var segments: [SpeechSegment] = []
        if let words = bestAlternative["words"] as? [[String: Any]] {
            segments = words.compactMap { word in
                guard let wordText = word["word"] as? String,
                      let startTime = word["startTime"] as? String,
                      let endTime = word["endTime"] as? String else {
                    return nil
                }
                
                let startSeconds = parseTimeString(startTime)
                let endSeconds = parseTimeString(endTime)
                let wordConfidence = word["confidence"] as? Double ?? confidence
                
                return SpeechSegment(
                    text: wordText,
                    startTime: startSeconds,
                    endTime: endSeconds,
                    confidence: wordConfidence,
                    speakerId: nil
                )
            }
        }
        
        let result = SpeechRecognitionResult(
            text: transcript,
            confidence: confidence,
            method: .googleSpeech,
            language: preferredLanguage,
            processingTime: 0.0, // Google APIでは取得不可
            segments: segments
        )
        
        logger.info("Google Speech recognition completed successfully")
        return result
    }
    
    /// リアルタイム認識結果を処理
    private func handleRealtimeRecognitionResult(result: SFSpeechRecognitionResult?, error: Error?) {
        if let error = error {
            logger.error("Realtime recognition error: \(error.localizedDescription)")
            
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.speechRecognition(didFailWithError: error)
            }
            return
        }
        
        guard let result = result else { return }
        
        let transcript = result.bestTranscription.formattedString
        confidence = Double(result.bestTranscription.averageConfidence)
        
        // デリゲートに部分結果を通知
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.speechRecognition(didRecognizeText: transcript, isFinal: result.isFinal)
        }
        
        // 最終結果の場合
        if result.isFinal {
            accumulatedText += transcript + " "
            
            let finalResult = SpeechRecognitionResult(
                text: accumulatedText.trimmingCharacters(in: .whitespaces),
                confidence: confidence,
                method: currentMethod,
                language: preferredLanguage,
                processingTime: 0.0,
                segments: result.bestTranscription.segments.map { segment in
                    SpeechSegment(
                        text: segment.substring,
                        startTime: segment.timestamp,
                        endTime: segment.timestamp + segment.duration,
                        confidence: Double(segment.confidence),
                        speakerId: nil
                    )
                }
            )
            
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.speechRecognition(didCompleteWithResult: finalResult)
            }
            
            logger.info("Realtime recognition completed with final result")
        }
    }
    
    /// タイムアウトタイマーを開始
    private func startTimeoutTimer() {
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: recognitionTimeout, repeats: false) { [weak self] _ in
            self?.logger.warning("Speech recognition timeout")
            self?.stopRecognition()
            
            DispatchQueue.main.async {
                self?.delegate?.speechRecognitionDidTimeout()
            }
        }
    }
    
    /// 音声バッファをDataに変換
    private func audioBufferToData(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let channelData = buffer.int16ChannelData?[0] else { return nil }
        
        let frameLength = Int(buffer.frameLength)
        let data = Data(bytes: channelData, count: frameLength * MemoryLayout<Int16>.size)
        
        return data
    }
    
    /// Google APIの時間文字列を秒に変換
    private func parseTimeString(_ timeString: String) -> TimeInterval {
        // "1.234s" -> 1.234
        let cleaned = timeString.replacingOccurrences(of: "s", with: "")
        return Double(cleaned) ?? 0.0
    }
}

// MARK: - SFSpeechRecognizerDelegate

extension SpeechRecognitionService: SFSpeechRecognizerDelegate {
    
    func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        logger.info("Speech recognizer availability changed: \(available)")
        
        if !available {
            stopRecognition()
        }
    }
}

// MARK: - Error Handling

extension SpeechRecognitionService {
    
    /// エラーハンドリング用のヘルパーメソッド
    private func handleError(_ error: Error, context: String) {
        logger.error("Error in \(context): \(error.localizedDescription)")
        
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.speechRecognition(didFailWithError: error)
        }
    }
}

// MARK: - Debug Support

#if DEBUG
extension SpeechRecognitionService {
    
    /// デバッグ情報を出力
    func printDebugInfo() {
        logger.debug("""
            SpeechRecognitionService Debug Info:
            - Current Method: \(currentMethod.rawValue)
            - Confidence: \(confidence)
            - Preferred Language: \(preferredLanguage)
            - Is Recognizing: \(isRecognizing)
            - Supported Languages: \(supportedLanguages.joined(separator: ", "))
            - Buffer Queue Count: \(audioBufferQueue.count)
            - Google API Available: \(googleAPIKey != nil)
            """)
    }
}
#endif