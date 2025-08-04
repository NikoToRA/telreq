import Foundation
import os.log

/// Azure API設定管理
///
/// 開発環境とプロダクション環境でのAzure API設定を管理します。
struct AzureConfig {
    
    // MARK: - Environment Configuration
    
    /// 環境変数からAzure設定を取得
    static func loadFromEnvironment() -> AzureKeys {
        let storageConnectionString = ProcessInfo.processInfo.environment["AZURE_STORAGE_CONNECTION_STRING"]
        let speechSubscriptionKey = ProcessInfo.processInfo.environment["AZURE_SPEECH_SUBSCRIPTION_KEY"]
        let openAIAPIKey = ProcessInfo.processInfo.environment["AZURE_OPENAI_API_KEY"]
        let openAIEndpoint = ProcessInfo.processInfo.environment["AZURE_OPENAI_ENDPOINT"]
        
        return AzureKeys(
            storageConnectionString: storageConnectionString ?? getDefaultStorageConnectionString(),
            speechSubscriptionKey: speechSubscriptionKey ?? getDefaultSpeechSubscriptionKey(),
            openAIAPIKey: openAIAPIKey ?? getDefaultOpenAIAPIKey(),
            openAIEndpoint: openAIEndpoint ?? getDefaultOpenAIEndpoint()
        )
    }
    
    // MARK: - Default Values (Development)
    
    /// デフォルトのストレージ接続文字列
    private static func getDefaultStorageConnectionString() -> String {
        #if DEBUG
        return "DefaultEndpointsProtocol=https;AccountName=telreqstorage;AccountKey=your-storage-account-key;EndpointSuffix=core.windows.net"
        #else
        return ""
        #endif
    }
    
    /// デフォルトのSpeech Subscription Key
    private static func getDefaultSpeechSubscriptionKey() -> String {
        #if DEBUG
        return "your-speech-subscription-key"
        #else
        return ""
        #endif
    }
    
    /// デフォルトのOpenAI API Key
    private static func getDefaultOpenAIAPIKey() -> String {
        #if DEBUG
        return "your-openai-api-key"
        #else
        return ""
        #endif
    }
    
    /// デフォルトのOpenAI Endpoint
    private static func getDefaultOpenAIEndpoint() -> String {
        #if DEBUG
        return "https://telreq-openai.openai.azure.com/"
        #else
        return ""
        #endif
    }
    
    // MARK: - Configuration Validation
    
    /// 設定が有効かどうかを確認
    static func validateConfiguration(_ keys: AzureKeys) -> Bool {
        #if DEBUG
        // デバッグモードでは基本的な設定チェックのみ
        let hasStorageConfig = !keys.storageConnectionString.isEmpty
        let hasSpeechConfig = !keys.speechSubscriptionKey.isEmpty
        let hasOpenAIConfig = !keys.openAIAPIKey.isEmpty && !keys.openAIEndpoint.isEmpty
        
        return hasStorageConfig && hasSpeechConfig && hasOpenAIConfig
        #else
        // プロダクションモードでは厳密な検証
        let hasStorageConfig = !keys.storageConnectionString.isEmpty && 
                              keys.storageConnectionString.contains("AccountName=") &&
                              !keys.storageConnectionString.contains("your-storage-account-key")
        let hasSpeechConfig = !keys.speechSubscriptionKey.isEmpty &&
                             !keys.speechSubscriptionKey.contains("your-speech-subscription-key")
        let hasOpenAIConfig = !keys.openAIAPIKey.isEmpty && 
                             !keys.openAIEndpoint.isEmpty &&
                             !keys.openAIAPIKey.contains("your-openai-api-key")
        
        return hasStorageConfig && hasSpeechConfig && hasOpenAIConfig
        #endif
    }
    
    /// 設定の詳細をログ出力
    static func logConfigurationStatus(_ keys: AzureKeys) {
        let logger = Logger(subsystem: "com.telreq.app", category: "AzureConfig")
        
        logger.info("Azure Configuration Status:")
        logger.info("- Storage: \(keys.storageConnectionString.isEmpty ? "Not configured" : "Configured")")
        logger.info("- Speech: \(keys.speechSubscriptionKey.isEmpty ? "Not configured" : "Configured")")
        logger.info("- OpenAI: \(keys.openAIAPIKey.isEmpty ? "Not configured" : "Configured")")
        logger.info("- OpenAI Endpoint: \(keys.openAIEndpoint.isEmpty ? "Not configured" : "Configured")")
        
        if validateConfiguration(keys) {
            logger.info("All Azure services are properly configured")
        } else {
            logger.warning("Some Azure services are not properly configured")
        }
    }
}

/// 拡張されたAzure認証情報
struct AzureKeys {
    let storageConnectionString: String
    let speechSubscriptionKey: String
    let openAIAPIKey: String
    let openAIEndpoint: String
    
    init(
        storageConnectionString: String,
        speechSubscriptionKey: String,
        openAIAPIKey: String,
        openAIEndpoint: String = ""
    ) {
        self.storageConnectionString = storageConnectionString
        self.speechSubscriptionKey = speechSubscriptionKey
        self.openAIAPIKey = openAIAPIKey
        self.openAIEndpoint = openAIEndpoint
    }
} 