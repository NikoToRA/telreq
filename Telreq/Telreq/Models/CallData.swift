import Foundation

// MARK: - Core Data Models for Call Transcription

/// 通話データの構造化モデル
struct StructuredCallData: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let duration: TimeInterval
    let participantNumber: String
    let audioFileUrl: String
    let transcriptionText: String
    let summary: CallSummary
    let metadata: CallMetadata
    let isShared: Bool
    let sharedWith: [String]
    let createdAt: Date
    let updatedAt: Date
    
    init(
        id: UUID = UUID(),
        timestamp: Date,
        duration: TimeInterval,
        participantNumber: String,
        audioFileUrl: String,
        transcriptionText: String,
        summary: CallSummary,
        metadata: CallMetadata,
        isShared: Bool = false,
        sharedWith: [String] = []
    ) {
        self.id = id
        self.timestamp = timestamp
        self.duration = duration
        self.participantNumber = participantNumber
        self.audioFileUrl = audioFileUrl
        self.transcriptionText = transcriptionText
        self.summary = summary
        self.metadata = metadata
        self.isShared = isShared
        self.sharedWith = sharedWith
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

/// 通話要約データ
struct CallSummary: Codable {
    let keyPoints: [String]
    let summary: String
    let duration: TimeInterval
    let participants: [String]
    let tags: [String]
    let confidence: Double
    
    init(
        keyPoints: [String],
        summary: String,
        duration: TimeInterval,
        participants: [String],
        tags: [String] = [],
        confidence: Double
    ) {
        self.keyPoints = keyPoints
        self.summary = summary
        self.duration = duration
        self.participants = participants
        self.tags = tags
        self.confidence = confidence
    }
}

/// 通話メタデータ
struct CallMetadata: Codable {
    let callDirection: CallDirection
    let audioQuality: AudioQuality
    let transcriptionMethod: TranscriptionMethod
    let language: String
    let confidence: Double
    let startTime: Date
    let endTime: Date
    let deviceInfo: DeviceInfo
    let networkInfo: NetworkInfo
    
    init(
        callDirection: CallDirection,
        audioQuality: AudioQuality,
        transcriptionMethod: TranscriptionMethod,
        language: String,
        confidence: Double,
        startTime: Date,
        endTime: Date,
        deviceInfo: DeviceInfo,
        networkInfo: NetworkInfo
    ) {
        self.callDirection = callDirection
        self.audioQuality = audioQuality
        self.transcriptionMethod = transcriptionMethod
        self.language = language
        self.confidence = confidence
        self.startTime = startTime
        self.endTime = endTime
        self.deviceInfo = deviceInfo
        self.networkInfo = networkInfo
    }
}

/// 通話方向
enum CallDirection: String, Codable, CaseIterable {
    case incoming = "incoming"
    case outgoing = "outgoing"
    
    var displayName: String {
        switch self {
        case .incoming:
            return "着信"
        case .outgoing:
            return "発信"
        }
    }
}

/// 音声品質レベル
enum AudioQuality: String, Codable, CaseIterable {
    case excellent = "excellent"
    case good = "good"
    case fair = "fair"
    case poor = "poor"
    
    var displayName: String {
        switch self {
        case .excellent:
            return "優秀"
        case .good:
            return "良好"
        case .fair:
            return "普通"
        case .poor:
            return "不良"
        }
    }
    
    var confidenceThreshold: Double {
        switch self {
        case .excellent:
            return 0.95
        case .good:
            return 0.85
        case .fair:
            return 0.70
        case .poor:
            return 0.50
        }
    }
}

/// 転写方法
enum TranscriptionMethod: String, Codable, CaseIterable {
    case iosSpeech = "ios_speech"
    case azureSpeech = "azure_speech"
    case hybridProcessing = "hybrid_processing"
    
    var displayName: String {
        switch self {
        case .iosSpeech:
            return "iOS Speech Framework"
        case .azureSpeech:
            return "Azure Speech Service"
        case .hybridProcessing:
            return "ハイブリッド処理"
        }
    }
}

/// デバイス情報
struct DeviceInfo: Codable {
    let deviceModel: String
    let systemVersion: String
    let appVersion: String
    let batteryLevel: Float?
    let availableMemory: Int64?
    
    init(
        deviceModel: String,
        systemVersion: String,
        appVersion: String,
        batteryLevel: Float? = nil,
        availableMemory: Int64? = nil
    ) {
        self.deviceModel = deviceModel
        self.systemVersion = systemVersion
        self.appVersion = appVersion
        self.batteryLevel = batteryLevel
        self.availableMemory = availableMemory
    }
}

/// ネットワーク情報
struct NetworkInfo: Codable {
    let connectionType: NetworkConnectionType
    let signalStrength: Int?
    let bandwidth: Double?
    
    init(
        connectionType: NetworkConnectionType,
        signalStrength: Int? = nil,
        bandwidth: Double? = nil
    ) {
        self.connectionType = connectionType
        self.signalStrength = signalStrength
        self.bandwidth = bandwidth
    }
}

/// ネットワーク接続タイプ
enum NetworkConnectionType: String, Codable, CaseIterable {
    case wifi = "wifi"
    case cellular5G = "cellular_5g"
    case cellular4G = "cellular_4g"
    case cellular3G = "cellular_3g"
    case offline = "offline"
    
    var displayName: String {
        switch self {
        case .wifi:
            return "Wi-Fi"
        case .cellular5G:
            return "5G"
        case .cellular4G:
            return "4G"
        case .cellular3G:
            return "3G"
        case .offline:
            return "オフライン"
        }
    }
}

// MARK: - Call Record for UI Display

/// UI表示用の通話記録
struct CallRecord: Identifiable, Hashable {
    let id: UUID
    let timestamp: Date
    let duration: TimeInterval
    let participantNumber: String
    let summaryPreview: String
    let audioQuality: AudioQuality
    let transcriptionMethod: TranscriptionMethod
    let isShared: Bool
    let hasAudio: Bool
    let tags: [String]
    
    init(from callData: StructuredCallData) {
        self.id = callData.id
        self.timestamp = callData.timestamp
        self.duration = callData.duration
        self.participantNumber = callData.participantNumber
        self.summaryPreview = String(callData.summary.summary.prefix(100))
        self.audioQuality = callData.metadata.audioQuality
        self.transcriptionMethod = callData.metadata.transcriptionMethod
        self.isShared = callData.isShared
        self.hasAudio = !callData.audioFileUrl.isEmpty
        self.tags = callData.summary.tags
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: CallRecord, rhs: CallRecord) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Extensions

extension StructuredCallData {
    /// 通話時間の表示用フォーマット
    var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    /// 参加者番号のマスク表示
    var maskedParticipantNumber: String {
        guard participantNumber.count > 4 else { return participantNumber }
        let prefix = String(participantNumber.prefix(3))
        let suffix = String(participantNumber.suffix(4))
        return "\(prefix)****\(suffix)"
    }
    
    /// データサイズの概算計算
    var estimatedDataSize: Int64 {
        let textSize = Int64(transcriptionText.utf8.count)
        let audioSize = Int64(duration * 32000) // 32kbps相当
        return textSize + audioSize
    }
}

extension CallSummary {
    /// 要約の信頼度に基づく品質評価
    var summaryQualityLevel: AudioQuality {
        switch confidence {
        case 0.9...:
            return .excellent
        case 0.8..<0.9:
            return .good
        case 0.6..<0.8:
            return .fair
        default:
            return .poor
        }
    }
}