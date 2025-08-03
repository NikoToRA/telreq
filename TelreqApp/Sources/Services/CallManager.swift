import Foundation
import AVFoundation
import CallKit
import Contacts
import os.log

/// 通話管理サービス
/// 
/// AVAudioSessionの設定、通話状態の監視、自動音声キャプチャ開始/停止を管理します。
/// CallKitとの連携により、システム通話イベントを監視し、適切なタイミングで
/// 音声キャプチャと音声認識を制御します。
final class CallManager: NSObject, ObservableObject {
    
    // MARK: - Properties
    
    /// 通話状態の監視デリゲート
    weak var delegate: CallManagerDelegate?
    
    /// 現在の通話状態
    @Published private(set) var callState: CallState = .idle
    
    /// 音声キャプチャサービス
    private let audioCaptureService: AudioCaptureServiceProtocol
    
    /// 音声認識サービス
    private let speechRecognitionService: SpeechRecognitionServiceProtocol
    
    /// CallKit関連
    private let callObserver = CXCallObserver()
    
    /// 音声セッション
    private let audioSession = AVAudioSession.sharedInstance()
    
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
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    
    /// 音声セッション監視タイマー
    private var sessionMonitorTimer: Timer?
    
    // MARK: - Initialization
    
    /// CallManagerの初期化
    /// - Parameters:
    ///   - audioCaptureService: 音声キャプチャサービス
    ///   - speechRecognitionService: 音声認識サービス
    init(
        audioCaptureService: AudioCaptureServiceProtocol,
        speechRecognitionService: SpeechRecognitionServiceProtocol
    ) {
        self.audioCaptureService = audioCaptureService
        self.speechRecognitionService = speechRecognitionService
        
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
        
        callObserver.setDelegate(self, queue: DispatchQueue.main)
        startSessionMonitoring()
        
        logger.info("Call monitoring started")
    }
    
    /// 通話監視を停止
    func stopMonitoring() {
        logger.info("Stopping call monitoring")
        
        callObserver.setDelegate(nil, queue: nil)
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
    
    // MARK: - Private Methods
    
    /// CallObserverを設定
    private func setupCallObserver() {
        // CallKitのセットアップは既に実行時に自動で行われる
        logger.info("Call observer setup completed")
    }
    
    /// 音声セッション通知を設定
    private func setupAudioSessionNotifications() {
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
        
        // 音声ルートをチェック
        let currentRoute = audioSession.currentRoute
        let isUsingBuiltInSpeaker = currentRoute.outputs.contains { output in
            output.portType == .builtInSpeaker
        }
        
        // スピーカーフォンが無効になった場合の警告
        if !isUsingBuiltInSpeaker && autoSpeakerEnabled {
            logger.warning("Built-in speaker not active during call - audio quality may be poor")
        }
    }
    
    /// 通話状態を更新
    private func updateCallState(_ newState: CallState) {
        let oldState = callState
        callState = newState
        
        logger.info("Call state changed: \(oldState) -> \(newState)")
        
        // デリゲートに通知
        delegate?.callManager(self, didUpdateCallState: newState)
        
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
        
        // 通話情報をクリア
        currentCall = nil
        callStartTime = nil
        
        // バックグラウンドタスク終了
        endBackgroundTask()
        
        // 音声セッションを非アクティブ化
        Task {
            do {
                try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
                logger.info("Audio session deactivated")
            } catch {
                logger.error("Failed to deactivate audio session: \(error.localizedDescription)")
            }
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
        
        logger.info("Audio session configured for call")
    }
    
    /// 現在の通話を停止
    private func stopCurrentCall() {
        logger.info("Stopping current call")
        
        stopAudioCapture()
        currentCall = nil
        callStartTime = nil
    }
    
    /// バックグラウンドタスクを開始
    private func startBackgroundTask() {
        endBackgroundTask() // 既存のタスクを終了
        
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "CallRecording") { [weak self] in
            self?.endBackgroundTask()
        }
        
        logger.info("Background task started: \(backgroundTask.rawValue)")
    }
    
    /// バックグラウンドタスクを終了
    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
            logger.info("Background task ended")
        }
    }
    
    /// 通話情報を作成
    private func createCallInfo(from call: CXCall) -> CallInfo {
        let direction: CallDirection = call.isOutgoing ? .outgoing : .incoming
        let phoneNumber = call.remoteHandle?.value ?? "Unknown"
        
        return CallInfo(
            id: call.uuid,
            direction: direction,
            phoneNumber: phoneNumber,
            startTime: Date(),
            isConnected: call.hasConnected
        )
    }
}

// MARK: - CXCallObserverDelegate

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

// MARK: - AudioCaptureDelegate

extension CallManager: AudioCaptureDelegate {
    
    func audioCaptureDidStart() {
        logger.info("Audio capture started")
        delegate?.callManagerDidStartAudioCapture(self)
    }
    
    func audioCaptureDidStop() {
        logger.info("Audio capture stopped")
        delegate?.callManagerDidStopAudioCapture(self)
    }
    
    func audioCapture(didReceiveBuffer buffer: AVAudioPCMBuffer) {
        // 音声認識サービスにバッファを送信
        speechRecognitionService.addAudioBuffer(buffer)
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
                do {
                    try audioSession.overrideOutputAudioPort(.speaker)
                } catch {
                    logger.error("Failed to override audio port: \(error.localizedDescription)")
                }
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
    /// 通話状態が変更された
    func callManager(_ manager: CallManager, didUpdateCallState state: CallState)
    
    /// 音声キャプチャが開始された
    func callManagerDidStartAudioCapture(_ manager: CallManager)
    
    /// 音声キャプチャが停止された
    func callManagerDidStopAudioCapture(_ manager: CallManager)
    
    /// 音声レベルが更新された
    func callManager(_ manager: CallManager, didUpdateAudioLevel level: Float)
    
    /// 音声認識テキストが取得された
    func callManager(_ manager: CallManager, didRecognizeText text: String, isFinal: Bool)
    
    /// 音声認識が完了した
    func callManager(_ manager: CallManager, didCompleteRecognition result: SpeechRecognitionResult)
    
    /// エラーが発生した
    func callManager(_ manager: CallManager, didEncounterError error: Error)
}

// MARK: - Debug Support

#if DEBUG
extension CallManager {
    
    /// デバッグ情報を出力
    func printDebugInfo() {
        logger.debug("""
            CallManager Debug Info:
            - Call State: \(callState)
            - Current Call: \(currentCall?.phoneNumber ?? "none")
            - Auto Capturing: \(autoCapturingEnabled)
            - Auto Speaker: \(autoSpeakerEnabled)
            - Background Task: \(backgroundTask.rawValue)
            - Audio Session Category: \(audioSession.category.rawValue)
            - Audio Session Mode: \(audioSession.mode.rawValue)
            """)
    }
}
#endif