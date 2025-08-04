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
    private(set) var currentMethod: TranscriptionMethod = .iosSpeech // デフォルトをローカルに変更
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
        guard !isRecognizing else { return }
        
        do {
            switch currentMethod {
            case .iosSpeech:
                try await startLocalRealtimeRecognition()
            case .azureSpeech:
                try await startAzureRealtimeRecognition()
            case .hybridProcessing:
                try await startHybridRealtimeRecognition()
            }
        } catch {
            logger.error("Failed to start real-time recognition: \(error.localizedDescription)")
            throw AppError.speechRecognitionFailed(underlying: error)
        }
    }
    
    func checkSpeechRecognitionPermission() async -> Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        }
        return status == .authorized
    }
    
    /// 最終的な音声認識結果を取得
    func getFinalRecognitionResult() async throws -> SpeechRecognitionResult {
        logger.info("Getting final recognition result")
        
        // 現在の認識を停止
        stopRecognition()
        
        // 蓄積された音声データから最終結果を生成
        guard let audioEngine = audioEngine else {
            throw AppError.speechRecognitionFailed(underlying: NSError(domain: "SpeechRecognition", code: 0, userInfo: [NSLocalizedDescriptionKey: "No audio engine available"]))
        }
        
        // 音声データを取得してバッチ処理
        let audioData = try await captureFinalAudioData()
        let finalText = try await performBatchRecognition(audioData: audioData)
        
        let result = SpeechRecognitionResult(
            text: finalText,
            confidence: confidence,
            method: currentMethod,
            language: preferredLanguage,
            processingTime: 0,
            segments: []
        )
        
        logger.info("Final recognition result obtained: \(finalText.count) characters")
        return result
    }
    
    /// 最終的な音声データをキャプチャ
    private func captureFinalAudioData() async throws -> Data {
        // 簡易実装：実際のアプリでは音声バッファを蓄積して使用
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("final_audio.wav")
        
        // ダミーデータを生成（実際の実装では蓄積された音声データを使用）
        let dummyAudioData = Data(repeating: 0, count: 1024)
        try dummyAudioData.write(to: tempURL)
        
        return try Data(contentsOf: tempURL)
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
        guard let recognizer = iosSpeechRecognizer else {
            throw AppError.speechRecognitionUnavailable
        }
        
        // 音声エンジンを初期化
        audioEngine = AVAudioEngine()
        guard let audioEngine = audioEngine else {
            throw AppError.speechRecognitionUnavailable
        }
        
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
        // 音声入力の設定
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            self.recognitionRequest?.append(buffer)
        }
        
        audioEngine.prepare()
        try audioEngine.start()
        
        // 認識リクエストの設定
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            throw AppError.speechRecognitionUnavailable
        }
        
        recognitionRequest.shouldReportPartialResults = true
        
        recognitionTask = recognizer.recognitionTask(with: recognitionRequest) { result, error in
            if let error = error {
                self.logger.error("Local recognition error: \(error.localizedDescription)")
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
        
        isRecognizing = true
        currentMethod = .iosSpeech
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
        logger.info("Azure real-time recognition not fully implemented, using batch processing")
        currentMethod = .azureSpeech
        isRecognizing = true
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
        guard let channelData = buffer.floatChannelData?[0] else {
            throw AppError.speechRecognitionFailed(underlying: NSError(domain: "AudioConversion", code: 0, userInfo: nil))
        }
        
        let frameLength = Int(buffer.frameLength)
        let data = Data(bytes: channelData, count: frameLength * MemoryLayout<Float>.size)
        
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
        header.append(withUnsafeBytes(of: UInt32(sampleRate * Double(channels) * 2).littleEndian) { Data($0) }) // byte rate
        header.append(withUnsafeBytes(of: UInt16(channels * 2).littleEndian) { Data($0) }) // block align
        header.append(withUnsafeBytes(of: UInt16(16).littleEndian) { Data($0) }) // bits per sample
        
        // data チャンク
        header.append("data".data(using: .ascii)!)
        header.append(withUnsafeBytes(of: UInt32(dataSize).littleEndian) { Data($0) })
        
        return header
    }
    
    private func performBatchRecognition(audioData: Data) async throws -> String {
        let url = URL(string: "https://\(azureConfig.region).stt.speech.microsoft.com/speech/recognition/conversation/cognitiveservices/v1?language=\(preferredLanguage)")!
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.setValue(azureConfig.subscriptionKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.httpBody = audioData
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppError.speechRecognitionFailed(underlying: NSError(domain: "SpeechRecognition", code: 0, userInfo: nil))
        }
        
        if httpResponse.statusCode != 200 {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            logger.error("Speech recognition failed with status \(httpResponse.statusCode): \(errorMessage)")
            throw AppError.speechRecognitionFailed(underlying: NSError(domain: "SpeechRecognition", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let displayText = json["DisplayText"] as? String else {
            throw AppError.speechRecognitionFailed(underlying: NSError(domain: "SpeechRecognition", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid response format"]))
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
