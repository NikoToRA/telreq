import SwiftUI
import os.log
import AVFoundation

/// 通話詳細ビュー
/// 
/// 転写テキストの全文表示、要約とキーワード表示、音声再生機能、共有機能を提供します。
/// 詳細な通話データの表示とインタラクション機能を含みます。
@available(iOS 15.0, *)
struct CallDetailView: View {
    
    // MARK: - Properties
    
    let callRecord: CallRecord?
    @StateObject private var viewModel = CallDetailViewModel()
    @EnvironmentObject private var serviceContainer: ServiceContainer
    @Environment(\.dismiss) private var dismiss
    
    @State private var showingShareSheet = false
    @State private var showingTranscriptionEdit = false
    @State private var showingMetadataSheet = false
    
    // MARK: - Body
    
    var body: some View {
        Group {
            if let callRecord = callRecord {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // ヘッダー情報
                        callHeaderView
                        
                        // 音声再生コントロール
                        if callRecord.hasAudio {
                            audioPlayerView
                        }
                        
                        // 要約セクション
                        summarySection
                        
                        // キーワードセクション
                        keywordsSection
                        
                        // 転写テキストセクション
                        transcriptionSection
                        
                        // メタデータセクション
                        metadataSection
                        
                        // 共有情報セクション
                        if callRecord.isShared {
                            sharingSection
                        }
                    }
                    .padding()
                }
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "phone.badge.clock")
                        .font(.system(size: 60))
                        .foregroundColor(.secondary)
                    
                    Text("通話記録がありません")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text("通話を開始すると、ここに記録が表示されます")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                .padding()
            }
        }
        .navigationTitle("通話詳細")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button(action: {
                    showingMetadataSheet = true
                }) {
                    Image(systemName: "info.circle")
                }
                
                Button(action: {
                    showingShareSheet = true
                }) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .sheet(isPresented: $showingShareSheet) {
            if let callRecord = callRecord {
                CallSharingSheet(
                    callRecord: callRecord,
                    viewModel: viewModel
                )
            }
        }
        .sheet(isPresented: $showingTranscriptionEdit) {
            if let callRecord = callRecord {
                TranscriptionEditView(
                    callRecord: callRecord,
                    viewModel: viewModel
                )
            }
        }
        .sheet(isPresented: $showingMetadataSheet) {
            if let callRecord = callRecord {
                CallMetadataView(callRecord: callRecord)
            }
        }
        .alert("エラー", isPresented: $viewModel.showingError) {
            Button("OK") {
                viewModel.dismissError()
            }
        } message: {
            Text(viewModel.errorMessage)
        }
        .onAppear {
            viewModel.setServiceContainer(serviceContainer)
            if let callRecord = callRecord {
                Task {
                    await viewModel.loadCallDetails(callRecord.id)
                }
            }
        }
    }
    
    // MARK: - Subviews
    
    /// 通話ヘッダービュー
    private var callHeaderView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(formatPhoneNumber(callRecord?.participantNumber ?? ""))
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    Text(formatTimestamp(callRecord?.timestamp ?? Date()))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    Text(formatDuration(callRecord?.duration ?? 0))
                        .font(.headline)
                        .fontWeight(.semibold)
                    
                    HStack(spacing: 8) {
                        QualityIndicator(quality: callRecord?.audioQuality ?? .good)
                        TranscriptionMethodBadge(method: callRecord?.transcriptionMethod ?? .iosSpeech)
                    }
                }
            }
            
            if let callRecord = callRecord, !callRecord.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(callRecord.tags, id: \.self) { tag in
                            TagView(text: tag)
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    /// 音声プレイヤービュー
    private var audioPlayerView: some View {
        Group {
            if let callRecord = callRecord {
                AudioPlayerView(
                    callId: callRecord.id.uuidString,
                    duration: callRecord.duration,
                    viewModel: viewModel
                )
                .padding()
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(12)
            }
        }
    }
    
    /// 要約セクション
    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("要約")
                    .font(.headline)
                    .fontWeight(.semibold)
                
                Spacer()
                
                if let summary = viewModel.callDetails?.summary {
                    ConfidenceIndicator(confidence: summary.confidence)
                }
            }
            
            if let summary = viewModel.callDetails?.summary.summary {
                Text(summary)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("要約を読み込み中...")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .redacted(reason: viewModel.isLoading ? .placeholder : [])
            }
            
            // アクションアイテム
            if let actionItems = viewModel.callDetails?.summary.actionItems, !actionItems.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("アクションアイテム")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    
                    ForEach(actionItems, id: \.self) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "checkmark.circle")
                                .foregroundColor(.blue)
                                .font(.caption)
                            
                            Text(item)
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 8)
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    /// キーワードセクション
    private var keywordsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("キーワード")
                .font(.headline)
                .fontWeight(.semibold)
            
            if let keyPoints = viewModel.callDetails?.summary.keyPoints, !keyPoints.isEmpty {
                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: 100), spacing: 8)
                ], spacing: 8) {
                    ForEach(keyPoints, id: \.self) { keyword in
                        KeywordTagView(text: keyword)
                    }
                }
            } else {
                Text("キーワードを抽出中...")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .redacted(reason: viewModel.isLoading ? .placeholder : [])
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    /// 転写テキストセクション
    private var transcriptionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("転写テキスト")
                    .font(.headline)
                    .fontWeight(.semibold)
                
                Spacer()
                
                Button(action: {
                    showingTranscriptionEdit = true
                }) {
                    Image(systemName: "pencil")
                        .font(.caption)
                }
            }
            
            if let transcription = viewModel.callDetails?.transcriptionText {
                ScrollView {
                    Text(transcription)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 300)
            } else {
                Text("転写テキストを読み込み中...")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .redacted(reason: viewModel.isLoading ? .placeholder : [])
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    /// メタデータセクション
    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("詳細情報")
                .font(.headline)
                .fontWeight(.semibold)
            
            VStack(spacing: 6) {
                MetadataRow(
                    title: "転写方法",
                    value: callRecord?.transcriptionMethod.displayName ?? "iOS Speech"
                )
                
                MetadataRow(
                    title: "音声品質",
                    value: callRecord?.audioQuality.displayName ?? "標準"
                )
                
                if let details = viewModel.callDetails {
                    MetadataRow(
                        title: "参加者",
                        value: details.summary.participants.joined(separator: ", ")
                    )
                    
                    MetadataRow(
                        title: "データサイズ",
                        value: formatDataSize(details.estimatedDataSize)
                    )
                }
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    /// 共有セクション
    private var sharingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("共有情報")
                .font(.headline)
                .fontWeight(.semibold)
            
            if let details = viewModel.callDetails {
                VStack(alignment: .leading, spacing: 8) {
                    Text("共有先: \(details.sharedWith.count)人")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    ForEach(details.sharedWith, id: \.self) { userId in
                        HStack {
                            Image(systemName: "person.circle")
                                .foregroundColor(.blue)
                            
                            Text(userId)
                                .font(.subheadline)
                            
                            Spacer()
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    // MARK: - Helper Methods
    
    private func formatPhoneNumber(_ number: String) -> String {
        return number
    }
    
    private func formatTimestamp(_ timestamp: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    private func formatDataSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Supporting Views

/// タグビュー
struct TagView: View {
    let text: String
    
    var body: some View {
        Text(text)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.blue.opacity(0.1))
            .foregroundColor(.blue)
            .cornerRadius(8)
    }
}

/// キーワードタグビュー
struct KeywordTagView: View {
    let text: String
    
    var body: some View {
        Text(text)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.green.opacity(0.1))
            .foregroundColor(.green)
            .cornerRadius(12)
    }
}

/// 信頼度インジケーター
struct ConfidenceIndicator: View {
    let confidence: Double
    
    var body: some View {
        HStack(spacing: 4) {
            Text("\(Int(confidence * 100))%")
                .font(.caption)
                .fontWeight(.semibold)
            
            Circle()
                .fill(confidenceColor)
                .frame(width: 8, height: 8)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(confidenceColor.opacity(0.1))
        .cornerRadius(8)
    }
    
    private var confidenceColor: Color {
        switch confidence {
        case 0.9...:
            return .green
        case 0.7..<0.9:
            return .orange
        default:
            return .red
        }
    }
}

/// メタデータ行
struct MetadataRow: View {
    let title: String
    let value: String
    
    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Spacer()
            
            Text(value)
                .font(.subheadline)
                .fontWeight(.medium)
        }
    }
}

/// 音声プレイヤービュー
struct AudioPlayerView: View {
    let callId: String
    let duration: TimeInterval
    @ObservedObject var viewModel: CallDetailViewModel
    
    @State private var isPlaying = false
    @State private var currentTime: TimeInterval = 0
    @State private var playbackRate: Float = 1.0
    
    var body: some View {
        VStack(spacing: 16) {
            // 再生時間表示
            HStack {
                Text(formatTime(currentTime))
                    .font(.caption)
                    .monospacedDigit()
                
                Spacer()
                
                Text(formatTime(duration))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundColor(.secondary)
            }
            
            // 進捗バー
            ProgressView(value: currentTime, total: duration)
                .tint(.blue)
            
            // 再生コントロール
            HStack(spacing: 20) {
                // 15秒戻る
                Button(action: {
                    seekBackward()
                }) {
                    Image(systemName: "gobackward.15")
                        .font(.title2)
                }
                
                // 再生/一時停止
                Button(action: {
                    togglePlayback()
                }) {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.largeTitle)
                }
                
                // 15秒進む
                Button(action: {
                    seekForward()
                }) {
                    Image(systemName: "goforward.15")
                        .font(.title2)
                }
                
                Spacer()
                
                // 再生速度
                Menu {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                        Button(action: {
                            setPlaybackRate(Float(rate))
                        }) {
                            HStack {
                                Text(String(format: "%.2gx", rate))
                                if Float(rate) == playbackRate {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Text(String(format: "%.2gx", playbackRate))
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(UIColor.tertiarySystemBackground))
                        .cornerRadius(6)
                }
            }
        }
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    private func togglePlayback() {
        isPlaying.toggle()
        // 実際の音声再生ロジック
    }
    
    private func seekBackward() {
        currentTime = max(0, currentTime - 15)
        // 実際のシークロジック
    }
    
    private func seekForward() {
        currentTime = min(duration, currentTime + 15)
        // 実際のシークロジック
    }
    
    private func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        // 実際の再生速度変更ロジック
    }
}

// MARK: - Call Sharing Sheet

/// 通話共有シート
struct CallSharingSheet: View {
    let callRecord: CallRecord
    @ObservedObject var viewModel: CallDetailViewModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var selectedUsers: Set<String> = []
    @State private var shareMessage = ""
    @State private var permissionLevel = SharingPermission.read
    @State private var expiryDate: Date?
    @State private var hasExpiry = false
    
    var body: some View {
        NavigationView {
            Form {
                Section("共有メッセージ") {
                    TextField("メッセージ（任意）", text: $shareMessage, axis: .vertical)
                        .lineLimit(3...6)
                }
                
                Section("権限レベル") {
                    Picker("権限", selection: $permissionLevel) {
                        Text("読み取り専用").tag(SharingPermission.read)
                        Text("読み書き可能").tag(SharingPermission.readWrite)
                        Text("管理者").tag(SharingPermission.admin)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                }
                
                Section("有効期限") {
                    Toggle("有効期限を設定", isOn: $hasExpiry)
                    
                    if hasExpiry {
                        DatePicker(
                            "期限日時",
                            selection: Binding(
                                get: { expiryDate ?? Date().addingTimeInterval(86400 * 7) },
                                set: { expiryDate = $0 }
                            ),
                            in: Date()...,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                    }
                }
                
                Section("共有先ユーザー") {
                    // ユーザー検索とセレクション
                    // 実際の実装ではユーザー検索機能を含む
                    Text("ユーザー選択機能を実装")
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("通話記録を共有")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("キャンセル") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("共有") {
                        Task {
                            await shareCall()
                        }
                    }
                    .disabled(selectedUsers.isEmpty)
                }
            }
        }
    }
    
    private func shareCall() async {
        // 共有ロジックの実装
        dismiss()
    }
}

// MARK: - Transcription Edit View

/// 転写編集ビュー
struct TranscriptionEditView: View {
    let callRecord: CallRecord
    @ObservedObject var viewModel: CallDetailViewModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var editedText = ""
    @State private var hasChanges = false
    
    var body: some View {
        NavigationView {
            VStack {
                TextEditor(text: $editedText)
                    .font(.body)
                    .padding()
                    .onChange(of: editedText) { oldValue, newValue in
                        hasChanges = true
                    }
            }
            .navigationTitle("転写テキスト編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("キャンセル") {
                        if hasChanges {
                            // 変更確認ダイアログ
                        }
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        Task {
                            await saveChanges()
                        }
                    }
                    .disabled(!hasChanges)
                }
            }
        }
        .onAppear {
            editedText = viewModel.callDetails?.transcriptionText ?? ""
        }
    }
    
    private func saveChanges() async {
        // 変更保存ロジック
        dismiss()
    }
}

// MARK: - Call Metadata View

/// 通話メタデータビュー
struct CallMetadataView: View {
    let callRecord: CallRecord
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            List {
                Section("基本情報") {
                    LabeledContent("通話ID", value: callRecord.id.uuidString)
                    LabeledContent("時刻", value: formatTimestamp(callRecord.timestamp))
                    LabeledContent("時間", value: formatDuration(callRecord.duration))
                    LabeledContent("参加者", value: callRecord.participantNumber)
                }
                
                Section("品質情報") {
                    LabeledContent("音声品質", value: callRecord.audioQuality.displayName)
                    LabeledContent("転写方法", value: callRecord.transcriptionMethod.displayName)
                }
                
                Section("状態") {
                    LabeledContent("共有状態", value: callRecord.isShared ? "共有済み" : "非共有")
                    LabeledContent("音声ファイル", value: callRecord.hasAudio ? "あり" : "なし")
                }
            }
            .navigationTitle("メタデータ")
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
    
    private func formatTimestamp(_ timestamp: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Call Detail View Model

/// 通話詳細ViewModel
@MainActor
class CallDetailViewModel: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published var callDetails: StructuredCallData?
    @Published var isLoading = false
    @Published var showingError = false
    @Published var errorMessage = ""
    
    // MARK: - Private Properties
    
    private var serviceContainer: ServiceContainer?
    private let logger = Logger(subsystem: "com.telreq.app", category: "CallDetailViewModel")
    
    // MARK: - Public Methods
    
    /// サービスコンテナを設定
    func setServiceContainer(_ container: ServiceContainer) {
        self.serviceContainer = container
    }
    
    /// 通話詳細を読み込み
    func loadCallDetails(_ callId: UUID) async {
        isLoading = true
        
        do {
            guard let serviceContainer = serviceContainer else {
                throw AppError.invalidConfiguration
            }
            
            let details = try await serviceContainer.offlineDataManager.loadCallDetails(callId.uuidString)
            callDetails = details
            
            logger.info("Loaded call details for: \(callId)")
        } catch {
            logger.error("Failed to load call details: \(error.localizedDescription)")
            showError("通話詳細の読み込みに失敗しました: \(error.localizedDescription)")
        }
        
        isLoading = false
    }
    
    /// エラーを表示
    private func showError(_ message: String) {
        errorMessage = message
        showingError = true
    }
    
    /// エラーを非表示
    func dismissError() {
        showingError = false
        errorMessage = ""
    }
}

// MARK: - Preview

#Preview {
    NavigationView {
        CallDetailView(callRecord: nil)
            .environmentObject(ServiceContainer.shared)
    }
}