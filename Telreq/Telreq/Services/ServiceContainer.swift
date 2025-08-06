import Foundation
import os.log
import AVFoundation

/// サービスコンテナ
///
/// アプリケーション全体で使用するサービスのインスタンス管理と依存性注入を提供します。
final class ServiceContainer: ObservableObject {
    
    // MARK: - Properties
    
    /// ログ出力用
    private let logger = Logger(subsystem: "com.telreq.app", category: "ServiceContainer")
    
    // MARK: - Azure Configurations
    
    /// Azureサービスの認証情報
    /// - Important: このキーはプロダクションビルドに含めないでください。
    ///              CI/CDプロセスやセキュアな設定管理システムから注入することを推奨します。
    private lazy var azureKeys: AzureKeys = {
        let keys = AzureConfig.loadFromEnvironment()
        AzureConfig.logConfigurationStatus(keys)
        return keys
    }()
    
    private lazy var azureStorageConfig: AzureStorageConfig = {
        AzureStorageConfig(
            connectionString: azureKeys.storageConnectionString,
            containerName: "telreq-data" // 例: コンテナ名
        )
    }()
    
    private lazy var azureSpeechConfig: AzureSpeechConfig = {
        // リージョンは環境変数から取得するか、デフォルト値を使用
        let region = ProcessInfo.processInfo.environment["AZURE_SPEECH_REGION"] ?? "japaneast"
        
        logger.info("Speech Configuration - Region: \(region)")
        
        return AzureSpeechConfig(
            subscriptionKey: azureKeys.speechSubscriptionKey,
            region: region
        )
    }()
    
    private lazy var azureOpenAIConfig: AzureOpenAIConfig = {
        let endpointString = azureKeys.openAIEndpoint
        let endpoint = URL(string: endpointString) ?? URL(string: "https://telreq.openai.azure.com/")!
        
        // デプロイメント名は環境変数から取得するか、デフォルト値を使用
        let deploymentName = ProcessInfo.processInfo.environment["AZURE_OPENAI_DEPLOYMENT_NAME"] ?? "gpt-35-turbo"
        
        logger.info("OpenAI Configuration - Endpoint: \(endpoint), Deployment: \(deploymentName)")
        
        return AzureOpenAIConfig(
            endpoint: endpoint,
            apiKey: azureKeys.openAIAPIKey,
            deploymentName: deploymentName
        )
    }()

    
    // MARK: - Service Definitions
    
    /// 暗号化サービス
    lazy var encryptionService: EncryptionServiceProtocol = {
        return EncryptionService(useSecureEnclave: true)
    }()
    
    /// オフラインデータマネージャー
    lazy var offlineDataManager: OfflineDataManagerProtocol = {
        return OfflineDataManager()
    }()
    
    /// Azure ストレージサービス
    lazy var azureStorageService: StorageServiceProtocol = {
        return AzureStorageService(
            config: azureStorageConfig,
            encryptionService: encryptionService,
            offlineDataManager: offlineDataManager
        )
    }()
    
    /// テキスト処理サービス
    lazy var textProcessingService: TextProcessingServiceProtocol = {
        return TextProcessingService(
            openAIConfig: azureOpenAIConfig
        )
    }()
    
    /// 音声認識サービス
    lazy var speechRecognitionService: SpeechRecognitionService = {
        return SpeechRecognitionService(azureConfig: azureSpeechConfig)
    }()
    
    /// 音声キャプチャサービス（具象型で保持）
    private let _audioCaptureService = AudioCaptureService()
    var audioCaptureService: AudioCaptureService {
        return _audioCaptureService
    }
    
    /// 通話管理サービス
    lazy var callManager: CallManagerProtocol = {
        let manager = CallManager(
            audioCaptureService: self.audioCaptureService,
            speechRecognitionService: self.speechRecognitionService,
            textProcessingService: self.textProcessingService,
            storageService: self.azureStorageService,
            offlineDataManager: self.offlineDataManager
        )
        return manager
    }()
    
    /// 共有サービス
    lazy var sharingService: SharingServiceProtocol = {
        // SharingServiceの仮実装。実際の依存関係に合わせて修正してください。
        // return SharingService(storageService: azureStorageService, encryptionService: encryptionService)
        // fatalError("SharingService is not implemented yet.")
        
        // 一時的なダミー実装
        return DummySharingService()
    }()
    
    /// シングルトンインスタンス
    static let shared = ServiceContainer()
    
    // MARK: - Initialization
    
    private init() {
        logger.info("ServiceContainer initialized")
        setupServices()
    }
    
    // MARK: - Public Methods
    
    /// 現在のユーザーを設定
    /// - Parameter userId: ユーザーID
    func setCurrentUser(_ userId: String) {
        logger.info("Setting current user: \\(userId)")
        
        if let azureService = azureStorageService as? AzureStorageService {
            azureService.setCurrentUser(userId)
        }
    }
    
    /// すべてのサービスを初期化
    func initializeServices() async throws {
        logger.info("Initializing all services")
        
        // Azure設定の検証
        guard AzureConfig.validateConfiguration(azureKeys) else {
            logger.error("Azure configuration is invalid")
            throw AppError.invalidConfiguration
        }
        
        do {
            // Azure Storage の初期化（失敗してもローカル処理で続行）
            do {
                try await azureStorageService.initializeStorage()
                logger.info("Azure Storage initialized successfully")
            } catch {
                logger.warning("Azure Storage initialization failed, continuing with local storage: \(error.localizedDescription)")
            }
            
            // 音声認識サービスの権限確認
            let speechPermission = await speechRecognitionService.checkSpeechRecognitionPermission()
            if !speechPermission {
                logger.warning("Speech recognition permission not granted")
            } else {
                logger.info("Speech recognition permission granted")
            }
            
            // 音声キャプチャサービスの初期化
            let audioPermission = await audioCaptureService.requestMicrophonePermission()
            if !audioPermission {
                logger.warning("Microphone permission not granted")
            } else {
                logger.info("Microphone permission granted")
            }
            
            logger.info("All services initialized successfully")
        } catch {
            logger.error("Failed to initialize services: \(error.localizedDescription)")
            // 重要: 権限系のエラー以外は続行
            let hasPermission = await speechRecognitionService.checkSpeechRecognitionPermission()
            if !hasPermission {
                throw error // 音声認識権限がない場合のみエラーとして扱う
            }
        }
    }
    
    /// 権限処理を考慮したサービス初期化
    func initializeServicesWithPermissionHandling() async throws {
        logger.info("Initializing services with permission handling")
        
        // Azure設定の検証（デバッグモードでは緩く）
        #if DEBUG
        if !AzureConfig.validateConfiguration(azureKeys) {
            logger.warning("Azure configuration may be incomplete in debug mode, continuing")
        }
        #else
        guard AzureConfig.validateConfiguration(azureKeys) else {
            logger.error("Azure configuration is invalid")
            throw AppError.invalidConfiguration
        }
        #endif
        
        var initializationErrors: [Error] = []
        
        // Azure Storage の初期化（失敗してもローカル処理で続行）
        do {
            try await azureStorageService.initializeStorage()
            logger.info("Azure Storage initialized successfully")
        } catch {
            logger.warning("Azure Storage initialization failed, continuing with local storage: \(error.localizedDescription)")
            initializationErrors.append(error)
        }
        
        // 音声認識サービスの権限確認
        let speechPermission = await speechRecognitionService.checkSpeechRecognitionPermission()
        if !speechPermission {
            logger.warning("Speech recognition permission not granted - limited functionality")
            initializationErrors.append(AppError.speechRecognitionUnavailable)
        } else {
            logger.info("Speech recognition permission granted")
        }
        
        // 音声キャプチャサービスの初期化
        let audioPermission = await audioCaptureService.requestMicrophonePermission()
        if !audioPermission {
            logger.warning("Microphone permission not granted - recording unavailable")
            initializationErrors.append(AppError.audioPermissionDenied)
        } else {
            logger.info("Microphone permission granted")
        }
        
        // すべての権限が拒否された場合のみエラー
        if !speechPermission && !audioPermission {
            logger.error("Critical permissions denied - app cannot function")
            throw AppError.speechRecognitionUnavailable
        }
        
        logger.info("Services initialized with \(initializationErrors.count) warnings")
        
        // 警告レベルのエラーをログ出力
        for error in initializationErrors {
            logger.warning("Initialization warning: \(error.localizedDescription)")
        }
    }
    
    /// アプリケーションがバックグラウンドに移行する際の処理
    func applicationDidEnterBackground() {
        logger.info("Application entering background")
    }
    
    /// アプリケーションがフォアグラウンドに復帰する際の処理
    func applicationWillEnterForeground() {
        logger.info("Application entering foreground")
        
        // ネットワーク状態をチェックして同期を試行
        Task {
            do {
                try await azureStorageService.syncOfflineData()
            } catch {
                logger.warning("Background sync failed: \\(error.localizedDescription)")
            }
        }
    }
    
    /// メモリ警告時の処理
    func applicationDidReceiveMemoryWarning() {
        logger.warning("Application received memory warning")
        
        Task {
            try? await offlineDataManager.clearCache()
        }
    }
    
    // MARK: - Private Methods
    
    /// サービスを設定
    private func setupServices() {
        // サービス間の相互依存関係を設定
    }
}

// MARK: - ServiceContainer Extensions

extension ServiceContainer {
    
    /// デバッグ情報を出力
    func printDebugInfo() {
        logger.debug("=== ServiceContainer Debug Info ===")
        
        #if DEBUG
        if let encryptionService = encryptionService as? EncryptionService {
            encryptionService.printDebugInfo()
        }
        
        if let speechService = speechRecognitionService as? SpeechRecognitionService {
            speechService.printDebugInfo()
        }
        
        if let textService = textProcessingService as? TextProcessingService {
            let testText = "これはテスト用のテキストです。"
            textService.printDebugInfo(for: testText)
        }
        #endif
        
        logger.debug("=== End Debug Info ===")
    }
    
    /// データベースの整合性をチェック
    func validateDatabaseIntegrity() throws {
        logger.info("Validating database integrity")
    }
    
    /// すべてのローカルデータを削除（開発用）
    func resetAllData() async throws {
        logger.warning("Resetting all data")
        
        #if DEBUG
        if let encryptionService = encryptionService as? EncryptionService {
            try encryptionService.deleteAllKeys()
        }
        
        try await offlineDataManager.clearCache() // In-memory cache clear
        
        logger.info("All data reset completed")
        #else
        logger.error("Data reset not available in production builds")
        #endif
    }
}

// MARK: - Dummy Services

/// ダミー共有サービス（開発用）
final class DummySharingService: SharingServiceProtocol {
    func requestSharing(callId: String, recipientId: String) async throws {
        // ダミー実装
    }
    
    func acceptSharingRequest(_ request: SharingRequest) async throws {
        // ダミー実装
    }
    
    func mergeSharedRecords(_ records: [CallRecord]) async throws -> CallRecord {
        // ダミー実装
        return CallRecord(from: StructuredCallData(
            timestamp: Date(),
            duration: 0,
            participantNumber: "",
            audioFileUrl: "",
            transcriptionText: "",
            summary: CallSummary(
                keyPoints: [],
                summary: "",
                duration: 0,
                participants: [],
                actionItems: [],
                tags: [],
                confidence: 0
            ),
            metadata: CallMetadata(
                callDirection: .incoming,
                audioQuality: .good,
                transcriptionMethod: .iosSpeech,
                language: "ja-JP",
                confidence: 0,
                startTime: Date(),
                endTime: Date(),
                deviceInfo: DeviceInfo(
                    deviceModel: "",
                    systemVersion: "",
                    appVersion: ""
                ),
                networkInfo: NetworkInfo(
                    connectionType: .wifi
                )
            )
        ))
    }
    
    func getSharedRecords() async throws -> [SharedCallRecord] {
        // ダミー実装
        return []
    }
    
    func getSentSharedRecords() async throws -> [SharedCallRecord] {
        // ダミー実装
        return []
    }
    
    func getSharingRequests() async throws -> [SharingRequest] {
        // ダミー実装
        return []
    }
    
    func revokeSharing(callId: String, userId: String) async throws {
        // ダミー実装
    }
    
    func searchUsers(query: String) async throws -> [UserProfile] {
        // ダミー実装
        return []
    }
}
