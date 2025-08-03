import Foundation
import AVFoundation
import CallKit
import os.log

/// リアルタイム音声キャプチャサービス
/// 
/// スピーカーフォン経由での音声取得、品質監視、権限管理を提供します。
/// iOS通話録音制限に対応したスピーカーフォン方式を実装しています。
final class AudioCaptureService: NSObject, AudioCaptureServiceProtocol {
    
    // MARK: - Properties
    
    /// デリゲート
    weak var delegate: AudioCaptureDelegate?
    
    /// 現在のキャプチャ状態
    private(set) var captureState: AudioCaptureState = .idle
    
    /// 現在の音声レベル（0.0-1.0）
    private(set) var audioLevel: Float = 0.0
    
    /// 音声エンジン
    private var audioEngine = AVAudioEngine()
    
    /// 音声入力ノード
    private var inputNode: AVAudioInputNode {
        return audioEngine.inputNode
    }
    
    /// 音声フォーマット
    private var audioFormat: AVAudioFormat?
    
    /// 現在の音声バッファ
    private var currentAudioBuffer: AVAudioPCMBuffer?
    
    /// バッファサイズ
    private let bufferSize: AVAudioFrameCount = 4096
    
    /// 音声品質監視用タイマー
    private var qualityMonitorTimer: Timer?
    
    /// 音声レベル計算用の累積値
    private var audioLevelAccumulator: Float = 0.0
    private var audioLevelSampleCount: Int = 0
    
    /// ログ出力用
    private let logger = Logger(subsystem: "com.telreq.app", category: "AudioCapture")
    
    /// 音声セッション
    private let audioSession = AVAudioSession.sharedInstance()
    
    // MARK: - Initialization
    
    override init() {
        super.init()
        setupAudioFormat()
        logger.info("AudioCaptureService initialized")
    }
    
    deinit {
        stopCapture()
        logger.info("AudioCaptureService deinitialized")
    }
    
    // MARK: - AudioCaptureServiceProtocol Implementation
    
    /// 音声キャプチャを開始
    /// - Returns: 開始成功フラグ
    func startCapture() async throws -> Bool {
        logger.info("Starting audio capture")
        
        // 権限チェック
        guard await checkMicrophonePermission() else {
            logger.error("Microphone permission denied")
            updateCaptureState(.error(AppError.audioPermissionDenied))
            throw AppError.audioPermissionDenied
        }
        
        updateCaptureState(.preparing)
        
        do {
            // オーディオセッション設定
            try await configureAudioSession()
            
            // オーディオエンジン設定
            try setupAudioEngine()
            
            // キャプチャ開始
            try audioEngine.start()
            
            // 品質監視開始
            startQualityMonitoring()
            
            updateCaptureState(.recording)
            
            await MainActor.run {
                delegate?.audioCaptureDidStart()
            }
            
            logger.info("Audio capture started successfully")
            return true
            
        } catch {
            logger.error("Failed to start audio capture: \(error.localizedDescription)")
            updateCaptureState(.error(error))
            throw error
        }
    }
    
    /// 音声キャプチャを停止
    func stopCapture() {
        logger.info("Stopping audio capture")
        
        // 品質監視停止
        stopQualityMonitoring()
        
        // オーディオエンジン停止
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        
        updateCaptureState(.idle)
        
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.audioCaptureDidStop()
        }
        
        logger.info("Audio capture stopped")
    }
    
    /// 現在の音声バッファを取得
    /// - Returns: 音声バッファ、利用できない場合はnil
    func getAudioBuffer() -> AVAudioPCMBuffer? {
        return currentAudioBuffer
    }
    
    /// 音声品質を監視
    /// - Returns: 現在の音声品質
    func monitorAudioQuality() -> AudioQuality {
        let currentLevel = audioLevel
        
        switch currentLevel {
        case 0.8...:
            return .excellent
        case 0.6..<0.8:
            return .good
        case 0.3..<0.6:
            return .fair
        default:
            return .poor
        }
    }
    
    /// マイクアクセス権限を確認
    /// - Returns: 権限が許可されている場合true
    func checkMicrophonePermission() async -> Bool {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }
    
    // MARK: - Private Methods
    
    /// 音声フォーマットを設定
    private func setupAudioFormat() {
        // 16kHz、16bit、モノラル設定
        audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )
    }
    
    /// オーディオセッションを設定
    private func configureAudioSession() async throws {
        logger.info("Configuring audio session")
        
        try audioSession.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
        )
        
        // サンプルレート設定
        try audioSession.setPreferredSampleRate(16000)
        
        // I/Oバッファ期間設定
        try audioSession.setPreferredIOBufferDuration(0.023)
        
        // セッション有効化
        try audioSession.setActive(true)
        
        logger.info("Audio session configured successfully")
    }
    
    /// オーディオエンジンを設定
    private func setupAudioEngine() throws {
        logger.info("Setting up audio engine")
        
        guard let format = audioFormat else {
            throw NSError(
                domain: "AudioCaptureService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Audio format not configured"]
            )
        }
        
        // 既存のタップを削除
        inputNode.removeTap(onBus: 0)
        
        // 音声バッファを作成
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: bufferSize
        ) else {
            throw NSError(
                domain: "AudioCaptureService",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create audio buffer"]
            )
        }
        
        currentAudioBuffer = buffer
        
        // 音声入力タップを設定
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, time in
            self?.processAudioBuffer(buffer, at: time)
        }
        
        // オーディオエンジンを準備
        audioEngine.prepare()
        
        logger.info("Audio engine setup completed")
    }
    
    /// 音声バッファを処理
    /// - Parameters:
    ///   - buffer: 音声バッファ
    ///   - time: タイムスタンプ
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        // 現在のバッファを更新
        currentAudioBuffer = buffer
        
        // 音声レベルを計算
        calculateAudioLevel(from: buffer)
        
        // デリゲートに通知
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.audioCapture(didReceiveBuffer: buffer)
            self.delegate?.audioCapture(didUpdateLevel: self.audioLevel)
        }
    }
    
    /// 音声レベルを計算
    /// - Parameter buffer: 音声バッファ
    private func calculateAudioLevel(from buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.int16ChannelData?[0] else { return }
        
        let frameLength = Int(buffer.frameLength)
        var sum: Float = 0.0
        
        // RMS値を計算
        for i in 0..<frameLength {
            let sample = Float(channelData[i]) / Float(Int16.max)
            sum += sample * sample
        }
        
        let rms = sqrt(sum / Float(frameLength))
        
        // 音声レベルを累積（平滑化のため）
        audioLevelAccumulator += rms
        audioLevelSampleCount += 1
        
        // 平均値を計算
        if audioLevelSampleCount >= 10 {
            audioLevel = min(audioLevelAccumulator / Float(audioLevelSampleCount), 1.0)
            audioLevelAccumulator = 0.0
            audioLevelSampleCount = 0
        }
    }
    
    /// 品質監視を開始
    private func startQualityMonitoring() {
        logger.info("Starting quality monitoring")
        
        qualityMonitorTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            let quality = self.monitorAudioQuality()
            self.logger.debug("Audio quality: \(quality.rawValue), level: \(self.audioLevel)")
            
            // 品質が低下した場合の警告
            if quality == .poor {
                self.logger.warning("Poor audio quality detected")
            }
        }
    }
    
    /// 品質監視を停止
    private func stopQualityMonitoring() {
        qualityMonitorTimer?.invalidate()
        qualityMonitorTimer = nil
        logger.info("Quality monitoring stopped")
    }
    
    /// キャプチャ状態を更新
    /// - Parameter newState: 新しい状態
    private func updateCaptureState(_ newState: AudioCaptureState) {
        let oldState = captureState
        captureState = newState
        
        logger.info("Capture state changed: \(oldState) -> \(newState)")
        
        // エラー状態の場合、デリゲートに通知
        if case .error(let error) = newState {
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.audioCapture(didEncounterError: error)
            }
        }
    }
}

// MARK: - AVAudioSession Notifications

extension AudioCaptureService {
    
    /// AVAudioSession通知の監視を開始
    private func startAudioSessionMonitoring() {
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
    }
    
    /// オーディオセッション割り込み処理
    @objc private func handleAudioSessionInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        logger.info("Audio session interruption: \(type.rawValue)")
        
        switch type {
        case .began:
            logger.info("Audio session interrupted - pausing capture")
            if captureState == .recording {
                updateCaptureState(.paused)
            }
            
        case .ended:
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else {
                return
            }
            
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                logger.info("Audio session interruption ended - resuming capture")
                Task {
                    do {
                        _ = try await startCapture()
                    } catch {
                        logger.error("Failed to resume capture after interruption: \(error.localizedDescription)")
                    }
                }
            }
            
        @unknown default:
            logger.warning("Unknown audio session interruption type")
        }
    }
    
    /// オーディオルート変更処理
    @objc private func handleAudioSessionRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }
        
        logger.info("Audio route changed: \(reason.rawValue)")
        
        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable:
            // デバイス変更時は音声設定を再構成
            Task {
                do {
                    try await configureAudioSession()
                    logger.info("Audio session reconfigured for route change")
                } catch {
                    logger.error("Failed to reconfigure audio session: \(error.localizedDescription)")
                }
            }
            
        default:
            break
        }
    }
}

// MARK: - Error Handling

extension AudioCaptureService {
    
    /// エラーハンドリング用のヘルパーメソッド
    private func handleError(_ error: Error, context: String) {
        logger.error("Error in \(context): \(error.localizedDescription)")
        updateCaptureState(.error(error))
    }
}

// MARK: - Debug Support

#if DEBUG
extension AudioCaptureService {
    
    /// デバッグ情報を出力
    func printDebugInfo() {
        logger.debug("""
            AudioCaptureService Debug Info:
            - State: \(captureState)
            - Audio Level: \(audioLevel)
            - Engine Running: \(audioEngine.isRunning)
            - Sample Rate: \(audioFormat?.sampleRate ?? 0)
            - Channels: \(audioFormat?.channelCount ?? 0)
            """)
    }
}
#endif