import SwiftUI
import os.log

/// リアルタイム転写ビュー
/// 
/// 通話中の転写進行表示、音声レベルインジケーター、転写方法切り替えを提供します。
/// ライブ転写の表示とユーザーインタラクション機能を含みます。
@available(iOS 15.0, *)
struct RealTimeTranscriptionView: View {
    
    // MARK: - Properties
    
    @StateObject private var viewModel = RealTimeTranscriptionViewModel()
    @EnvironmentObject private var serviceContainer: ServiceContainer
    @State private var showingSettings = false
    @State private var showingMethodSelector = false
    
    // MARK: - Body
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 転写状態ヘッダー
                transcriptionStatusHeader
                
                // 音声レベルインジケーター
                if viewModel.isTranscribing {
                    audioLevelIndicator
                        .padding(.vertical, 16)
                }
                
                // 転写テキスト表示エリア
                transcriptionDisplayArea
                
                // 転写コントロール
                transcriptionControls
                    .padding(.bottom, 16)
            }
            .navigationTitle("リアルタイム転写")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button(action: {
                        showingMethodSelector = true
                    }) {
                        Image(systemName: "waveform.badge.magnifyingglass")
                    }
                    .disabled(viewModel.isTranscribing)
                    
                    Button(action: {
                        showingSettings = true
                    }) {
                        Image(systemName: "slider.horizontal.3")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                TranscriptionSettingsSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $showingMethodSelector) {
                TranscriptionMethodSelector(viewModel: viewModel)
            }
            .alert("エラー", isPresented: $viewModel.showingError) {
                Button("OK") {
                    viewModel.dismissError()
                }
                if viewModel.canRetry {
                    Button("再試行") {
                        Task {
                            await viewModel.retryTranscription()
                        }
                    }
                }
            } message: {
                Text(viewModel.errorMessage)
            }
        }
        .onAppear {
            viewModel.setServiceContainer(serviceContainer)
            Task {
                await viewModel.initialize()
            }
        }
        .onDisappear {
            Task {
                await viewModel.cleanup()
            }
        }
    }
    
    // MARK: - Subviews
    
    /// 転写状態ヘッダー
    private var transcriptionStatusHeader: some View {
        VStack(spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.statusText)
                        .font(.headline)
                        .fontWeight(.semibold)
                    
                    if viewModel.isTranscribing {
                        HStack(spacing: 8) {
                            Text("転写時間: \(formatDuration(viewModel.transcriptionDuration))")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            
                            Text("方法: \(viewModel.currentMethod.displayName)")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    if viewModel.isTranscribing {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 8, height: 8)
                                .scaleEffect(viewModel.isRecording ? 1.2 : 0.8)
                                .animation(
                                    .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                                    value: viewModel.isRecording
                                )
                            
                            Text("録音中")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                    
                    if let confidence = viewModel.currentConfidence {
                        ConfidenceIndicator(confidence: confidence)
                    }
                }
            }
            
            // 進捗インジケーター
            if viewModel.isProcessing {
                ProgressView()
                    .scaleEffect(0.8)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
    }
    
    /// 音声レベルインジケーター
    private var audioLevelIndicator: some View {
        VStack(spacing: 12) {
            Text("音声レベル")
                .font(.caption)
                .foregroundColor(.secondary)
            
            HStack(spacing: 2) {
                ForEach(0..<20, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(audioLevelColor(for: index))
                        .frame(width: 6, height: audioLevelHeight(for: index))
                        .animation(
                            .easeInOut(duration: 0.1),
                            value: viewModel.audioLevel
                        )
                }
            }
            .frame(height: 40)
            
            HStack {
                Text("静か")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Text("大きい")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)
        }
        .padding(.horizontal)
    }
    
    /// 転写テキスト表示エリア
    private var transcriptionDisplayArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if viewModel.transcriptionSegments.isEmpty {
                        emptyTranscriptionView
                    } else {
                        ForEach(viewModel.transcriptionSegments) { segment in
                            TranscriptionSegmentView(
                                segment: segment,
                                isLive: segment.id == viewModel.liveSegmentId
                            )
                            .id(segment.id)
                        }
                    }
                }
                .padding()
            }
            .onChange(of: viewModel.liveSegmentId) { oldValue, newSegmentId in
                if let segmentId = newSegmentId {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(segmentId, anchor: .bottom)
                    }
                }
            }
        }
        .background(Color(UIColor.systemBackground))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    /// 空の転写ビュー
    private var emptyTranscriptionView: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 50))
                .foregroundColor(.secondary)
            
            Text(viewModel.isTranscribing ? "音声を検出中..." : "転写を開始してください")
                .font(.headline)
                .foregroundColor(.secondary)
            
            if !viewModel.isTranscribing {
                Text("マイクボタンをタップして\nリアルタイム転写を開始できます")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }
    
    /// 転写コントロール
    private var transcriptionControls: some View {
        VStack(spacing: 16) {
            // メイン制御ボタン
            HStack(spacing: 24) {
                // 一時停止/再開ボタン
                if viewModel.isTranscribing {
                    Button(action: {
                        Task {
                            await viewModel.pauseResumeTranscription()
                        }
                    }) {
                        Image(systemName: viewModel.isPaused ? "play.circle.fill" : "pause.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.blue)
                    }
                    .accessibilityLabel(viewModel.isPaused ? "転写を再開" : "転写を一時停止")
                }
                
                // メイン転写ボタン
                Button(action: {
                    Task {
                        await viewModel.toggleTranscription()
                    }
                }) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 20)
                            .fill(buttonBackgroundColor)
                            .frame(width: 120, height: 120)
                            .scaleEffect(viewModel.isTranscribing ? 1.05 : 1.0)
                            .animation(.easeInOut(duration: 0.2), value: viewModel.isTranscribing)
                        
                        Image(systemName: buttonIcon)
                            .font(.system(size: 40, weight: .medium))
                            .foregroundColor(.white)
                    }
                }
                .disabled(viewModel.isProcessing)
                .accessibilityLabel(viewModel.isTranscribing ? "転写を停止" : "転写を開始")
                
                // 保存ボタン
                if viewModel.hasTranscriptionData {
                    Button(action: {
                        Task {
                            await viewModel.saveTranscription()
                        }
                    }) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 32))
                            .foregroundColor(.green)
                    }
                    .accessibilityLabel("転写を保存")
                }
            }
            
            // 転写統計情報
            if viewModel.isTranscribing || viewModel.hasTranscriptionData {
                transcriptionStats
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
    }
    
    /// 転写統計情報
    private var transcriptionStats: some View {
        HStack(spacing: 24) {
            StatItem(
                title: "単語数",
                value: "\(viewModel.wordCount)",
                icon: "textformat"
            )
            
            StatItem(
                title: "文字数",
                value: "\(viewModel.characterCount)",
                icon: "character"
            )
            
            StatItem(
                title: "平均信頼度",
                value: "\(Int((viewModel.averageConfidence ?? 0) * 100))%",
                icon: "checkmark.shield"
            )
        }
    }
    
    // MARK: - Computed Properties
    
    private var buttonBackgroundColor: Color {
        if viewModel.isTranscribing {
            return .red
        } else {
            return .blue
        }
    }
    
    private var buttonIcon: String {
        if viewModel.isProcessing {
            return "stop.circle"
        } else if viewModel.isTranscribing {
            return "stop.fill"
        } else {
            return "mic.fill"
        }
    }
    
    // MARK: - Helper Methods
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    private func audioLevelColor(for index: Int) -> Color {
        let threshold = Int(viewModel.audioLevel * 20)
        if index < threshold {
            switch index {
            case 0..<7:
                return .green
            case 7..<14:
                return .yellow
            default:
                return .red
            }
        } else {
            return Color.gray.opacity(0.3)
        }
    }
    
    private func audioLevelHeight(for index: Int) -> CGFloat {
        let threshold = Int(viewModel.audioLevel * 20)
        let baseHeight: CGFloat = 4
        let maxHeight: CGFloat = 32
        
        if index < threshold {
            return baseHeight + (maxHeight - baseHeight) * CGFloat(index) / 19
        } else {
            return baseHeight
        }
    }
}

// MARK: - Supporting Views

/// 転写セグメントビュー
struct TranscriptionSegmentView: View {
    let segment: TranscriptionSegment
    let isLive: Bool
    
    @State private var isExpanded = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // タイムスタンプ
                Text(formatTimestamp(segment.timestamp))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(UIColor.tertiarySystemBackground))
                    .cornerRadius(8)
                
                Spacer()
                
                // ライブインジケーター
                if isLive {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 6, height: 6)
                            .scaleEffect(isLive ? 1.2 : 0.8)
                            .animation(
                                .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                                value: isLive
                            )
                        
                        Text("LIVE")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundColor(.red)
                    }
                }
                
                // 信頼度
                if segment.confidence > 0 {
                    ConfidenceIndicator(confidence: segment.confidence)
                }
            }
            
            // 転写テキスト
            Text(segment.text)
                .font(.body)
                .lineLimit(isExpanded ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
                .animation(.easeInOut(duration: 0.3), value: isExpanded)
            
            // 展開/折りたたみボタン（長いテキストの場合）
            if segment.text.count > 100 {
                Button(action: {
                    isExpanded.toggle()
                }) {
                    Text(isExpanded ? "折りたたむ" : "もっと見る")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isLive ? Color.blue.opacity(0.1) : Color(UIColor.secondarySystemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(isLive ? Color.blue.opacity(0.3) : Color.clear, lineWidth: 1)
                )
        )
        .textSelection(.enabled)
    }
    
    private func formatTimestamp(_ timestamp: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter.string(from: timestamp)
    }
}

/// 統計アイテム
struct StatItem: View {
    let title: String
    let value: String
    let icon: String
    
    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Text(value)
                .font(.headline)
                .fontWeight(.semibold)
        }
    }
}

/// 転写設定シート
struct TranscriptionSettingsSheet: View {
    @ObservedObject var viewModel: RealTimeTranscriptionViewModel
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            Form {
                Section("音声設定") {
                    Toggle("ノイズリダクション", isOn: $viewModel.noiseReductionEnabled)
                    
                    Picker("音声品質", selection: $viewModel.audioQuality) {
                        Text("低品質").tag(AudioQuality.poor)
                        Text("標準品質").tag(AudioQuality.fair)
                        Text("高品質").tag(AudioQuality.good)
                        Text("最高品質").tag(AudioQuality.excellent)
                    }
                    
                    Toggle("音声レベル表示", isOn: $viewModel.showAudioLevels)
                }
                
                Section("転写設定") {
                    Toggle("自動句読点", isOn: $viewModel.autoPunctuation)
                    
                    Toggle("話者識別", isOn: $viewModel.speakerIdentification)
                    
                    Stepper(
                        "最大セグメント数: \(viewModel.maxSegments)",
                        value: $viewModel.maxSegments,
                        in: 10...100,
                        step: 10
                    )
                }
                
                Section("表示設定") {
                    Toggle("タイムスタンプ表示", isOn: $viewModel.showTimestamps)
                    
                    Toggle("信頼度表示", isOn: $viewModel.showConfidence)
                    
                    Picker("フォントサイズ", selection: $viewModel.fontSize) {
                        Text("小").tag(FontSize.small)
                        Text("標準").tag(FontSize.standard)
                        Text("大").tag(FontSize.large)
                    }
                }
            }
            .navigationTitle("転写設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完了") {
                        dismiss()
                    }
                }
            }
        }
    }
}

/// 転写方法セレクター
struct TranscriptionMethodSelector: View {
    @ObservedObject var viewModel: RealTimeTranscriptionViewModel
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            List {
                ForEach(TranscriptionMethod.allCases, id: \.self) { method in
                    TranscriptionMethodRow(
                        method: method,
                        isSelected: viewModel.currentMethod == method,
                        isAvailable: viewModel.isMethodAvailable(method)
                    ) {
                        Task {
                            await viewModel.switchTranscriptionMethod(method)
                        }
                        dismiss()
                    }
                }
            }
            .navigationTitle("転写方法を選択")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("キャンセル") {
                        dismiss()
                    }
                }
            }
        }
    }
}

/// 転写方法行
struct TranscriptionMethodRow: View {
    let method: TranscriptionMethod
    let isSelected: Bool
    let isAvailable: Bool
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(method.displayName)
                        .font(.headline)
                        .foregroundColor(isAvailable ? .primary : .secondary)
                    
                    Text(methodDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                }
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.blue)
                }
                
                if !isAvailable {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                }
            }
            .padding(.vertical, 8)
        }
        .disabled(!isAvailable)
        .buttonStyle(PlainButtonStyle())
    }
    
    private var methodDescription: String {
        switch method {
        case .iosSpeech:
            return "デバイス内で処理、高速・プライベート"
        case .azureSpeech:
            return "クラウド処理、高精度・多言語対応"
        case .hybridProcessing:
            return "複数の方法を組み合わせ、最高精度"
        }
    }
}

// MARK: - Supporting Types

struct TranscriptionSegment: Identifiable {
    let id: UUID
    let timestamp: Date
    let text: String
    let confidence: Double
    let speakerId: String?
    let isLive: Bool
    
    init(id: UUID = UUID(), timestamp: Date, text: String, confidence: Double, speakerId: String?, isLive: Bool) {
        self.id = id
        self.timestamp = timestamp
        self.text = text
        self.confidence = confidence
        self.speakerId = speakerId
        self.isLive = isLive
    }
}

enum FontSize: String, CaseIterable {
    case small = "small"
    case standard = "standard"
    case large = "large"
}

// MARK: - Real Time Transcription View Model

/// リアルタイム転写ViewModel
@MainActor
class RealTimeTranscriptionViewModel: ObservableObject, SpeechRecognitionDelegate {
    
    // MARK: - Published Properties
    
    @Published var isTranscribing = false
    @Published var isPaused = false
    @Published var isRecording = false
    @Published var isProcessing = false
    @Published var transcriptionSegments: [TranscriptionSegment] = []
    @Published var liveSegmentId: UUID?
    @Published var audioLevel: Float = 0.0
    @Published var transcriptionDuration: TimeInterval = 0
    @Published var currentMethod: TranscriptionMethod = .iosSpeech
    @Published var currentConfidence: Double?
    
    // 統計情報
    @Published var wordCount = 0
    @Published var characterCount = 0
    @Published var averageConfidence: Double?
    
    // 設定
    @Published var noiseReductionEnabled = true
    @Published var audioQuality: AudioQuality = .good
    @Published var showAudioLevels = true
    @Published var autoPunctuation = true
    @Published var speakerIdentification = false
    @Published var maxSegments = 50
    @Published var showTimestamps = true
    @Published var showConfidence = true
    @Published var fontSize: FontSize = .standard
    
    // エラー処理
    @Published var showingError = false
    @Published var errorMessage = ""
    @Published var canRetry = false
    
    // MARK: - Computed Properties
    
    var statusText: String {
        if isProcessing {
            return "処理中..."
        } else if isPaused {
            return "一時停止中"
        } else if isTranscribing {
            return "転写中"
        } else {
            return "待機中"
        }
    }
    
    var hasTranscriptionData: Bool {
        !transcriptionSegments.isEmpty
    }
    
    // MARK: - Private Properties
    
    private var serviceContainer: ServiceContainer?
    private var transcriptionTimer: Timer?
    private var audioLevelTimer: Timer?
    private var statisticsTimer: Timer?
    private let logger = Logger(subsystem: "com.telreq.app", category: "RealTimeTranscriptionViewModel")
    
    // MARK: - Initialization
    
    init() {
        setupTimers()
    }
    
    deinit {
        Task.detached { [weak self] in
            await self?.cleanup()
        }
    }
    
    // MARK: - Public Methods
    
    /// サービスコンテナを設定
    func setServiceContainer(_ container: ServiceContainer) {
        self.serviceContainer = container
    }
    
    /// 初期化
    func initialize() async {
        // 権限チェック
        guard await checkPermissions() else {
            showError("マイクと音声認識の権限が必要です", canRetry: false)
            return
        }
        
        // サービス初期化
        await initializeServices()
        
        logger.info("Real-time transcription initialized")
    }
    
    /// クリーンアップ
    func cleanup() async {
        if isTranscribing {
            await stopTranscription()
        }
        
        transcriptionTimer?.invalidate()
        audioLevelTimer?.invalidate()
        statisticsTimer?.invalidate()
        
        logger.info("Real-time transcription cleaned up")
    }
    
    /// 転写の切り替え
    func toggleTranscription() async {
        if isTranscribing {
            await stopTranscription()
        } else {
            await startTranscription()
        }
    }
    
    /// 転写の一時停止/再開
    func pauseResumeTranscription() async {
        if isPaused {
            await resumeTranscription()
        } else {
            await pauseTranscription()
        }
    }
    
    /// 転写方法を切り替え
    func switchTranscriptionMethod(_ method: TranscriptionMethod) async {
        guard !isTranscribing else {
            showError("転写中は方法を変更できません")
            return
        }
        
        currentMethod = method
        logger.info("Switched transcription method to: \(method.displayName)")
    }
    
    /// 転写方法が利用可能かチェック
    func isMethodAvailable(_ method: TranscriptionMethod) -> Bool {
        // 実際の実装では各方法の利用可能性をチェック
        return true
    }
    
    /// 転写を保存
    func saveTranscription() async {
        guard hasTranscriptionData else {
            showError("保存する転写データがありません")
            return
        }
        
        guard let container = serviceContainer else {
            showError("サービスが初期化されていません")
            return
        }
        
        // CallManagerを使って現在の転写セッションを適切に終了・保存
        await container.callManager.stopAudioCaptureAndSave()
        
        logger.info("Transcription saved successfully via CallManager")
        
        // 保存後のクリーンアップ
        transcriptionSegments.removeAll()
        resetStatistics()
    }
    
    /// 転写を再試行
    func retryTranscription() async {
        await stopTranscription()
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1秒待機
        await startTranscription()
    }
    
    /// エラーを非表示
    func dismissError() {
        showingError = false
        errorMessage = ""
        canRetry = false
    }
    
    // MARK: - Private Methods
    
    /// 権限をチェック
    private func checkPermissions() async -> Bool {
        guard let container = serviceContainer else { return false }
        
        // 音声認識権限をチェック
        let speechPermission = await container.speechRecognitionService.checkSpeechRecognitionPermission()
        
        // マイク権限をチェック
        let micPermission = await container.audioCaptureService.requestMicrophonePermission()
        
        return speechPermission && micPermission
    }
    
    /// サービスを初期化
    private func initializeServices() async {
        guard serviceContainer != nil else {
            logger.warning("ServiceContainer not available for initialization")
            return
        }
        
        // 音声認識サービスのデリゲートを設定
        // Note: CallManager already manages speech recognition delegates
        logger.info("Speech recognition service initialized with delegate")
    }
    
    /// 転写を開始
    private func startTranscription() async {
        guard !isTranscribing else { return }
        guard let container = serviceContainer else {
            showError("サービスが初期化されていません", canRetry: false)
            return
        }
        
        isProcessing = true
        
        do {
            // 音声認識サービスでリアルタイム認識を開始
            try await container.speechRecognitionService.startRealtimeRecognition()
        } catch {
            logger.error("Failed to start transcription: \(error.localizedDescription)")
            showError("転写の開始に失敗しました", canRetry: true)
            isProcessing = false
            return
        }
        
        isTranscribing = true
        isRecording = true
        isPaused = false
        transcriptionDuration = 0
        
        startTimers()
        
        logger.info("Transcription started")
        
        isProcessing = false
    }
    
    /// 転写を停止
    private func stopTranscription() async {
        guard isTranscribing else { return }
        guard let container = serviceContainer else { return }
        
        isProcessing = true
        
        // 音声認識サービスを停止
        container.speechRecognitionService.stopRecognition()
        
        // CallManagerを使って結果を保存
        await container.callManager.stopAudioCaptureAndSave()
        
        isTranscribing = false
        isRecording = false
        isPaused = false
        liveSegmentId = nil
        
        stopTimers()
        
        logger.info("Transcription stopped and results saved")
        
        isProcessing = false
    }
    
    /// 転写を一時停止
    private func pauseTranscription() async {
        guard isTranscribing && !isPaused else { return }
        
        isPaused = true
        isRecording = false
        
        // 音声キャプチャを一時停止
        
        logger.info("Transcription paused")
    }
    
    /// 転写を再開
    private func resumeTranscription() async {
        guard isTranscribing && isPaused else { return }
        
        isPaused = false
        isRecording = true
        
        // 音声キャプチャを再開
        
        logger.info("Transcription resumed")
    }
    
    /// タイマーを設定
    private func setupTimers() {
        // 実際の実装ではタイマーを設定
    }
    
    /// タイマーを開始
    private func startTimers() {
        // 転写時間タイマー
        transcriptionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                self.transcriptionDuration += 1
            }
        }
        
        // 音声レベルタイマー
        audioLevelTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                self.updateAudioLevel()
            }
        }
        
        // 統計情報タイマー
        statisticsTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor in
                self.updateStatistics()
            }
        }
    }
    
    /// タイマーを停止
    private func stopTimers() {
        transcriptionTimer?.invalidate()
        audioLevelTimer?.invalidate()
        statisticsTimer?.invalidate()
        
        transcriptionTimer = nil
        audioLevelTimer = nil
        statisticsTimer = nil
    }
    
    /// 音声レベルを更新
    private func updateAudioLevel() {
        guard serviceContainer != nil,
              isTranscribing && !isPaused else {
            audioLevel = 0.0
            return
        }
        
        // AudioCaptureServiceから音声レベルを取得
        // 実際の実装では AudioCaptureService から現在の音声レベルを取得
        // ここではダミーの音声レベルを生成
        audioLevel = Float.random(in: 0.0...1.0) * (isRecording ? 1.0 : 0.3)
    }
    
    /// 統計情報を更新
    private func updateStatistics() {
        let allText = transcriptionSegments.map { $0.text }.joined(separator: " ")
        
        wordCount = allText.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.count
        
        characterCount = allText.count
        
        if !transcriptionSegments.isEmpty {
            let totalConfidence = transcriptionSegments.reduce(0) { $0 + $1.confidence }
            averageConfidence = totalConfidence / Double(transcriptionSegments.count)
        }
    }
    
    /// 統計情報をリセット
    private func resetStatistics() {
        wordCount = 0
        characterCount = 0
        averageConfidence = nil
        transcriptionDuration = 0
    }
    
    // MARK: - SpeechRecognitionDelegate
    
    nonisolated func speechRecognition(didRecognizeText text: String, isFinal: Bool) {
        Task { @MainActor in
            if isFinal {
                // 最終的な認識結果として新しいセグメントを追加
                let segment = TranscriptionSegment(
                    timestamp: Date(),
                    text: text,
                    confidence: currentConfidence ?? 0.8,
                    speakerId: nil,
                    isLive: false
                )
                transcriptionSegments.append(segment)
                
                // 最大セグメント数を制限
                if transcriptionSegments.count > maxSegments {
                    transcriptionSegments.removeFirst()
                }
                
                updateStatistics()
                logger.info("Final transcription segment added: \(text)")
            } else {
                // リアルタイム認識結果として表示
                if let lastSegment = transcriptionSegments.last,
                   lastSegment.isLive {
                    // 既存のライブセグメントを更新
                    transcriptionSegments[transcriptionSegments.count - 1] = TranscriptionSegment(
                        id: lastSegment.id,
                        timestamp: lastSegment.timestamp,
                        text: text,
                        confidence: currentConfidence ?? 0.6,
                        speakerId: nil,
                        isLive: true
                    )
                } else {
                    // 新しいライブセグメントを追加
                    let liveSegment = TranscriptionSegment(
                        timestamp: Date(),
                        text: text,
                        confidence: currentConfidence ?? 0.6,
                        speakerId: nil,
                        isLive: true
                    )
                    transcriptionSegments.append(liveSegment)
                    liveSegmentId = liveSegment.id
                }
                
                logger.debug("Live transcription updated: \(text)")
            }
        }
    }
    
    nonisolated func speechRecognition(didCompleteWithResult result: SpeechRecognitionResult) {
        Task { @MainActor in
            currentConfidence = result.confidence
            logger.info("Speech recognition completed with confidence: \(result.confidence)")
        }
    }
    
    nonisolated func speechRecognition(didFailWithError error: Error) {
        Task { @MainActor in
            logger.error("Speech recognition failed: \(error.localizedDescription)")
            showError("音声認識でエラーが発生しました: \(error.localizedDescription)", canRetry: true)
        }
    }
    
    nonisolated func speechRecognitionDidTimeout() {
        Task { @MainActor in
            logger.warning("Speech recognition timed out")
            showError("音声認識がタイムアウトしました", canRetry: true)
        }
    }
    
    /// エラーを表示
    private func showError(_ message: String, canRetry: Bool = false) {
        errorMessage = message
        self.canRetry = canRetry
        showingError = true
    }
}

// MARK: - Preview

#Preview {
    RealTimeTranscriptionView()
        .environmentObject(ServiceContainer.shared)
}