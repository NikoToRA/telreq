import Foundation
import os.log

/// サービスコンテナ
/// 
/// アプリケーション全体で使用するサービスのインスタンス管理と依存性注入を提供します。
final class ServiceContainer: ObservableObject {
    
    // MARK: - Properties
    
    /// ログ出力用
    private let logger = Logger(subsystem: "com.telreq.app", category: "ServiceContainer")
    
    /// 暗号化サービス
    lazy var encryptionService: EncryptionServiceProtocol = {
        return EncryptionService(useSecureEnclave: true)
    }()
    
    /// オフラインデータマネージャー
    lazy var offlineDataManager: OfflineDataManagerProtocol = {
        return OfflineDataManager(encryptionService: encryptionService)
    }()
    
    /// Azure ストレージサービス
    lazy var azureStorageService: StorageServiceProtocol = {
        return AzureStorageService(
            encryptionService: encryptionService,
            offlineDataManager: offlineDataManager
        )
    }()
    
    /// テキスト処理サービス
    lazy var textProcessingService: TextProcessingServiceProtocol = {
        return TextProcessingService()
    }()
    
    /// 音声認識サービス
    lazy var speechRecognitionService: SpeechRecognitionServiceProtocol = {
        return SpeechRecognitionService()
    }()
    
    /// 音声キャプチャサービス
    lazy var audioCaptureService: AudioCaptureServiceProtocol = {
        // 実際の実装では既存のAudioCaptureServiceを使用
        fatalError("AudioCaptureService implementation needed")
    }()
    
    /// 通話管理サービス
    lazy var callManager: CallManagerProtocol = {
        // 実際の実装では既存のCallManagerを使用
        fatalError("CallManager implementation needed")
    }()
    
    /// 共有サービス
    lazy var sharingService: SharingServiceProtocol = {
        return SharingService(
            storageService: azureStorageService,
            encryptionService: encryptionService
        )
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
        logger.info("Setting current user: \(userId)")
        
        if let azureService = azureStorageService as? AzureStorageService {
            azureService.setCurrentUser(userId)
        }
    }
    
    /// すべてのサービスを初期化
    func initializeServices() async throws {
        logger.info("Initializing all services")
        
        // 暗号化サービスのテスト
        do {
            if let encryptionService = encryptionService as? EncryptionService {
                try encryptionService.testEncryptionRoundTrip()
                logger.info("Encryption service validated")
            }
        } catch {
            logger.error("Encryption service validation failed: \(error.localizedDescription)")
            throw error
        }
        
        // 音声認識サービスの権限チェック
        if await !speechRecognitionService.checkSpeechRecognitionPermission() {
            logger.warning("Speech recognition permission not granted")
        }
        
        logger.info("All services initialized successfully")
    }
    
    /// アプリケーションがバックグラウンドに移行する際の処理
    func applicationDidEnterBackground() {
        logger.info("Application entering background")
        
        // オフラインデータマネージャーのコンテキスト保存
        if let offlineManager = offlineDataManager as? OfflineDataManager {
            try? offlineManager.saveContext()
        }
    }
    
    /// アプリケーションがフォアグラウンドに復帰する際の処理
    func applicationWillEnterForeground() {
        logger.info("Application entering foreground")
        
        // ネットワーク状態をチェックして同期を試行
        Task {
            do {
                try await azureStorageService.syncOfflineData()
            } catch {
                logger.warning("Background sync failed: \(error.localizedDescription)")
            }
        }
    }
    
    /// メモリ警告時の処理
    func applicationDidReceiveMemoryWarning() {
        logger.warning("Application received memory warning")
        
        // キャッシュをクリア
        if let offlineManager = offlineDataManager as? OfflineDataManager {
            try? offlineManager.clearCache()
        }
    }
    
    // MARK: - Private Methods
    
    /// サービスを設定
    private func setupServices() {
        // サービス間の相互依存関係を設定
        // 実際の実装では必要に応じて設定
    }
}

// MARK: - Call Manager Protocol (Placeholder)

/// 通話管理プロトコル（プレースホルダー）
protocol CallManagerProtocol {
    func startCall() async throws
    func endCall() async throws
    func getCurrentCall() -> CallSession?
}

/// 通話セッション（プレースホルダー）
struct CallSession {
    let id: UUID
    let startTime: Date
    var endTime: Date?
    let participantNumber: String
}

// MARK: - Sharing Service Implementation

/// 共有サービス実装
final class SharingService: SharingServiceProtocol {
    
    private let storageService: StorageServiceProtocol
    private let encryptionService: EncryptionServiceProtocol
    private let logger = Logger(subsystem: "com.telreq.app", category: "SharingService")
    
    init(storageService: StorageServiceProtocol, encryptionService: EncryptionServiceProtocol) {
        self.storageService = storageService
        self.encryptionService = encryptionService
    }
    
    func requestSharing(callId: String, recipientId: String) async throws {
        logger.info("Requesting to share call \(callId) with \(recipientId)")
        try await storageService.shareCallRecord(callId, with: recipientId)
    }
    
    func acceptSharingRequest(_ request: SharingRequest) async throws {
        logger.info("Accepting sharing request: \(request.id)")
        // 実装例：共有承認のロジック
    }
    
    func mergeSharedRecords(_ records: [CallRecord]) async throws -> CallRecord {
        logger.info("Merging \(records.count) shared records")
        // 実装例：複数の共有記録をマージするロジック
        return records.first!
    }
    
    func getSharedRecords() async throws -> [SharedCallRecord] {
        logger.info("Getting shared records")
        // 実装例：共有記録を取得するロジック
        return []
    }
    
    func revokeSharing(callId: String, userId: String) async throws {
        logger.info("Revoking sharing for call \(callId) from user \(userId)")
        // 実装例：共有を取り消すロジック
    }
    
    func searchUsers(query: String) async throws -> [UserProfile] {
        logger.info("Searching users with query: \(query)")
        // 実装例：ユーザー検索のロジック
        return []
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
        
        if let offlineManager = offlineDataManager as? OfflineDataManager {
            offlineManager.printDebugInfo()
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
        
        #if DEBUG
        if let offlineManager = offlineDataManager as? OfflineDataManager {
            try offlineManager.validateDatabaseIntegrity()
        }
        #endif
        
        logger.info("Database integrity validation completed")
    }
    
    /// すべてのローカルデータを削除（開発用）
    func resetAllData() throws {
        logger.warning("Resetting all data")
        
        #if DEBUG
        // 暗号化キーを削除
        if let encryptionService = encryptionService as? EncryptionService {
            try encryptionService.deleteAllKeys()
        }
        
        // ローカルデータを削除
        if let offlineManager = offlineDataManager as? OfflineDataManager {
            try offlineManager.deleteAllLocalData()
        }
        
        logger.info("All data reset completed")
        #else
        logger.error("Data reset not available in production builds")
        throw NSError(domain: "ServiceContainer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Data reset not available in production"])
        #endif
    }
}

// MARK: - Missing Protocol Extensions

extension SpeechRecognitionService {
    
    /// 音声認識権限をチェック（プレースホルダー実装）
    func checkSpeechRecognitionPermission() async -> Bool {
        // 実際の実装では適切な権限チェックを行う
        return true
    }
}