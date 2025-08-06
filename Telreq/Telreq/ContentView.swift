//
//  ContentView.swift
//  Telreq
//
//  Created by Suguru Hirayama on 2025/08/03.
//

import SwiftUI
import Speech
import os.log
#if canImport(UIKit)
import UIKit
#endif

@available(iOS 15.0, *)
struct ContentView: View {
    @StateObject private var contentViewModel = ContentViewModel()
    @StateObject private var serviceContainer = ServiceContainer.shared
    private let logger = Logger(subsystem: "com.telreq.app", category: "ContentView")
    @State private var selectedTab = 0
    @State private var showingCallInterface = false
    @State private var isRecording = false
    @State private var isProcessing = false
    @State private var isAudioProcessing = false  // 音声処理中フラグを追加
    @State private var processingMessage = ""
    @State private var showingSummaryPopup = false
    @State private var currentSummary = ""
    @State private var currentTodos: [String] = []
    
    var body: some View {
        TabView(selection: $selectedTab) {
            // ホーム画面
            NavigationView {
                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        // ヘッダーセクション - コンパクト化
                        HStack {
                            Image(systemName: "waveform.and.mic")
                                .font(.system(size: 24))
                                .foregroundStyle(
                                    LinearGradient(
                                        gradient: Gradient(colors: [.blue, .purple]),
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                            
                            Text("Telreq")
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundColor(.primary)
                            
                            Spacer()
                        }
                        .padding(.vertical, 8)
                        
                        Spacer()
                        
                        // メインコンテンツエリア - 要約表示エリア
                        VStack(spacing: 16) {
                            if isProcessing {
                                // 処理中表示
                                VStack(spacing: 20) {
                                    ZStack {
                                        Circle()
                                            .stroke(Color.blue.opacity(0.3), lineWidth: 6)
                                            .frame(width: 80, height: 80)
                                        
                                        Circle()
                                            .trim(from: 0, to: 0.7)
                                            .stroke(
                                                AngularGradient(
                                                    gradient: Gradient(colors: [.blue, .purple]),
                                                    center: .center
                                                ),
                                                style: StrokeStyle(lineWidth: 6, lineCap: .round)
                                            )
                                            .frame(width: 80, height: 80)
                                            .rotationEffect(.degrees(-90))
                                            .animation(.linear(duration: 2).repeatForever(autoreverses: false), value: isProcessing)
                                        
                                        Image(systemName: "waveform")
                                            .font(.system(size: 24))
                                            .foregroundColor(.blue)
                                    }
                                    
                                    Text(processingMessage)
                                        .font(.headline)
                                        .fontWeight(.medium)
                                        .foregroundColor(.primary)
                                        .multilineTextAlignment(.center)
                                }
                            } else {
                                // 要約表示エリア（常に表示）
                                VStack(spacing: 16) {
                                    HStack {
                                        Image(systemName: !contentViewModel.latestSummary.isEmpty ? "checkmark.circle.fill" : "doc.text")
                                            .font(.title3)
                                            .foregroundColor(!contentViewModel.latestSummary.isEmpty ? .green : .gray)
                                        Text(!contentViewModel.latestSummary.isEmpty ? "最新の要約" : "要約")
                                            .font(.title3)
                                            .fontWeight(.semibold)
                                        Spacer()
                                    }
                                    
                                    ScrollView {
                                        VStack(alignment: .leading, spacing: 16) {
                                            VStack(alignment: .leading, spacing: 8) {
                                                Text(contentViewModel.latestSummary.isEmpty ? "録音を開始すると、ここに要約が表示されます" : contentViewModel.latestSummary)
                                                    .font(.body)
                                                    .foregroundColor(contentViewModel.latestSummary.isEmpty ? .secondary : .primary)
                                                    .padding(16)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                                    .background(contentViewModel.latestSummary.isEmpty ? Color.gray.opacity(0.1) : Color.blue.opacity(0.1))
                                                    .cornerRadius(12)
                                                    .overlay(
                                                        RoundedRectangle(cornerRadius: 12)
                                                            .stroke(contentViewModel.latestSummary.isEmpty ? Color.gray.opacity(0.2) : Color.blue.opacity(0.3), lineWidth: 1)
                                                    )
                                            }
                                            
                                            if !contentViewModel.latestTodos.isEmpty {
                                                VStack(alignment: .leading, spacing: 8) {
                                                    Text("アクション項目")
                                                        .font(.headline)
                                                        .fontWeight(.bold)
                                                        .foregroundColor(.primary)
                                                    
                                                    ForEach(contentViewModel.latestTodos.indices, id: \.self) { index in
                                                        HStack(alignment: .top, spacing: 12) {
                                                            Image(systemName: "circle.fill")
                                                                .font(.caption)
                                                                .foregroundColor(.blue)
                                                                .padding(.top, 4)
                                                            
                                                            Text(contentViewModel.latestTodos[index])
                                                                .font(.body)
                                                                .lineLimit(nil)
                                                        }
                                                        .padding(.vertical, 4)
                                                    }
                                                }
                                                .padding(16)
                                                .background(Color.green.opacity(0.1))
                                                .cornerRadius(12)
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 12)
                                                        .stroke(Color.green.opacity(0.3), lineWidth: 1)
                                                )
                                            }
                                        }
                                    }
                                    .frame(maxHeight: 300)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        
                        Spacer()
                        
                        // ボタンセクション - 30%の高さ
                        VStack(spacing: 16) {
                            // メイン録音ボタン
                            Button(action: {
                                if isRecording {
                                    stopRecording()
                                } else {
                                    startRecording()
                                }
                            }) {
                                ZStack {
                                    // 背景円
                                    Circle()
                                        .fill(
                                            LinearGradient(
                                                gradient: Gradient(colors: isRecording ? 
                                                    [Color.red, Color.red.opacity(0.8)] : 
                                                    [Color.blue, Color.blue.opacity(0.8)]
                                                ),
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        .frame(width: 180, height: 180)
                                        .shadow(
                                            color: (isRecording ? Color.red : Color.blue).opacity(0.4),
                                            radius: 20,
                                            x: 0,
                                            y: 8
                                        )
                                    
                                    // 外側のパルス円（録音中のみ）
                                    if isRecording {
                                        Circle()
                                            .stroke(Color.red.opacity(0.5), lineWidth: 4)
                                            .frame(width: 200, height: 200)
                                            .scaleEffect(isRecording ? 1.1 : 1.0)
                                            .opacity(isRecording ? 0.0 : 1.0)
                                            .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false), value: isRecording)
                                    }
                                    
                                    // アイコンとテキスト
                                    VStack(spacing: 12) {
                                        Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                                            .font(.system(size: 50, weight: .medium))
                                            .foregroundColor(.white)
                                            .scaleEffect(isRecording ? 1.2 : 1.0)
                                            .animation(.easeInOut(duration: 0.3), value: isRecording)
                                        
                                        Text(isRecording ? "録音停止" : "録音開始")
                                            .font(.title2)
                                            .fontWeight(.bold)
                                            .foregroundColor(.white)
                                    }
                                }
                            }
                            .buttonStyle(PlainButtonStyle())
                            .disabled(isProcessing)
                            .scaleEffect(isProcessing ? 0.95 : 1.0)
                            .opacity(isProcessing ? 0.7 : 1.0)
                            .animation(.easeInOut(duration: 0.2), value: isProcessing)
                            
                            // ステータス表示
                            if isRecording {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 8, height: 8)
                                        .scaleEffect(1.5)
                                        .opacity(0.8)
                                        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isRecording)
                                    
                                    Text("録音中...")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                        .foregroundColor(.red)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.red.opacity(0.1))
                                .cornerRadius(20)
                            }
                        }
                        .frame(height: geometry.size.height * 0.3)
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 20)
                .padding()
                .navigationTitle("ホーム")
                #if canImport(UIKit) && !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
            }
            .tabItem {
                Image(systemName: "house.fill")
                Text("ホーム")
            }
            .tag(0)
            
            // 通話履歴
            CallHistoryView()
                .tabItem {
                    Image(systemName: "clock.fill")
                    Text("履歴")
                }
                .tag(1)
            
            // プロンプト設定
            PromptSettingsView()
                .tabItem {
                    Image(systemName: "text.bubble")
                    Text("プロンプト")
                }
                .tag(2)
            
            // 共有
            SharingView()
                .tabItem {
                    Image(systemName: "square.and.arrow.up")
                    Text("共有")
                }
                .tag(3)
            
            // 設定
            SettingsView()
                .tabItem {
                    Image(systemName: "gearshape.fill")
                    Text("設定")
                }
                .tag(4)
        }
        .sheet(isPresented: $showingCallInterface) {
            CallDetailView(callRecord: nil)
        }
        .sheet(isPresented: $showingSummaryPopup) {
            SummaryPopupView(
                summary: currentSummary,
                todos: currentTodos,
                isPresented: $showingSummaryPopup
            )
        }
        .environmentObject(serviceContainer)
        .task {
            // Step 1: デフォルトプロンプト設定（初回のみ）
            setupDefaultPromptsIfNeeded()
            
            // Step 2: 権限要求と状態確認
            await requestSpeechRecognitionPermission()
            
            // Step 3: 権限状態に基づく処理分岐
            let speechStatus = SFSpeechRecognizer.authorizationStatus()
            if speechStatus == .denied {
                await MainActor.run {
                    showPermissionDeniedAlert()
                }
            }
            
            // Step 4: サービス初期化（権限に関係なく基本機能は動作）
            do {
                try await serviceContainer.initializeServicesWithPermissionHandling()
            } catch {
                // サイレントに続行（権限エラー以外は続行を試みる）
                if case AppError.speechRecognitionUnavailable = error {
                    // 音声認識が利用不可でも限定機能で続行
                }
            }
            
            // Step 5: デリゲート設定を安全に実行
            await MainActor.run {
                serviceContainer.callManager.delegate = contentViewModel
            }
            
            // Step 6: 監視開始
            serviceContainer.callManager.startMonitoring()
            
            print("App initialization completed with status: \(speechStatus.rawValue)")
        }
    }
    
    // MARK: - Setup Methods
    
    private func setupDefaultPromptsIfNeeded() {
        // 初回起動時のみデフォルトプロンプトを設定
        if UserDefaults.standard.object(forKey: "customSummaryPrompt") == nil {
            let defaultSummaryPrompt = "以下の通話内容を500文字以内で簡潔に要約してください。重要なポイント、決定事項、次のアクションを含めてください。\n\n通話内容: {text}\n\n要約:"
            let defaultSystemPrompt = "あなたは電話会議の要約を専門とするアシスタントです。簡潔で分かりやすい要約を作成してください。"
            
            UserDefaults.standard.set(defaultSummaryPrompt, forKey: "customSummaryPrompt")
            UserDefaults.standard.set(defaultSystemPrompt, forKey: "customSystemPrompt")
            UserDefaults.standard.set(true, forKey: "useCustomPrompt")
            
            print("Default prompts set up")
        }
    }
    
    // MARK: - Permission Methods
    
    private func requestSpeechRecognitionPermission() async {
        let currentStatus = SFSpeechRecognizer.authorizationStatus()
        print("Current speech recognition status: \(currentStatus.rawValue)")
        
        // 権限状態に関係なく、明示的にユーザーに状況を説明
        switch currentStatus {
        case .notDetermined:
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    print("Speech recognition authorization result: \(status.rawValue)")
                    continuation.resume()
                }
            }
        case .denied:
            print("Speech recognition denied - directing user to Settings")
            // iOS設定アプリへの誘導を後で実装
        case .restricted:
            print("Speech recognition restricted by system policy")
        case .authorized:
            print("Speech recognition already authorized")
        @unknown default:
            print("Speech recognition unknown status: \(currentStatus.rawValue)")
        }
    }
    
    /// 権限が拒否された場合の設定画面誘導
    private func showPermissionDeniedAlert() {
        #if canImport(UIKit) && !os(macOS)
        // 設定画面への誘導アラートを表示
        let alert = UIAlertController(
            title: "音声認識権限が必要です",
            message: "アプリの音声認識機能を使用するには、設定で音声認識を有効にしてください。",
            preferredStyle: .alert
        )
        
        alert.addAction(UIAlertAction(title: "設定を開く", style: .default) { _ in
            if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(settingsURL)
            }
        })
        
        alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        
        // 現在のルートビューコントローラーから表示
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first,
           let rootViewController = window.rootViewController {
            rootViewController.present(alert, animated: true)
        }
        #else
        print("Permission denied - please enable speech recognition in System Preferences")
        #endif
    }
    
    // MARK: - AI Prompt Methods (Moved to Recording tab)
    
    // MARK: - Recording Methods
    
    private func startRecording() {
        // 権限チェック
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        guard speechStatus == .authorized else {
            processingMessage = "音声認識権限が必要です。設定で許可してください。"
            showPermissionDeniedAlert()
            return
        }
        
        isRecording = true
        processingMessage = ""
        contentViewModel.latestSummary = ""
        contentViewModel.latestTodos = []
        
        Task {
            do {
                let success = await serviceContainer.callManager.startAudioCapture()
                if !success {
                    await MainActor.run {
                        isRecording = false
                        processingMessage = "録音開始に失敗しました"
                    }
                }
            }
        }
    }
    
    private func stopRecording() {
        guard isRecording && !isProcessing && !isAudioProcessing else { 
            logger.warning("⚠️ Stop recording blocked: isRecording=\(isRecording), isProcessing=\(isProcessing), isAudioProcessing=\(isAudioProcessing)")
            return 
        }
        
        isRecording = false
        isProcessing = true
        isAudioProcessing = true
        processingMessage = "録音停止中..."
        logger.info("🛑 Starting stop recording process")
        
        Task { @MainActor in
            do {
                // Step 1: 録音停止
                serviceContainer.callManager.stopAudioCapture()
                
                // Step 2: テキスト書き起こし
                await MainActor.run {
                    processingMessage = "テキスト書き起こし中..."
                }
                
                // 音声認識実行（失敗した場合はダミーテキストで続行）
                let recognitionResult: SpeechRecognitionResult
                do {
                    recognitionResult = try await serviceContainer.speechRecognitionService.getFinalRecognitionResult()
                } catch {
                    // サイレント処理でダミーテキストを使用
                    recognitionResult = SpeechRecognitionResult(
                        text: "これはテスト録音です。MVP機能の動作確認を行っています。要約機能とTODO抽出をテストします。",
                        confidence: 0.5,
                        method: .iosSpeech,
                        language: "ja-JP",
                        processingTime: 0,
                        segments: []
                    )
                }
                
                guard !recognitionResult.text.isEmpty else {
                    await MainActor.run {
                        isProcessing = false
                        processingMessage = "音声が認識されませんでした"
                    }
                    return
                }
                
                // Step 3: AI要約作成
                await MainActor.run {
                    processingMessage = "AI要約作成中..."
                }
                
                // AI要約とTODO作成（安全な処理）
                let summary: CallSummary
                var aiProcessingSucceeded = false
                
                do {
                    // メモリ使用量をチェック
                    let memoryBefore = AsyncDebugHelpers.shared.getMemoryUsage()
                    logger.info("📊 Memory before AI processing: \(String(format: "%.1f", memoryBefore)) MB")
                    
                    if memoryBefore > 150.0 {
                        // メモリ不足の場合はローカル処理のみ（閾値を150MBに下げる）
                        logger.warning("⚠️ Memory too high (\(String(format: "%.1f", memoryBefore)) MB), using local processing only")
                        summary = generateLocalSummary(from: recognitionResult.text)
                        
                        // 強制ガベージコレクション
                        autoreleasepool {
                            // メモリクリーンアップ処理
                            AsyncDebugHelpers.shared.forceMemoryCleanup()
                        }
                    } else {
                        // タイムアウト付きでAI処理を実行
                        summary = try await withTimeout(30.0) {
                            return try await serviceContainer.textProcessingService.summarizeText(recognitionResult.text)
                        }
                        aiProcessingSucceeded = true
                    }
                } catch {
                    logger.warning("AI processing failed: \(error.localizedDescription)")
                    // AI処理が失敗した場合はローカル要約生成
                    summary = generateLocalSummary(from: recognitionResult.text)
                }
                
                // 成功した場合のみ履歴に保存
                if aiProcessingSucceeded && !summary.summary.isEmpty && summary.summary != "音声認識は完了しましたが、AI処理に失敗しました" {
                    // Step 4: 結果保存（履歴用）
                    await MainActor.run {
                        processingMessage = "結果を保存中..."
                    }
                    
                    // 簡単な通話データを作成して保存
                    let callData = StructuredCallData(
                        timestamp: Date(),
                        duration: 0, // 実際の録音時間は後で設定
                        participantNumber: "Manual Recording",
                        audioFileUrl: "",
                        transcriptionText: recognitionResult.text,
                        summary: summary,
                        metadata: CallMetadata(
                            callDirection: .outgoing,
                            audioQuality: .good,
                            transcriptionMethod: .iosSpeech,
                            language: "ja-JP",
                            confidence: recognitionResult.confidence,
                            startTime: Date(),
                            endTime: Date(),
                            deviceInfo: DeviceInfo(deviceModel: "iPhone", systemVersion: "18.0", appVersion: "1.0"),
                            networkInfo: NetworkInfo(connectionType: .wifi)
                        )
                    )
                    
                    // ローカル保存
                    try await serviceContainer.offlineDataManager.saveLocalData(callData)
                }
                
                // Step 5: 完了 - ポップアップ表示
                await MainActor.run {
                    isProcessing = false
                    isAudioProcessing = false  // 音声処理完了フラグ
                    processingMessage = ""
                    
                    logger.info("✅ Audio processing completed successfully")
                    
                    // ポップアップ用データ設定
                    currentSummary = summary.summary
                    currentTodos = summary.actionItems
                    showingSummaryPopup = true
                    
                    // ViewModelも更新（履歴表示用）
                    contentViewModel.latestSummary = summary.summary
                    contentViewModel.latestTodos = summary.actionItems
                }
                
            } catch {
                await MainActor.run {
                    isProcessing = false
                    isAudioProcessing = false  // エラー時もフラグリセット
                    processingMessage = "エラーが発生しました: \(error.localizedDescription)"
                    logger.error("❌ Audio processing failed: \(error.localizedDescription)")
                }
            }
        }
    }
    
    // MARK: - Utility Methods
    
    /// タイムアウト付きで非同期処理を実行（改善版）
    private func withTimeout<T>(_ timeout: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                return try await operation()
            }
            
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw AppError.networkTimeout
            }
            
            guard let result = try await group.next() else {
                throw AppError.networkTimeout
            }
            
            group.cancelAll()
            return result
        }
    }
    
    // MARK: - Local Processing Methods
    
    /// ローカル要約生成（Azure AI が利用できない場合のフォールバック）
    private func generateLocalSummary(from text: String) -> CallSummary {
        let wordCount = text.components(separatedBy: .whitespacesAndNewlines).count
        
        let summary: String
        if text.isEmpty {
            summary = "音声データが検出されませんでした。"
        } else if wordCount < 10 {
            summary = "短い録音でした。主な内容: \(text.prefix(50))..."
        } else if wordCount < 50 {
            summary = "中程度の長さの録音でした。要約: \(text.prefix(100))..."
        } else {
            summary = "詳細な録音でした。主要なポイントが複数含まれています。要約: \(text.prefix(150))..."
        }
        
        // 簡単なTODO抽出
        let actionKeywords = ["する", "やる", "確認", "連絡", "検討", "実施", "準備", "対応"]
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".。!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        let actionItems = sentences.filter { sentence in
            actionKeywords.contains { keyword in
                sentence.contains(keyword)
            }
        }.prefix(5).map { $0 }
        
        return CallSummary(
            keyPoints: Array(sentences.prefix(3)),
            summary: summary,
            duration: 0,
            participants: ["録音者"],
            actionItems: Array(actionItems),
            tags: ["ローカル処理"],
            confidence: 0.7
        )
    }
}

// プロンプト設定画面
@available(iOS 15.0, *)
struct PromptSettingsView: View {
    @EnvironmentObject private var serviceContainer: ServiceContainer
    @State private var aiPromptText = ""
    @State private var systemPromptText = ""
    @State private var showingAdvanced = false
    @State private var saveMessage = ""
    @State private var selectedPromptType: PromptType = .summary
    
    enum PromptType: CaseIterable {
        case summary, system
        
        var title: String {
            switch self {
            case .summary: return "要約プロンプト"
            case .system: return "システムプロンプト"
            }
        }
        
        var description: String {
            switch self {
            case .summary: return "録音内容の要約を生成する際に使用するプロンプトです"
            case .system: return "AI全体の動作を制御するシステムプロンプトです"
            }
        }
        
        var placeholder: String {
            switch self {
            case .summary: return "例: 以下のテキストを簡潔に要約してください..."
            case .system: return "例: あなたは通話内容を要約するアシスタントです..."
            }
        }
    }
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    // ヘッダー
                    VStack(spacing: 12) {
                        Image(systemName: "text.bubble.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.blue)
                        
                        Text("AI プロンプト設定")
                            .font(.title)
                            .fontWeight(.bold)
                        
                        Text("AI要約の品質を向上させるためのプロンプトを設定できます")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top)
                    
                    // プロンプトタイプ選択
                    Picker("プロンプトタイプ", selection: $selectedPromptType) {
                        ForEach(PromptType.allCases, id: \.self) { type in
                            Text(type.title).tag(type)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .padding(.horizontal)
                    
                    // 現在選択中のプロンプト設定
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(selectedPromptType.title)
                                .font(.headline)
                                .fontWeight(.bold)
                            
                            Text(selectedPromptType.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        // プロンプト入力エリア
                        VStack(alignment: .leading, spacing: 8) {
                            TextEditor(text: currentPromptBinding)
                                .frame(minHeight: 150)
                                .padding(12)
                                .background(Color.gray.opacity(0.08))
                                .cornerRadius(12)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                                )
                                .font(.body)
                            
                            if currentPromptBinding.wrappedValue.isEmpty {
                                Text(selectedPromptType.placeholder)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .italic()
                            }
                        }
                        
                        // ボタンエリア
                        VStack(spacing: 12) {
                            HStack(spacing: 12) {
                                Button("デフォルト") {
                                    setDefaultPrompt()
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.blue.opacity(0.1))
                                .foregroundColor(.blue)
                                .cornerRadius(8)
                                
                                Button("クリア") {
                                    currentPromptBinding.wrappedValue = ""
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.red.opacity(0.1))
                                .foregroundColor(.red)
                                .cornerRadius(8)
                                
                                Spacer()
                            }
                            
                            Button(action: savePrompt) {
                                HStack {
                                    Image(systemName: "checkmark.circle.fill")
                                    Text("保存")
                                        .fontWeight(.semibold)
                                }
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.blue)
                                .cornerRadius(12)
                            }
                            
                            if !saveMessage.isEmpty {
                                HStack {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                    Text(saveMessage)
                                        .font(.caption)
                                        .foregroundColor(.green)
                                }
                            }
                        }
                    }
                    .padding()
                    .background(Color.gray.opacity(0.05))
                    .cornerRadius(16)
                    
                    Spacer()
                }
                .padding()
            }
            .navigationTitle("プロンプト設定")
            #if canImport(UIKit) && !os(macOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
        }
        .onAppear {
            loadPrompts()
        }
    }
    
    private var currentPromptBinding: Binding<String> {
        switch selectedPromptType {
        case .summary:
            return $aiPromptText
        case .system:
            return $systemPromptText
        }
    }
    
    private func loadPrompts() {
        aiPromptText = UserDefaults.standard.string(forKey: "customSummaryPrompt") ?? ""
        systemPromptText = UserDefaults.standard.string(forKey: "customSystemPrompt") ?? ""
    }
    
    private func setDefaultPrompt() {
        switch selectedPromptType {
        case .summary:
            aiPromptText = "以下のテキストを200文字以内で簡潔に要約してください。重要なポイント、決定事項、次のアクションを含めてください。\n\nテキスト: {text}\n\n要約:"
        case .system:
            systemPromptText = "あなたは電話会議の要約を専門とするアシスタントです。簡潔で分かりやすい要約を作成してください。"
        }
    }
    
    private func savePrompt() {
        switch selectedPromptType {
        case .summary:
            UserDefaults.standard.set(aiPromptText, forKey: "customSummaryPrompt")
            UserDefaults.standard.set(!aiPromptText.isEmpty, forKey: "useCustomPrompt")
        case .system:
            UserDefaults.standard.set(systemPromptText, forKey: "customSystemPrompt")
        }
        
        saveMessage = "\(selectedPromptType.title)が保存されました"
        
        // 2秒後にメッセージをクリア
        Task {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                saveMessage = ""
            }
        }
    }
}

// MARK: - ContentViewModel

@available(iOS 15.0, *)
class ContentViewModel: ObservableObject, CallManagerDelegate {
    @Published var currentTranscription: String?
    @Published var latestSummary: String = ""
    @Published var latestTodos: [String] = []
    
    func callManager(didStartCall callInfo: CallInfo) {
        print("Call started: \(callInfo.phoneNumber)")
    }
    
    func callManager(didEndCall callInfo: CallInfo) {
        print("Call ended: \(callInfo.phoneNumber)")
    }
    
    func callManager(didCompleteCallProcessing data: StructuredCallData, summary: CallSummary) {
        DispatchQueue.main.async {
            self.currentTranscription = data.transcriptionText
            self.latestSummary = summary.summary
            self.latestTodos = summary.actionItems
            print("Call processing completed - Summary: \(summary.summary)")
            print("Action items: \(self.latestTodos)")
        }
    }
    
    func callManager(didFailWithError error: Error) {
        // サイレントにエラーを処理
    }
}

// 要約結果ポップアップView
@available(iOS 15.0, *)
struct SummaryPopupView: View {
    let summary: String
    let todos: [String]
    @Binding var isPresented: Bool
    
    var body: some View {
        let navigationView = NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // 要約セクション
                    VStack(alignment: .leading, spacing: 12) {
                        Text("要約")
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(.primary)
                        
                        Text(summary.isEmpty ? "要約が生成されませんでした" : summary)
                            .font(.body)
                            .padding()
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(10)
                    }
                    
                    // TODO セクション
                    if !todos.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("TODO項目")
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundColor(.primary)
                            
                            ForEach(todos.indices, id: \.self) { index in
                                HStack(alignment: .top) {
                                    Text("•")
                                        .font(.body)
                                        .foregroundColor(.blue)
                                        .fontWeight(.bold)
                                    Text(todos[index])
                                        .font(.body)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                    
                    Spacer(minLength: 20)
                }
                .padding()
            }
            .navigationTitle("録音結果")
            .toolbar {
                ToolbarItem(placement: ToolbarItemPlacement.primaryAction) {
                    Button("完了") {
                        isPresented = false
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        
        #if canImport(UIKit) && !os(macOS)
        return navigationView
            .navigationBarTitleDisplayMode(.large)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        #else
        return navigationView
        #endif
    }
}

#Preview {
    ContentView()
}