import Foundation
import CoreData
#if canImport(UIKit)
import UIKit
#endif
import os.log

/// オフラインデータ管理サービス
/// 
/// ローカルデータベース（Core Data）、オフライン時のデータキューイング、
/// ネットワーク復旧時の自動同期、ローカルキャッシュ管理を提供します。
final class OfflineDataManager: NSObject, OfflineDataManagerProtocol {
    
    // MARK: - Properties
    
    /// ログ出力用
    private let logger = Logger(subsystem: "com.telreq.app", category: "OfflineDataManager")
    
    /// ローカルデータ保存用ディレクトリ
    private let documentsDirectory: URL
    private let callDataDirectory: URL
    
    /// データ保持期間（1ヶ月）
    private let dataRetentionPeriod: TimeInterval = 30 * 24 * 60 * 60 // 30日
    
    // MARK: - Initialization
    
    override init() {
        // Documentsディレクトリを取得
        self.documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.callDataDirectory = documentsDirectory.appendingPathComponent("CallData")
        
        super.init()
        
        // ディレクトリを作成
        createCallDataDirectoryIfNeeded()
        
        // メモリ警告の通知を監視 (iOS のみ)
        #if canImport(UIKit) && !os(macOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        #endif
        
        // 起動時に古いデータをクリーンアップ
        Task {
            await cleanupExpiredData()
        }
    }
    
    // MARK: - OfflineDataManagerProtocol Implementation
    
    func saveLocalData(_ data: StructuredCallData) async throws {
        logger.info("Saving local data for call ID: \(data.id.uuidString)")
        
        do {
            // JSONエンコード
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let jsonData = try encoder.encode(data)
            
            // ファイル名を生成（ID + タイムスタンプ）
            let fileName = "\(data.id.uuidString)_\(Int(data.timestamp.timeIntervalSince1970)).json"
            let fileURL = callDataDirectory.appendingPathComponent(fileName)
            
            // ファイルに保存
            try jsonData.write(to: fileURL)
            
            logger.info("Successfully saved call data to: \(fileURL.path)")
        } catch {
            logger.error("Failed to save local data: \(error.localizedDescription)")
            throw error
        }
    }
    
    func getLocalData(callId: String) async throws -> StructuredCallData? {
        logger.info("Fetching local data for call ID: \(callId)")
        
        do {
            let files = try FileManager.default.contentsOfDirectory(at: callDataDirectory, includingPropertiesForKeys: nil)
            
            // callIdで始まるファイルを検索
            let matchingFiles = files.filter { $0.lastPathComponent.hasPrefix(callId) }
            
            guard let fileURL = matchingFiles.first else {
                logger.info("No local data found for call ID: \(callId)")
                return nil
            }
            
            let jsonData = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let callData = try decoder.decode(StructuredCallData.self, from: jsonData)
            
            logger.info("Successfully loaded local data from: \(fileURL.path)")
            return callData
        } catch {
            logger.error("Failed to load local data: \(error.localizedDescription)")
            throw error
        }
    }
    
    func getAllLocalData() async throws -> [StructuredCallData] {
        logger.info("Fetching all local data")
        
        do {
            let files = try FileManager.default.contentsOfDirectory(at: callDataDirectory, includingPropertiesForKeys: nil)
            let jsonFiles = files.filter { $0.pathExtension == "json" }
            
            var allData: [StructuredCallData] = []
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            
            for fileURL in jsonFiles {
                do {
                    let jsonData = try Data(contentsOf: fileURL)
                    let callData = try decoder.decode(StructuredCallData.self, from: jsonData)
                    allData.append(callData)
                } catch {
                    logger.warning("Failed to decode file \(fileURL.lastPathComponent): \(error.localizedDescription)")
                    // 破損したファイルは削除
                    try? FileManager.default.removeItem(at: fileURL)
                }
            }
            
            // タイムスタンプでソート（新しい順）
            allData.sort { $0.timestamp > $1.timestamp }
            
            logger.info("Loaded \(allData.count) local data records")
            return allData
        } catch {
            logger.error("Failed to load all local data: \(error.localizedDescription)")
            throw error
        }
    }
    
    func deleteLocalData(callId: String) async throws {
        logger.info("Deleting local data for call ID: \(callId)")
        
        do {
            let files = try FileManager.default.contentsOfDirectory(at: callDataDirectory, includingPropertiesForKeys: nil)
            let matchingFiles = files.filter { $0.lastPathComponent.hasPrefix(callId) }
            
            for fileURL in matchingFiles {
                try FileManager.default.removeItem(at: fileURL)
                logger.info("Deleted file: \(fileURL.lastPathComponent)")
            }
        } catch {
            logger.error("Failed to delete local data: \(error.localizedDescription)")
            throw error
        }
    }
    
    func getPendingSyncData() async throws -> [StructuredCallData] {
        logger.info("Fetching pending sync data")
        
        // 現在の実装では、すべてのローカルデータを同期対象とする
        return try await getAllLocalData()
    }
    
    func markSyncCompleted(callId: String) async throws {
        logger.info("Marking sync as completed for call ID: \(callId)")
        
        // 同期完了後、ローカルデータを削除（Azureに保存済みのため）
        try await deleteLocalData(callId: callId)
    }
    
    func getStorageInfo() async throws -> LocalStorageInfo {
        logger.info("Getting local storage info")
        
        do {
            let files = try FileManager.default.contentsOfDirectory(at: callDataDirectory, includingPropertiesForKeys: nil)
            let jsonFiles = files.filter { $0.pathExtension == "json" }
            
            var totalSize: Int64 = 0
            for fileURL in jsonFiles {
                let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                if let fileSize = attributes[.size] as? Int64 {
                    totalSize += fileSize
                }
            }
            
            let pendingSyncCount = jsonFiles.count // 簡易実装
            
            return LocalStorageInfo(
                usedBytes: totalSize,
                availableBytes: getAvailableStorageSpace(),
                totalFiles: jsonFiles.count,
                pendingSyncCount: pendingSyncCount
            )
        } catch {
            logger.error("Failed to get storage info: \(error.localizedDescription)")
            throw error
        }
    }
    
    func clearCache() async throws {
        logger.info("Clearing cache")
        
        do {
            let files = try FileManager.default.contentsOfDirectory(at: callDataDirectory, includingPropertiesForKeys: nil)
            
            for fileURL in files {
                try FileManager.default.removeItem(at: fileURL)
            }
            
            logger.info("Cache cleared successfully")
        } catch {
            logger.error("Failed to clear cache: \(error.localizedDescription)")
            throw error
        }
    }
    
    func loadCallHistory(limit: Int, offset: Int) async throws -> [CallRecord] {
        logger.info("Loading call history with limit: \(limit), offset: \(offset)")
        
        let allData = try await getAllLocalData()
        let paginatedData = Array(allData.dropFirst(offset).prefix(limit))
        
        return paginatedData.map { CallRecord(from: $0) }
    }
    
    func deleteCallRecord(_ id: String) async throws {
        logger.info("Deleting call record with ID: \(id)")
        try await deleteLocalData(callId: id)
    }
    
    func loadCallDetails(_ callId: String) async throws -> StructuredCallData {
        logger.info("Loading call details for ID: \(callId)")
        
        guard let callData = try await getLocalData(callId: callId) else {
            throw AppError.callRecordNotFound
        }
        
        return callData
    }
    
    // MARK: - Private Helper Methods
    
    /// コールデータディレクトリを作成
    private func createCallDataDirectoryIfNeeded() {
        do {
            if !FileManager.default.fileExists(atPath: callDataDirectory.path) {
                try FileManager.default.createDirectory(at: callDataDirectory, withIntermediateDirectories: true)
                logger.info("Created call data directory: \(self.callDataDirectory.path)")
            }
        } catch {
            logger.error("Failed to create call data directory: \(error.localizedDescription)")
        }
    }
    
    /// 利用可能なストレージ容量を取得
    private func getAvailableStorageSpace() -> Int64 {
        do {
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: documentsDirectory.path)
            if let freeSize = attributes[.systemFreeSize] as? Int64 {
                return freeSize
            }
        } catch {
            logger.error("Failed to get available storage space: \(error.localizedDescription)")
        }
        return 0
    }
    
    /// 期限切れデータをクリーンアップ
    private func cleanupExpiredData() async {
        logger.info("Starting expired data cleanup")
        
        do {
            let files = try FileManager.default.contentsOfDirectory(at: callDataDirectory, includingPropertiesForKeys: nil)
            let jsonFiles = files.filter { $0.pathExtension == "json" }
            
            let cutoffDate = Date().addingTimeInterval(-dataRetentionPeriod)
            var deletedCount = 0
            
            for fileURL in jsonFiles {
                do {
                    // ファイル名からタイムスタンプを抽出
                    let fileName = fileURL.lastPathComponent
                    let components = fileName.components(separatedBy: "_")
                    
                    if components.count >= 2 {
                        let timestampString = components[1].replacingOccurrences(of: ".json", with: "")
                        if let timestamp = Double(timestampString) {
                            let fileDate = Date(timeIntervalSince1970: timestamp)
                            
                            if fileDate < cutoffDate {
                                try FileManager.default.removeItem(at: fileURL)
                                deletedCount += 1
                                logger.info("Deleted expired file: \(fileName)")
                            }
                        }
                    }
                } catch {
                    logger.warning("Failed to process file \(fileURL.lastPathComponent): \(error.localizedDescription)")
                }
            }
            
            logger.info("Cleanup completed. Deleted \(deletedCount) expired files")
        } catch {
            logger.error("Failed to cleanup expired data: \(error.localizedDescription)")
        }
    }
    
    @objc private func handleMemoryWarning() {
        logger.warning("Received memory warning")
        Task {
            try? await clearCache()
        }
    }
}
