import Foundation
import CoreData
import os.log

/// オフラインデータ管理サービス
/// 
/// ローカルデータベース（Core Data）、オフライン時のデータキューイング、
/// ネットワーク復旧時の自動同期、ローカルキャッシュ管理を提供します。
final class OfflineDataManager: NSObject, OfflineDataManagerProtocol {
    
    // MARK: - Properties
    
    /// ログ出力用
    private let logger = Logger(subsystem: "com.telreq.app", category: "OfflineDataManager")
    
    /// Core Data コンテキスト
    private lazy var viewContext: NSManagedObjectContext = {
        return persistentContainer.viewContext
    }()
    
    /// バックグラウンドコンテキスト
    private lazy var backgroundContext: NSManagedObjectContext = {
        let context = persistentContainer.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return context
    }()
    
    /// Core Data永続化コンテナ
    private lazy var persistentContainer: NSPersistentContainer = {
        let container = NSPersistentContainer(name: "TelreqDataModel")
        
        // SQLiteストアの設定
        let storeDescription = container.persistentStoreDescriptions.first
        storeDescription?.shouldInferMappingModelAutomatically = true
        storeDescription?.shouldMigrateStoreAutomatically = true
        storeDescription?.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        storeDescription?.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        
        container.loadPersistentStores { [weak self] _, error in
            if let error = error as NSError? {
                self?.logger.error("Core Data error: \(error), \(error.userInfo)")
                fatalError("Core Data initialization failed: \(error)")
            }
        }
        
        container.viewContext.automaticallyMergesChangesFromParent = true
        
        return container
    }()
    
    /// ファイルマネージャー
    private let fileManager = FileManager.default
    
    /// ローカルファイル保存パス
    private lazy var documentsDirectory: URL = {
        return fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
    }()
    
    /// 音声ファイル保存パス
    private lazy var audioDirectory: URL = {
        let url = documentsDirectory.appendingPathComponent("Audio")
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    
    /// キャッシュディレクトリ
    private lazy var cacheDirectory: URL = {
        let url = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return url.appendingPathComponent("TelreqCache")
    }()
    
    /// 同期状態
    private var lastSyncTime: Date {
        get {
            return UserDefaults.standard.object(forKey: "LastSyncTime") as? Date ?? Date.distantPast
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "LastSyncTime")
        }
    }
    
    /// 同期キュー
    private let syncQueue = DispatchQueue(label: "com.telreq.app.sync", qos: .utility)
    
    /// 暗号化サービス
    private let encryptionService: EncryptionServiceProtocol?
    
    // MARK: - Initialization
    
    init(encryptionService: EncryptionServiceProtocol? = nil) {
        self.encryptionService = encryptionService
        super.init()
        
        setupCacheDirectory()
        setupNotifications()
        
        logger.info("OfflineDataManager initialized")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        logger.info("OfflineDataManager deinitialized")
    }
    
    // MARK: - OfflineDataManagerProtocol Implementation
    
    /// アップロード待ちデータをキューに追加
    /// - Parameters:
    ///   - data: アップロードするデータ
    ///   - path: アップロード先のパス
    ///   - metadata: メタデータ
    func queueForUpload(data: Data, path: String, metadata: [String: String]) async throws {
        logger.info("Queuing data for upload: \(path)")
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            backgroundContext.perform {
                do {
                    let uploadItem = NSEntityDescription.entity(forEntityName: "UploadQueueItem", in: self.backgroundContext)!
                    let queueItem = NSManagedObject(entity: uploadItem, insertInto: self.backgroundContext)
                    
                    queueItem.setValue(UUID().uuidString, forKey: "id")
                    queueItem.setValue(data, forKey: "data")
                    queueItem.setValue(path, forKey: "path")
                    queueItem.setValue(try JSONSerialization.data(withJSONObject: metadata), forKey: "metadata")
                    queueItem.setValue(Date(), forKey: "createdAt")
                    queueItem.setValue(false, forKey: "isProcessing")
                    queueItem.setValue(0, forKey: "retryCount")
                    
                    try self.backgroundContext.save()
                    
                    self.logger.info("Data queued for upload successfully: \(path)")
                    continuation.resume()
                    
                } catch {
                    self.logger.error("Failed to queue data for upload: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// 削除待ち操作をキューに追加
    /// - Parameters:
    ///   - callId: 削除する通話ID
    ///   - metadata: メタデータ
    func queueForDeletion(callId: String, metadata: [String: String]) async throws {
        logger.info("Queuing deletion for call: \(callId)")
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            backgroundContext.perform {
                do {
                    let deletionItem = NSEntityDescription.entity(forEntityName: "DeletionQueueItem", in: self.backgroundContext)!
                    let queueItem = NSManagedObject(entity: deletionItem, insertInto: self.backgroundContext)
                    
                    queueItem.setValue(UUID().uuidString, forKey: "id")
                    queueItem.setValue(callId, forKey: "callId")
                    queueItem.setValue(try JSONSerialization.data(withJSONObject: metadata), forKey: "metadata")
                    queueItem.setValue(Date(), forKey: "createdAt")
                    queueItem.setValue(false, forKey: "isProcessing")
                    queueItem.setValue(0, forKey: "retryCount")
                    
                    try self.backgroundContext.save()
                    
                    self.logger.info("Deletion queued successfully: \(callId)")
                    continuation.resume()
                    
                } catch {
                    self.logger.error("Failed to queue deletion: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// 通話データをローカルに保存
    /// - Parameter data: 保存する通話データ
    func saveCallDataLocally(_ data: StructuredCallData) async throws {
        logger.info("Saving call data locally: \(data.id)")
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            backgroundContext.perform {
                do {
                    // 既存のデータを検索
                    let fetchRequest = NSFetchRequest<NSManagedObject>(entityName: "LocalCallData")
                    fetchRequest.predicate = NSPredicate(format: "id == %@", data.id.uuidString)
                    
                    let existingItems = try self.backgroundContext.fetch(fetchRequest)
                    
                    let callDataEntity: NSManagedObject
                    if let existingItem = existingItems.first {
                        callDataEntity = existingItem
                    } else {
                        let entity = NSEntityDescription.entity(forEntityName: "LocalCallData", in: self.backgroundContext)!
                        callDataEntity = NSManagedObject(entity: entity, insertInto: self.backgroundContext)
                        callDataEntity.setValue(data.id.uuidString, forKey: "id")
                    }
                    
                    // データを暗号化して保存
                    let jsonData = try JSONEncoder().encode(data)
                    let encryptedData: Data
                    
                    if let encryption = self.encryptionService {
                        let encrypted = try encryption.encrypt(data: jsonData)
                        encryptedData = try JSONEncoder().encode(encrypted)
                    } else {
                        encryptedData = jsonData
                    }
                    
                    callDataEntity.setValue(encryptedData, forKey: "encryptedData")
                    callDataEntity.setValue(data.timestamp, forKey: "timestamp")
                    callDataEntity.setValue(data.duration, forKey: "duration")
                    callDataEntity.setValue(data.participantNumber, forKey: "participantNumber")
                    callDataEntity.setValue(data.summary.summary, forKey: "summaryPreview")
                    callDataEntity.setValue(data.metadata.audioQuality.rawValue, forKey: "audioQuality")
                    callDataEntity.setValue(data.isShared, forKey: "isShared")
                    callDataEntity.setValue(Date(), forKey: "updatedAt")
                    
                    try self.backgroundContext.save()
                    
                    self.logger.info("Call data saved locally: \(data.id)")
                    continuation.resume()
                    
                } catch {
                    self.logger.error("Failed to save call data locally: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// ローカルから通話履歴を読み込み
    /// - Parameters:
    ///   - limit: 取得する件数
    ///   - offset: オフセット
    /// - Returns: 通話記録の配列
    func loadCallHistoryLocally(limit: Int, offset: Int) async throws -> [CallRecord] {
        logger.info("Loading call history locally: limit=\(limit), offset=\(offset)")
        
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[CallRecord], Error>) in
            viewContext.perform {
                do {
                    let fetchRequest = NSFetchRequest<NSManagedObject>(entityName: "LocalCallData")
                    fetchRequest.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
                    fetchRequest.fetchLimit = limit
                    fetchRequest.fetchOffset = offset
                    
                    let results = try self.viewContext.fetch(fetchRequest)
                    
                    let callRecords = try results.compactMap { item -> CallRecord? in
                        guard let encryptedData = item.value(forKey: "encryptedData") as? Data,
                              let timestamp = item.value(forKey: "timestamp") as? Date,
                              let duration = item.value(forKey: "duration") as? TimeInterval,
                              let participantNumber = item.value(forKey: "participantNumber") as? String,
                              let summaryPreview = item.value(forKey: "summaryPreview") as? String,
                              let audioQualityString = item.value(forKey: "audioQuality") as? String,
                              let audioQuality = AudioQuality(rawValue: audioQualityString),
                              let isShared = item.value(forKey: "isShared") as? Bool,
                              let idString = item.value(forKey: "id") as? String,
                              let id = UUID(uuidString: idString) else {
                            return nil
                        }
                        
                        // 復号化
                        let jsonData: Data
                        if let encryption = self.encryptionService {
                            let encryptedDataStruct = try JSONDecoder().decode(EncryptedData.self, from: encryptedData)
                            jsonData = try encryption.decrypt(encryptedData: encryptedDataStruct)
                        } else {
                            jsonData = encryptedData
                        }
                        
                        let structuredData = try JSONDecoder().decode(StructuredCallData.self, from: jsonData)
                        
                        return CallRecord(
                            id: id,
                            timestamp: timestamp,
                            duration: duration,
                            participantNumber: participantNumber,
                            summaryPreview: summaryPreview,
                            audioQuality: audioQuality,
                            transcriptionMethod: structuredData.metadata.transcriptionMethod,
                            isShared: isShared,
                            hasAudio: !structuredData.audioFileUrl.isEmpty,
                            tags: structuredData.summary.tags
                        )
                    }
                    
                    self.logger.info("Loaded \(callRecords.count) call records locally")
                    continuation.resume(returning: callRecords)
                    
                } catch {
                    self.logger.error("Failed to load call history locally: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// ローカルから通話記録を削除
    /// - Parameter id: 削除する記録のID
    func deleteCallRecordLocally(_ id: String) async throws {
        logger.info("Deleting call record locally: \(id)")
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            backgroundContext.perform {
                do {
                    let fetchRequest = NSFetchRequest<NSManagedObject>(entityName: "LocalCallData")
                    fetchRequest.predicate = NSPredicate(format: "id == %@", id)
                    
                    let results = try self.backgroundContext.fetch(fetchRequest)
                    
                    for item in results {
                        self.backgroundContext.delete(item)
                    }
                    
                    try self.backgroundContext.save()
                    
                    // 関連する音声ファイルも削除
                    let audioUrl = self.audioDirectory.appendingPathComponent("\(id).m4a")
                    try? self.fileManager.removeItem(at: audioUrl)
                    
                    self.logger.info("Call record deleted locally: \(id)")
                    continuation.resume()
                    
                } catch {
                    self.logger.error("Failed to delete call record locally: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// ローカル音声ファイルを取得
    /// - Parameter callId: 通話ID
    /// - Returns: ローカルファイルのURL（存在しない場合はnil）
    func getLocalAudioFile(for callId: String) async throws -> URL? {
        let audioUrl = audioDirectory.appendingPathComponent("\(callId).m4a")
        
        if fileManager.fileExists(atPath: audioUrl.path) {
            logger.info("Local audio file found: \(callId)")
            return audioUrl
        } else {
            logger.info("Local audio file not found: \(callId)")
            return nil
        }
    }
    
    /// 音声ファイルをローカルに保存
    /// - Parameters:
    ///   - data: 音声データ
    ///   - callId: 通話ID
    /// - Returns: 保存されたファイルのURL
    func saveAudioFileLocally(data: Data, for callId: String) async throws -> URL {
        logger.info("Saving audio file locally: \(callId)")
        
        let audioUrl = audioDirectory.appendingPathComponent("\(callId).m4a")
        
        // データを暗号化して保存
        if let encryption = encryptionService {
            try encryption.encryptFile(at: createTempFile(with: data), to: audioUrl, using: callId)
        } else {
            try data.write(to: audioUrl)
        }
        
        logger.info("Audio file saved locally: \(audioUrl.lastPathComponent)")
        return audioUrl
    }
    
    /// ローカルストレージ使用量を取得
    /// - Returns: ストレージ使用量情報
    func getLocalStorageUsage() async throws -> StorageUsage {
        logger.info("Getting local storage usage")
        
        var totalUsed: Int64 = 0
        var audioFilesSize: Int64 = 0
        var textDataSize: Int64 = 0
        var metadataSize: Int64 = 0
        
        // 音声ファイルサイズを計算
        let audioFiles = try fileManager.contentsOfDirectory(at: audioDirectory, includingPropertiesForKeys: [.fileSizeKey])
        for fileUrl in audioFiles {
            let fileSize = try fileUrl.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            audioFilesSize += Int64(fileSize)
        }
        
        // Core Dataファイルサイズを計算
        let storeUrl = persistentContainer.persistentStoreDescriptions.first?.url
        if let storeUrl = storeUrl {
            let storeSize = try storeUrl.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            textDataSize = Int64(storeSize)
        }
        
        // キャッシュファイルサイズを計算
        if fileManager.fileExists(atPath: cacheDirectory.path) {
            let cacheFiles = try fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey])
            for fileUrl in cacheFiles {
                let fileSize = try fileUrl.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                metadataSize += Int64(fileSize)
            }
        }
        
        totalUsed = audioFilesSize + textDataSize + metadataSize
        
        // 利用可能容量を計算
        let availableSpace = try fileManager.availableCapacity(for: documentsDirectory)
        
        return StorageUsage(
            totalUsed: totalUsed,
            audioFilesSize: audioFilesSize,
            textDataSize: textDataSize,
            metadataSize: metadataSize,
            availableQuota: availableSpace
        )
    }
    
    /// アップロード待ちデータを同期
    /// - Parameter handler: 各アップロードアイテムを処理するハンドラー
    func syncPendingUploads(_ handler: (Data, String, [String: String]) async throws -> Void) async throws {
        logger.info("Syncing pending uploads")
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            backgroundContext.perform {
                do {
                    let fetchRequest = NSFetchRequest<NSManagedObject>(entityName: "UploadQueueItem")
                    fetchRequest.predicate = NSPredicate(format: "isProcessing == NO")
                    fetchRequest.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
                    
                    let items = try self.backgroundContext.fetch(fetchRequest)
                    
                    var processedCount = 0
                    let totalCount = items.count
                    
                    Task {
                        for item in items {
                            do {
                                guard let data = item.value(forKey: "data") as? Data,
                                      let path = item.value(forKey: "path") as? String,
                                      let metadataData = item.value(forKey: "metadata") as? Data else {
                                    continue
                                }
                                
                                let metadata = try JSONSerialization.jsonObject(with: metadataData) as? [String: String] ?? [:]
                                
                                // 処理中フラグを設定
                                item.setValue(true, forKey: "isProcessing")
                                try self.backgroundContext.save()
                                
                                // ハンドラーを実行
                                try await handler(data, path, metadata)
                                
                                // 成功したアイテムを削除
                                self.backgroundContext.delete(item)
                                processedCount += 1
                                
                            } catch {
                                self.logger.error("Failed to sync upload item: \(error.localizedDescription)")
                                
                                // リトライ回数を増加
                                let retryCount = (item.value(forKey: "retryCount") as? Int32 ?? 0) + 1
                                item.setValue(retryCount, forKey: "retryCount")
                                item.setValue(false, forKey: "isProcessing")
                                
                                // 最大リトライ回数を超えた場合は削除
                                if retryCount > 3 {
                                    self.backgroundContext.delete(item)
                                }
                            }
                        }
                        
                        do {
                            try self.backgroundContext.save()
                            self.logger.info("Synced \(processedCount)/\(totalCount) pending uploads")
                            continuation.resume()
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                    
                } catch {
                    self.logger.error("Failed to fetch pending uploads: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// 削除待ち操作を同期
    /// - Parameter handler: 各削除アイテムを処理するハンドラー
    func syncPendingDeletions(_ handler: (String, [String: String]) async throws -> Void) async throws {
        logger.info("Syncing pending deletions")
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            backgroundContext.perform {
                do {
                    let fetchRequest = NSFetchRequest<NSManagedObject>(entityName: "DeletionQueueItem")
                    fetchRequest.predicate = NSPredicate(format: "isProcessing == NO")
                    fetchRequest.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
                    
                    let items = try self.backgroundContext.fetch(fetchRequest)
                    
                    var processedCount = 0
                    let totalCount = items.count
                    
                    Task {
                        for item in items {
                            do {
                                guard let callId = item.value(forKey: "callId") as? String,
                                      let metadataData = item.value(forKey: "metadata") as? Data else {
                                    continue
                                }
                                
                                let metadata = try JSONSerialization.jsonObject(with: metadataData) as? [String: String] ?? [:]
                                
                                // 処理中フラグを設定
                                item.setValue(true, forKey: "isProcessing")
                                try self.backgroundContext.save()
                                
                                // ハンドラーを実行
                                try await handler(callId, metadata)
                                
                                // 成功したアイテムを削除
                                self.backgroundContext.delete(item)
                                processedCount += 1
                                
                            } catch {
                                self.logger.error("Failed to sync deletion item: \(error.localizedDescription)")
                                
                                // リトライ回数を増加
                                let retryCount = (item.value(forKey: "retryCount") as? Int32 ?? 0) + 1
                                item.setValue(retryCount, forKey: "retryCount")
                                item.setValue(false, forKey: "isProcessing")
                                
                                // 最大リトライ回数を超えた場合は削除
                                if retryCount > 3 {
                                    self.backgroundContext.delete(item)
                                }
                            }
                        }
                        
                        do {
                            try self.backgroundContext.save()
                            self.logger.info("Synced \(processedCount)/\(totalCount) pending deletions")
                            continuation.resume()
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                    
                } catch {
                    self.logger.error("Failed to fetch pending deletions: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// 最後の同期時刻を取得
    /// - Returns: 最後の同期時刻
    func getLastSyncTime() async -> Date {
        return lastSyncTime
    }
    
    /// 最後の同期時刻を更新
    /// - Parameter time: 新しい同期時刻
    func updateLastSyncTime(_ time: Date) async {
        lastSyncTime = time
        logger.info("Last sync time updated: \(time)")
    }
    
    // MARK: - Public Methods
    
    /// Core Dataストアを保存
    func saveContext() throws {
        guard viewContext.hasChanges else { return }
        
        try viewContext.save()
        logger.info("Core Data context saved")
    }
    
    /// キャッシュをクリア
    func clearCache() throws {
        logger.info("Clearing cache")
        
        if fileManager.fileExists(atPath: cacheDirectory.path) {
            try fileManager.removeItem(at: cacheDirectory)
        }
        
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        logger.info("Cache cleared successfully")
    }
    
    /// すべてのローカルデータを削除
    func deleteAllLocalData() throws {
        logger.warning("Deleting all local data")
        
        // Core Dataストアを削除
        try backgroundContext.perform {
            let entities = ["LocalCallData", "UploadQueueItem", "DeletionQueueItem"]
            
            for entityName in entities {
                let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
                let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
                
                do {
                    try self.backgroundContext.execute(deleteRequest)
                } catch {
                    self.logger.error("Failed to delete \(entityName): \(error.localizedDescription)")
                }
            }
            
            try self.backgroundContext.save()
        }
        
        // 音声ファイルを削除
        if fileManager.fileExists(atPath: audioDirectory.path) {
            try fileManager.removeItem(at: audioDirectory)
            try fileManager.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        }
        
        // キャッシュを削除
        try clearCache()
        
        // 同期時刻をリセット
        lastSyncTime = Date.distantPast
        
        logger.info("All local data deleted")
    }
    
    // MARK: - Private Methods
    
    /// キャッシュディレクトリを設定
    private func setupCacheDirectory() {
        if !fileManager.fileExists(atPath: cacheDirectory.path) {
            try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
    }
    
    /// 通知を設定
    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contextDidSave),
            name: .NSManagedObjectContextDidSave,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate),
            name: UIApplication.willTerminateNotification,
            object: nil
        )
    }
    
    /// Core Dataコンテキスト保存通知のハンドラー
    @objc private func contextDidSave(_ notification: Notification) {
        guard let context = notification.object as? NSManagedObjectContext,
              context != viewContext else {
            return
        }
        
        viewContext.perform {
            self.viewContext.mergeChanges(fromContextDidSave: notification)
        }
    }
    
    /// アプリ終了時の処理
    @objc private func applicationWillTerminate(_ notification: Notification) {
        logger.info("Application terminating, saving context")
        try? saveContext()
    }
    
    /// 一時ファイルを作成
    private func createTempFile(with data: Data) throws -> URL {
        let tempUrl = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: tempUrl)
        return tempUrl
    }
}

// MARK: - FileManager Extension

extension FileManager {
    
    /// 利用可能容量を取得
    /// - Parameter url: チェックするディレクトリのURL
    /// - Returns: 利用可能なバイト数
    func availableCapacity(for url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        
        if let capacity = values.volumeAvailableCapacityForImportantUsage {
            return capacity
        } else {
            // フォールバック: 通常の利用可能容量を使用
            let fallbackValues = try url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
            return fallbackValues.volumeAvailableCapacity ?? 0
        }
    }
}

// MARK: - Debug Support

#if DEBUG
extension OfflineDataManager {
    
    /// デバッグ情報を出力
    func printDebugInfo() {
        viewContext.perform {
            do {
                // ローカル通話データ数
                let callDataRequest = NSFetchRequest<NSManagedObject>(entityName: "LocalCallData")
                let callDataCount = try self.viewContext.count(for: callDataRequest)
                
                // アップロードキュー数
                let uploadRequest = NSFetchRequest<NSManagedObject>(entityName: "UploadQueueItem")
                let uploadCount = try self.viewContext.count(for: uploadRequest)
                
                // 削除キュー数
                let deletionRequest = NSFetchRequest<NSManagedObject>(entityName: "DeletionQueueItem")
                let deletionCount = try self.viewContext.count(for: deletionRequest)
                
                self.logger.debug("""
                    OfflineDataManager Debug Info:
                    - Local Call Data Count: \(callDataCount)
                    - Upload Queue Count: \(uploadCount)
                    - Deletion Queue Count: \(deletionCount)
                    - Last Sync Time: \(self.lastSyncTime)
                    - Documents Directory: \(self.documentsDirectory.path)
                    - Audio Directory: \(self.audioDirectory.path)
                    - Cache Directory: \(self.cacheDirectory.path)
                    """)
                
            } catch {
                self.logger.debug("Failed to get debug info: \(error.localizedDescription)")
            }
        }
    }
    
    /// データベースの整合性をチェック
    func validateDatabaseIntegrity() throws {
        logger.info("Validating database integrity")
        
        viewContext.performAndWait {
            do {
                // すべてのローカル通話データを検証
                let fetchRequest = NSFetchRequest<NSManagedObject>(entityName: "LocalCallData")
                let items = try viewContext.fetch(fetchRequest)
                
                var validCount = 0
                var invalidCount = 0
                
                for item in items {
                    guard let encryptedData = item.value(forKey: "encryptedData") as? Data,
                          let id = item.value(forKey: "id") as? String else {
                        invalidCount += 1
                        continue
                    }
                    
                    // 復号化テスト
                    do {
                        if let encryption = encryptionService {
                            let encryptedDataStruct = try JSONDecoder().decode(EncryptedData.self, from: encryptedData)
                            _ = try encryption.decrypt(encryptedData: encryptedDataStruct)
                        }
                        validCount += 1
                    } catch {
                        logger.warning("Invalid encrypted data for call: \(id)")
                        invalidCount += 1
                    }
                }
                
                logger.info("Database integrity check: \(validCount) valid, \(invalidCount) invalid")
                
            } catch {
                logger.error("Database integrity check failed: \(error.localizedDescription)")
                throw error
            }
        }
    }
}
#endif