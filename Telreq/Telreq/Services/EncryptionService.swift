import Foundation
import Security
import CryptoKit
import os.log

/// 暗号化サービス
/// 
/// AES-256暗号化/復号化、iOS Keychainでのキー管理、
/// 暗号化されたファイルストレージを提供します。
final class EncryptionService: EncryptionServiceProtocol {
    
    // MARK: - Properties
    
    /// ログ出力用
    private let logger = Logger(subsystem: "com.telreq.app", category: "Encryption")
    
    /// Keychain サービス識別子
    private let keychainService = "com.telreq.app.encryption"
    
    /// 暗号化アルゴリズム
    private let defaultAlgorithm: EncryptionAlgorithm = .aes256GCM
    
    /// キーの有効期限（デフォルト: 1年）
    private let keyExpirationInterval: TimeInterval = 365 * 24 * 60 * 60
    
    /// キーローテーション用のソルト
    private let keyDerivationSalt = "TelreqApp2024".data(using: .utf8)!
    
    /// セキュアエンクレーブ使用フラグ
    private let useSecureEnclave: Bool
    
    // MARK: - Initialization
    
    init(useSecureEnclave: Bool = true) {
        let isEnclaveAvailable: Bool
        #if targetEnvironment(simulator)
        isEnclaveAvailable = false
        #else
        isEnclaveAvailable = true
        #endif
        self.useSecureEnclave = useSecureEnclave && isEnclaveAvailable
        logger.info("EncryptionService initialized (Secure Enclave: \(self.useSecureEnclave))")
    }
    
    // MARK: - EncryptionServiceProtocol Implementation
    
    /// データを暗号化
    /// - Parameter data: 暗号化するデータ
    /// - Returns: 暗号化されたデータ
    func encrypt(data: Data) throws -> EncryptedData {
        logger.info("Encrypting data of size: \(data.count) bytes")
        
        do {
            switch defaultAlgorithm {
            case .aes256:
                return try encryptWithAES256(data: data)
            case .aes256GCM:
                return try encryptWithAES256GCM(data: data)
            }
        } catch {
            logger.error("Encryption failed: \(error.localizedDescription)")
            throw AppError.encryptionFailed
        }
    }
    
    /// データを復号化
    /// - Parameter encryptedData: 復号化する暗号化データ
    /// - Returns: 復号化されたデータ
    func decrypt(encryptedData: EncryptedData) throws -> Data {
        logger.info("Decrypting data of size: \(encryptedData.data.count) bytes")
        
        do {
            switch encryptedData.algorithm {
            case .aes256:
                return try decryptWithAES256(encryptedData: encryptedData)
            case .aes256GCM:
                return try decryptWithAES256GCM(encryptedData: encryptedData)
            }
        } catch {
            logger.error("Decryption failed: \(error.localizedDescription)")
            throw AppError.encryptionFailed
        }
    }
    
    /// 暗号化キーを生成
    /// - Returns: 生成されたキーの識別子
    func generateEncryptionKey() throws -> String {
        let keyIdentifier = UUID().uuidString
        logger.info("Generating encryption key: \(keyIdentifier)")
        
        do {
            switch defaultAlgorithm {
            case .aes256, .aes256GCM:
                let key = SymmetricKey(size: .bits256)
                try storeSymmetricKey(key, identifier: keyIdentifier)
            }
            
            logger.info("Encryption key generated successfully: \(keyIdentifier)")
            return keyIdentifier
            
        } catch {
            logger.error("Key generation failed: \(error.localizedDescription)")
            throw AppError.encryptionFailed
        }
    }
    
    /// 暗号化キーを保存
    /// - Parameters:
    ///   - key: 保存するキー
    ///   - identifier: キーの識別子
    func storeEncryptionKey(_ key: String, for identifier: String) throws {
        logger.info("Storing encryption key: \(identifier)")
        
        guard let keyData = key.data(using: .utf8) else {
            throw AppError.encryptionFailed
        }
        
        do {
            try storeDataInKeychain(keyData, identifier: identifier)
            logger.info("Encryption key stored successfully: \(identifier)")
        } catch {
            logger.error("Key storage failed: \(error.localizedDescription)")
            throw AppError.encryptionFailed
        }
    }
    
    /// 暗号化キーを取得
    /// - Parameter identifier: キーの識別子
    /// - Returns: 取得されたキー
    func retrieveEncryptionKey(for identifier: String) throws -> String {
        logger.info("Retrieving encryption key: \(identifier)")
        
        do {
            let keyData = try retrieveDataFromKeychain(identifier: identifier)
            
            guard let key = String(data: keyData, encoding: .utf8) else {
                throw AppError.encryptionFailed
            }
            
            logger.info("Encryption key retrieved successfully: \(identifier)")
            return key
            
        } catch {
            logger.error("Key retrieval failed: \(error.localizedDescription)")
            throw AppError.encryptionFailed
        }
    }
    
    /// 暗号化キーを削除
    /// - Parameter identifier: キーの識別子
    func deleteEncryptionKey(for identifier: String) throws {
        logger.info("Deleting encryption key: \(identifier)")
        
        do {
            try deleteDataFromKeychain(identifier: identifier)
            logger.info("Encryption key deleted successfully: \(identifier)")
        } catch {
            logger.error("Key deletion failed: \(error.localizedDescription)")
            throw AppError.encryptionFailed
        }
    }
    
    // MARK: - Public Methods
    
    /// ファイルを暗号化
    /// - Parameters:
    ///   - fileUrl: 暗号化するファイルのURL
    ///   - outputUrl: 暗号化されたファイルの出力URL
    ///   - keyIdentifier: 使用するキーの識別子
    func encryptFile(at fileUrl: URL, to outputUrl: URL, using keyIdentifier: String? = nil) throws {
        logger.info("Encrypting file: \(fileUrl.lastPathComponent)")
        
        let data = try Data(contentsOf: fileUrl)
        
        let encryptedData: EncryptedData
        if let keyId = keyIdentifier {
            encryptedData = try encryptWithKey(data: data, keyIdentifier: keyId)
        } else {
            encryptedData = try encrypt(data: data)
        }
        
        // 暗号化されたデータとメタデータを結合
        let fileMetadata = EncryptedFileMetadata(
            originalFilename: fileUrl.lastPathComponent,
            originalSize: data.count,
            encryptionAlgorithm: encryptedData.algorithm,
            keyIdentifier: encryptedData.keyIdentifier,
            createdAt: encryptedData.createdAt
        )
        
        let metadataData = try JSONEncoder().encode(fileMetadata)
        var metadataLength = UInt32(metadataData.count)
        
        // ファイル形式: [メタデータ長(4バイト)][メタデータ][暗号化データ]
        var outputData = Data()
        outputData.append(Data(bytes: &metadataLength, count: 4))
        outputData.append(metadataData)
        outputData.append(encryptedData.data)
        
        try outputData.write(to: outputUrl)
        logger.info("File encrypted successfully: \(outputUrl.lastPathComponent)")
    }
    
    /// ファイルを復号化
    /// - Parameters:
    ///   - fileUrl: 復号化する暗号化ファイルのURL
    ///   - outputUrl: 復号化されたファイルの出力URL
    /// - Returns: 復号化されたファイルのメタデータ
    @discardableResult
    func decryptFile(at fileUrl: URL, to outputUrl: URL) throws -> EncryptedFileMetadata {
        logger.info("Decrypting file: \(fileUrl.lastPathComponent)")
        
        let encryptedFileData = try Data(contentsOf: fileUrl)
        
        // メタデータ長を読み取り
        guard encryptedFileData.count >= 4 else {
            throw EncryptionError.invalidFileFormat
        }
        
        let metadataLength = encryptedFileData.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }
        
        guard encryptedFileData.count >= 4 + Int(metadataLength) else {
            throw EncryptionError.invalidFileFormat
        }
        
        // メタデータを読み取り
        let metadataData = encryptedFileData.subdata(in: 4..<Int(4 + metadataLength))
        let metadata = try JSONDecoder().decode(EncryptedFileMetadata.self, from: metadataData)
        
        // 暗号化データを読み取り
        let encryptedDataPortion = encryptedFileData.subdata(in: Int(4 + metadataLength)..<encryptedFileData.count)
        
        let encryptedData = EncryptedData(
            data: encryptedDataPortion,
            keyIdentifier: metadata.keyIdentifier,
            algorithm: metadata.encryptionAlgorithm,
            createdAt: metadata.createdAt
        )
        
        // 復号化
        let decryptedData = try decrypt(encryptedData: encryptedData)
        
        try decryptedData.write(to: outputUrl)
        logger.info("File decrypted successfully: \(outputUrl.lastPathComponent)")
        
        return metadata
    }
    
    /// キーローテーションを実行
    /// - Parameter oldKeyIdentifier: 古いキーの識別子
    /// - Returns: 新しいキーの識別子
    func rotateKey(oldKeyIdentifier: String) throws -> String {
        logger.info("Rotating encryption key: \(oldKeyIdentifier)")
        
        // 新しいキーを生成
        let newKeyIdentifier = try generateEncryptionKey()
        
        // 古いキーの使用状況をチェック（実際の実装では使用中データの再暗号化が必要）
        logger.warning("Key rotation completed. Old encrypted data should be re-encrypted with new key.")
        
        return newKeyIdentifier
    }
    
    /// キーの有効期限をチェック
    /// - Parameter keyIdentifier: チェックするキーの識別子
    /// - Returns: キーが有効かどうか
    func isKeyValid(_ keyIdentifier: String) -> Bool {
        do {
            // キーが存在するかチェック
            _ = try retrieveDataFromKeychain(identifier: keyIdentifier)
            
            // 実際の実装では作成日時もチェックして有効期限を確認
            return true
            
        } catch {
            logger.warning("Key validation failed for \(keyIdentifier): \(error.localizedDescription)")
            return false
        }
    }
    
    // MARK: - Private Methods
    
    /// AES-256で暗号化
    private func encryptWithAES256(data: Data) throws -> EncryptedData {
        let keyIdentifier = try generateEncryptionKey()
        return try encryptWithKey(data: data, keyIdentifier: keyIdentifier)
    }
    
    /// AES-256 GCMで暗号化
    private func encryptWithAES256GCM(data: Data) throws -> EncryptedData {
        let keyIdentifier = UUID().uuidString
        let key = SymmetricKey(size: .bits256)
        
        // キーをKeychainに保存
        try storeSymmetricKey(key, identifier: keyIdentifier)
        
        // AES-GCMで暗号化
        let sealedBox = try AES.GCM.seal(data, using: key)
        
        guard let combinedData = sealedBox.combined else {
            throw EncryptionError.encryptionFailed
        }
        
        return EncryptedData(
            data: combinedData,
            keyIdentifier: keyIdentifier,
            algorithm: .aes256GCM,
            createdAt: Date()
        )
    }
    
    /// 指定されたキーでデータを暗号化
    private func encryptWithKey(data: Data, keyIdentifier: String) throws -> EncryptedData {
        let key = try retrieveSymmetricKey(identifier: keyIdentifier)
        
        let sealedBox = try AES.GCM.seal(data, using: key)
        
        guard let combinedData = sealedBox.combined else {
            throw EncryptionError.encryptionFailed
        }
        
        return EncryptedData(
            data: combinedData,
            keyIdentifier: keyIdentifier,
            algorithm: .aes256GCM,
            createdAt: Date()
        )
    }
    
    /// AES-256で復号化
    private func decryptWithAES256(encryptedData: EncryptedData) throws -> Data {
        return try decryptWithAES256GCM(encryptedData: encryptedData)
    }
    
    /// AES-256 GCMで復号化
    private func decryptWithAES256GCM(encryptedData: EncryptedData) throws -> Data {
        let key = try retrieveSymmetricKey(identifier: encryptedData.keyIdentifier)
        
        let sealedBox = try AES.GCM.SealedBox(combined: encryptedData.data)
        let decryptedData = try AES.GCM.open(sealedBox, using: key)
        
        return decryptedData
    }
    
    /// 対称キーをKeychainに保存
    private func storeSymmetricKey(_ key: SymmetricKey, identifier: String) throws {
        let keyData = key.withUnsafeBytes { Data($0) }
        try storeDataInKeychain(keyData, identifier: identifier)
    }
    
    /// 対称キーをKeychainから取得
    private func retrieveSymmetricKey(identifier: String) throws -> SymmetricKey {
        let keyData = try retrieveDataFromKeychain(identifier: identifier)
        return SymmetricKey(data: keyData)
    }
    
    /// データをKeychainに保存
    private func storeDataInKeychain(_ data: Data, identifier: String) throws {
        // 既存のアイテムを削除
        try? deleteDataFromKeychain(identifier: identifier)
        
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: identifier,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        
        // セキュアエンクレーブが利用可能な場合は使用
        if useSecureEnclave {
            query[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave
        }
        
        let status = SecItemAdd(query as CFDictionary, nil)
        
        guard status == errSecSuccess else {
            throw EncryptionError.keychainError(status)
        }
    }
    
    /// データをKeychainから取得
    private func retrieveDataFromKeychain(identifier: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: identifier,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess else {
            throw EncryptionError.keychainError(status)
        }
        
        guard let data = result as? Data else {
            throw EncryptionError.invalidKeychainData
        }
        
        return data
    }
    
    /// データをKeychainから削除
    private func deleteDataFromKeychain(identifier: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: identifier
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw EncryptionError.keychainError(status)
        }
    }
    
    /// セキュアエンクレーブが利用可能かチェック
    private func isSecureEnclaveAvailable() -> Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }
    
    /// すべてのキーを削除（デバッグ用）
    func deleteAllKeys() throws {
        logger.warning("Deleting all encryption keys")
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw EncryptionError.keychainError(status)
        }
        
        logger.info("All encryption keys deleted")
    }
    
    /// 保存されているキー一覧を取得（デバッグ用）
    func listStoredKeys() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                return []
            }
            throw EncryptionError.keychainError(status)
        }
        
        guard let items = result as? [[String: Any]] else {
            return []
        }
        
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}

// MARK: - Supporting Types

/// 暗号化エラー
enum EncryptionError: LocalizedError {
    case encryptionFailed
    case decryptionFailed
    case invalidFileFormat
    case keychainError(OSStatus)
    case invalidKeychainData
    case keyNotFound
    
    var errorDescription: String? {
        switch self {
        case .encryptionFailed:
            return "暗号化に失敗しました。"
        case .decryptionFailed:
            return "復号化に失敗しました。"
        case .invalidFileFormat:
            return "無効なファイル形式です。"
        case .keychainError(let status):
            return "Keychain操作エラー: \(status)"
        case .invalidKeychainData:
            return "無効なKeychainデータです。"
        case .keyNotFound:
            return "暗号化キーが見つかりません。"
        }
    }
}

/// 暗号化されたファイルのメタデータ
struct EncryptedFileMetadata: Codable {
    let originalFilename: String
    let originalSize: Int
    let encryptionAlgorithm: EncryptionAlgorithm
    let keyIdentifier: String
    let createdAt: Date
}

// MARK: - Debug Support

#if DEBUG
extension EncryptionService {
    
    /// デバッグ情報を出力
    func printDebugInfo() {
        do {
            let keys = try listStoredKeys()
            logger.debug("""
                EncryptionService Debug Info:
                - Secure Enclave Available: \(self.useSecureEnclave)
                - Default Algorithm: \(self.defaultAlgorithm.rawValue)
                - Stored Keys Count: \(keys.count)
                - Stored Keys: \(keys.joined(separator: ", "))
                """)
        } catch {
            logger.debug("Failed to get debug info: \(error.localizedDescription)")
        }
    }
    
    /// テスト用の暗号化/復号化
    func testEncryptionRoundTrip() throws {
        let testData = "Hello, World! 暗号化テスト".data(using: .utf8)!
        
        let encrypted = try encrypt(data: testData)
        let decrypted = try decrypt(encryptedData: encrypted)
        
        guard testData == decrypted else {
            throw EncryptionError.encryptionFailed
        }
        
        logger.info("Encryption round-trip test passed")
    }
}
#endif