import SwiftUI

/// メインコンテンツビュー
/// 
/// タブベースのナビゲーションを提供し、アプリケーションの主要機能へのアクセスを管理します。
/// リアルタイム転写表示と通話状態インジケーターを含みます。
struct ContentView: View {
    
    // MARK: - Properties
    
    @StateObject private var contentViewModel = ContentViewModel()
    @StateObject private var serviceContainer = ServiceContainer.shared
    @State private var selectedTab = 0
    @State private var showingCallInterface = false
    
    // MARK: - Body
    
    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                // 通話履歴タブ
                CallHistoryView()
                    .tabItem {
                        Image(systemName: "phone.fill")
                        Text("通話履歴")
                    }
                    .tag(0)
                
                // リアルタイム転写タブ
                RealTimeTranscriptionView()
                    .tabItem {
                        Image(systemName: "waveform")
                        Text("転写")
                    }
                    .tag(1)
                
                // 共有タブ
                SharingView()
                    .tabItem {
                        Image(systemName: "person.2.fill")
                        Text("共有")
                    }
                    .tag(2)
                
                // 設定タブ
                SettingsView()
                    .tabItem {
                        Image(systemName: "gear")
                        Text("設定")
                    }
                    .tag(3)
            }
            .environmentObject(serviceContainer)
            
            // 通話状態インジケーター
            if contentViewModel.isCallActive {
                VStack {
                    Spacer()
                    
                    CallStatusIndicator(
                        isActive: contentViewModel.isCallActive,
                        duration: contentViewModel.callDuration,
                        quality: contentViewModel.callQuality
                    )
                    .padding(.bottom, 100) // タブバーの上に配置
                    .onTapGesture {
                        showingCallInterface = true
                    }
                }
                .transition(.move(edge: .bottom))
                .animation(.easeInOut, value: contentViewModel.isCallActive)
            }
        }
        .onAppear {
            setupInitialState()
        }
        .onChange(of: selectedTab) { newTab in
            handleTabChange(newTab)
        }
        .sheet(isPresented: $showingCallInterface) {
            CallInterfaceView()
                .environmentObject(serviceContainer)
        }
        .alert("エラー", isPresented: $contentViewModel.showingError) {
            Button("OK") {
                contentViewModel.dismissError()
            }
        } message: {
            Text(contentViewModel.errorMessage)
        }
    }
    
    // MARK: - Private Methods
    
    /// 初期状態を設定
    private func setupInitialState() {
        Task {
            await contentViewModel.initializeApp()
        }
    }
    
    /// タブ変更を処理
    private func handleTabChange(_ newTab: Int) {
        // タブ変更時の処理
        switch newTab {
        case 0:
            // 通話履歴タブ
            contentViewModel.trackEvent("tab_call_history_selected")
        case 1:
            // 転写タブ
            contentViewModel.trackEvent("tab_transcription_selected")
        case 2:
            // 共有タブ
            contentViewModel.trackEvent("tab_sharing_selected")
        case 3:
            // 設定タブ
            contentViewModel.trackEvent("tab_settings_selected")
        default:
            break
        }
    }
}

// MARK: - Call Status Indicator

/// 通話状態インジケーター
struct CallStatusIndicator: View {
    let isActive: Bool
    let duration: TimeInterval
    let quality: AudioQuality
    
    @State private var isAnimating = false
    
    var body: some View {
        HStack(spacing: 12) {
            // 通話アイコン
            Image(systemName: "phone.fill")
                .foregroundColor(.white)
                .scaleEffect(isAnimating ? 1.2 : 1.0)
                .animation(
                    .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                    value: isAnimating
                )
            
            VStack(alignment: .leading, spacing: 2) {
                Text("通話中")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                
                HStack(spacing: 8) {
                    // 通話時間
                    Text(formatDuration(duration))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                    
                    // 音声品質インジケーター
                    HStack(spacing: 2) {
                        ForEach(0..<4) { index in
                            Rectangle()
                                .fill(qualityColor(for: quality, index: index))
                                .frame(width: 3, height: CGFloat(6 + index * 2))
                                .cornerRadius(1.5)
                        }
                    }
                }
            }
            
            Spacer()
            
            // タップヒント
            Image(systemName: "chevron.up")
                .foregroundColor(.white.opacity(0.7))
                .font(.system(size: 12, weight: .semibold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(Color.green.gradient)
                .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
        )
        .padding(.horizontal, 20)
        .onAppear {
            isAnimating = true
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("通話中 \(formatDuration(duration)) 音声品質: \(quality.displayName)")
        .accessibilityHint("タップして通話画面を表示")
    }
    
    /// 通話時間をフォーマット
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    /// 音声品質の色を取得
    private func qualityColor(for quality: AudioQuality, index: Int) -> Color {
        let activeCount: Int
        switch quality {
        case .excellent:
            activeCount = 4
        case .good:
            activeCount = 3
        case .fair:
            activeCount = 2
        case .poor:
            activeCount = 1
        }
        
        return index < activeCount ? .white : .white.opacity(0.3)
    }
}

// MARK: - Call Interface View

/// 通話中インターフェースビュー
struct CallInterfaceView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var serviceContainer: ServiceContainer
    @StateObject private var callViewModel = CallInterfaceViewModel()
    
    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                // 通話情報
                VStack(spacing: 8) {
                    Text("通話中")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    if let number = callViewModel.participantNumber {
                        Text(number)
                            .font(.title)
                            .fontWeight(.bold)
                    }
                    
                    Text(formatDuration(callViewModel.duration))
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 40)
                
                Spacer()
                
                // リアルタイム転写プレビュー
                if let transcriptionText = callViewModel.currentTranscription, !transcriptionText.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("転写中...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        ScrollView {
                            Text(transcriptionText)
                                .font(.body)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(UIColor.secondarySystemBackground))
                                .cornerRadius(12)
                        }
                        .frame(maxHeight: 200)
                    }
                    .padding(.horizontal)
                }
                
                Spacer()
                
                // 通話終了ボタン
                Button(action: {
                    Task {
                        await callViewModel.endCall()
                        dismiss()
                    }
                }) {
                    Image(systemName: "phone.down.fill")
                        .font(.title2)
                        .foregroundColor(.white)
                        .frame(width: 60, height: 60)
                        .background(Color.red)
                        .clipShape(Circle())
                }
                .padding(.bottom, 40)
            }
            .navigationTitle("")
            .navigationBarHidden(true)
        }
        .onAppear {
            callViewModel.setServiceContainer(serviceContainer)
        }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Content View Model

/// コンテンツビューのViewModel
@MainActor
class ContentViewModel: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published var isCallActive = false
    @Published var callDuration: TimeInterval = 0
    @Published var callQuality: AudioQuality = .good
    @Published var showingError = false
    @Published var errorMessage = ""
    
    // MARK: - Private Properties
    
    private var callTimer: Timer?
    private let logger = Logger(subsystem: "com.telreq.app", category: "ContentViewModel")
    
    // MARK: - Initialization
    
    init() {
        setupNotificationObservers()
    }
    
    deinit {
        callTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Public Methods
    
    /// アプリケーションを初期化
    func initializeApp() async {
        do {
            try await ServiceContainer.shared.initializeServices()
            logger.info("App initialized successfully")
        } catch {
            logger.error("App initialization failed: \(error.localizedDescription)")
            showError("アプリケーションの初期化に失敗しました: \(error.localizedDescription)")
        }
    }
    
    /// イベントを追跡
    func trackEvent(_ event: String) {
        logger.info("Event tracked: \(event)")
        // 実際の実装では分析サービスに送信
    }
    
    /// エラーを表示
    func showError(_ message: String) {
        errorMessage = message
        showingError = true
    }
    
    /// エラーを非表示
    func dismissError() {
        showingError = false
        errorMessage = ""
    }
    
    // MARK: - Private Methods
    
    /// 通知オブザーバーを設定
    private func setupNotificationObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(callDidStart),
            name: NSNotification.Name("CallDidStart"),
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(callDidEnd),
            name: NSNotification.Name("CallDidEnd"),
            object: nil
        )
    }
    
    /// 通話開始通知の処理
    @objc private func callDidStart() {
        isCallActive = true
        startCallTimer()
    }
    
    /// 通話終了通知の処理
    @objc private func callDidEnd() {
        isCallActive = false
        stopCallTimer()
        callDuration = 0
    }
    
    /// 通話タイマーを開始
    private func startCallTimer() {
        callTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                self.callDuration += 1
            }
        }
    }
    
    /// 通話タイマーを停止
    private func stopCallTimer() {
        callTimer?.invalidate()
        callTimer = nil
    }
}

// MARK: - Call Interface View Model

/// 通話インターフェースのViewModel
@MainActor
class CallInterfaceViewModel: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published var participantNumber: String?
    @Published var duration: TimeInterval = 0
    @Published var currentTranscription: String?
    
    // MARK: - Private Properties
    
    private var serviceContainer: ServiceContainer?
    private var transcriptionTimer: Timer?
    
    // MARK: - Public Methods
    
    /// サービスコンテナを設定
    func setServiceContainer(_ container: ServiceContainer) {
        self.serviceContainer = container
        startTranscriptionUpdates()
    }
    
    /// 通話を終了
    func endCall() async {
        do {
            try await serviceContainer?.callManager.endCall()
            NotificationCenter.default.post(name: NSNotification.Name("CallDidEnd"), object: nil)
        } catch {
            print("通話終了エラー: \(error)")
        }
    }
    
    // MARK: - Private Methods
    
    /// 転写の更新を開始
    private func startTranscriptionUpdates() {
        // 実際の実装では音声認識サービスからリアルタイム転写を取得
        transcriptionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor in
                // デモ用のサンプルテキスト
                self.currentTranscription = "こんにちは、今日はお忙しい中お時間をいただきありがとうございます。"
            }
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView()
}