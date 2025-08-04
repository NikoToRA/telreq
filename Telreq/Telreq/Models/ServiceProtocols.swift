import Foundation
import AVFoundation
import Speech

// MARK: - Audio Capture Service Protocol

/// 音声キャプチャサービスのプロトコル
protocol AudioCaptureServiceProtocol: AnyObject {
    /// 音声キャプチャを開始
    func startCapture() async throws -> Bool
    
    /// 音声キャプチャを停止
    func stopCapture()
    
    /// 現在の音声バッファを取得
    func getAudioBuffer() -> AVAudioPCMBuffer?
    
    /// 音声品質を監視
    func monitorAudioQuality() -> AudioQuality
    
    /// マイクアクセス権限を確認
    func checkMicrophonePermission() async -> Bool
    
    /// マイクアクセス権限を要求
    func requestMicrophonePermission() async -> Bool
    
    /// 音声キャプチャの状態
    var captureState: AudioCaptureState { get }
    
    /// 音声レベル（0.0-1.0）
    var audioLevel: Float { get }
    
    /// デリゲート
    var delegate: AudioCaptureDelegate? { get set }
}

/// 音声キャプチャの状態
enum AudioCaptureState: Equatable {
    case idle
    case preparing
    case recording
    case paused
    case error(Error)

    static func == (lhs: AudioCaptureState, rhs: AudioCaptureState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.preparing, .preparing),
             (.recording, .recording),
             (.paused, .paused):
            return true
        case (.error, .error):
            // ErrorはEquatableに準拠していないため、ここでは単純にfalseを返すか、
            // エラーの内容を比較する方法を別途検討する必要があります。
            // 今回は状態の種別のみを比較するため、これで十分とします。
            return false
        default:
            return false
        }
    }
}

/// 音声キャプチャデリゲート
protocol AudioCaptureDelegate: AnyObject {
    func audioCaptureDidStart()
    func audioCaptureDidStop()
    func audioCapture(didReceiveBuffer buffer: AVAudioPCMBuffer)
    func audioCapture(didUpdateLevel level: Float)
    func audioCapture(didEncounterError error: Error)
}

// MARK: - Speech Recognition Service Protocol

/// 音声認識サービスのプロトコル
protocol SpeechRecognitionServiceProtocol: AnyObject {
    /// 音声認識を開始
    func startRecognition(audioBuffer: AVAudioPCMBuffer) async throws -> String
    
    /// 音声認識を停止
    func stopRecognition()
    
    /// バックアップサービスに切り替え
    func switchToBackupService() async throws
    
    /// 転写方法を切り替え
    func switchTranscriptionMethod(_ method: TranscriptionMethod)
    
    /// リアルタイム音声認識を開始
    func startRealtimeRecognition() async throws
    
    /// 現在の認識方法
    var currentMethod: TranscriptionMethod { get }
    
    /// 認識精度（0.0-1.0）
    var confidence: Double { get }
    
    /// サポートする言語一覧
    var supportedLanguages: [String] { get }
    
    /// デリゲート
    var delegate: SpeechRecognitionDelegate? { get set }
    
    /// 音声認識権限をチェック
    func checkSpeechRecognitionPermission() async -> Bool
    
    /// 最終的な音声認識結果を取得
    func getFinalRecognitionResult() async throws -> SpeechRecognitionResult
}

/// 音声認識デリゲート
protocol SpeechRecognitionDelegate: AnyObject {
    func speechRecognition(didRecognizeText text: String, isFinal: Bool)
    func speechRecognition(didCompleteWithResult result: SpeechRecognitionResult)
    func speechRecognition(didFailWithError error: Error)
    func speechRecognitionDidTimeout()
}

/// 音声認識結果
struct SpeechRecognitionResult {
    let text: String
    let confidence: Double
    let method: TranscriptionMethod
    let language: String
    let processingTime: TimeInterval
    let segments: [SpeechSegment]
}

/// 音声セグメント
struct SpeechSegment {
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let confidence: Double
    let speakerId: String?
}

// MARK: - Text Processing Service Protocol

/// テキスト処理サービスのプロトコル
protocol TextProcessingServiceProtocol: AnyObject {
    /// テキストを要約
    func summarizeText(_ text: String) async throws -> CallSummary
    
    /// 通話データを構造化
    func structureCallData(_ text: String, metadata: CallMetadata) async throws -> StructuredCallData
    
    /// キーワードを抽出
    func extractKeywords(from text: String) async throws -> [String]
    
    /// アクションアイテムを抽出
    func extractActionItems(from text: String) async throws -> [String]
    
    /// 発言者を識別（可能な場合）
    func identifySpeakers(in text: String) async throws -> [String]
    
    /// 言語を検出
    func detectLanguage(in text: String) -> String
    
    /// テキストの品質を評価
    func evaluateTextQuality(_ text: String) -> Double
}

// MARK: - Storage Service Protocol

/// ストレージサービスのプロトコル
protocol StorageServiceProtocol: AnyObject {
    /// 通話データを保存
    func saveCallData(_ data: StructuredCallData) async throws -> String
    
    /// 通話履歴を読み込み
    func loadCallHistory(limit: Int, offset: Int) async throws -> [CallRecord]
    
    /// 通話記録を削除
    func deleteCallRecord(_ id: String) async throws
    
    /// 通話記録を共有
    func shareCallRecord(_ id: String, with userId: String) async throws
    
    /// 音声ファイルをアップロード
    func uploadAudioFile(_ fileUrl: URL, for callId: String) async throws -> String
    
    /// 音声ファイルをダウンロード
    func downloadAudioFile(for callId: String) async throws -> URL
    
    /// ストレージ使用量を取得
    func getStorageUsage() async throws -> StorageUsage
    
    /// オフライン同期
    func syncOfflineData() async throws
    
    /// ストレージの状態
    var storageState: StorageState { get }
    
    /// ストレージを初期化
    func initializeStorage() async throws
}

/// ストレージ使用量
struct StorageUsage {
    let totalUsed: Int64
    let audioFilesSize: Int64
    let textDataSize: Int64
    let metadataSize: Int64
    let availableQuota: Int64
}

/// ストレージの状態
enum StorageState {
    case available
    case offline
    case syncing
    case error(Error)
    case quotaExceeded
}

// MARK: - Sharing Service Protocol

/// 共有サービスのプロトコル
protocol SharingServiceProtocol: AnyObject {
    /// 共有リクエストを送信
    func requestSharing(callId: String, recipientId: String) async throws
    
    /// 共有リクエストを承認
    func acceptSharingRequest(_ request: SharingRequest) async throws
    
    /// 共有記録をマージ
    func mergeSharedRecords(_ records: [CallRecord]) async throws -> CallRecord
    
    /// 共有記録一覧を取得
    func getSharedRecords() async throws -> [SharedCallRecord]
    
    /// 送信済み共有記録を取得
    func getSentSharedRecords() async throws -> [SharedCallRecord]
    
    /// 共有リクエスト一覧を取得
    func getSharingRequests() async throws -> [SharingRequest]
    
    /// 共有を取り消し
    func revokeSharing(callId: String, userId: String) async throws
    
    /// ユーザーを検索
    func searchUsers(query: String) async throws -> [UserProfile]
}

/// 共有リクエスト
struct SharingRequest: Codable, Identifiable {
    let id: UUID
    let callId: String
    let senderId: String
    let senderName: String
    let recipientId: String
    let message: String?
    let permissionLevel: SharingPermission
    let expiryDate: Date?
    let createdAt: Date
    let status: SharingRequestStatus
}

/// 共有権限レベル
enum SharingPermission: String, Codable {
    case read = "read"
    case readWrite = "read_write"
    case admin = "admin"
}

/// 共有リクエストの状態
enum SharingRequestStatus: String, Codable {
    case pending = "pending"
    case accepted = "accepted"
    case rejected = "rejected"
    case expired = "expired"
}

/// 共有された通話記録
struct SharedCallRecord: Identifiable {
    let id: UUID
    let originalCallId: String
    let ownerId: String
    let ownerName: String
    let sharedAt: Date
    let permission: SharingPermission
    let callRecord: CallRecord
}

/// ユーザープロファイル
struct UserProfile: Codable, Identifiable, Hashable {
    let id: UUID
    let displayName: String
    let email: String?
    let phoneNumber: String?
    let avatar: String?
    let isOnline: Bool

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: UserProfile, rhs: UserProfile) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Encryption Service Protocol

/// 暗号化サービスのプロトコル
protocol EncryptionServiceProtocol: AnyObject {
    /// データを暗号化
    func encrypt(data: Data) throws -> EncryptedData
    
    /// データを復号化
    func decrypt(encryptedData: EncryptedData) throws -> Data
    
    /// 暗号化キーを生成
    func generateEncryptionKey() throws -> String
    
    /// 暗号化キーを保存
    func storeEncryptionKey(_ key: String, for identifier: String) throws
    
    /// 暗号化キーを取得
    func retrieveEncryptionKey(for identifier: String) throws -> String
    
    /// 暗号化キーを削除
    func deleteEncryptionKey(for identifier: String) throws
}

// MARK: - Offline Data Manager Protocol

/// オフラインデータ管理サービスのプロトコル
protocol OfflineDataManagerProtocol: AnyObject {
    /// ローカルデータを保存
    func saveLocalData(_ data: StructuredCallData) async throws
    
    /// ローカルデータを取得
    func getLocalData(callId: String) async throws -> StructuredCallData?
    
    /// すべてのローカルデータを取得
    func getAllLocalData() async throws -> [StructuredCallData]
    
    /// ローカルデータを削除
    func deleteLocalData(callId: String) async throws
    
    /// 同期が必要なデータを取得
    func getPendingSyncData() async throws -> [StructuredCallData]
    
    /// 同期完了をマーク
    func markSyncCompleted(callId: String) async throws
    
    /// オフラインストレージの容量情報
    func getStorageInfo() async throws -> LocalStorageInfo
    
    /// キャッシュをクリア
    func clearCache() async throws

    /// 通話履歴を読み込み
    func loadCallHistory(limit: Int, offset: Int) async throws -> [CallRecord]

    /// 通話記録を削除
    func deleteCallRecord(_ id: String) async throws
    
    /// 通話詳細を読み込み
    func loadCallDetails(_ callId: String) async throws -> StructuredCallData
}

/// ローカルストレージ情報
struct LocalStorageInfo {
    let usedBytes: Int64
    let availableBytes: Int64
    let totalFiles: Int
    let pendingSyncCount: Int
}

/// 暗号化されたデータ
struct EncryptedData: Codable {
    let data: Data
    let keyIdentifier: String
    let algorithm: EncryptionAlgorithm
    let createdAt: Date
}

/// 暗号化アルゴリズム
enum EncryptionAlgorithm: String, Codable {
    case aes256 = "aes256"
    case aes256GCM = "aes256_gcm"
}

// MARK: - Error Types

/// アプリケーションエラー
enum AppError: LocalizedError {
    case audioPermissionDenied
    case speechRecognitionFailed(underlying: Error)
    case speechRecognitionUnavailable
    case storageConnectionFailed
    case storageQuotaExceeded
    case sharingRequestFailed(reason: String)
    case encryptionFailed
    case networkUnavailable
    case invalidConfiguration
    case userNotFound
    case callRecordNotFound
    
    var errorDescription: String? {
        switch self {
        case .audioPermissionDenied:
            return "マイクアクセスが拒否されました。設定でアクセスを許可してください。"
        case .speechRecognitionFailed(let _):
            return "音声認識に失敗しました"
        case .speechRecognitionUnavailable:
            return "音声認識機能が利用できません。"
        case .storageConnectionFailed:
            return "ストレージへの接続に失敗しました。"
        case .storageQuotaExceeded:
            return "ストレージ容量の上限に達しています。"
        case .sharingRequestFailed(let _):
            return "共有リクエストに失敗しました"
        case .encryptionFailed:
            return "データの暗号化に失敗しました。"
        case .networkUnavailable:
            return "ネットワーク接続がありません。"
        case .invalidConfiguration:
            return "設定が無効です。"
        case .userNotFound:
            return "ユーザーが見つかりません。"
        case .callRecordNotFound:
            return "通話記録が見つかりません。"
        }
    }
}

// MARK: - Azure Service Configurations



/// Azure Blob Storageの設定
struct AzureStorageConfig {
    let connectionString: String
    let containerName: String
}

/// Azure Speech Serviceの設定
struct AzureSpeechConfig {
    let subscriptionKey: String
    let region: String
}

/// Azure OpenAI Serviceの設定
struct AzureOpenAIConfig {
    let endpoint: URL
    let apiKey: String
    let deploymentName: String
}

// MARK: - Call Manager Protocol

protocol CallManagerProtocol: AnyObject {
    var delegate: CallManagerDelegate? { get set }
    func startMonitoring()
    func stopMonitoring()
    func startAudioCapture() async -> Bool
    func stopAudioCapture()
    func stopAudioCaptureAndSave() async
    func startCallRecording() async throws
    func stopCallRecording() async throws -> SpeechRecognitionResult
}

