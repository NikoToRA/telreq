import SwiftUI
import os.log

/// 通話履歴ビュー
/// 
/// 通話記録の一覧表示、検索・フィルタリング機能、詳細ビューへのナビゲーションを提供します。
/// プルリフレッシュとインフィニットスクロール対応。
@available(iOS 15.0, *)
struct CallHistoryView: View {
    
    // MARK: - Properties
    
    @StateObject private var viewModel = CallHistoryViewModel()
    @EnvironmentObject private var serviceContainer: ServiceContainer
    @State private var showingSearchSheet = false
    @State private var showingFilterSheet = false
    @State private var selectedCall: CallRecord?
    
    // MARK: - Body
    
    var body: some View {
        NavigationView {
            ZStack {
                if viewModel.callRecords.isEmpty && !viewModel.isLoading {
                    emptyStateView
                } else {
                    callHistoryList
                }
                
                if viewModel.isLoading && viewModel.callRecords.isEmpty {
                    loadingView
                }
            }
            .navigationTitle("通話履歴")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button(action: {
                        showingFilterSheet = true
                    }) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                    
                    Button(action: {
                        showingSearchSheet = true
                    }) {
                        Image(systemName: "magnifyingglass")
                    }
                }
            }
            .refreshable {
                await viewModel.refreshData()
            }
            .searchable(
                text: $viewModel.searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "通話履歴を検索"
            )
            .onSubmit(of: .search) {
                Task {
                    await viewModel.performSearch()
                }
            }
            .onChange(of: viewModel.searchText) { oldValue, newValue in
                viewModel.handleSearchTextChange(newValue)
            }
            .sheet(isPresented: $showingFilterSheet) {
                CallHistoryFilterView(viewModel: viewModel)
            }
            .sheet(item: $selectedCall) { call in
                NavigationView {
                    CallDetailView(callRecord: call)
                        .environmentObject(serviceContainer)
                }
            }
            .alert("エラー", isPresented: $viewModel.showingError) {
                Button("OK") {
                    viewModel.dismissError()
                }
                if viewModel.canRetry {
                    Button("再試行") {
                        Task {
                            await viewModel.retryLastOperation()
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
                await viewModel.loadInitialData()
            }
        }
    }
    
    // MARK: - Subviews
    
    /// 通話履歴リスト
    private var callHistoryList: some View {
        List {
            ForEach(viewModel.callRecords) { record in
                CallHistoryRow(
                    record: record,
                    onTap: {
                        selectedCall = record
                    },
                    onDelete: {
                        Task {
                            await viewModel.deleteCall(record)
                        }
                    }
                )
                .onAppear {
                    // インフィニットスクロール
                    if record == viewModel.callRecords.last {
                        Task {
                            await viewModel.loadMoreData()
                        }
                    }
                }
            }
            .onDelete(perform: deleteRows)
            
            // ローディングインジケーター（追加読み込み時）
            if viewModel.isLoadingMore {
                HStack {
                    Spacer()
                    ProgressView()
                        .scaleEffect(0.8)
                    Spacer()
                }
                .padding(.vertical, 8)
            }
        }
        .listStyle(PlainListStyle())
    }
    
    /// 空の状態ビュー
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "phone.badge.clock")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            
            Text("通話履歴がありません")
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
    
    /// ローディングビュー
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            
            Text("通話履歴を読み込み中...")
                .font(.body)
                .foregroundColor(.secondary)
        }
    }
    
    // MARK: - Methods
    
    /// 行を削除
    private func deleteRows(offsets: IndexSet) {
        Task {
            await viewModel.deleteCallsAtIndices(offsets)
        }
    }
}

// MARK: - Call History Row

/// 通話履歴行ビュー
struct CallHistoryRow: View {
    let record: CallRecord
    let onTap: () -> Void
    let onDelete: () -> Void
    
    @State private var showingDeleteConfirmation = false
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // 通話方向インジケーター
                VStack {
                    Image(systemName: callDirectionIcon)
                        .font(.title3)
                        .foregroundColor(callDirectionColor)
                }
                .frame(width: 24)
                
                VStack(alignment: .leading, spacing: 6) {
                    // 録音タイトルと時間を一行で表示
                    HStack {
                        Text(formatRecordingTitle(record.participantNumber))
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        Spacer()
                        
                        Text(formatDuration(record.duration))
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.blue)
                    }
                    
                    // 要約プレビュー（より見やすく）
                    if !record.summaryPreview.isEmpty {
                        Text(record.summaryPreview)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    } else {
                        Text("音声処理中...")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .italic()
                    }
                    
                    // メタデータ
                    HStack(spacing: 8) {
                        // 時刻
                        Text(formatTimestamp(record.timestamp))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        // 品質インジケーター
                        QualityIndicator(quality: record.audioQuality)
                        
                        Spacer()
                        
                        // 共有インジケーター
                        if record.isShared {
                            Image(systemName: "person.2.fill")
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                        
                        // 音声ファイルインジケーター
                        if record.hasAudio {
                            Image(systemName: "waveform")
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    }
                }
                
                Spacer()
                
                // 転写方法インジケーター
                TranscriptionMethodBadge(method: record.transcriptionMethod)
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(PlainButtonStyle())
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                showingDeleteConfirmation = true
            } label: {
                Label("削除", systemImage: "trash")
            }
            
            Button {
                // 共有アクション
            } label: {
                Label("共有", systemImage: "square.and.arrow.up")
            }
            .tint(.blue)
        }
        .confirmationDialog("通話記録を削除", isPresented: $showingDeleteConfirmation) {
            Button("削除", role: .destructive) {
                onDelete()
            }
            Button("キャンセル", role: .cancel) { }
        } message: {
            Text("この通話記録を完全に削除しますか？この操作は取り消せません。")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("タップして詳細を表示")
    }
    
    // MARK: - Computed Properties
    
    private var callDirectionIcon: String {
        // 実際の実装では通話方向に基づいて決定
        return "phone.arrow.up.right"
    }
    
    private var callDirectionColor: Color {
        return .blue
    }
    
    private var accessibilityLabel: String {
        let direction = "発信"
        let time = formatTimestamp(record.timestamp)
        let duration = formatDuration(record.duration)
        return "\(direction) \(record.participantNumber) \(time) 通話時間\(duration)"
    }
    
    // MARK: - Helper Methods
    
    private func formatRecordingTitle(_ participantNumber: String) -> String {
        if participantNumber == "Manual Recording" {
            return "録音記録"
        } else {
            return participantNumber
        }
    }
    
    private func formatPhoneNumber(_ number: String) -> String {
        // 電話番号のフォーマット
        return number
    }
    
    private func formatTimestamp(_ timestamp: Date) -> String {
        let formatter = DateFormatter()
        
        if Calendar.current.isDateInToday(timestamp) {
            formatter.timeStyle = .short
            return "今日 \(formatter.string(from: timestamp))"
        } else if Calendar.current.isDateInYesterday(timestamp) {
            formatter.timeStyle = .short
            return "昨日 \(formatter.string(from: timestamp))"
        } else {
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            return formatter.string(from: timestamp)
        }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return "\(minutes):\(String(format: "%02d", seconds))"
    }
}

// MARK: - Quality Indicator

/// 音声品質インジケーター
struct QualityIndicator: View {
    let quality: AudioQuality
    
    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<4, id: \.self) { index in
                Rectangle()
                    .fill(barColor(for: index))
                    .frame(width: 2, height: CGFloat(4 + index))
                    .cornerRadius(1)
            }
        }
    }
    
    private func barColor(for index: Int) -> Color {
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
        
        return index < activeCount ? qualityColor : Color.gray.opacity(0.3)
    }
    
    private var qualityColor: Color {
        switch quality {
        case .excellent:
            return .green
        case .good:
            return .blue
        case .fair:
            return .orange
        case .poor:
            return .red
        }
    }
}

// MARK: - Transcription Method Badge

/// 転写方法バッジ
struct TranscriptionMethodBadge: View {
    let method: TranscriptionMethod
    
    var body: some View {
        Text(badgeText)
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(badgeColor.opacity(0.2))
            .foregroundColor(badgeColor)
            .cornerRadius(4)
    }
    
    private var badgeText: String {
        switch method {
        case .iosSpeech:
            return "iOS"
        case .azureSpeech:
            return "Azure"
        case .hybridProcessing:
            return "Hybrid"
        }
    }
    
    private var badgeColor: Color {
        switch method {
        case .iosSpeech:
            return .blue
        case .azureSpeech:
            return .green
        case .hybridProcessing:
            return .purple
        }
    }
}

// MARK: - Call History Filter View

/// 通話履歴フィルタービュー
struct CallHistoryFilterView: View {
    @ObservedObject var viewModel: CallHistoryViewModel
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            Form {
                Section("期間") {
                    DatePicker(
                        "開始日",
                        selection: $viewModel.filterStartDate,
                        displayedComponents: .date
                    )
                    
                    DatePicker(
                        "終了日",
                        selection: $viewModel.filterEndDate,
                        displayedComponents: .date
                    )
                }
                
                Section("音声品質") {
                    ForEach(AudioQuality.allCases, id: \.self) { quality in
                        HStack {
                            Text(quality.displayName)
                            Spacer()
                            if viewModel.selectedQualities.contains(quality) {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            viewModel.toggleQualityFilter(quality)
                        }
                    }
                }
                
                Section("転写方法") {
                    ForEach(TranscriptionMethod.allCases, id: \.self) { method in
                        HStack {
                            Text(method.displayName)
                            Spacer()
                            if viewModel.selectedMethods.contains(method) {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            viewModel.toggleMethodFilter(method)
                        }
                    }
                }
                
                Section("その他") {
                    Toggle("共有済みのみ", isOn: $viewModel.showOnlyShared)
                    Toggle("音声ファイルありのみ", isOn: $viewModel.showOnlyWithAudio)
                }
                
                Section {
                    Button("フィルターをクリア") {
                        viewModel.clearFilters()
                    }
                    .foregroundColor(.red)
                }
            }
            .navigationTitle("フィルター")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("キャンセル") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("適用") {
                        Task {
                            await viewModel.applyFilters()
                        }
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Call History View Model

/// 通話履歴ViewModel
@MainActor
class CallHistoryViewModel: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published var callRecords: [CallRecord] = []
    @Published var searchText = ""
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var showingError = false
    @Published var errorMessage = ""
    @Published var canRetry = false
    
    // フィルター関連
    @Published var filterStartDate = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @Published var filterEndDate = Date()
    @Published var selectedQualities: Set<AudioQuality> = Set(AudioQuality.allCases)
    @Published var selectedMethods: Set<TranscriptionMethod> = Set(TranscriptionMethod.allCases)
    @Published var showOnlyShared = false
    @Published var showOnlyWithAudio = false
    
    // MARK: - Private Properties
    
    private var serviceContainer: ServiceContainer?
    private var currentPage = 0
    private let pageSize = 20
    private var hasMoreData = true
    private var searchTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.telreq.app", category: "CallHistoryViewModel")
    
    // MARK: - Public Methods
    
    /// サービスコンテナを設定
    func setServiceContainer(_ container: ServiceContainer) {
        self.serviceContainer = container
    }
    
    /// 初期データを読み込み
    func loadInitialData() async {
        guard !isLoading else { return }
        
        isLoading = true
        currentPage = 0
        hasMoreData = true
        
        do {
            // ページ番号をリセット
            currentPage = 0
            
            let records = try await serviceContainer?.offlineDataManager.loadCallHistory(
                limit: pageSize,
                offset: currentPage * pageSize
            ) ?? []
            
            // 重複を排除して新しいデータで置き換え
            let uniqueRecords = Array(Set(records))
            callRecords = uniqueRecords
            currentPage = 1
            hasMoreData = records.count == pageSize
            
            logger.info("Loaded \(uniqueRecords.count) unique call records")
        } catch {
            logger.error("Failed to load call history: \(error.localizedDescription)")
            showError("通話履歴の読み込みに失敗しました", canRetry: true)
        }
        
        isLoading = false
    }
    
    /// 追加データを読み込み
    func loadMoreData() async {
        guard !isLoadingMore && hasMoreData else { return }
        
        isLoadingMore = true
        
        do {
            let records = try await serviceContainer?.offlineDataManager.loadCallHistory(
                limit: pageSize,
                offset: currentPage * pageSize
            ) ?? []
            
            // 重複を排除してから追加
            let existingIds = Set(callRecords.map { $0.id })
            let newRecords = records.filter { !existingIds.contains($0.id) }
            
            callRecords.append(contentsOf: newRecords)
            currentPage += 1
            hasMoreData = records.count == pageSize
            
            logger.info("Loaded \(newRecords.count) new unique call records (filtered from \(records.count))")
        } catch {
            logger.error("Failed to load more call history: \(error.localizedDescription)")
            showError("追加の通話履歴の読み込みに失敗しました")
        }
        
        isLoadingMore = false
    }
    
    /// データを更新
    func refreshData() async {
        await loadInitialData()
    }
    
    /// 検索を実行
    func performSearch() async {
        // 検索ロジックの実装
        logger.info("Performing search with query: \(self.searchText)")
        await loadInitialData()
    }
    
    /// 検索テキストの変更を処理
    func handleSearchTextChange(_ newValue: String) {
        searchTask?.cancel()
        
        guard !newValue.isEmpty else {
            Task {
                await loadInitialData()
            }
            return
        }
        
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms デバウンス
            if !Task.isCancelled {
                await performSearch()
            }
        }
    }
    
    /// 通話を削除
    func deleteCall(_ record: CallRecord) async {
        do {
            try await serviceContainer?.offlineDataManager.deleteCallRecord(record.id.uuidString)
            callRecords.removeAll { $0.id == record.id }
            logger.info("Deleted call record: \(record.id)")
        } catch {
            logger.error("Failed to delete call record: \(error.localizedDescription)")
            showError("通話記録の削除に失敗しました")
        }
    }
    
    /// インデックスで通話を削除
    func deleteCallsAtIndices(_ indices: IndexSet) async {
        let recordsToDelete = indices.map { callRecords[$0] }
        
        for record in recordsToDelete {
            await deleteCall(record)
        }
    }
    
    /// 品質フィルターを切り替え
    func toggleQualityFilter(_ quality: AudioQuality) {
        if selectedQualities.contains(quality) {
            selectedQualities.remove(quality)
        } else {
            selectedQualities.insert(quality)
        }
    }
    
    /// 転写方法フィルターを切り替え
    func toggleMethodFilter(_ method: TranscriptionMethod) {
        if selectedMethods.contains(method) {
            selectedMethods.remove(method)
        } else {
            selectedMethods.insert(method)
        }
    }
    
    /// フィルターをクリア
    func clearFilters() {
        filterStartDate = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
        filterEndDate = Date()
        selectedQualities = Set(AudioQuality.allCases)
        selectedMethods = Set(TranscriptionMethod.allCases)
        showOnlyShared = false
        showOnlyWithAudio = false
    }
    
    /// フィルターを適用
    func applyFilters() async {
        logger.info("Applying filters")
        await loadInitialData()
    }
    
    /// エラーを表示
    func showError(_ message: String, canRetry: Bool = false) {
        errorMessage = message
        self.canRetry = canRetry
        showingError = true
    }
    
    /// エラーを非表示
    func dismissError() {
        showingError = false
        errorMessage = ""
        canRetry = false
    }
    
    /// 最後の操作を再試行
    func retryLastOperation() async {
        await loadInitialData()
    }
}

// MARK: - Preview

#Preview {
    NavigationView {
        CallHistoryView()
            .environmentObject(ServiceContainer.shared)
    }
}