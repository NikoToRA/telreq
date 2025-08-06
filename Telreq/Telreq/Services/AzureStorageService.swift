import Foundation
#if canImport(UIKit)
import UIKit
#endif
import os.log
import CommonCrypto

/// Azure Blob Storage統合サービス
///
/// ユーザー別データ階層化、音声ファイル・転写テキスト・メタデータの保存/取得、
/// オフライン対応とローカルキャッシュ、暗号化されたデータアップロード/ダウンロードを提供します。
final class AzureStorageService: NSObject, StorageServiceProtocol {
    
    // MARK: - Properties
    
    private let config: AzureStorageConfig
    private let encryptionService: EncryptionServiceProtocol
    private let offlineDataManager: OfflineDataManagerProtocol
    private(set) var storageState: StorageState = .offline
    private let logger = Logger(subsystem: "com.telreq.app", category: "AzureStorage")
    private var currentUserId: String?
    private let session: URLSession
    
    // MARK: - Initialization
    
    init(
        config: AzureStorageConfig,
        encryptionService: EncryptionServiceProtocol,
        offlineDataManager: OfflineDataManagerProtocol
    ) {
        self.config = config
        self.encryptionService = encryptionService
        self.offlineDataManager = offlineDataManager
        
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 30.0
        sessionConfig.timeoutIntervalForResource = 300.0
        self.session = URLSession(configuration: sessionConfig)
        
        super.init()
        logger.info("AzureStorageService initialized")
    }
    
    func setCurrentUser(_ userId: String) {
        self.currentUserId = userId
    }
    
    func initializeStorage() async throws {
        do {
            // コンテナーの存在確認
            let containerExists = try await checkContainerExists()
            if !containerExists {
                try await createContainer()
                logger.info("Blob container '\(self.config.containerName)' created.")
            }
            storageState = .available
            logger.info("Azure Storage initialized successfully for container: \(self.config.containerName)")
        } catch {
            logger.error("Failed to initialize Azure Storage: \(error.localizedDescription)")
            storageState = .error(error)
            throw AppError.storageConnectionFailed
        }
    }
    
    func saveCallData(_ data: StructuredCallData) async throws -> String {
        guard let userId = currentUserId else { throw AppError.userNotFound }
        let blobName = "\(userId)/\(data.id.uuidString).json"
        
        do {
            let jsonData = try JSONEncoder().encode(data)
            let encryptedData = try encryptionService.encrypt(data: jsonData)
            let finalData = try JSONEncoder().encode(encryptedData)
            
            let url = try buildBlobURL(blobName: blobName)
            try await uploadBlob(url: url, data: finalData, contentType: "application/json")
            
            logger.info("Successfully saved call data to \(blobName)")
            return url.absoluteString
        } catch {
            logger.error("Failed to save call data: \(error.localizedDescription)")
            throw AppError.storageConnectionFailed
        }
    }

    func uploadAudioFile(_ fileUrl: URL, for callId: String) async throws -> String {
        guard let userId = currentUserId else { throw AppError.userNotFound }
        let blobName = "\(userId)/\(callId).m4a"

        do {
            let audioData = try Data(contentsOf: fileUrl)
            let encryptedData = try encryptionService.encrypt(data: audioData)
            let finalData = try JSONEncoder().encode(encryptedData)
            
            let url = try buildBlobURL(blobName: blobName)
            try await uploadBlob(url: url, data: finalData, contentType: "audio/m4a")
            
            logger.info("Successfully uploaded audio file to \(blobName)")
            
            // アップロード成功後、ローカルの音声ファイルを削除
            try await deleteLocalAudioFile(fileUrl)
            
            return url.absoluteString
        } catch {
            logger.error("Failed to upload audio file: \(error.localizedDescription)")
            throw AppError.storageConnectionFailed
        }
    }

    // MARK: - Protocol Methods (To Be Implemented)

    func loadCallHistory(limit: Int, offset: Int) async throws -> [CallRecord] {
        logger.info("loadCallHistory not implemented")
        return []
    }

    func deleteCallRecord(_ id: String) async throws {
        logger.info("deleteCallRecord not implemented")
    }

    func shareCallRecord(_ id: String, with userId: String) async throws {
        logger.info("shareCallRecord not implemented")
    }

    func downloadAudioFile(for callId: String) async throws -> URL {
        logger.info("downloadAudioFile not implemented")
        throw AppError.callRecordNotFound
    }

    func getStorageUsage() async throws -> StorageUsage {
        logger.info("getStorageUsage not implemented")
        return StorageUsage(totalUsed: 0, audioFilesSize: 0, textDataSize: 0, metadataSize: 0, availableQuota: 0)
    }

    func syncOfflineData() async throws {
        logger.info("syncOfflineData not implemented")
    }
    
    // MARK: - Private Helper Methods
    
    private func buildBlobURL(blobName: String) throws -> URL {
        guard let connectionString = parseConnectionString(config.connectionString) else {
            throw AppError.invalidConfiguration
        }
        
        let baseURL = "https://\(connectionString.accountName).blob.core.windows.net"
        let containerURL = "\(baseURL)/\(config.containerName)"
        let blobURL = "\(containerURL)/\(blobName)"
        
        guard let url = URL(string: blobURL) else {
            throw AppError.invalidConfiguration
        }
        
        return url
    }
    
    private func parseConnectionString(_ connectionString: String) -> (accountName: String, accountKey: String)? {
        logger.info("Parsing connection string: \(connectionString)")
        let components = connectionString.components(separatedBy: ";")
        logger.info("Split into \(components.count) components: \(components)")
        var accountName: String?
        var accountKey: String?
        
        for component in components {
            let trimmedComponent = component.trimmingCharacters(in: .whitespaces)
            if trimmedComponent.isEmpty { continue }
            
            // Find the first = to split key and value properly
            if let firstEqualIndex = trimmedComponent.firstIndex(of: "=") {
                let key = String(trimmedComponent[..<firstEqualIndex]).trimmingCharacters(in: .whitespaces)
                let valueStartIndex = trimmedComponent.index(after: firstEqualIndex)
                let value = String(trimmedComponent[valueStartIndex...]).trimmingCharacters(in: .whitespaces)
                
                logger.info("Processing component: '\(trimmedComponent)' -> key: '\(key)', value: '\(value.prefix(10))...'")
                
                switch key {
                case "AccountName":
                    accountName = value
                    logger.info("Found AccountName: \(value)")
                case "AccountKey":
                    accountKey = value
                    logger.info("Found AccountKey: \(value.prefix(10))...")
                default:
                    logger.info("Ignoring key: \(key)")
                    break
                }
            }
        }
        
        logger.info("Final result - AccountName: \(accountName ?? "nil"), AccountKey: \(accountKey != nil ? "found" : "nil")")
        
        guard let name = accountName, let key = accountKey else {
            logger.error("Failed to parse connection string - missing AccountName or AccountKey")
            return nil
        }
        
        return (accountName: name, accountKey: key)
    }
    
    private func checkContainerExists() async throws -> Bool {
        guard let connectionString = parseConnectionString(config.connectionString) else {
            logger.error("Failed to parse connection string: \(self.config.connectionString)")
            throw AppError.invalidConfiguration
        }
        
        logger.info("Parsed connection string - Account: \(connectionString.accountName)")
        
        let baseURL = "https://\(connectionString.accountName).blob.core.windows.net"
        let containerURL = "\(baseURL)/\(config.containerName)?restype=container"
        
        guard let url = URL(string: containerURL) else {
            logger.error("Failed to create URL: \(containerURL)")
            throw AppError.invalidConfiguration
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        
        // Azure Storage 認証ヘッダーを追加
        do {
            // 日付ヘッダーを設定
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
            dateFormatter.timeZone = TimeZone(abbreviation: "GMT")
            dateFormatter.locale = Locale(identifier: "en_US_POSIX")
            let date = dateFormatter.string(from: Date())
            
            request.setValue(date, forHTTPHeaderField: "x-ms-date")
            request.setValue("2020-04-08", forHTTPHeaderField: "x-ms-version")
            
            let authHeader = try generateAuthHeader(
                method: "HEAD",
                url: url,
                accountKey: connectionString.accountKey,
                contentType: "",
                contentLength: 0
            )
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        } catch {
            logger.error("Failed to generate auth header: \(error.localizedDescription)")
            throw AppError.invalidConfiguration
        }
        
        let (_, response) = try await session.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse {
            logger.info("Container check response: \(httpResponse.statusCode)")
            return httpResponse.statusCode == 200
        }
        
        return false
    }
    
    private func createContainer() async throws {
        guard let connectionString = parseConnectionString(config.connectionString) else {
            throw AppError.invalidConfiguration
        }
        
        let baseURL = "https://\(connectionString.accountName).blob.core.windows.net"
        let containerURL = "\(baseURL)/\(config.containerName)?restype=container"
        
        guard let url = URL(string: containerURL) else {
            throw AppError.invalidConfiguration
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        
        // 日付ヘッダーを設定
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        dateFormatter.timeZone = TimeZone(abbreviation: "GMT")
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        let date = dateFormatter.string(from: Date())
        
        request.setValue(date, forHTTPHeaderField: "x-ms-date")
        request.setValue("2020-04-08", forHTTPHeaderField: "x-ms-version")
        
        // Azure Storage 認証ヘッダーを追加
        let authHeader = try self.generateAuthHeader(
            method: "PUT",
            url: url,
            accountKey: connectionString.accountKey,
            contentType: "application/xml",
            contentLength: 0
        )
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        
        let (_, response) = try await session.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse {
            logger.info("Create container response: \(httpResponse.statusCode)")
            if httpResponse.statusCode != 201 && httpResponse.statusCode != 409 {
                throw AppError.storageConnectionFailed
            }
        }
    }
    
    private func uploadBlob(url: URL, data: Data, contentType: String) async throws {
        guard let connectionString = parseConnectionString(config.connectionString) else {
            throw AppError.invalidConfiguration
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = data
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")
        request.setValue("BlockBlob", forHTTPHeaderField: "x-ms-blob-type")
        
        // 日付ヘッダーを設定
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        dateFormatter.timeZone = TimeZone(abbreviation: "GMT")
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        let date = dateFormatter.string(from: Date())
        
        request.setValue(date, forHTTPHeaderField: "x-ms-date")
        request.setValue("2020-04-08", forHTTPHeaderField: "x-ms-version")
        
        // Azure Storage 認証ヘッダーを追加
        let authHeader = try self.generateAuthHeader(
            method: "PUT",
            url: url,
            accountKey: connectionString.accountKey,
            contentType: contentType,
            contentLength: data.count
        )
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        
        let (_, response) = try await session.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse {
            if httpResponse.statusCode != 201 {
                throw AppError.storageConnectionFailed
            }
        }
    }
    
    private func generateAuthHeader(method: String, url: URL, accountKey: String, contentType: String, contentLength: Int) throws -> String {
        // Azure Storage の Shared Key 認証を実装
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        dateFormatter.timeZone = TimeZone(abbreviation: "GMT")
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        let date = dateFormatter.string(from: Date())
        
        // アカウント名を取得
        guard let hostComponents = url.host?.components(separatedBy: "."),
              let accountName = hostComponents.first else {
            throw AppError.invalidConfiguration
        }
        
        // Canonicalized Headers
        let canonicalizedHeaders = [
            "x-ms-date:\(date)",
            "x-ms-version:2020-04-08"
        ].joined(separator: "\n")
        
        // Canonicalized Resource
        let path = url.path
        var canonicalizedResource = "/\(accountName)\(path)"
        if let query = url.query, !query.isEmpty {
            let queryParams = query.components(separatedBy: "&")
                .compactMap { param -> (String, String)? in
                    let keyValue = param.components(separatedBy: "=")
                    guard keyValue.count == 2 else { return nil }
                    return (keyValue[0], keyValue[1])
                }
                .sorted { $0.0 < $1.0 }
            
            for (key, value) in queryParams {
                canonicalizedResource += "\n\(key):\(value)"
            }
        }
        
        // String to Sign
        let stringToSign = [
            method,
            "", // Content-Encoding
            "", // Content-Language
            contentLength > 0 ? "\(contentLength)" : "", // Content-Length
            "", // Content-MD5
            contentType,
            "", // Date (empty when using x-ms-date)
            "", // If-Modified-Since
            "", // If-Match
            "", // If-None-Match
            "", // If-Unmodified-Since
            "", // Range
            canonicalizedHeaders,
            canonicalizedResource
        ].joined(separator: "\n")
        
        logger.info("String to sign: \(stringToSign)")
        
        // HMAC-SHA256 で署名を生成
        guard let keyData = Data(base64Encoded: accountKey),
              let stringData = stringToSign.data(using: .utf8) else {
            logger.error("Failed to create signature data")
            throw AppError.encryptionFailed
        }
        
        let signature = hmacSHA256(data: stringData, key: keyData)
        
        return "SharedKey \(accountName):\(signature)"
    }
    
    private func hmacSHA256(data: Data, key: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        
        data.withUnsafeBytes { dataBytes in
            key.withUnsafeBytes { keyBytes in
                CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256),
                       keyBytes.baseAddress,
                       key.count,
                       dataBytes.baseAddress,
                       data.count,
                       &digest)
            }
        }
        
        return Data(digest).base64EncodedString()
    }
    
    /// ローカルの音声ファイルを削除
    private func deleteLocalAudioFile(_ fileUrl: URL) async throws {
        do {
            if FileManager.default.fileExists(atPath: fileUrl.path) {
                try FileManager.default.removeItem(at: fileUrl)
                logger.info("Successfully deleted local audio file: \(fileUrl.lastPathComponent)")
            } else {
                logger.warning("Local audio file not found: \(fileUrl.path)")
            }
        } catch {
            logger.error("Failed to delete local audio file: \(error.localizedDescription)")
            // 削除に失敗してもアップロードは成功しているため、エラーは投げない
        }
    }
}
