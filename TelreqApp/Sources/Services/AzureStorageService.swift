import Foundation
import AzureStorageBlob
import os.log

/// Azure Blob Storage統合サービス
/// 
/// ユーザー別データ階層化、音声ファイル・転写テキスト・メタデータの保存/取得、
/// オフライン対応とローカルキャッシュ、暗号化されたデータアップロード/ダウンロードを提供します。
final class AzureStorageService: NSObject, StorageServiceProtocol {
    
    // MARK: - Properties
    
    /// Azure Blob Storage クライアント
    private var blobServiceClient: BlobServiceClient?
    
    /// 暗号化サービス
    private let encryptionService: EncryptionServiceProtocol
    
    /// オフラインデータマネージャー
    private let offlineDataManager: OfflineDataManagerProtocol
    
    /// ストレージの状態
    private(set) var storageState: StorageState = .offline
    
    /// Azure設定情報
    private var azureConfig: AzureStorageConfig
    
    /// ログ出力用
    private let logger = Logger(subsystem: "com.telreq.app", category: "AzureStorage")
    
    /// ネットワーク監視
    private var networkMonitor: NetworkMonitor?
    
    /// 現在のユーザーID
    private var currentUserId: String?
    
    /// バックグラウンドタスクID
    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
    
    /// アップロード進行状況のトラッキング
    private var uploadTasks: [String: URLSessionUploadTask] = [:]
    
    /// ダウンロード進行状況のトラッキング
    private var downloadTasks: [String: URLSessionDownloadTask] = [:]
    
    /// URLSession (バックグラウンド対応)
    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.telreq.app.azure-storage")
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.shouldUseExtendedBackgroundIdleMode = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    
    // MARK: - Initialization
    
    init(
        encryptionService: EncryptionServiceProtocol,
        offlineDataManager: OfflineDataManagerProtocol,
        config: AzureStorageConfig? = nil
    ) {
        self.encryptionService = encryptionService
        self.offlineDataManager = offlineDataManager
        self.azureConfig = config ?? AzureStorageConfig.loadFromEnvironment()
        
        super.init()
        
        setupAzureClient()
        setupNetworkMonitoring()
        
        logger.info("AzureStorageService initialized")
    }
    
    deinit {
        networkMonitor?.stopMonitoring()
        logger.info("AzureStorageService deinitialized")
    }
    
    // MARK: - StorageServiceProtocol Implementation
    
    /// 通話データを保存
    /// - Parameter data: 保存する通話データ
    /// - Returns: 保存されたデータのID
    func saveCallData(_ data: StructuredCallData) async throws -> String {
        logger.info("Saving call data: \(data.id)")
        
        guard let userId = currentUserId else {
            throw AppError.invalidConfiguration
        }
        
        do {
            // データを暗号化
            let jsonData = try JSONEncoder().encode(data)
            let encryptedData = try encryptionService.encrypt(data: jsonData)
            
            // Azure Blob Storageのパスを構築
            let blobPath = buildBlobPath(userId: userId, callId: data.id.uuidString, type: .callData)
            
            if storageState == .available {
                // オンライン：直接Azure Storageに保存
                try await uploadToAzure(data: encryptedData.data, path: blobPath)
                logger.info("Call data saved to Azure: \(blobPath)")
            } else {
                // オフライン：ローカルキューに保存
                try await offlineDataManager.queueForUpload(
                    data: encryptedData.data,
                    path: blobPath,
                    metadata: ["type": "call_data", "callId": data.id.uuidString]
                )
                logger.info("Call data queued for offline upload: \(data.id)")
            }
            
            // ローカルキャッシュにも保存
            try await offlineDataManager.saveCallDataLocally(data)
            
            return data.id.uuidString
            
        } catch {
            logger.error("Failed to save call data: \(error.localizedDescription)")
            throw AppError.storageConnectionFailed
        }
    }
    
    /// 通話履歴を読み込み
    /// - Parameters:
    ///   - limit: 取得する件数
    ///   - offset: オフセット
    /// - Returns: 通話記録の配列
    func loadCallHistory(limit: Int, offset: Int) async throws -> [CallRecord] {
        logger.info("Loading call history: limit=\(limit), offset=\(offset)")
        
        do {
            // まずローカルキャッシュから取得を試行
            let localRecords = try await offlineDataManager.loadCallHistoryLocally(limit: limit, offset: offset)
            
            if storageState == .available {
                // オンライン時はAzureから最新データを取得してローカルと同期
                try await syncWithAzure()
                
                // 同期後に再度ローカルから取得
                return try await offlineDataManager.loadCallHistoryLocally(limit: limit, offset: offset)
            } else {
                // オフライン時はローカルデータのみ返す
                logger.info("Returning cached call history (offline mode)")
                return localRecords
            }
            
        } catch {
            logger.error("Failed to load call history: \(error.localizedDescription)")
            throw AppError.storageConnectionFailed
        }
    }
    
    /// 通話記録を削除
    /// - Parameter id: 削除する記録のID
    func deleteCallRecord(_ id: String) async throws {
        logger.info("Deleting call record: \(id)")
        
        guard let userId = currentUserId else {
            throw AppError.invalidConfiguration
        }
        
        do {
            // ローカルから削除
            try await offlineDataManager.deleteCallRecordLocally(id)
            
            if storageState == .available {
                // Azure Storageからも削除
                let paths = [
                    buildBlobPath(userId: userId, callId: id, type: .callData),
                    buildBlobPath(userId: userId, callId: id, type: .audioFile),
                    buildBlobPath(userId: userId, callId: id, type: .transcription)
                ]
                
                for path in paths {
                    try await deleteFromAzure(path: path)
                }
                
                logger.info("Call record deleted from Azure: \(id)")
            } else {
                // オフライン時は削除操作をキューに追加
                try await offlineDataManager.queueForDeletion(
                    callId: id,
                    metadata: ["type": "call_deletion"]
                )
                logger.info("Call record deletion queued for offline: \(id)")
            }
            
        } catch {
            logger.error("Failed to delete call record: \(error.localizedDescription)")
            throw AppError.storageConnectionFailed
        }
    }
    
    /// 通話記録を共有
    /// - Parameters:
    ///   - id: 共有する記録のID
    ///   - userId: 共有先ユーザーID
    func shareCallRecord(_ id: String, with userId: String) async throws {
        logger.info("Sharing call record \(id) with user \(userId)")
        
        guard let currentUserId = currentUserId else {
            throw AppError.invalidConfiguration
        }
        
        do {
            // 共有メタデータを作成
            let shareMetadata = SharedCallMetadata(
                callId: id,
                ownerId: currentUserId,
                sharedWithUserId: userId,
                sharedAt: Date(),
                permission: .read
            )
            
            // 共有メタデータを暗号化
            let metadataJson = try JSONEncoder().encode(shareMetadata)
            let encryptedMetadata = try encryptionService.encrypt(data: metadataJson)
            
            // 共有メタデータのパスを構築
            let sharePath = buildSharedBlobPath(
                ownerId: currentUserId,
                sharedWithUserId: userId,
                callId: id
            )
            
            if storageState == .available {
                try await uploadToAzure(data: encryptedMetadata.data, path: sharePath)
                logger.info("Call record shared successfully: \(id)")
            } else {
                try await offlineDataManager.queueForUpload(
                    data: encryptedMetadata.data,
                    path: sharePath,
                    metadata: ["type": "share_metadata", "callId": id, "sharedWith": userId]
                )
                logger.info("Call record sharing queued for offline: \(id)")
            }
            
        } catch {
            logger.error("Failed to share call record: \(error.localizedDescription)")
            throw AppError.sharingRequestFailed(reason: error.localizedDescription)
        }
    }
    
    /// 音声ファイルをアップロード
    /// - Parameters:
    ///   - fileUrl: ローカルファイルのURL
    ///   - callId: 通話ID
    /// - Returns: アップロードされたファイルのURL
    func uploadAudioFile(_ fileUrl: URL, for callId: String) async throws -> String {
        logger.info("Uploading audio file for call: \(callId)")
        
        guard let userId = currentUserId else {
            throw AppError.invalidConfiguration
        }
        
        do {
            // 音声ファイルを読み込み
            let audioData = try Data(contentsOf: fileUrl)
            
            // データを暗号化
            let encryptedData = try encryptionService.encrypt(data: audioData)
            
            // Azure Blob Storageのパスを構築
            let blobPath = buildBlobPath(userId: userId, callId: callId, type: .audioFile)
            
            if storageState == .available {
                // バックグラウンドアップロードを開始
                let uploadUrl = try await startBackgroundUpload(
                    data: encryptedData.data,
                    path: blobPath,
                    callId: callId
                )
                
                logger.info("Audio file upload started: \(blobPath)")
                return uploadUrl
            } else {
                // オフライン時はキューに追加
                try await offlineDataManager.queueForUpload(
                    data: encryptedData.data,
                    path: blobPath,
                    metadata: ["type": "audio_file", "callId": callId]
                )
                
                logger.info("Audio file queued for offline upload: \(callId)")
                return "queued://\(blobPath)"
            }
            
        } catch {
            logger.error("Failed to upload audio file: \(error.localizedDescription)")
            throw AppError.storageConnectionFailed
        }
    }
    
    /// 音声ファイルをダウンロード
    /// - Parameter callId: 通話ID
    /// - Returns: ダウンロードされたファイルのローカルURL
    func downloadAudioFile(for callId: String) async throws -> URL {
        logger.info("Downloading audio file for call: \(callId)")
        
        guard let userId = currentUserId else {
            throw AppError.invalidConfiguration
        }
        
        do {
            // まずローカルキャッシュを確認
            if let localUrl = try await offlineDataManager.getLocalAudioFile(for: callId) {
                logger.info("Audio file found in local cache: \(callId)")
                return localUrl
            }
            
            guard storageState == .available else {
                logger.warning("Audio file not available offline: \(callId)")
                throw AppError.networkUnavailable
            }
            
            // Azure Storageからダウンロード
            let blobPath = buildBlobPath(userId: userId, callId: callId, type: .audioFile)
            let encryptedData = try await downloadFromAzure(path: blobPath)
            
            // データを復号化
            let encryptedDataStruct = EncryptedData(
                data: encryptedData,
                keyIdentifier: callId,
                algorithm: .aes256,
                createdAt: Date()
            )
            let audioData = try encryptionService.decrypt(encryptedData: encryptedDataStruct)
            
            // ローカルファイルに保存
            let localUrl = try await offlineDataManager.saveAudioFileLocally(
                data: audioData,
                for: callId
            )
            
            logger.info("Audio file downloaded and cached: \(callId)")
            return localUrl
            
        } catch {
            logger.error("Failed to download audio file: \(error.localizedDescription)")
            throw AppError.storageConnectionFailed
        }
    }
    
    /// ストレージ使用量を取得
    /// - Returns: ストレージ使用量情報
    func getStorageUsage() async throws -> StorageUsage {
        logger.info("Getting storage usage information")
        
        do {
            // ローカルストレージ使用量を取得
            let localUsage = try await offlineDataManager.getLocalStorageUsage()
            
            if storageState == .available {
                // Azure Storageの使用量も取得
                let azureUsage = try await getAzureStorageUsage()
                
                return StorageUsage(
                    totalUsed: azureUsage.totalUsed,
                    audioFilesSize: azureUsage.audioFilesSize,
                    textDataSize: azureUsage.textDataSize,
                    metadataSize: azureUsage.metadataSize,
                    availableQuota: azureUsage.availableQuota
                )
            } else {
                // オフライン時はローカル使用量のみ
                return localUsage
            }
            
        } catch {
            logger.error("Failed to get storage usage: \(error.localizedDescription)")
            throw AppError.storageConnectionFailed
        }
    }
    
    /// オフライン同期
    func syncOfflineData() async throws {
        logger.info("Starting offline data synchronization")
        
        guard storageState == .available else {
            logger.warning("Cannot sync offline data - storage not available")
            throw AppError.networkUnavailable
        }
        
        storageState = .syncing
        
        do {
            // アップロード待ちのデータを同期
            try await offlineDataManager.syncPendingUploads { data, path, metadata in
                try await self.uploadToAzure(data: data, path: path)
                self.logger.info("Synced pending upload: \(path)")
            }
            
            // 削除待ちの操作を同期
            try await offlineDataManager.syncPendingDeletions { callId, metadata in
                guard let userId = self.currentUserId else { return }
                
                let paths = [
                    self.buildBlobPath(userId: userId, callId: callId, type: .callData),
                    self.buildBlobPath(userId: userId, callId: callId, type: .audioFile),
                    self.buildBlobPath(userId: userId, callId: callId, type: .transcription)
                ]
                
                for path in paths {
                    try await self.deleteFromAzure(path: path)
                }
                
                self.logger.info("Synced pending deletion: \(callId)")
            }
            
            storageState = .available
            logger.info("Offline data synchronization completed")
            
        } catch {
            storageState = .error(error)
            logger.error("Failed to sync offline data: \(error.localizedDescription)")
            throw error
        }
    }
    
    // MARK: - Public Methods
    
    /// ユーザーを設定
    /// - Parameter userId: ユーザーID
    func setCurrentUser(_ userId: String) {
        currentUserId = userId
        logger.info("Current user set: \(userId)")
    }
    
    /// ネットワーク状態を手動で更新
    func updateNetworkStatus(_ isConnected: Bool) {
        let newState: StorageState = isConnected ? .available : .offline
        
        if storageState != newState {
            storageState = newState
            logger.info("Storage state updated: \(storageState)")
            
            if isConnected {
                // ネットワーク復旧時に自動同期を開始
                Task {
                    try? await syncOfflineData()
                }
            }
        }
    }
    
    // MARK: - Private Methods
    
    /// Azure クライアントを設定
    private func setupAzureClient() {
        do {
            let credential = StorageSharedKeyCredential(
                accountName: azureConfig.accountName,
                accountKey: azureConfig.accountKey
            )
            
            let clientOptions = BlobClientOptions()
            blobServiceClient = try BlobServiceClient(
                url: azureConfig.blobServiceUrl,
                credential: credential,
                options: clientOptions
            )
            
            logger.info("Azure Blob Storage client configured successfully")
            storageState = .available
            
        } catch {
            logger.error("Failed to configure Azure client: \(error.localizedDescription)")
            storageState = .error(error)
        }
    }
    
    /// ネットワーク監視を設定
    private func setupNetworkMonitoring() {
        networkMonitor = NetworkMonitor { [weak self] isConnected in
            self?.updateNetworkStatus(isConnected)
        }
        networkMonitor?.startMonitoring()
    }
    
    /// Blobパスを構築
    private func buildBlobPath(userId: String, callId: String, type: BlobType) -> String {
        return "user-\(userId)/calls/\(callId)/\(type.filename)"
    }
    
    /// 共有Blobパスを構築
    private func buildSharedBlobPath(ownerId: String, sharedWithUserId: String, callId: String) -> String {
        return "shared/from-\(ownerId)/to-\(sharedWithUserId)/\(callId)/metadata.json"
    }
    
    /// Azure Storageにアップロード
    private func uploadToAzure(data: Data, path: String) async throws {
        guard let client = blobServiceClient else {
            throw AppError.storageConnectionFailed
        }
        
        let containerClient = client.containerClient(containerName: azureConfig.containerName)
        let blobClient = containerClient.blobClient(blobName: path)
        
        try await blobClient.upload(data: data, overwrite: true)
    }
    
    /// Azure Storageから削除
    private func deleteFromAzure(path: String) async throws {
        guard let client = blobServiceClient else {
            throw AppError.storageConnectionFailed
        }
        
        let containerClient = client.containerClient(containerName: azureConfig.containerName)
        let blobClient = containerClient.blobClient(blobName: path)
        
        try await blobClient.delete()
    }
    
    /// Azure Storageからダウンロード
    private func downloadFromAzure(path: String) async throws -> Data {
        guard let client = blobServiceClient else {
            throw AppError.storageConnectionFailed
        }
        
        let containerClient = client.containerClient(containerName: azureConfig.containerName)
        let blobClient = containerClient.blobClient(blobName: path)
        
        let downloadResponse = try await blobClient.download()
        return downloadResponse.data
    }
    
    /// バックグラウンドアップロードを開始
    private func startBackgroundUpload(data: Data, path: String, callId: String) async throws -> String {
        // バックグラウンドタスクを開始
        backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "AudioUpload") { [weak self] in
            self?.endBackgroundTask()
        }
        
        // 一時ファイルを作成
        let tempUrl = FileManager.default.temporaryDirectory.appendingPathComponent("\(callId)_upload.dat")
        try data.write(to: tempUrl)
        
        // Azure Blob Storage SAS URLを生成
        let uploadUrl = try generateSASUploadUrl(for: path)
        
        // バックグラウンドアップロードタスクを作成
        var request = URLRequest(url: URL(string: uploadUrl)!)
        request.httpMethod = "PUT"
        request.setValue("BlockBlob", forHTTPHeaderField: "x-ms-blob-type")
        
        let uploadTask = urlSession.uploadTask(with: request, fromFile: tempUrl)
        uploadTasks[callId] = uploadTask
        uploadTask.resume()
        
        return uploadUrl
    }
    
    /// SASアップロードURLを生成
    private func generateSASUploadUrl(for path: String) throws -> String {
        // 実装例：SAS tokenを生成してアップロードURLを構築
        let expiryTime = Date().addingTimeInterval(3600) // 1時間後に有効期限
        let sasToken = generateSASToken(for: path, expiryTime: expiryTime)
        
        return "\(azureConfig.blobServiceUrl)/\(azureConfig.containerName)/\(path)?\(sasToken)"
    }
    
    /// SAS tokenを生成
    private func generateSASToken(for path: String, expiryTime: Date) -> String {
        // 簡略化された実装例
        // 実際の実装では適切なSAS token生成ロジックを使用
        let formatter = ISO8601DateFormatter()
        let expiry = formatter.string(from: expiryTime)
        
        return "sv=2020-08-04&ss=b&srt=o&sp=w&se=\(expiry)&sig=placeholder"
    }
    
    /// バックグラウンドタスクを終了
    private func endBackgroundTask() {
        if backgroundTaskId != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskId)
            backgroundTaskId = .invalid
        }
    }
    
    /// Azure Storageの使用量を取得
    private func getAzureStorageUsage() async throws -> StorageUsage {
        guard let userId = currentUserId,
              let client = blobServiceClient else {
            throw AppError.storageConnectionFailed
        }
        
        let containerClient = client.containerClient(containerName: azureConfig.containerName)
        let userPrefix = "user-\(userId)/"
        
        var totalSize: Int64 = 0
        var audioFilesSize: Int64 = 0
        var textDataSize: Int64 = 0
        var metadataSize: Int64 = 0
        
        // ユーザーのBlob一覧を取得して使用量を計算
        let listOptions = ListBlobsOptions()
        listOptions.prefix = userPrefix
        
        for try await blob in containerClient.listBlobs(options: listOptions) {
            let size = blob.properties.contentLength ?? 0
            totalSize += size
            
            if blob.name.contains("/audio/") {
                audioFilesSize += size
            } else if blob.name.contains("/transcription/") {
                textDataSize += size
            } else {
                metadataSize += size
            }
        }
        
        // 利用可能クォータ（例：1GB）
        let availableQuota: Int64 = 1024 * 1024 * 1024
        
        return StorageUsage(
            totalUsed: totalSize,
            audioFilesSize: audioFilesSize,
            textDataSize: textDataSize,
            metadataSize: metadataSize,
            availableQuota: max(0, availableQuota - totalSize)
        )
    }
    
    /// Azure Storageと同期
    private func syncWithAzure() async throws {
        // 実装例：増分同期ロジック
        guard let userId = currentUserId else { return }
        
        let lastSyncTime = await offlineDataManager.getLastSyncTime()
        
        // Azure Storageから変更されたBlobを取得
        // 実際の実装では適切な変更検出ロジックを使用
        logger.info("Syncing with Azure Storage (last sync: \(lastSyncTime))")
        
        await offlineDataManager.updateLastSyncTime(Date())
    }
}

// MARK: - URLSessionDelegate

extension AzureStorageService: URLSessionDelegate, URLSessionTaskDelegate {
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            logger.error("Background upload failed: \(error.localizedDescription)")
        } else {
            logger.info("Background upload completed successfully")
        }
        
        // タスクをクリーンアップ
        if let uploadTask = task as? URLSessionUploadTask {
            for (callId, taskInProgress) in uploadTasks {
                if taskInProgress == uploadTask {
                    uploadTasks.removeValue(forKey: callId)
                    break
                }
            }
        }
        
        endBackgroundTask()
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let progress = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        logger.debug("Upload progress: \(progress * 100)%")
    }
}

// MARK: - Supporting Types

/// Azure Storage設定
struct AzureStorageConfig {
    let accountName: String
    let accountKey: String
    let containerName: String
    let blobServiceUrl: URL
    
    static func loadFromEnvironment() -> AzureStorageConfig {
        // 環境変数またはplistファイルから設定を読み込み
        let accountName = ProcessInfo.processInfo.environment["AZURE_STORAGE_ACCOUNT"] ?? "telreqstorage"
        let accountKey = ProcessInfo.processInfo.environment["AZURE_STORAGE_KEY"] ?? ""
        let containerName = "call-data"
        let serviceUrl = URL(string: "https://\(accountName).blob.core.windows.net")!
        
        return AzureStorageConfig(
            accountName: accountName,
            accountKey: accountKey,
            containerName: containerName,
            blobServiceUrl: serviceUrl
        )
    }
}

/// Blobタイプ
enum BlobType {
    case callData
    case audioFile
    case transcription
    case metadata
    
    var filename: String {
        switch self {
        case .callData:
            return "call_data.json"
        case .audioFile:
            return "audio.enc"
        case .transcription:
            return "transcription.json"
        case .metadata:
            return "metadata.json"
        }
    }
}

/// 共有メタデータ
struct SharedCallMetadata: Codable {
    let callId: String
    let ownerId: String
    let sharedWithUserId: String
    let sharedAt: Date
    let permission: SharingPermission
}

/// ネットワーク監視
class NetworkMonitor {
    private let callback: (Bool) -> Void
    private var monitor: Any? // NWPathMonitor の実装
    
    init(callback: @escaping (Bool) -> Void) {
        self.callback = callback
    }
    
    func startMonitoring() {
        // Network framework を使用してネットワーク状態を監視
        // 簡略化された実装例
        callback(true) // 初期値として接続ありとする
    }
    
    func stopMonitoring() {
        monitor = nil
    }
}

/// オフラインデータマネージャープロトコル
protocol OfflineDataManagerProtocol {
    func queueForUpload(data: Data, path: String, metadata: [String: String]) async throws
    func queueForDeletion(callId: String, metadata: [String: String]) async throws
    func saveCallDataLocally(_ data: StructuredCallData) async throws
    func loadCallHistoryLocally(limit: Int, offset: Int) async throws -> [CallRecord]
    func deleteCallRecordLocally(_ id: String) async throws
    func getLocalAudioFile(for callId: String) async throws -> URL?
    func saveAudioFileLocally(data: Data, for callId: String) async throws -> URL
    func getLocalStorageUsage() async throws -> StorageUsage
    func syncPendingUploads(_ handler: (Data, String, [String: String]) async throws -> Void) async throws
    func syncPendingDeletions(_ handler: (String, [String: String]) async throws -> Void) async throws
    func getLastSyncTime() async -> Date
    func updateLastSyncTime(_ time: Date) async
}