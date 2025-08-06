import Foundation
import Speech
import AVFoundation
import os.log

/// 音声認識サービス
///
/// Azure Speech Serviceをプライマリとし、iOS Speech Frameworkをフォールバックとして
/// リアルタイム音声認識とバッチ処理、言語自動検出を提供します。
final class SpeechRecognitionService: NSObject, SpeechRecognitionServiceProtocol {
    
    // MARK: - Properties
    
    weak var delegate: SpeechRecognitionDelegate?
    private(set) var currentMethod: TranscriptionMethod = .azureSpeech // Azure Speech Serviceを優先
    private(set) var confidence: Double = 0.0
    
    var supportedLanguages: [String] {
        return ["ja-JP", "en-US", "en-GB", "zh-CN", "ko-KR"]
    }
    
    // MARK: - Azure Speech Service Properties
    private let azureConfig: AzureSpeechConfig
    private let session: URLSession
    
    // MARK: - iOS Speech Framework Properties (Primary)
    private var iosSpeechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?
    
    private var preferredLanguage: String = "ja-JP"
    private let logger = Logger(subsystem: "com.telreq.app", category: "SpeechRecognition")
    private var isRecognizing: Bool = false
    
    // 録音データの蓄積用
    private var recordedAudioData = Data()
    private var recordingStartTime: Date?

    // MARK: - Initialization
    
    init(azureConfig: AzureSpeechConfig) {
        self.azureConfig = azureConfig
        
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 30.0
        sessionConfig.timeoutIntervalForResource = 300.0
        self.session = URLSession(configuration: sessionConfig)
        
        super.init()
        setupRecognizers()
        logger.info("SpeechRecognitionService initialized")
    }
    
    deinit {
        stopRecognition()
    }
    
    // MARK: - SpeechRecognitionServiceProtocol Implementation
    
    func startRecognition(audioBuffer: AVAudioPCMBuffer) async throws -> String {
        // 権限チェック
        guard await checkSpeechRecognitionPermission() else {
            logger.error("Speech recognition permission denied")
            throw AppError.speechRecognitionFailed(underlying: NSError(domain: "SpeechRecognition", code: -1, userInfo: [NSLocalizedDescriptionKey: "Speech recognition permission denied"]))
        }
        
        switch currentMethod {
        case .iosSpeech:
            return try await performLocalRecognition(audioBuffer: audioBuffer)
        case .azureSpeech:
            return try await performAzureRecognition(audioBuffer: audioBuffer)
        case .hybridProcessing:
            return try await performHybridRecognition(audioBuffer: audioBuffer)
        }
    }
    
    func stopRecognition() {
        logger.info("Stopping speech recognition")
        isRecognizing = false
        
        // iOS Speech Frameworkの停止
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        audioEngine?.stop()
        audioEngine = nil
        
        // 録音データはクリアしない（最終処理まで保持）
        logger.info("Stopped recognition, keeping \(self.recordedAudioData.count) bytes of recorded data")
    }
    
    func switchToBackupService() async throws {
        logger.info("Switching to backup service (iOS Speech)")
        stopRecognition()
        currentMethod = .iosSpeech
    }
    
    func switchTranscriptionMethod(_ method: TranscriptionMethod) {
        logger.info("Switching transcription method to: \(method.displayName)")
        stopRecognition()
        currentMethod = method
    }
    
    func startRealtimeRecognition() async throws {
        // リアルタイム認識は無効化し、録音終了時のバッチ処理のみ使用
        logger.info("Real-time recognition disabled, will process at recording end")
        isRecognizing = true
        recordedAudioData = Data()
        recordingStartTime = Date()
    }
    
    /// 音声データを蓄積（録音中に呼び出される）
    func accumulateAudioData(_ buffer: AVAudioPCMBuffer) {
        guard isRecognizing else { 
            logger.debug("Not recognizing, skipping audio data accumulation")
            return 
        }
        
        do {
            let audioData = try convertAudioBufferToData(buffer)
            recordedAudioData.append(audioData)
            logger.debug("Accumulated \(audioData.count) bytes of audio data, total: \(self.recordedAudioData.count) bytes")
        } catch {
            logger.error("Failed to accumulate audio data: \(error.localizedDescription)")
            // エラーが発生してもログのみにして、プロセス全体を停止しない
        }
    }
    
    func checkSpeechRecognitionPermission() async -> Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        logger.info("Checking speech recognition permission, current status: \(status.rawValue)")
        
        switch status {
        case .notDetermined:
            logger.info("Speech recognition permission not determined, requesting...")
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { newStatus in
                    let isAuthorized = newStatus == .authorized
                    self.logger.info("Speech recognition permission result: \(newStatus.rawValue), authorized: \(isAuthorized)")
                    continuation.resume(returning: isAuthorized)
                }
            }
        case .authorized:
            logger.info("Speech recognition permission already authorized")
            return true
        case .denied:
            logger.warning("Speech recognition permission denied")
            return false
        case .restricted:
            logger.warning("Speech recognition permission restricted")
            return false
        @unknown default:
            logger.warning("Speech recognition permission unknown status: \(status.rawValue)")
            return false
        }
    }
    
    /// 最終的な音声認識結果を取得
    func getFinalRecognitionResult() async throws -> SpeechRecognitionResult {
        logger.info("Getting final recognition result")
        
        // 現在の認識を停止
        stopRecognition()
        
        // 現在の方法に基づいて最終結果を取得
        do {
            let finalText: String
            let method = currentMethod
            
            switch method {
            case .azureSpeech:
                // Azure Speech Serviceを使用してバッチ処理
                let audioData = try await captureFinalAudioData()
                
                // 音声データサイズ制限（5MB、より安全に）
                let maxAudioSize = 5 * 1024 * 1024
                if audioData.count > maxAudioSize {
                    logger.warning("Audio data too large (\(audioData.count) bytes), truncating to \(maxAudioSize) bytes for stability")
                    let truncatedData = audioData.prefix(maxAudioSize)
                    finalText = try await performBatchRecognition(audioData: Data(truncatedData))
                } else if audioData.count < 1024 {
                    // 音声データが小さすぎる場合
                    logger.warning("Audio data too small (\(audioData.count) bytes), may indicate recording issue")
                    finalText = "録音データが不十分です"
                } else {
                    finalText = try await performBatchRecognition(audioData: audioData)
                }
            case .iosSpeech:
                // iOS Speech Frameworkの場合は、デリゲートから最後の結果を使用するか、
                // フォールバックテキストを使用
                finalText = "音声認識に失敗しました"
            case .hybridProcessing:
                // ハイブリッド方式ではAzureを試して、失敗したらローカルを使用
                do {
                    let audioData = try await captureFinalAudioData()
                    
                    // 音声データサイズ制限（5MB、より安全に）
                    let maxAudioSize = 5 * 1024 * 1024
                    if audioData.count > maxAudioSize {
                        logger.warning("Audio data too large (\(audioData.count) bytes), truncating to \(maxAudioSize) bytes for stability")
                        let truncatedData = audioData.prefix(maxAudioSize)
                        finalText = try await performBatchRecognition(audioData: Data(truncatedData))
                    } else if audioData.count < 1024 {
                        logger.warning("Audio data too small (\(audioData.count) bytes), may indicate recording issue")
                        finalText = "録音データが不十分です"
                    } else {
                        finalText = try await performBatchRecognition(audioData: audioData)
                    }
                } catch {
                    logger.warning("Azure recognition failed in hybrid mode, using fallback text")
                    finalText = "音声認識に失敗しました"
                }
            }
            
            let result = SpeechRecognitionResult(
                text: finalText,
                confidence: confidence,
                method: method,
                language: preferredLanguage,
                processingTime: 0,
                segments: []
            )
            
            logger.info("Final recognition result obtained: \(finalText.count) characters")
            return result
            
        } catch {
            logger.error("Failed to get final recognition result: \(error.localizedDescription)")
            
            // エラーが発生した場合はフォールバックテキストを返す
            let fallbackResult = SpeechRecognitionResult(
                text: "音声認識に失敗しました",
                confidence: 0.0,
                method: currentMethod,
                language: preferredLanguage,
                processingTime: 0,
                segments: []
            )
            
            return fallbackResult
        }
    }
    
    /// 最終的な音声データをキャプチャ
    private func captureFinalAudioData() async throws -> Data {
        guard !recordedAudioData.isEmpty else {
            logger.warning("No recorded audio data available, generating minimal WAV file")
            // 最小限のWAVファイルを生成（1秒間の無音データ）
            let sampleRate: Double = 16000
            let duration: Double = 1.0
            let frameCount = Int(sampleRate * duration)
            let channels: UInt32 = 1
            
            // 16ビットPCMデータを生成
            var audioSamples = [Int16](repeating: 0, count: frameCount)
            let audioData = Data(bytes: &audioSamples, count: frameCount * MemoryLayout<Int16>.size)
            
            return try convertToWAV(data: audioData, sampleRate: sampleRate, channels: channels)
        }
        
        // 蓄積された音声データを使用
        let sampleRate: Double = 16000
        let channels: UInt32 = 1
        
        let wavData = try convertToWAV(data: recordedAudioData, sampleRate: sampleRate, channels: channels)
        
        let duration = recordingStartTime.map { -$0.timeIntervalSinceNow } ?? 0
        logger.info("Captured \(self.recordedAudioData.count) bytes of audio data, duration: \(String(format: "%.1f", duration))s, WAV size: \(wavData.count) bytes")
        
        return wavData
    }
    
    // MARK: - Private Methods
    
    private func setupRecognizers() {
        let locale = Locale(identifier: preferredLanguage)
        iosSpeechRecognizer = SFSpeechRecognizer(locale: locale)
    }
    
    // MARK: - Local Recognition (iOS Speech Framework)
    
    private func performLocalRecognition(audioBuffer: AVAudioPCMBuffer) async throws -> String {
        guard let recognizer = iosSpeechRecognizer else {
            throw AppError.speechRecognitionUnavailable
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            // 音声データを一時ファイルに保存
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("temp_audio.wav")
            do {
                let audioData = try convertAudioBufferToData(audioBuffer)
                try audioData.write(to: tempURL)
                
                // SFSpeechURLRecognitionRequestを使用
                let request = SFSpeechURLRecognitionRequest(url: tempURL)
                
                recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                    defer {
                        // 一時ファイルを削除
                        try? FileManager.default.removeItem(at: tempURL)
                    }
                    
                    if let error = error {
                        continuation.resume(throwing: AppError.speechRecognitionFailed(underlying: error))
                        return
                    }
                    
                    guard let result = result else {
                        continuation.resume(throwing: AppError.speechRecognitionFailed(underlying: NSError(domain: "SpeechRecognition", code: 0, userInfo: nil)))
                        return
                    }
                    
                    let recognizedText = result.bestTranscription.formattedString
                    let confidenceValues = result.bestTranscription.segments.map { Double($0.confidence) }
                    self.confidence = confidenceValues.isEmpty ? 0.0 : confidenceValues.reduce(0, +) / Double(confidenceValues.count)
                    
                    // 結果をデリゲートに通知
                    let speechResult = SpeechRecognitionResult(
                        text: recognizedText,
                        confidence: self.confidence,
                        method: .iosSpeech,
                        language: self.preferredLanguage,
                        processingTime: 0,
                        segments: []
                    )
                    
                    DispatchQueue.main.async {
                        self.delegate?.speechRecognition(didRecognizeText: recognizedText, isFinal: true)
                        self.delegate?.speechRecognition(didCompleteWithResult: speechResult)
                    }
                    
                    continuation.resume(returning: recognizedText)
                }
            } catch {
                continuation.resume(throwing: AppError.speechRecognitionFailed(underlying: error))
            }
        }
    }
    
    private func startLocalRealtimeRecognition() async throws {
        logger.info("Starting local real-time recognition")
        
        guard let recognizer = iosSpeechRecognizer else {
            logger.error("Speech recognizer is not available")
            throw AppError.speechRecognitionUnavailable
        }
        
        guard recognizer.isAvailable else {
            logger.error("Speech recognizer is not available for the current locale")
            throw AppError.speechRecognitionUnavailable
        }
        
        do {
            // 既存のエンジンをクリーンアップ
            if let existingEngine = audioEngine {
                if existingEngine.isRunning {
                    existingEngine.stop()
                }
                existingEngine.inputNode.removeTap(onBus: 0)
                self.audioEngine = nil
            }
            
            // 音声エンジンを初期化
            audioEngine = AVAudioEngine()
            guard let audioEngine = audioEngine else {
                logger.error("Failed to create audio engine")
                throw AppError.speechRecognitionUnavailable
            }
            
            // 音声セッションの設定を確認
            #if canImport(AVFoundation) && !os(macOS)
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            #endif
            
            let inputNode = audioEngine.inputNode
            
            // 認識リクエストを先に設定
            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let recognitionRequest = recognitionRequest else {
                logger.error("Failed to create recognition request")
                throw AppError.speechRecognitionUnavailable
            }
            
            recognitionRequest.shouldReportPartialResults = true
            
            // 録音フォーマットを取得
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            logger.info("Recording format: \(recordingFormat)")
            
            // 音声タップを設定
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                self?.recognitionRequest?.append(buffer)
            }
            
            // 認識タスクを開始
            recognitionTask = recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                guard let self = self else { return }
                
                if let error = error {
                    self.logger.error("Local recognition error: \(error.localizedDescription)")
                    // エラーが発生した場合は認識を停止
                    DispatchQueue.main.async {
                        self.stopRecognition()
                    }
                    return
                }
                
                guard let result = result else { return }
                
                let recognizedText = result.bestTranscription.formattedString
                let confidenceValues = result.bestTranscription.segments.map { Double($0.confidence) }
                self.confidence = confidenceValues.isEmpty ? 0.0 : confidenceValues.reduce(0, +) / Double(confidenceValues.count)
                
                DispatchQueue.main.async {
                    self.delegate?.speechRecognition(didRecognizeText: recognizedText, isFinal: result.isFinal)
                }
            }
            
            // オーディオエンジンを準備して開始
            audioEngine.prepare()
            try audioEngine.start()
            
            isRecognizing = true
            currentMethod = .iosSpeech
            
            logger.info("Local real-time recognition started successfully")
            
        } catch {
            logger.error("Failed to start local real-time recognition: \(error.localizedDescription)")
            
            // クリーンアップ
            if let engine = audioEngine {
                if engine.isRunning {
                    engine.stop()
                }
                engine.inputNode.removeTap(onBus: 0)
                self.audioEngine = nil
            }
            
            recognitionRequest = nil
            recognitionTask?.cancel()
            recognitionTask = nil
            
            throw AppError.speechRecognitionFailed(underlying: error)
        }
    }
    
    // MARK: - Azure Recognition
    
    private func performAzureRecognition(audioBuffer: AVAudioPCMBuffer) async throws -> String {
        do {
            let audioData = try convertAudioBufferToData(audioBuffer)
            let result = try await performBatchRecognition(audioData: audioData)
            return result
        } catch {
            logger.error("Failed to perform Azure recognition: \(error.localizedDescription)")
            throw AppError.speechRecognitionFailed(underlying: error)
        }
    }
    
    private func startAzureRealtimeRecognition() async throws {
        logger.info("Starting Azure real-time recognition")
        
        // Azure Speech Serviceのリアルタイム認識はWebSocketベースの実装が必要
        // 現在はバッチ処理に優雅にフォールバックしてローカル認識を併用
        do {
            try await startLocalRealtimeRecognition()
            currentMethod = .azureSpeech
            isRecognizing = true
            logger.info("Azure real-time recognition started with local audio capture")
        } catch {
            logger.error("Failed to start Azure real-time recognition, falling back to local: \(error.localizedDescription)")
            try await startLocalRealtimeRecognition()
            currentMethod = .iosSpeech
            throw error
        }
    }
    
    // MARK: - Hybrid Recognition
    
    private func performHybridRecognition(audioBuffer: AVAudioPCMBuffer) async throws -> String {
        // ローカルとAzureの両方で認識を試行
        do {
            let localResult = try await performLocalRecognition(audioBuffer: audioBuffer)
            return localResult
        } catch {
            logger.warning("Local recognition failed, trying Azure: \(error.localizedDescription)")
            return try await performAzureRecognition(audioBuffer: audioBuffer)
        }
    }
    
    private func startHybridRealtimeRecognition() async throws {
        logger.info("Hybrid real-time recognition using local method")
        try await startLocalRealtimeRecognition()
        currentMethod = .hybridProcessing
    }
    
    // MARK: - Audio Conversion
    
    private func convertAudioBufferToData(_ buffer: AVAudioPCMBuffer) throws -> Data {
        // Float32データとInt16データの両方に対応
        let frameLength = Int(buffer.frameLength)
        var data = Data()
        
        if let floatChannelData = buffer.floatChannelData?[0] {
            // Float32 -> Int16変換
            var int16Data = [Int16]()
            int16Data.reserveCapacity(frameLength)
            
            for i in 0..<frameLength {
                let floatSample = floatChannelData[i]
                let clampedSample = max(-1.0, min(1.0, floatSample))
                let int16Sample = Int16(clampedSample * Float(Int16.max))
                int16Data.append(int16Sample)
            }
            
            data = Data(bytes: int16Data, count: frameLength * MemoryLayout<Int16>.size)
            
        } else if let int16ChannelData = buffer.int16ChannelData?[0] {
            // すでにInt16形式
            data = Data(bytes: int16ChannelData, count: frameLength * MemoryLayout<Int16>.size)
        } else {
            throw AppError.speechRecognitionFailed(underlying: NSError(domain: "AudioConversion", code: 0, userInfo: [NSLocalizedDescriptionKey: "Unsupported audio format"]))
        }
        
        // WAV 形式に変換
        return try convertToWAV(data: data, sampleRate: buffer.format.sampleRate, channels: buffer.format.channelCount)
    }
    
    private func convertToWAV(data: Data, sampleRate: Double, channels: UInt32) throws -> Data {
        var wavData = Data()
        
        // WAV ヘッダー
        let header = createWAVHeader(dataSize: data.count, sampleRate: sampleRate, channels: channels)
        wavData.append(header)
        wavData.append(data)
        
        return wavData
    }
    
    private func createWAVHeader(dataSize: Int, sampleRate: Double, channels: UInt32) -> Data {
        var header = Data()
        
        // RIFF ヘッダー
        header.append("RIFF".data(using: .ascii)!)
        header.append(withUnsafeBytes(of: UInt32(36 + dataSize).littleEndian) { Data($0) })
        header.append("WAVE".data(using: .ascii)!)
        
        // fmt チャンク
        header.append("fmt ".data(using: .ascii)!)
        header.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) }) // fmt chunk size
        header.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) }) // audio format (PCM)
        header.append(withUnsafeBytes(of: UInt16(channels).littleEndian) { Data($0) }) // channels
        header.append(withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Data($0) }) // sample rate
        header.append(withUnsafeBytes(of: UInt32(Int(sampleRate) * Int(channels) * 2).littleEndian) { Data($0) }) // byte rate
        header.append(withUnsafeBytes(of: UInt16(Int(channels) * 2).littleEndian) { Data($0) }) // block align
        header.append(withUnsafeBytes(of: UInt16(16).littleEndian) { Data($0) }) // bits per sample
        
        // data チャンク
        header.append("data".data(using: .ascii)!)
        header.append(withUnsafeBytes(of: UInt32(dataSize).littleEndian) { Data($0) })
        
        return header
    }
    
    private func performBatchRecognition(audioData: Data) async throws -> String {
        // Azure Speech Service設定の検証
        guard !azureConfig.subscriptionKey.isEmpty && !azureConfig.subscriptionKey.contains("your-speech-subscription-key") else {
            logger.error("Azure Speech Service subscription key is not configured properly")
            throw AppError.speechRecognitionFailed(underlying: NSError(domain: "SpeechRecognition", code: -1, userInfo: [NSLocalizedDescriptionKey: "Azure Speech Service not configured"]))
        }
        
        // dictationモードを使用して長時間の音声認識に対応し、完全な結果を取得
        let url = URL(string: "https://\(azureConfig.region).stt.speech.microsoft.com/speech/recognition/dictation/cognitiveservices/v1?language=\(preferredLanguage)&format=detailed&profanity=raw")!
        logger.info("Sending Azure Speech request to: \(url.absoluteString)")
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.setValue(azureConfig.subscriptionKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue("telreq-ios-app", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60.0 // 長い音声ファイル用に60秒に延長
        request.httpBody = audioData
        
        logger.info("Azure Speech request - Audio data size: \(audioData.count) bytes")
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppError.speechRecognitionFailed(underlying: NSError(domain: "SpeechRecognition", code: 0, userInfo: nil))
        }
        
        if httpResponse.statusCode != 200 {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            logger.error("Speech recognition failed with status \(httpResponse.statusCode): \(errorMessage)")
            throw AppError.speechRecognitionFailed(underlying: NSError(domain: "SpeechRecognition", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.speechRecognitionFailed(underlying: NSError(domain: "SpeechRecognition", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON response format"]))
        }
        
        logger.info("Azure Speech API response received: \(String(data: data, encoding: .utf8)?.prefix(200) ?? "Unable to parse")")
        
        // より柔軟なテキスト抽出 - DisplayText優先、NBestからも取得
        var displayText: String = ""
        
        if let directDisplayText = json["DisplayText"] as? String, !directDisplayText.isEmpty {
            displayText = directDisplayText
            logger.info("Using DisplayText: \(displayText.prefix(50))...")
        } else if let nbest = json["NBest"] as? [[String: Any]], 
                  let firstResult = nbest.first,
                  let nbestDisplay = firstResult["Display"] as? String, !nbestDisplay.isEmpty {
            displayText = nbestDisplay
            logger.info("Using NBest Display: \(displayText.prefix(50))...")
        } else if let recognitionStatus = json["RecognitionStatus"] as? String {
            logger.error("Speech recognition failed with status: \(recognitionStatus)")
            if let errorDetail = json["ErrorDetails"] as? String {
                logger.error("Error details: \(errorDetail)")
            }
            throw AppError.speechRecognitionFailed(underlying: NSError(domain: "SpeechRecognition", code: 0, userInfo: [NSLocalizedDescriptionKey: "Recognition failed: \(recognitionStatus)"]))
        } else {
            logger.error("No valid text found in response: \(json)")
            throw AppError.speechRecognitionFailed(underlying: NSError(domain: "SpeechRecognition", code: 0, userInfo: [NSLocalizedDescriptionKey: "No DisplayText or NBest results found"]))
        }
        
        // 信頼度を更新
        if let confidenceValue = json["NBest"] as? [[String: Any]],
           let firstResult = confidenceValue.first,
           let confidence = firstResult["Confidence"] as? Double {
            self.confidence = confidence
        }
        
        // 結果をデリゲートに通知
        let speechResult = SpeechRecognitionResult(
            text: displayText,
            confidence: self.confidence,
            method: .azureSpeech,
            language: preferredLanguage,
            processingTime: 0,
            segments: []
        )
        
        DispatchQueue.main.async {
            self.delegate?.speechRecognition(didRecognizeText: displayText, isFinal: true)
            self.delegate?.speechRecognition(didCompleteWithResult: speechResult)
        }
        
        return displayText
    }
}

// MARK: - Debug Support
#if DEBUG
extension SpeechRecognitionService {
    func printDebugInfo() {
        logger.debug("""
            SpeechRecognitionService Debug Info:
            - Current Method: \(self.currentMethod.rawValue)
            - Preferred Language: \(self.preferredLanguage)
            - Is Recognizing: \(self.isRecognizing)
            """)
    }
}
#endif
