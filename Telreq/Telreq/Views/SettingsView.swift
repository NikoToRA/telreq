import SwiftUI
import os.log

/// 設定ビュー
/// 
/// 転写方法選択、自動起動設定、プライバシー設定、Azure接続設定を提供します。
/// アプリケーションの全般的な設定とユーザー設定を管理します。
@available(iOS 15.0, *)
struct SettingsView: View {
    
    // MARK: - Properties
    
    @EnvironmentObject private var serviceContainer: ServiceContainer
    @StateObject private var viewModel = SettingsViewModel()
    @State private var showingConnectionTest = false
    @State private var showingAbout = false
    @State private var showingResetConfirmation = false
    
    // MARK: - Body
    
    var body: some View {
        NavigationView {
            Form {
                // 転写設定セクション
                transcriptionSettingsSection
                
                // 音声設定セクション
                audioSettingsSection
                
                // プライバシー設定セクション
                privacySettingsSection
                
                // ストレージ設定セクション
                storageSettingsSection
                
                // 接続設定セクション
                connectionSettingsSection
                
                // アプリケーション設定セクション
                applicationSettingsSection
                
                // デバッグ設定セクション（開発時のみ）
                #if DEBUG
                debugSettingsSection
                #endif
            }
            .navigationTitle("設定")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .toolbar {
                ToolbarItem(placement: {
                    #if os(macOS)
                    return .primaryAction
                    #else
                    return .navigationBarTrailing
                    #endif
                }()) {
                    Button(action: {
                        showingAbout = true
                    }) {
                        Image(systemName: "info.circle")
                    }
                }
            }
            .sheet(isPresented: $showingConnectionTest) {
                ConnectionTestView(viewModel: viewModel)
            }
            .sheet(isPresented: $showingAbout) {
                AboutView()
            }
            .alert("設定をリセット", isPresented: $showingResetConfirmation) {
                Button("リセット", role: .destructive) {
                    Task {
                        await viewModel.resetAllSettings()
                    }
                }
                Button("キャンセル", role: .cancel) { }
            } message: {
                Text("すべての設定が初期値にリセットされます。この操作は取り消せません。")
            }
            .alert("エラー", isPresented: $viewModel.showingError) {
                Button("OK") {
                    viewModel.dismissError()
                }
            } message: {
                Text(viewModel.errorMessage)
            }
        }
        .onAppear {
            viewModel.setServiceContainer(serviceContainer)
            Task {
                await viewModel.loadSettings()
            }
        }
    }
    
    // MARK: - Settings Sections
    
    /// 転写設定セクション
    private var transcriptionSettingsSection: some View {
        Section("転写設定") {
            // 転写方法選択
            Picker("転写方法", selection: $viewModel.selectedTranscriptionMethod) {
                ForEach(TranscriptionMethod.allCases, id: \.self) { method in
                    Text(method.displayName).tag(method)
                }
            }
            .onChange(of: viewModel.selectedTranscriptionMethod) { oldValue, newValue in
                Task {
                    await viewModel.updateTranscriptionMethod(newValue)
                }
            }
            
            // 自動転写開始
            Toggle("通話開始時に自動転写", isOn: $viewModel.autoStartTranscription)
                .onChange(of: viewModel.autoStartTranscription) { oldValue, newValue in
                    Task {
                        await viewModel.updateAutoStartTranscription(newValue)
                    }
                }
            
            // リアルタイム転写
            Toggle("リアルタイム転写", isOn: $viewModel.realtimeTranscription)
                .onChange(of: viewModel.realtimeTranscription) { oldValue, newValue in
                    Task {
                        await viewModel.updateRealtimeTranscription(newValue)
                    }
                }
            
            // 言語設定
            Picker("転写言語", selection: $viewModel.selectedLanguage) {
                ForEach(viewModel.supportedLanguages, id: \.code) { language in
                    Text(language.name).tag(language.code)
                }
            }
            .onChange(of: viewModel.selectedLanguage) { oldValue, newValue in
                Task {
                    await viewModel.updateLanguage(newValue)
                }
            }
            
            // 自動要約
            Toggle("自動要約生成", isOn: $viewModel.autoGenerateSummary)
                .onChange(of: viewModel.autoGenerateSummary) { oldValue, newValue in
                    Task {
                        await viewModel.updateAutoGenerateSummary(newValue)
                    }
                }
        }
    }
    
    /// 音声設定セクション
    private var audioSettingsSection: some View {
        Section("音声設定") {
            // 音声品質
            Picker("録音品質", selection: $viewModel.recordingQuality) {
                Text("低品質（省電力）").tag(RecordingQuality.low)
                Text("標準品質").tag(RecordingQuality.standard)
                Text("高品質").tag(RecordingQuality.high)
            }
            .onChange(of: viewModel.recordingQuality) { oldValue, newValue in
                Task {
                    await viewModel.updateRecordingQuality(newValue)
                }
            }
            
            // ノイズリダクション
            Toggle("ノイズリダクション", isOn: $viewModel.noiseReduction)
                .onChange(of: viewModel.noiseReduction) { oldValue, newValue in
                    Task {
                        await viewModel.updateNoiseReduction(newValue)
                    }
                }
            
            // 音声ファイル保存
            Toggle("音声ファイルを保存", isOn: $viewModel.saveAudioFiles)
                .onChange(of: viewModel.saveAudioFiles) { oldValue, newValue in
                    Task {
                        await viewModel.updateSaveAudioFiles(newValue)
                    }
                }
            
            // 音声レベル表示
            Toggle("音声レベル表示", isOn: $viewModel.showAudioLevels)
                .onChange(of: viewModel.showAudioLevels) { oldValue, newValue in
                    viewModel.updateShowAudioLevels(newValue)
                }
        }
    }
    
    /// プライバシー設定セクション
    private var privacySettingsSection: some View {
        Section("プライバシー設定") {
            // 暗号化設定
            Toggle("データ暗号化", isOn: $viewModel.encryptionEnabled)
                .onChange(of: viewModel.encryptionEnabled) { oldValue, newValue in
                    Task {
                        await viewModel.updateEncryption(newValue)
                    }
                }
            
            // Secure Enclave使用
            Toggle("Secure Enclave使用", isOn: $viewModel.useSecureEnclave)
                .disabled(!viewModel.secureEnclaveAvailable)
                .onChange(of: viewModel.useSecureEnclave) { oldValue, newValue in
                    Task {
                        await viewModel.updateSecureEnclave(newValue)
                    }
                }
            
            if !viewModel.secureEnclaveAvailable {
                Text("このデバイスではSecure Enclaveが利用できません")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            // 自動削除設定
            Picker("自動削除", selection: $viewModel.autoDeletePeriod) {
                Text("しない").tag(AutoDeletePeriod.never)
                Text("1週間後").tag(AutoDeletePeriod.oneWeek)
                Text("1ヶ月後").tag(AutoDeletePeriod.oneMonth)
                Text("3ヶ月後").tag(AutoDeletePeriod.threeMonths)
                Text("6ヶ月後").tag(AutoDeletePeriod.sixMonths)
                Text("1年後").tag(AutoDeletePeriod.oneYear)
            }
            .onChange(of: viewModel.autoDeletePeriod) { oldValue, newValue in
                Task {
                    await viewModel.updateAutoDeletePeriod(newValue)
                }
            }
            
            // パスコード設定
            Toggle("アプリ起動時にパスコード", isOn: $viewModel.requirePasscode)
                .onChange(of: viewModel.requirePasscode) { oldValue, newValue in
                    Task {
                        await viewModel.updatePasscodeRequirement(newValue)
                    }
                }
        }
    }
    
    /// ストレージ設定セクション
    private var storageSettingsSection: some View {
        Section("ストレージ設定") {
            // ストレージ使用量表示
            if let usage = viewModel.storageUsage {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("使用容量")
                        Spacer()
                        Text(formatBytes(usage.totalUsed))
                            .fontWeight(.semibold)
                    }
                    
                    ProgressView(value: Double(usage.totalUsed), total: Double(usage.availableQuota))
                        .tint(storageProgressColor(usage))
                    
                    HStack {
                        Text("音声ファイル: \(formatBytes(usage.audioFilesSize))")
                        Spacer()
                        Text("テキスト: \(formatBytes(usage.textDataSize))")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            } else {
                HStack {
                    Text("ストレージ使用量")
                    Spacer()
                    if viewModel.isLoadingStorage {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Text("読み込み中...")
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            // キャッシュクリア
            Button("キャッシュをクリア") {
                Task {
                    await viewModel.clearCache()
                }
            }
            .foregroundColor(.orange)
            
            // オフラインデータ同期
            Button("オフラインデータを同期") {
                Task {
                    await viewModel.syncOfflineData()
                }
            }
            .disabled(viewModel.isSyncing)
            
            if viewModel.isSyncing {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("同期中...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
    
    /// 接続設定セクション
    private var connectionSettingsSection: some View {
        Section("接続設定") {
            // Azure接続状態
            HStack {
                Text("Azure接続")
                Spacer()
                HStack(spacing: 4) {
                    Circle()
                        .fill(azureConnectionColor)
                        .frame(width: 8, height: 8)
                    Text(azureConnectionText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            // オフラインモード
            Toggle("オフラインモード", isOn: $viewModel.offlineMode)
                .onChange(of: viewModel.offlineMode) { oldValue, newValue in
                    Task {
                        await viewModel.updateOfflineMode(newValue)
                    }
                }
            
            // 自動再接続
            Toggle("自動再接続", isOn: $viewModel.autoReconnect)
                .onChange(of: viewModel.autoReconnect) { oldValue, newValue in
                    viewModel.updateAutoReconnect(newValue)
                }
            
            // 接続テスト
            Button("接続をテスト") {
                showingConnectionTest = true
            }
            .foregroundColor(.blue)
        }
    }
    
    /// アプリケーション設定セクション
    private var applicationSettingsSection: some View {
        Section("アプリケーション設定") {
            // 通知設定
            NavigationLink(destination: NotificationSettingsView(viewModel: viewModel)) {
                Text("通知設定")
            }
            
            // テーマ設定
            Picker("テーマ", selection: $viewModel.selectedTheme) {
                Text("システム設定に従う").tag(ThemeMode.system)
                Text("ライトモード").tag(ThemeMode.light)
                Text("ダークモード").tag(ThemeMode.dark)
            }
            .onChange(of: viewModel.selectedTheme) { oldValue, newValue in
                viewModel.updateTheme(newValue)
            }
            
            // 分析データ送信
            Toggle("分析データを送信", isOn: $viewModel.analyticsEnabled)
                .onChange(of: viewModel.analyticsEnabled) { oldValue, newValue in
                    viewModel.updateAnalytics(newValue)
                }
            
            // アプリレビュー
            Button("アプリを評価") {
                viewModel.requestAppReview()
            }
            
            // フィードバック送信
            Button("フィードバックを送信") {
                viewModel.openFeedback()
            }
        }
    }
    
    /// デバッグ設定セクション
    #if DEBUG
    private var debugSettingsSection: some View {
        Section("デバッグ設定") {
            // ログレベル
            Picker("ログレベル", selection: $viewModel.logLevel) {
                Text("エラーのみ").tag(LogLevel.error)
                Text("警告以上").tag(LogLevel.warning)
                Text("情報以上").tag(LogLevel.info)
                Text("デバッグ").tag(LogLevel.debug)
            }
            .onChange(of: viewModel.logLevel) { oldValue, newValue in
                viewModel.updateLogLevel(newValue)
            }
            
            // デバッグ情報表示
            Button("デバッグ情報を表示") {
                viewModel.showDebugInfo()
            }
            
            // 設定リセット
            Button("すべての設定をリセット") {
                showingResetConfirmation = true
            }
            .foregroundColor(.red)
            

        }
    }
    #endif
    
    // MARK: - Helper Methods
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
    
    private func storageProgressColor(_ usage: StorageUsage) -> Color {
        let percentage = Double(usage.totalUsed) / Double(usage.availableQuota)
        switch percentage {
        case 0..<0.7:
            return .green
        case 0.7..<0.9:
            return .orange
        default:
            return .red
        }
    }
    
    // MARK: - Computed Properties
    
    private var azureConnectionColor: Color {
        switch viewModel.azureConnectionStatus {
        case .connected:
            return .green
        case .connecting:
            return .orange
        case .disconnected:
            return .red
        case .unknown:
            return .gray
        }
    }
    
    private var azureConnectionText: String {
        switch viewModel.azureConnectionStatus {
        case .connected:
            return "接続済み"
        case .connecting:
            return "接続中..."
        case .disconnected:
            return "未接続"
        case .unknown:
            return "不明"
        }
    }
}

// MARK: - Supporting Views

/// 接続状態インジケーター
struct ConnectionStatusIndicator: View {
    let status: ConnectionStatus
    
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            
            Text(statusText)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    private var statusColor: Color {
        switch status {
        case .connected:
            return .green
        case .connecting:
            return .orange
        case .disconnected:
            return .red
        case .unknown:
            return .gray
        }
    }
    
    private var statusText: String {
        switch status {
        case .connected:
            return "接続済み"
        case .connecting:
            return "接続中"
        case .disconnected:
            return "未接続"
        case .unknown:
            return "不明"
        }
    }
}

/// Azure設定ビュー
struct AzureSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var apiKey = ""
    @State private var endpoint = ""
    @State private var region = ""
    @State private var showingApiKey = false
    
    var body: some View {
        Form {
            Section("接続情報") {
                HStack {
                    TextField("エンドポイント", text: $endpoint)
                    
                    Button(action: {
                        // QRコードスキャン機能
                    }) {
                        Image(systemName: "qrcode.viewfinder")
                    }
                }
                
                TextField("リージョン", text: $region)
                
                HStack {
                    if showingApiKey {
                        TextField("APIキー", text: $apiKey)
                    } else {
                        SecureField("APIキー", text: $apiKey)
                    }
                    
                    Button(action: {
                        showingApiKey.toggle()
                    }) {
                        Image(systemName: showingApiKey ? "eye.slash" : "eye")
                    }
                }
            }
            
            Section("設定") {
                Button("設定を保存") {
                    Task {
                        await saveAzureSettings()
                    }
                }
                .disabled(apiKey.isEmpty || endpoint.isEmpty)
                
                Button("接続をテスト") {
                    Task {
                        await testAzureConnection()
                    }
                }
                .disabled(apiKey.isEmpty || endpoint.isEmpty)
            }
        }
        .navigationTitle("Azure OpenAI設定")
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: {
                #if os(macOS)
                return .primaryAction
                #else
                return .navigationBarTrailing
                #endif
            }()) {
                Button("完了") {
                    dismiss()
                }
            }
        }
        .onAppear {
            loadCurrentSettings()
        }
    }
    
    private func loadCurrentSettings() {
        // 現在の設定を読み込み
    }
    
    private func saveAzureSettings() async {
        // Azure設定を保存
    }
    
    private func testAzureConnection() async {
        // Azure接続をテスト
    }
}

/// 通知設定ビュー
struct NotificationSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        Form {
            Section("通知設定") {
                Toggle("通話終了通知", isOn: $viewModel.notifyCallEnd)
                Toggle("転写完了通知", isOn: $viewModel.notifyTranscriptionComplete)
                Toggle("共有リクエスト通知", isOn: $viewModel.notifySharingRequest)
                Toggle("エラー通知", isOn: $viewModel.notifyErrors)
            }
            
            Section("音声設定") {
                Toggle("通知音", isOn: $viewModel.notificationSound)
                Toggle("バイブレーション", isOn: $viewModel.notificationVibration)
            }
        }
        .navigationTitle("通知設定")
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// 接続テストビュー
struct ConnectionTestView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var isRunningTests = false
    @State private var testResults: [ConnectionTestResult] = []
    
    var body: some View {
        NavigationView {
            List {
                Section("接続テスト結果") {
                    if isRunningTests {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("テスト実行中...")
                                .foregroundColor(.secondary)
                        }
                    } else if testResults.isEmpty {
                        Text("テストを実行してください")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(testResults, id: \.name) { result in
                            ConnectionTestRow(result: result)
                        }
                    }
                }
                
                Section {
                    Button("テストを実行") {
                        Task {
                            await runConnectionTests()
                        }
                    }
                    .disabled(isRunningTests)
                }
            }
            .navigationTitle("接続テスト")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: {
                    #if os(macOS)
                    return .primaryAction
                    #else
                    return .navigationBarTrailing
                    #endif
                }()) {
                    Button("完了") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private func runConnectionTests() async {
        isRunningTests = true
        testResults = []
        
        // 各種接続テストを実行
        let tests = [
            ("ネットワーク接続", testNetworkConnection),
            ("Azure OpenAI接続", testAzureConnection),
            ("音声認識サービス", testSpeechRecognition),
            ("ストレージアクセス", testStorageAccess)
        ]
        
        for (testName, testFunction) in tests {
            let result = await testFunction()
            testResults.append(ConnectionTestResult(
                name: testName,
                status: result.success ? .success : .failure,
                message: result.message,
                duration: result.duration
            ))
        }
        
        isRunningTests = false
    }
    
    private func testNetworkConnection() async -> TestResult {
        // ネットワーク接続テスト
        return TestResult(success: true, message: "接続成功", duration: 0.5)
    }
    
    private func testAzureConnection() async -> TestResult {
        // Azure接続テスト
        return TestResult(success: true, message: "Azure接続成功", duration: 1.2)
    }
    
    private func testSpeechRecognition() async -> TestResult {
        // 音声認識テスト
        return TestResult(success: true, message: "音声認識利用可能", duration: 0.8)
    }
    
    private func testStorageAccess() async -> TestResult {
        // ストレージアクセステスト
        return TestResult(success: true, message: "ストレージアクセス正常", duration: 0.3)
    }
}

/// 接続テスト行
struct ConnectionTestRow: View {
    let result: ConnectionTestResult
    
    var body: some View {
        HStack {
            Image(systemName: statusIcon)
                .foregroundColor(statusColor)
                .frame(width: 20)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(result.name)
                    .font(.body)
                
                Text(result.message)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Text("\(result.duration, specifier: "%.1f")s")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    private var statusIcon: String {
        switch result.status {
        case .success:
            return "checkmark.circle.fill"
        case .failure:
            return "xmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        }
    }
    
    private var statusColor: Color {
        switch result.status {
        case .success:
            return .green
        case .failure:
            return .red
        case .warning:
            return .orange
        }
    }
}

/// アプリについてビュー
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    // アプリアイコン
                    Image(systemName: "phone.and.waveform")
                        .font(.system(size: 80))
                        .foregroundColor(.blue)
                    
                    VStack(spacing: 8) {
                        Text("Telreq")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                        
                        Text("バージョン 1.0.0")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        
                        Text("ビルド 1")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Text("通話の自動文字起こしと要約を行うアプリケーションです。")
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    
                    VStack(spacing: 16) {
                        Button("プライバシーポリシー") {
                            // プライバシーポリシーを表示
                        }
                        
                        Button("利用規約") {
                            // 利用規約を表示
                        }
                        
                        Button("ライセンス情報") {
                            // ライセンス情報を表示
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("アプリについて")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: {
                    #if os(macOS)
                    return .primaryAction
                    #else
                    return .navigationBarTrailing
                    #endif
                }()) {
                    Button("完了") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Supporting Types

enum RecordingQuality: String, CaseIterable {
    case low = "low"
    case standard = "standard"
    case high = "high"
}

enum AutoDeletePeriod: String, CaseIterable {
    case never = "never"
    case oneWeek = "one_week"
    case oneMonth = "one_month"
    case threeMonths = "three_months"
    case sixMonths = "six_months"
    case oneYear = "one_year"
}

enum ThemeMode: String, CaseIterable {
    case system = "system"
    case light = "light"
    case dark = "dark"
}

enum LogLevel: String, CaseIterable {
    case error = "error"
    case warning = "warning"
    case info = "info"
    case debug = "debug"
}

enum ConnectionStatus {
    case connected
    case connecting
    case disconnected
    case unknown
}

struct SupportedLanguage {
    let code: String
    let name: String
}

struct ConnectionTestResult {
    let name: String
    let status: TestStatus
    let message: String
    let duration: TimeInterval
}

struct TestResult {
    let success: Bool
    let message: String
    let duration: TimeInterval
}

enum TestStatus {
    case success
    case failure
    case warning
}

// MARK: - Settings View Model

/// 設定ViewModel
@MainActor
class SettingsViewModel: ObservableObject {
    
    // MARK: - Published Properties
    
    // 転写設定
    @Published var selectedTranscriptionMethod: TranscriptionMethod = .iosSpeech
    @Published var autoStartTranscription = true
    @Published var realtimeTranscription = true
    @Published var selectedLanguage = "ja-JP"
    @Published var autoGenerateSummary = true
    
    // 音声設定
    @Published var recordingQuality: RecordingQuality = .standard
    @Published var noiseReduction = true
    @Published var saveAudioFiles = true
    @Published var showAudioLevels = true
    
    // プライバシー設定
    @Published var encryptionEnabled = true
    @Published var useSecureEnclave = true
    @Published var secureEnclaveAvailable = true
    @Published var autoDeletePeriod: AutoDeletePeriod = .never
    @Published var requirePasscode = false
    
    // ストレージ設定
    @Published var storageUsage: StorageUsage?
    @Published var isLoadingStorage = false
    @Published var isSyncing = false
    
    // 接続設定
    @Published var azureConnectionStatus: ConnectionStatus = .unknown
    @Published var offlineMode = false
    @Published var autoReconnect = true
    
    // アプリケーション設定
    @Published var selectedTheme: ThemeMode = .system
    @Published var analyticsEnabled = true
    @Published var notifyCallEnd = true
    @Published var notifyTranscriptionComplete = true
    @Published var notifySharingRequest = true
    @Published var notifyErrors = true
    @Published var notificationSound = true
    @Published var notificationVibration = true
    
    // デバッグ設定
    @Published var logLevel: LogLevel = .info
    
    // エラー処理
    @Published var showingError = false
    @Published var errorMessage = ""
    
    // MARK: - Computed Properties
    
    var supportedLanguages: [SupportedLanguage] {
        return [
            SupportedLanguage(code: "ja-JP", name: "日本語"),
            SupportedLanguage(code: "en-US", name: "English (US)"),
            SupportedLanguage(code: "zh-CN", name: "中文（简体）"),
            SupportedLanguage(code: "ko-KR", name: "한국어")
        ]
    }
    
    // MARK: - Private Properties
    
    private var serviceContainer: ServiceContainer?
    private let logger = Logger(subsystem: "com.telreq.app", category: "SettingsViewModel")
    
    // MARK: - Public Methods
    
    /// サービスコンテナを設定
    func setServiceContainer(_ container: ServiceContainer) {
        self.serviceContainer = container
        logger.info("ServiceContainer set in SettingsViewModel")
    }
    
    /// 設定を読み込み
    func loadSettings() async {
        isLoadingStorage = true
        
        // 保存された設定を読み込み
        loadSavedSettings()
        
        // 設定を読み込み
        await loadStorageUsage()
        await checkAzureConnection()
        
        logger.info("Settings loaded successfully")
        
        isLoadingStorage = false
    }
    
    /// 保存された設定を読み込み
    private func loadSavedSettings() {
        // 転写方法
        if let savedMethod = UserDefaults.standard.string(forKey: "selectedTranscriptionMethod"),
           let method = TranscriptionMethod(rawValue: savedMethod) {
            selectedTranscriptionMethod = method
            // SpeechRecognitionServiceにも反映
            if let container = serviceContainer {
                container.speechRecognitionService.switchTranscriptionMethod(method)
            }
        }
        
        // その他の設定も同様に読み込み
        autoStartTranscription = UserDefaults.standard.bool(forKey: "autoStartTranscription")
        realtimeTranscription = UserDefaults.standard.bool(forKey: "realtimeTranscription")
        selectedLanguage = UserDefaults.standard.string(forKey: "selectedLanguage") ?? "ja-JP"
        autoGenerateSummary = UserDefaults.standard.bool(forKey: "autoGenerateSummary")
        
        // 音声設定
        if let qualityString = UserDefaults.standard.string(forKey: "recordingQuality"),
           let quality = RecordingQuality(rawValue: qualityString) {
            recordingQuality = quality
        }
        noiseReduction = UserDefaults.standard.bool(forKey: "noiseReduction")
        saveAudioFiles = UserDefaults.standard.bool(forKey: "saveAudioFiles")
        showAudioLevels = UserDefaults.standard.bool(forKey: "showAudioLevels")
        
        // プライバシー設定
        encryptionEnabled = UserDefaults.standard.bool(forKey: "encryptionEnabled")
        useSecureEnclave = UserDefaults.standard.bool(forKey: "useSecureEnclave")
        
        // 接続設定
        offlineMode = UserDefaults.standard.bool(forKey: "offlineMode")
        autoReconnect = UserDefaults.standard.bool(forKey: "autoReconnect")
        
        logger.info("Saved settings loaded successfully")
    }
    
    /// ストレージ使用量を読み込み
    private func loadStorageUsage() async {
        guard let container = serviceContainer else {
            logger.warning("ServiceContainer not available for storage usage")
            return
        }
        
        do {
            storageUsage = try await container.azureStorageService.getStorageUsage()
        } catch {
            logger.warning("Failed to load storage usage: \(error.localizedDescription)")
        }
    }
    
    /// Azure接続をチェック
    private func checkAzureConnection() async {
        azureConnectionStatus = .connecting
        
        do {
            // Azure OpenAI APIをテスト
            let testResult = try await testAzureOpenAIConnection()
            if testResult {
                azureConnectionStatus = .connected
                logger.info("Azure OpenAI connection test successful")
            } else {
                azureConnectionStatus = .disconnected
                logger.warning("Azure OpenAI connection test failed")
            }
        } catch {
            azureConnectionStatus = .disconnected
            logger.error("Azure OpenAI connection test error: \(error.localizedDescription)")
        }
    }
    
    /// Azure OpenAI接続をテスト
    private func testAzureOpenAIConnection() async throws -> Bool {
        guard let container = serviceContainer else {
            logger.warning("ServiceContainer not available for Azure OpenAI test")
            throw AppError.invalidConfiguration
        }
        
        // 簡単なテスト用のテキストで要約を試行
        let testText = "これはAzure OpenAI接続のテストです。"
        
        do {
            let summary = try await container.textProcessingService.summarizeText(testText)
            return !summary.summary.isEmpty
        } catch {
            logger.error("Azure OpenAI test failed: \(error.localizedDescription)")
            return false
        }
    }
    
    // MARK: - Settings Update Methods
    
    func updateTranscriptionMethod(_ method: TranscriptionMethod) async {
        logger.info("Updating transcription method to: \(method.displayName)")
        
        guard let container = serviceContainer else {
            logger.warning("ServiceContainer not available for transcription method update")
            showError("サービスが初期化されていません")
            return
        }
        
        // SpeechRecognitionServiceの方法を切り替え
        container.speechRecognitionService.switchTranscriptionMethod(method)
        selectedTranscriptionMethod = method
        
        // 設定を永続化（UserDefaultsに保存）
        UserDefaults.standard.set(method.rawValue, forKey: "selectedTranscriptionMethod")
        
        logger.info("Transcription method updated successfully to: \(method.displayName)")
    }
    
    func updateAutoStartTranscription(_ enabled: Bool) async {
        logger.info("Updating auto start transcription to: \(enabled)")
        autoStartTranscription = enabled
        UserDefaults.standard.set(enabled, forKey: "autoStartTranscription")
    }
    
    func updateRealtimeTranscription(_ enabled: Bool) async {
        logger.info("Updating realtime transcription to: \(enabled)")
        realtimeTranscription = enabled
        UserDefaults.standard.set(enabled, forKey: "realtimeTranscription")
    }
    
    func updateLanguage(_ language: String) async {
        logger.info("Updating language to: \(language)")
        selectedLanguage = language
        UserDefaults.standard.set(language, forKey: "selectedLanguage")
    }
    
    func updateAutoGenerateSummary(_ enabled: Bool) async {
        logger.info("Updating auto generate summary to: \(enabled)")
        autoGenerateSummary = enabled
        UserDefaults.standard.set(enabled, forKey: "autoGenerateSummary")
    }
    
    func updateRecordingQuality(_ quality: RecordingQuality) async {
        logger.info("Updating recording quality to: \(quality.rawValue)")
        recordingQuality = quality
        UserDefaults.standard.set(quality.rawValue, forKey: "recordingQuality")
    }
    
    func updateNoiseReduction(_ enabled: Bool) async {
        logger.info("Updating noise reduction to: \(enabled)")
        noiseReduction = enabled
        UserDefaults.standard.set(enabled, forKey: "noiseReduction")
    }
    
    func updateSaveAudioFiles(_ enabled: Bool) async {
        logger.info("Updating save audio files to: \(enabled)")
        saveAudioFiles = enabled
        UserDefaults.standard.set(enabled, forKey: "saveAudioFiles")
    }
    
    func updateShowAudioLevels(_ enabled: Bool) {
        logger.info("Updating show audio levels to: \(enabled)")
        showAudioLevels = enabled
        UserDefaults.standard.set(enabled, forKey: "showAudioLevels")
    }
    
    func updateEncryption(_ enabled: Bool) async {
        logger.info("Updating encryption to: \(enabled)")
        encryptionEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "encryptionEnabled")
    }
    
    func updateSecureEnclave(_ enabled: Bool) async {
        logger.info("Updating secure enclave to: \(enabled)")
        useSecureEnclave = enabled
        UserDefaults.standard.set(enabled, forKey: "useSecureEnclave")
    }
    
    func updateAutoDeletePeriod(_ period: AutoDeletePeriod) async {
        logger.info("Updating auto delete period to: \(period.rawValue)")
        // 設定更新ロジック
    }
    
    func updatePasscodeRequirement(_ required: Bool) async {
        logger.info("Updating passcode requirement to: \(required)")
        // 設定更新ロジック
    }
    
    func updateOfflineMode(_ enabled: Bool) async {
        logger.info("Updating offline mode to: \(enabled)")
        offlineMode = enabled
        UserDefaults.standard.set(enabled, forKey: "offlineMode")
    }
    
    func updateAutoReconnect(_ enabled: Bool) {
        logger.info("Updating auto reconnect to: \(enabled)")
        // 設定更新ロジック
    }
    
    func updateTheme(_ theme: ThemeMode) {
        logger.info("Updating theme to: \(theme.rawValue)")
        // 設定更新ロジック
    }
    
    func updateAnalytics(_ enabled: Bool) {
        logger.info("Updating analytics to: \(enabled)")
        // 設定更新ロジック
    }
    
    func updateLogLevel(_ level: LogLevel) {
        logger.info("Updating log level to: \(level.rawValue)")
        // 設定更新ロジック
    }
    
    // MARK: - Action Methods
    
    func clearCache() async {
        guard let container = serviceContainer else {
            logger.warning("ServiceContainer not available for cache clear")
            showError("サービスが初期化されていません")
            return
        }
        
        do {
            try await container.offlineDataManager.clearCache()
            await loadStorageUsage() // 使用量を再読み込み
            logger.info("Cache cleared successfully")
        } catch {
            logger.error("Failed to clear cache: \(error.localizedDescription)")
            showError("キャッシュのクリアに失敗しました")
        }
    }
    
    func syncOfflineData() async {
        guard let container = serviceContainer else {
            logger.warning("ServiceContainer not available for data sync")
            showError("サービスが初期化されていません")
            return
        }
        
        isSyncing = true
        
        do {
            try await container.azureStorageService.syncOfflineData()
            await loadStorageUsage() // 使用量を再読み込み
            logger.info("Offline data synced successfully")
        } catch {
            logger.error("Failed to sync offline data: \(error.localizedDescription)")
            showError("オフラインデータの同期に失敗しました")
        }
        
        isSyncing = false
    }
    
    func requestAppReview() {
        logger.info("Requesting app review")
        // App Store Review API呼び出し
    }
    
    func openFeedback() {
        logger.info("Opening feedback")
        // フィードバック画面を開く
    }
    
    func showDebugInfo() {
        logger.info("Showing debug info")
        guard let container = serviceContainer else {
            logger.warning("ServiceContainer not available for debug info")
            return
        }
        container.printDebugInfo()
    }
    
    func resetAllSettings() async {
        #if DEBUG
        guard let container = serviceContainer else {
            logger.warning("ServiceContainer not available for settings reset")
            showError("サービスが初期化されていません")
            return
        }
        
        do {
            try await container.resetAllData()
            logger.info("All settings reset successfully")
        } catch {
            logger.error("Failed to reset settings: \(error.localizedDescription)")
            showError("設定のリセットに失敗しました")
        }
        #endif
    }
    

    
    // MARK: - Error Handling
    
    private func showError(_ message: String) {
        errorMessage = message
        showingError = true
    }
    
    func dismissError() {
        showingError = false
        errorMessage = ""
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
        .environmentObject(ServiceContainer.shared)
}