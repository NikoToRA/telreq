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
    private let audioCaptureService: AudioCaptureService
    
    /// 音声認識サービス
    private let speechRecognitionService: SpeechRecognitionService
    
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
    
    /// 処理状態フラグ（重複処理防止）
    private var isProcessingResult = false
    private let processingQueue = DispatchQueue(label: "com.telreq.processing", qos: .userInitiated)
    
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
        audioCaptureService: AudioCaptureService,
        speechRecognitionService: SpeechRecognitionService,
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
        logger.info("CallManager deinitializing")
        stopMonitoring()
        cleanupServices()
        
        // 通知の監視を停止
        NotificationCenter.default.removeObserver(self)
        
        logger.info("CallManager deinitialized")
    }
    
    // MARK: - Service Setup
    
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
            // 手動録音のための通話情報を作成（先に作成）
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
            
            // 音声キャプチャ開始
            let success = try await audioCaptureService.startCapture()
            if success {
                // 少し遅延させてから音声認識を開始（安定化のため）
                try await Task.sleep(nanoseconds: 500_000_000) // 0.5秒
                
                do {
                    try await speechRecognitionService.startRealtimeRecognition()
                    logger.info("Manual audio capture and speech recognition started successfully")
                } catch {
                    logger.warning("Speech recognition failed to start, but audio capture is running: \(error.localizedDescription)")
                    // 音声認識が失敗しても音声キャプチャは継続
                }
            }
            return success
        } catch {
            // サイレントにエラー処理
            
            // エラー時はクリーンアップ
            currentCall = nil
            callStartTime = nil
            
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
            // サイレントにエラー処理
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
                // サイレントにエラー処理
                return false
            }
            
            // 音声認識開始
            try await speechRecognitionService.startRealtimeRecognition()
            
            // 通話状態を更新
            updateCallState(.active)
            
            logger.info("One-button call recording started successfully")
            return true
        } catch {
            // サイレントにエラー処理
            return false
        }
    }
    
    /// 通話終了後のテキスト処理を実行
    func processCallTextAfterEnd() async {
        logger.info("Processing call text after end")
        
        guard currentCall != nil else {
            logger.warning("No call info available for text processing")
            return
        }
        
        do {
            // 設定からtranscription方法を取得
            let selectedTranscriptionMethod = getSelectedTranscriptionMethod()
            logger.info("Using transcription method: \(selectedTranscriptionMethod.displayName)")
            
            // 選択された方法にSpeechRecognitionServiceを切り替え
            speechRecognitionService.switchTranscriptionMethod(selectedTranscriptionMethod)
            
            // 音声認識結果を取得
            let recognitionResult = try await speechRecognitionService.getFinalRecognitionResult()
            
            guard !recognitionResult.text.isEmpty else {
                logger.warning("No text recognized from call")
                return
            }
            
            // 通話メタデータを作成（選択された転写方法を使用）
            let metadata = CallMetadata(
                callDirection: currentCall?.direction ?? .incoming,
                audioQuality: .good,
                transcriptionMethod: selectedTranscriptionMethod,
                language: "ja-JP",
                confidence: recognitionResult.confidence,
                startTime: currentCall?.startTime ?? Date(),
                endTime: Date(),
                deviceInfo: await createDeviceInfo(),
                networkInfo: NetworkInfo(
                    connectionType: .wifi
                )
            )
            
            // 通話時間を計算
            let callDuration = callStartTime != nil ? Date().timeIntervalSince(callStartTime!) : 0
            
            // テキスト処理と構造化
            let structuredData = try await textProcessingService.structureCallData(
                recognitionResult.text,
                metadata: metadata
            )
            
            // 通話時間と参加者番号を更新したStructuredCallDataを作成
            let updatedStructuredData = StructuredCallData(
                id: structuredData.id,
                timestamp: structuredData.timestamp,
                duration: callDuration,
                participantNumber: currentCall?.phoneNumber ?? "Manual Recording",
                audioFileUrl: structuredData.audioFileUrl,
                transcriptionText: structuredData.transcriptionText,
                summary: structuredData.summary,
                metadata: structuredData.metadata,
                isShared: structuredData.isShared,
                sharedWith: structuredData.sharedWith
            )
            
            // ローカルにテキストデータを保存（1ヶ月保持）
            try await offlineDataManager.saveLocalData(updatedStructuredData)
            
            // Azureにテキストデータを保存
            let storageUrl = try await storageService.saveCallData(updatedStructuredData)
            
            // 音声ファイルをAzureにアップロード（ローカルファイルは自動削除される）
            #if canImport(AVFoundation) && !os(macOS)
            if let audioFileUrl = getCurrentAudioFileURL() {
                let audioStorageUrl = try await storageService.uploadAudioFile(audioFileUrl, for: updatedStructuredData.id.uuidString)
                logger.info("Audio file uploaded to: \(audioStorageUrl)")
            }
            #endif
            
            logger.info("Call text processed and saved successfully: \(storageUrl), Duration: \(callDuration)s")
            
            // デリゲートに通知 - 現在のプロトコルに合わせて修正
            // delegate?.callManager(didCompleteCallProcessing: updatedStructuredData, summary: updatedStructuredData.summary)
            
        } catch {
            logger.error("Failed to process call text: \(error.localizedDescription)")
            delegate?.callManager(didFailWithError: error)
        }
    }
    
    // MARK: - Private Methods
    
    /// MainActorでDeviceInfo作成
    @MainActor
    private func createDeviceInfo() -> DeviceInfo {
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
    }
    
    /// 設定からtranscription方法を取得
    private func getSelectedTranscriptionMethod() -> TranscriptionMethod {
        guard let savedMethodString = UserDefaults.standard.string(forKey: "selectedTranscriptionMethod"),
              let method = TranscriptionMethod(rawValue: savedMethodString) else {
            // デフォルトはiOS Speech Framework（iOS優先の方針に従って）
            return .iosSpeech
        }
        return method
    }
    
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
        // 音声キャプチャサービスのデリゲート設定（循環参照を避けるため弱参照を確実に使用）
        audioCaptureService.delegate = self
        logger.info("AudioCaptureService delegate set")
        
        // 音声認識サービスのデリゲート設定（循環参照を避けるため弱参照を確実に使用）
        speechRecognitionService.delegate = self
        logger.info("SpeechRecognitionService delegate set")
        
        logger.info("Services setup completed")
    }
    
    /// サービスのクリーンアップ
    private func cleanupServices() {
        logger.info("Cleaning up services")
        
        // 音声キャプチャを安全に停止
        if callState == .active {
            stopAudioCapture()
        }
        
        // デリゲートを明示的にnilに設定
        audioCaptureService.delegate = nil
        speechRecognitionService.delegate = nil
        
        logger.info("Services cleanup completed")
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
    
    /// 通話状態を更新 - SwiftUI安全版
    private func updateCallState(_ newState: CallState) {
        let oldState = callState
        
        // @Published プロパティの更新は必ずMainActorで実行
        Task { @MainActor in
            self.callState = newState
            
            self.logger.info("Call state changed: \(oldState) -> \(newState)")
            
            // 状態に応じた処理もMainActorで安全に実行
            switch newState {
            case .active:
                await self.handleCallStartedSafely()
            case .idle:
                await self.handleCallEndedSafely()
            case .connecting:
                await self.handleCallConnectingSafely()
            }
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
    
    /// 通話開始処理 - SwiftUI安全版
    @MainActor
    private func handleCallStartedSafely() async {
        logger.info("Handling call started safely")
        
        callStartTime = Date()
        
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
        
        // バックグラウンドタスク開始
        startBackgroundTask()
    }
    
    /// 通話終了処理 - SwiftUI安全版
    @MainActor
    private func handleCallEndedSafely() async {
        logger.info("Handling call ended safely")
        
        // 音声キャプチャ停止
        stopAudioCapture()
        
        // 通話終了後のテキスト処理を実行
        await processCallTextAfterEnd()
        
        // 通話情報をクリア
        currentCall = nil
        callStartTime = nil
        
        // バックグラウンドタスク終了
        endBackgroundTask()
        
        // 音声セッションを非アクティブ化
        #if canImport(AVFoundation) && !os(macOS)
        do {
            try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            logger.info("Audio session deactivated")
        } catch {
            logger.error("Failed to deactivate audio session: \(error.localizedDescription)")
        }
        #endif
    }
    
    /// 通話接続中処理 - SwiftUI安全版
    @MainActor
    private func handleCallConnectingSafely() async {
        logger.info("Handling call connecting safely")
        
        // 音声セッションを準備
        do {
            try await setupAudioSessionForCall()
        } catch {
            logger.error("Failed to setup audio session during connection: \(error.localizedDescription)")
        }
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

// MARK: - AudioCaptureDelegate Implementation

extension CallManager: AudioCaptureDelegate {
    func audioCaptureDidStart() {
        logger.info("Audio capture started - beginning speech recognition data accumulation")
    }
    
    func audioCaptureDidStop() {
        logger.info("Audio capture stopped - will process accumulated speech data")
        
        // 録音停止時にSTT処理を実行
        Task {
            await processRecordedAudio()
        }
    }
    
    /// 録音された音声データを処理
    private func processRecordedAudio() async {
        logger.info("Starting speech recognition processing of recorded audio")
        
        do {
            // SpeechRecognitionServiceで最終的な音声認識結果を取得
            let result = try await speechRecognitionService.getFinalRecognitionResult()
            logger.info("Speech recognition successful: \(result.text.prefix(50))...")
            
            // 結果をデリゲートメソッドに渡して処理（重複防止済み）
            await handleSpeechRecognitionResult(result)
            
        } catch {
            logger.error("Speech recognition processing failed: \(error.localizedDescription)")
            
            // エラーの場合もフォールバック結果を作成
            let fallbackResult = SpeechRecognitionResult(
                text: "音声認識に失敗しました",
                confidence: 0.0,
                method: .azureSpeech,
                language: "ja-JP",
                processingTime: 0,
                segments: []
            )
            
            await handleSpeechRecognitionResult(fallbackResult)
        }
    }
    
    func audioCapture(didReceiveBuffer buffer: AVAudioPCMBuffer) {
        // 音声バッファをSpeechRecognitionServiceに送信して蓄積
        speechRecognitionService.accumulateAudioData(buffer)
    }
    
    func audioCapture(didUpdateLevel level: Float) {
        // 音声レベルの更新（必要に応じて）
    }
    
    func audioCapture(didEncounterError error: Error) {
        logger.error("Audio capture error: \(error.localizedDescription)")
    }
}

// MARK: - SpeechRecognitionDelegate Implementation

extension CallManager: SpeechRecognitionDelegate {
    func speechRecognition(didRecognizeText text: String, isFinal: Bool) {
        // リアルタイム認識は無効化しているため、何もしない
        logger.info("Speech recognition text received (ignored): \(text.prefix(50))...")
    }
    
    func speechRecognition(didCompleteWithResult result: SpeechRecognitionResult) {
        logger.info("Speech recognition completed: \(result.text.prefix(50))...")
        // 完了した音声認識結果を処理（重複防止済み）
        Task {
            await handleSpeechRecognitionResult(result)
        }
    }
    
    func speechRecognition(didFailWithError error: Error) {
        logger.error("Speech recognition failed: \(error.localizedDescription)")
    }
    
    func speechRecognitionDidTimeout() {
        logger.warning("Speech recognition timed out")
    }
    
    /// 音声認識結果を処理 - SwiftUI安全版（重複防止）
    private func handleSpeechRecognitionResult(_ result: SpeechRecognitionResult) async {
        // 重複処理を防ぐためのチェック
        return await withCheckedContinuation { continuation in
            processingQueue.async { [weak self] in
                guard let self = self, !self.isProcessingResult else {
                    continuation.resume()
                    return
                }
                
                self.isProcessingResult = true
                self.logger.info("🔄 Processing speech recognition result (length: \(result.text.count))")
                
                Task { [weak self] in
                    await self?.performSpeechProcessing(result)
                    
                    self?.processingQueue.async { [weak self] in
                        self?.isProcessingResult = false
                        continuation.resume()
                    }
                }
            }
        }
    }
    
    /// 実際の音声処理を実行
    private func performSpeechProcessing(_ result: SpeechRecognitionResult) async {
        do {
            // 1. AI要約を実行 - エラーハンドリング強化
            logger.info("📝 Starting text summarization for text length: \(result.text.count)")
            let summary = try await AsyncDebugHelpers.shared.trackAsyncTask(
                {
                    try await self.textProcessingService.summarizeText(result.text)
                },
                name: "TextSummarization"
            )
            
            // 2. 通話メタデータを作成
            let metadata = createCallMetadata()
            
            // 3. 構造化された通話データを作成
            let structuredData = try await textProcessingService.structureCallData(result.text, metadata: metadata)
            
            // 4. ローカルに保存（オフライン対応）
            try await saveCallDataLocally(structuredData)
            
            // 5. クラウドストレージに保存（利用可能な場合）
            await saveCallDataToCloud(structuredData)
            
            // 6. UIに結果を通知（ポップアップ表示用）
            await notifyCallProcessingComplete(structuredData, summary: summary)
            
            logger.info("Call processing completed successfully")
            
        } catch {
            logger.error("Failed to process call data: \(error.localizedDescription)")
            
            // エラーの場合も基本的な保存は実行
            let fallbackMetadata = createCallMetadata()
            let fallbackSummary = CallSummary(
                keyPoints: ["音声認識完了"],
                summary: "音声認識は完了しましたが、AI処理に失敗しました",
                duration: 0,
                participants: ["Unknown"],
                actionItems: [],
                tags: [],
                confidence: result.confidence
            )
            
            let fallbackData = StructuredCallData(
                timestamp: Date(),
                duration: 0,
                participantNumber: currentCall?.phoneNumber ?? "Unknown",
                audioFileUrl: "",
                transcriptionText: result.text,
                summary: fallbackSummary,
                metadata: fallbackMetadata
            )
            
            do {
                try await saveCallDataLocally(fallbackData)
                await notifyCallProcessingComplete(fallbackData, summary: fallbackData.summary)
            } catch {
                logger.error("Failed to save fallback data: \(error.localizedDescription)")
            }
        }
    }
    
    /// 通話メタデータを作成
    private func createCallMetadata() -> CallMetadata {
        let deviceInfo = DeviceInfo(
            deviceModel: "iOS Simulator",
            systemVersion: "18.5",
            appVersion: "1.0.0"
        )
        
        let networkInfo = NetworkInfo(
            connectionType: .wifi,
            signalStrength: 100
        )
        
        // 設定から転写方法を取得
        let selectedTranscriptionMethod = getSelectedTranscriptionMethod()
        
        return CallMetadata(
            callDirection: currentCall?.direction ?? .incoming,
            audioQuality: .good,
            transcriptionMethod: selectedTranscriptionMethod,
            language: "ja-JP",
            confidence: 0.8,
            startTime: callStartTime ?? Date(),
            endTime: Date(),
            deviceInfo: deviceInfo,
            networkInfo: networkInfo
        )
    }
    
    /// 通話データをローカルに保存
    private func saveCallDataLocally(_ data: StructuredCallData) async throws {
        logger.info("Saving local data for call ID: \(data.id)")
        try await offlineDataManager.saveLocalData(data)
        logger.info("Successfully saved call data locally")
    }
    
    /// 通話データをクラウドに保存
    private func saveCallDataToCloud(_ data: StructuredCallData) async {
        do {
            logger.info("Attempting to save call data to cloud storage")
            let _ = try await storageService.saveCallData(data)
            logger.info("Successfully saved call data to cloud")
        } catch {
            logger.warning("Failed to save to cloud storage: \(error.localizedDescription)")
            // クラウド保存に失敗してもエラーにはしない（オフライン対応）
        }
    }
    
    /// 通話処理完了をUIに通知
    private func notifyCallProcessingComplete(_ data: StructuredCallData, summary: CallSummary) async {
        logger.info("Notifying UI of call processing completion")
        
        await MainActor.run {
            // デリゲートに通知（ViewModelが受け取る）
            delegate?.callManager(didCompleteCallProcessing: data, summary: summary)
        }
    }
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