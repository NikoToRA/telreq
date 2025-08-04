import Foundation
import AVFoundation
import CallKit
import Contacts
#if canImport(UIKit)
import UIKit
#endif
import os.log

/// 通話管理サービス
/// 
/// AVAudioSessionの設定、通話状態の監視、自動音声キャプチャ開始/停止を管理します。
/// CallKitとの連携により、システム通話イベントを監視し、適切なタイミングで
/// 音声キャプチャと音声認識を制御します。
final class CallManager: NSObject, CallManagerProtocol, ObservableObject {
    
    // MARK: - Properties
    
    /// 通話状態の監視デリゲート
    weak var delegate: CallManagerDelegate?
    
    /// 現在の通話状態
    @Published private(set) var callState: CallState = .idle
    
    /// 音声キャプチャサービス
    private let audioCaptureService: AudioCaptureServiceProtocol
    
    /// 音声認識サービス
    private let speechRecognitionService: SpeechRecognitionServiceProtocol
    
    /// テキスト処理サービス
    private let textProcessingService: TextProcessingServiceProtocol
    
    /// ストレージサービス
    private let storageService: StorageServiceProtocol
    
    /// オフラインデータマネージャー
    private let offlineDataManager: OfflineDataManagerProtocol
    
    /// CallKit関連 (iOS のみ)
    #if canImport(CallKit) && !os(macOS)
    private let callObserver = CXCallObserver()
    #endif
    
    /// 音声セッション (iOS のみ)
    #if canImport(AVFoundation) && !os(macOS)
    private let audioSession = AVAudioSession.sharedInstance()
    #endif
    
    /// 現在の通話情報
    private(set) var currentCall: CallInfo?
    
    /// 通話開始時刻
    private var callStartTime: Date?
    
    /// 自動キャプチャ設定
    private var autoCapturingEnabled: Bool = true
    
    /// スピーカーフォン自動切り替え設定
    private var autoSpeakerEnabled: Bool = true
    
    /// ログ出力用
    private let logger = Logger(subsystem: "com.telreq.app", category: "CallManager")
    
    /// バックグラウンド処理用タスク
    #if canImport(UIKit) && !os(macOS)
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif
    
    /// 音声セッション監視タイマー
    private var sessionMonitorTimer: Timer?
    
    // MARK: - Initialization
    
    /// CallManagerの初期化
    /// - Parameters:
    ///   - audioCaptureService: 音声キャプチャサービス
    ///   - speechRecognitionService: 音声認識サービス
    ///   - textProcessingService: テキスト処理サービス
    ///   - storageService: ストレージサービス
    ///   - offlineDataManager: オフラインデータマネージャー
    init(
        audioCaptureService: AudioCaptureServiceProtocol,
        speechRecognitionService: SpeechRecognitionServiceProtocol,
        textProcessingService: TextProcessingServiceProtocol,
        storageService: StorageServiceProtocol,
        offlineDataManager: OfflineDataManagerProtocol
    ) {
        self.audioCaptureService = audioCaptureService
        self.speechRecognitionService = speechRecognitionService
        self.textProcessingService = textProcessingService
        self.storageService = storageService
        self.offlineDataManager = offlineDataManager
        
        super.init()
        
        setupCallObserver()
        setupAudioSessionNotifications()
        setupServices()
        
        logger.info("CallManager initialized")
    }
    
    deinit {
        stopMonitoring()
        logger.info("CallManager deinitialized")
    }
    
    // MARK: - Public Methods
    
    /// 通話監視を開始
    func startMonitoring() {
        logger.info("Starting call monitoring")
        
        #if canImport(CallKit) && !os(macOS)
        callObserver.setDelegate(self, queue: DispatchQueue.main)
        #endif
        startSessionMonitoring()
        
        logger.info("Call monitoring started")
    }
    
    /// 通話監視を停止
    func stopMonitoring() {
        logger.info("Stopping call monitoring")
        
        #if canImport(CallKit) && !os(macOS)
        callObserver.setDelegate(nil, queue: nil)
        #endif
        stopSessionMonitoring()
        stopCurrentCall()
        
        logger.info("Call monitoring stopped")
    }
    
    /// 手動で音声キャプチャを開始
    /// - Returns: 開始成功フラグ
    @discardableResult
    func startAudioCapture() async -> Bool {
        logger.info("Manually starting audio capture")
        
        do {
            let success = try await audioCaptureService.startCapture()
            if success {
                try await speechRecognitionService.startRealtimeRecognition()
                
                // 手動録音のための通話情報を作成
                if currentCall == nil {
                    currentCall = CallInfo(
                        id: UUID(),
                        direction: .outgoing,
                        phoneNumber: "Manual Recording",
                        startTime: Date(),
                        isConnected: true
                    )
                    callStartTime = Date()
                }
                
                logger.info("Manual audio capture started successfully")
            }
            return success
        } catch {
            logger.error("Failed to start manual audio capture: \(error.localizedDescription)")
            return false
        }
    }
    
    /// 手動で音声キャプチャを停止
    func stopAudioCapture() {
        logger.info("Manually stopping audio capture")
        
        audioCaptureService.stopCapture()
        speechRecognitionService.stopRecognition()
        
        logger.info("Manual audio capture stopped")
    }
    
    /// 手動音声キャプチャを停止して結果を保存
    func stopAudioCaptureAndSave() async {
        logger.info("Stopping manual audio capture and saving results")
        
        // 現在の通話情報がない場合は仮の情報を作成
        if currentCall == nil {
            currentCall = CallInfo(
                id: UUID(),
                direction: .outgoing,
                phoneNumber: "Manual Recording",
                startTime: callStartTime ?? Date().addingTimeInterval(-60), // 1分前と仮定
                isConnected: true
            )
        }
        
        // 音声キャプチャ停止
        stopAudioCapture()
        
        // テキスト処理と保存を実行
        await processCallTextAfterEnd()
        
        // 通話情報をクリア
        currentCall = nil
        callStartTime = nil
        
        logger.info("Manual audio capture stopped and results saved")
    }
    
    /// 自動キャプチャ設定を変更
    /// - Parameter enabled: 有効/無効フラグ
    func setAutoCapturing(_ enabled: Bool) {
        autoCapturingEnabled = enabled
        logger.info("Auto capturing set to: \(enabled)")
    }
    
    /// スピーカーフォン自動切り替え設定を変更
    /// - Parameter enabled: 有効/無効フラグ
    func setAutoSpeaker(_ enabled: Bool) {
        autoSpeakerEnabled = enabled
        logger.info("Auto speaker set to: \(enabled)")
    }
    
    /// 現在の通話を強制終了（緊急時用）
    func forceEndCurrentCall() {
        logger.warning("Force ending current call")
        stopCurrentCall()
        updateCallState(.idle)
    }
    
    /// 音声セッションを手動で設定
    func configureAudioSession() async throws {
        logger.info("Manually configuring audio session")
        try await setupAudioSessionForCall()
    }
    
    /// 通話記録を開始
    func startCallRecording() async throws {
        logger.info("Starting call recording")
        
        do {
            // 音声セッション設定
            try await setupAudioSessionForCall()
            
            // 音声キャプチャ開始
            let captureSuccess = try await audioCaptureService.startCapture()
            if !captureSuccess {
                throw AppError.audioPermissionDenied
            }
            
            // 音声認識開始
            try await speechRecognitionService.startRealtimeRecognition()
            
            // 通話状態を更新
            updateCallState(.active)
            
            logger.info("Call recording started successfully")
        } catch {
            logger.error("Failed to start call recording: \(error.localizedDescription)")
            throw error
        }
    }
    
    /// 通話記録を停止
    func stopCallRecording() async throws -> SpeechRecognitionResult {
        logger.info("Stopping call recording")
        
        // 音声キャプチャ停止
        audioCaptureService.stopCapture()
        
        // 最終的な音声認識結果を取得
        let result = try await speechRecognitionService.getFinalRecognitionResult()
        
        // 音声認識停止
        speechRecognitionService.stopRecognition()
        
        // 通話状態を更新
        updateCallState(.idle)
        
        // 通話終了後のテキスト処理を実行
        await processCallTextAfterEnd()
        
        logger.info("Call recording stopped successfully")
        return result
    }
    
    /// ワンボタンで通話記録を開始
    func startCallRecordingWithOneButton() async -> Bool {
        logger.info("Starting one-button call recording")
        
        do {
            // 音声セッション設定
            try await setupAudioSessionForCall()
            
            // 音声キャプチャ開始
            let captureSuccess = try await audioCaptureService.startCapture()
            if !captureSuccess {
                logger.error("Failed to start audio capture")
                return false
            }
            
            // 音声認識開始
            try await speechRecognitionService.startRealtimeRecognition()
            
            // 通話状態を更新
            updateCallState(.active)
            
            logger.info("One-button call recording started successfully")
            return true
        } catch {
            logger.error("Failed to start one-button call recording: \(error.localizedDescription)")
            return false
        }
    }
    
    /// 通話終了後のテキスト処理を実行
    func processCallTextAfterEnd() async {
        logger.info("Processing call text after end")
        
        guard let callInfo = currentCall else {
            logger.warning("No call info available for text processing")
            return
        }
        
        do {
            // 音声認識結果を取得
            let recognitionResult = try await speechRecognitionService.getFinalRecognitionResult()
            
            guard !recognitionResult.text.isEmpty else {
                logger.warning("No text recognized from call")
                return
            }
            
            // 通話メタデータを作成
            let metadata = CallMetadata(
                callDirection: currentCall?.direction ?? .incoming,
                audioQuality: .good,
                transcriptionMethod: .iosSpeech,
                language: "ja-JP",
                confidence: recognitionResult.confidence,
                startTime: currentCall?.startTime ?? Date(),
                endTime: Date(),
                deviceInfo: {
                    #if canImport(UIKit) && !os(macOS)
                    return DeviceInfo(
                        deviceModel: UIDevice.current.model,
                        systemVersion: UIDevice.current.systemVersion,
                        appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
                    )
                    #else
                    return DeviceInfo(
                        deviceModel: "Mac",
                        systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                        appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
                    )
                    #endif
                }(),
                networkInfo: NetworkInfo(
                    connectionType: .wifi
                )
            )
            
            // テキスト処理と構造化
            let structuredData = try await textProcessingService.structureCallData(
                recognitionResult.text,
                metadata: metadata
            )
            
            // ローカルにテキストデータを保存（1ヶ月保持）
            try await offlineDataManager.saveLocalData(structuredData)
            
            // Azureにテキストデータを保存
            let storageUrl = try await storageService.saveCallData(structuredData)
            
            // 音声ファイルをAzureにアップロード（ローカルファイルは自動削除される）
            #if canImport(AVFoundation) && !os(macOS)
            if let audioFileUrl = getCurrentAudioFileURL() {
                let audioStorageUrl = try await storageService.uploadAudioFile(audioFileUrl, for: structuredData.id.uuidString)
                logger.info("Audio file uploaded to: \(audioStorageUrl)")
            }
            #endif
            
            logger.info("Call text processed and saved successfully: \(storageUrl)")
            
            // デリゲートに通知
            delegate?.callManager(self, didCompleteTextProcessing: structuredData)
            
        } catch {
            logger.error("Failed to process call text: \(error.localizedDescription)")
            delegate?.callManager(self, didEncounterError: error)
        }
    }
    
    // MARK: - Private Methods
    
    /// CallObserverを設定
    private func setupCallObserver() {
        // CallKitのセットアップは既に実行時に自動で行われる
        logger.info("Call observer setup completed")
    }
    
    /// 音声セッション通知を設定
    private func setupAudioSessionNotifications() {
        #if canImport(AVFoundation) && !os(macOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruption),
            name: AVAudioSession.interruptionNotification,
            object: audioSession
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: audioSession
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionMediaServicesLost),
            name: AVAudioSession.mediaServicesWereLostNotification,
            object: audioSession
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionMediaServicesReset),
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: audioSession
        )
        #endif
        
        logger.info("Audio session notifications setup completed")
    }
    
    /// サービスを設定
    private func setupServices() {
        // 音声キャプチャサービスのデリゲート設定
        audioCaptureService.delegate = self
        
        // 音声認識サービスのデリゲート設定
        speechRecognitionService.delegate = self
        
        logger.info("Services setup completed")
    }
    
    /// セッション監視を開始
    private func startSessionMonitoring() {
        sessionMonitorTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.monitorAudioSession()
        }
    }
    
    /// セッション監視を停止
    private func stopSessionMonitoring() {
        sessionMonitorTimer?.invalidate()
        sessionMonitorTimer = nil
    }
    
    /// 音声セッションを監視
    private func monitorAudioSession() {
        // 通話中のみ監視
        guard callState == .active else { return }
        
        #if canImport(AVFoundation) && !os(macOS)
        // 音声ルートをチェック
        let currentRoute = audioSession.currentRoute
        let isUsingBuiltInSpeaker = currentRoute.outputs.contains { output in
            output.portType == .builtInSpeaker
        }
        
        // スピーカーフォンが無効になった場合の警告
        if !isUsingBuiltInSpeaker && autoSpeakerEnabled {
            logger.warning("Built-in speaker not active during call - audio quality may be poor")
        }
        #endif
    }
    
    /// 通話状態を更新
    private func updateCallState(_ newState: CallState) {
        let oldState = callState
        callState = newState
        
        logger.info("Call state changed: \(oldState) -> \(newState)")
        
        // デリゲートに通知
        // 通話状態の更新は新しいデリゲートメソッドでは不要
        
        // 状態に応じた処理
        switch newState {
        case .active:
            handleCallStarted()
        case .idle:
            handleCallEnded()
        case .connecting:
            handleCallConnecting()
        }
    }
    
    /// 通話開始処理
    private func handleCallStarted() {
        logger.info("Handling call started")
        
        callStartTime = Date()
        
        Task {
            do {
                // 音声セッション設定
                try await setupAudioSessionForCall()
                
                // 自動キャプチャが有効な場合
                if autoCapturingEnabled {
                    // 少し遅延させてから開始（通話安定化のため）
                    try await Task.sleep(nanoseconds: 2_000_000_000) // 2秒
                    await startAudioCapture()
                }
                
            } catch {
                logger.error("Failed to handle call started: \(error.localizedDescription)")
            }
        }
        
        // バックグラウンドタスク開始
        startBackgroundTask()
    }
    
    /// 通話終了処理
    private func handleCallEnded() {
        logger.info("Handling call ended")
        
        // 音声キャプチャ停止
        stopAudioCapture()
        
        // 通話終了後のテキスト処理を実行
        Task {
            await processCallTextAfterEnd()
        }
        
        // 通話情報をクリア
        currentCall = nil
        callStartTime = nil
        
        // バックグラウンドタスク終了
        endBackgroundTask()
        
        // 音声セッションを非アクティブ化
        Task {
            #if canImport(AVFoundation) && !os(macOS)
            do {
                try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
                logger.info("Audio session deactivated")
            } catch {
                logger.error("Failed to deactivate audio session: \(error.localizedDescription)")
            }
            #endif
        }
    }
    
    /// 通話接続中処理
    private func handleCallConnecting() {
        logger.info("Handling call connecting")
        
        // 音声セッションを準備
        Task {
            do {
                try await setupAudioSessionForCall()
            } catch {
                logger.error("Failed to setup audio session during connection: \(error.localizedDescription)")
            }
        }
    }
    
    /// 通話用音声セッションを設定
    private func setupAudioSessionForCall() async throws {
        logger.info("Setting up audio session for call")
        
        #if canImport(AVFoundation) && !os(macOS)
        try audioSession.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP, .mixWithOthers]
        )
        
        // 音質設定
        try audioSession.setPreferredSampleRate(16000)
        try audioSession.setPreferredIOBufferDuration(0.023)
        
        // セッション有効化
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        
        // スピーカーフォンに切り替え（自動設定が有効な場合）
        if autoSpeakerEnabled {
            try audioSession.overrideOutputAudioPort(.speaker)
            logger.info("Switched to speaker output")
        }
        #endif
        
        logger.info("Audio session configured for call")
    }
    
    /// 現在の通話を停止
    private func stopCurrentCall() {
        logger.info("Stopping current call")
        
        // 音声キャプチャ停止
        stopAudioCapture()
        
        // 通話終了後のテキスト処理を実行
        Task {
            await processCallTextAfterEnd()
        }
        
        // 通話情報をクリア
        currentCall = nil
        callStartTime = nil
    }
    
    /// バックグラウンドタスクを開始
    private func startBackgroundTask() {
        endBackgroundTask() // 既存のタスクを終了
        
        #if canImport(UIKit) && !os(macOS)
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "CallRecording") { [weak self] in
            self?.endBackgroundTask()
        }
        
        logger.info("Background task started: \(self.backgroundTask.rawValue)")
        #endif
    }
    
    /// バックグラウンドタスクを終了
    private func endBackgroundTask() {
        #if canImport(UIKit) && !os(macOS)
        if self.backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(self.backgroundTask)
            self.backgroundTask = .invalid
            logger.info("Background task ended")
        }
        #endif
    }
    
    /// 通話情報を作成
    #if canImport(CallKit) && !os(macOS)
    private func createCallInfo(from call: CXCall) -> CallInfo {
        let direction: CallDirection = call.isOutgoing ? .outgoing : .incoming
        let phoneNumber = call.uuid.uuidString
        
        return CallInfo(
            id: call.uuid,
            direction: direction,
            phoneNumber: phoneNumber,
            startTime: Date(),
            isConnected: call.hasConnected
        )
    }
    #endif
}

// MARK: - CXCallObserverDelegate

#if canImport(CallKit) && !os(macOS)
extension CallManager: CXCallObserverDelegate {
    
    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        logger.info("Call changed: \(call.uuid), hasConnected: \(call.hasConnected), hasEnded: \(call.hasEnded), isOutgoing: \(call.isOutgoing)")
        
        if call.hasEnded {
            // 通話終了
            if currentCall?.id == call.uuid {
                updateCallState(.idle)
            }
        } else if call.hasConnected {
            // 通話開始
            currentCall = createCallInfo(from: call)
            updateCallState(.active)
        } else {
            // 通話接続中
            currentCall = createCallInfo(from: call)
            updateCallState(.connecting)
        }
    }
}
#endif

// MARK: - AudioCaptureDelegate

extension CallManager: AudioCaptureDelegate {
    
    func audioCaptureDidStart() {
        logger.info("Audio capture started")
        if let currentCall = currentCall {
            delegate?.callManager(self, didStartCall: currentCall.id.uuidString)
        }
    }
    
    func audioCaptureDidStop() {
        logger.info("Audio capture stopped")
        if let currentCall = currentCall {
            delegate?.callManager(self, didEndCall: currentCall.id.uuidString)
        }
    }
    
    func audioCapture(didReceiveBuffer buffer: AVAudioPCMBuffer) {
        // 音声認識サービスにバッファを送信 (mock implementation)
        Task {
            do {
                _ = try await speechRecognitionService.startRecognition(audioBuffer: buffer)
            } catch {
                logger.error("Failed to process audio buffer: \(error.localizedDescription)")
            }
        }
    }
    
    func audioCapture(didUpdateLevel level: Float) {
        // 音声レベル更新をデリゲートに通知
        delegate?.callManager(self, didUpdateAudioLevel: level)
    }
    
    func audioCapture(didEncounterError error: Error) {
        logger.error("Audio capture error: \(error.localizedDescription)")
        delegate?.callManager(self, didEncounterError: error)
    }
}

// MARK: - SpeechRecognitionDelegate

extension CallManager: SpeechRecognitionDelegate {
    
    func speechRecognition(didRecognizeText text: String, isFinal: Bool) {
        delegate?.callManager(self, didRecognizeText: text, isFinal: isFinal)
    }
    
    func speechRecognition(didCompleteWithResult result: SpeechRecognitionResult) {
        logger.info("Speech recognition completed with confidence: \(result.confidence)")
        delegate?.callManager(self, didCompleteRecognition: result)
    }
    
    func speechRecognition(didFailWithError error: Error) {
        logger.error("Speech recognition error: \(error.localizedDescription)")
        delegate?.callManager(self, didEncounterError: error)
    }
    
    func speechRecognitionDidTimeout() {
        logger.warning("Speech recognition timeout")
        delegate?.callManager(self, didEncounterError: AppError.speechRecognitionFailed(underlying: 
            NSError(domain: "CallManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Recognition timeout"])
        ))
    }
}

// MARK: - Audio Session Notifications

extension CallManager {
    
    #if canImport(AVFoundation) && !os(macOS)
    @objc private func handleAudioSessionInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        logger.info("Audio session interruption: \(type.rawValue)")
        
        switch type {
        case .began:
            logger.info("Audio session interrupted")
            // 通話中の場合は何もしない（CallKitが処理）
            
        case .ended:
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else {
                return
            }
            
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) && callState == .active {
                logger.info("Resuming audio session after interruption")
                Task {
                    do {
                        try await setupAudioSessionForCall()
                    } catch {
                        logger.error("Failed to resume audio session: \(error.localizedDescription)")
                    }
                }
            }
            
        @unknown default:
            logger.warning("Unknown audio session interruption type")
        }
    }
    
    @objc private func handleAudioSessionRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }
        
        logger.info("Audio route changed: \(reason.rawValue)")
        
        switch reason {
        case .newDeviceAvailable:
            logger.info("New audio device available")
            
        case .oldDeviceUnavailable:
            logger.info("Audio device unavailable")
            
        case .categoryChange:
            logger.info("Audio category changed")
            
        case .override:
            logger.info("Audio route override")
            
        default:
            break
        }
        
        // 通話中の場合は適切な出力デバイスを確保
        if callState == .active && autoSpeakerEnabled {
            Task {
                #if canImport(AVFoundation) && !os(macOS)
                do {
                    try audioSession.overrideOutputAudioPort(.speaker)
                } catch {
                    logger.error("Failed to override audio port: \(error.localizedDescription)")
                }
                #endif
            }
        }
    }
    
    @objc private func handleAudioSessionMediaServicesLost(_ notification: Notification) {
        logger.warning("Audio media services lost")
        stopAudioCapture()
    }
    
    @objc private func handleAudioSessionMediaServicesReset(_ notification: Notification) {
        logger.info("Audio media services reset")
        
        if callState == .active {
            Task {
                do {
                    try await setupAudioSessionForCall()
                    if autoCapturingEnabled {
                        await startAudioCapture()
                    }
                } catch {
                    logger.error("Failed to reconfigure after media services reset: \(error.localizedDescription)")
                }
            }
        }
    }
    
    /// 現在の音声ファイルURLを取得
    private func getCurrentAudioFileURL() -> URL? {
        // 現在の実装では、AudioCaptureServiceから音声ファイルURLを取得する方法がないため、
        // 一時的な実装として、Documentsディレクトリ内の音声ファイルを探す
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let audioDirectory = documentsDirectory.appendingPathComponent("AudioFiles")
        
        do {
            let files = try FileManager.default.contentsOfDirectory(at: audioDirectory, includingPropertiesForKeys: nil)
            let audioFiles = files.filter { $0.pathExtension == "m4a" || $0.pathExtension == "wav" }
            
            // 最新の音声ファイルを返す
            return audioFiles.sorted { $0.lastPathComponent > $1.lastPathComponent }.first
        } catch {
            logger.warning("No audio files found: \(error.localizedDescription)")
            return nil
        }
    }
    #endif
}

// MARK: - Supporting Types

/// 通話状態
enum CallState: Equatable, CustomStringConvertible {
    case idle
    case connecting
    case active
    
    var description: String {
        switch self {
        case .idle:
            return "idle"
        case .connecting:
            return "connecting"
        case .active:
            return "active"
        }
    }
}

/// 通話情報
struct CallInfo {
    let id: UUID
    let direction: CallDirection
    let phoneNumber: String
    let startTime: Date
    let isConnected: Bool
}

/// CallManagerデリゲート
protocol CallManagerDelegate: AnyObject {
    /// 通話が開始された
    func callManager(_ manager: CallManager, didStartCall callId: String)
    
    /// 通話が終了された
    func callManager(_ manager: CallManager, didEndCall callId: String)
    
    /// 音声レベルが更新された
    func callManager(_ manager: CallManager, didUpdateAudioLevel level: Float)
    
    /// 音声認識テキストが取得された
    func callManager(_ manager: CallManager, didRecognizeText text: String, isFinal: Bool)
    
    /// 音声認識が完了した
    func callManager(_ manager: CallManager, didCompleteRecognition result: SpeechRecognitionResult)
    
    /// エラーが発生した
    func callManager(_ manager: CallManager, didEncounterError error: Error)
    
    /// テキスト処理が完了した
    func callManager(_ manager: CallManager, didCompleteTextProcessing data: StructuredCallData)
}

// MARK: - Debug Support

#if DEBUG
extension CallManager {
    
    /// デバッグ情報を出力
    func printDebugInfo() {
        #if canImport(AVFoundation) && !os(macOS)
        let backgroundTaskInfo = "- Background Task: \(self.backgroundTask.rawValue)"
        let audioSessionInfo = """
            - Audio Session Category: \(self.audioSession.category.rawValue)
            - Audio Session Mode: \(self.audioSession.mode.rawValue)
            """
        #else
        let backgroundTaskInfo = "- Background Task: Not available on macOS"
        let audioSessionInfo = "- Audio Session: Not available on macOS"
        #endif
        
        logger.debug("""
            CallManager Debug Info:
            - Call State: \(self.callState)
            - Current Call: \(self.currentCall?.phoneNumber ?? "none")
            - Auto Capturing: \(self.autoCapturingEnabled)
            - Auto Speaker: \(self.autoSpeakerEnabled)
            \(backgroundTaskInfo)
            \(audioSessionInfo)
            """)
    }
}
#endif