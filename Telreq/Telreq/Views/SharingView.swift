import SwiftUI
import os.log

/// 共有ビュー
/// 
/// ユーザー検索、共有リクエスト管理、共有記録表示を提供します。
/// 通話記録の共有と協働機能を管理します。
@available(iOS 15.0, *)
struct SharingView: View {
    
    // MARK: - Properties
    
    @StateObject private var viewModel = SharingViewModel()
    @EnvironmentObject private var serviceContainer: ServiceContainer
    @State private var selectedTab = 0
    @State private var showingUserSearch = false
    @State private var showingShareRequest = false
    @State private var selectedRequest: SharingRequest?
    
    // MARK: - Body
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // セグメントコントロール
                Picker("共有タブ", selection: $selectedTab) {
                    Text("受信済み").tag(0)
                    Text("送信済み").tag(1)
                    Text("リクエスト").tag(2)
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding()
                
                // コンテンツ
                TabView(selection: $selectedTab) {
                    // 受信済み共有
                    receivedSharingView
                        .tag(0)
                    
                    // 送信済み共有
                    sentSharingView
                        .tag(1)
                    
                    // 共有リクエスト
                    sharingRequestsView
                        .tag(2)
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
            }
            .navigationTitle("共有")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button(action: {
                        showingUserSearch = true
                    }) {
                        Image(systemName: "person.badge.plus")
                    }
                    
                    Button(action: {
                        showingShareRequest = true
                    }) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .refreshable {
                await viewModel.refreshData()
            }
            .sheet(isPresented: $showingUserSearch) {
                UserSearchSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $showingShareRequest) {
                ShareRequestSheet(viewModel: viewModel)
            }
            .sheet(item: $selectedRequest) { request in
                SharingRequestDetailView(
                    request: request,
                    viewModel: viewModel
                )
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
                await viewModel.loadInitialData()
            }
        }
    }
    
    // MARK: - Tab Views
    
    /// 受信済み共有ビュー
    private var receivedSharingView: some View {
        Group {
            if viewModel.receivedSharedRecords.isEmpty {
                emptyStateView(
                    icon: "tray.and.arrow.down",
                    title: "受信した共有がありません",
                    message: "他のユーザーから共有された通話記録がここに表示されます"
                )
            } else {
                List {
                    ForEach(viewModel.receivedSharedRecords) { sharedRecord in
                        ReceivedSharingRow(
                            sharedRecord: sharedRecord,
                            onTap: {
                                // 詳細表示
                            },
                            onRemove: {
                                Task {
                                    await viewModel.removeSharedRecord(sharedRecord)
                                }
                            }
                        )
                    }
                }
                .listStyle(PlainListStyle())
            }
        }
    }
    
    /// 送信済み共有ビュー
    private var sentSharingView: some View {
        Group {
            if viewModel.sentSharedRecords.isEmpty {
                emptyStateView(
                    icon: "tray.and.arrow.up",
                    title: "共有した記録がありません",
                    message: "あなたが他のユーザーと共有した通話記録がここに表示されます"
                )
            } else {
                List {
                    ForEach(viewModel.sentSharedRecords) { sharedRecord in
                        SentSharingRow(
                            sharedRecord: sharedRecord,
                            onTap: {
                                // 詳細表示
                            },
                            onRevoke: {
                                Task {
                                    await viewModel.revokeSharing(sharedRecord)
                                }
                            }
                        )
                    }
                }
                .listStyle(PlainListStyle())
            }
        }
    }
    
    /// 共有リクエストビュー
    private var sharingRequestsView: some View {
        Group {
            if viewModel.sharingRequests.isEmpty {
                emptyStateView(
                    icon: "envelope.badge.person.crop",
                    title: "共有リクエストがありません",
                    message: "受信した共有リクエストがここに表示されます"
                )
            } else {
                List {
                    ForEach(viewModel.sharingRequests) { request in
                        SharingRequestRow(
                            request: request,
                            onTap: {
                                selectedRequest = request
                            },
                            onAccept: {
                                Task {
                                    await viewModel.acceptSharingRequest(request)
                                }
                            },
                            onReject: {
                                Task {
                                    await viewModel.rejectSharingRequest(request)
                                }
                            }
                        )
                    }
                }
                .listStyle(PlainListStyle())
            }
        }
    }
    
    /// 空の状態ビュー
    private func emptyStateView(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            
            Text(title)
                .font(.title2)
                .fontWeight(.semibold)
            
            Text(message)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Row Views

/// 受信共有行
struct ReceivedSharingRow: View {
    let sharedRecord: SharedCallRecord
    let onTap: () -> Void
    let onRemove: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // 共有者のアバター
                Circle()
                    .fill(Color.blue.opacity(0.2))
                    .frame(width: 40, height: 40)
                    .overlay(
                        Text(String(sharedRecord.ownerName.prefix(1)))
                            .font(.headline)
                            .fontWeight(.semibold)
                            .foregroundColor(.blue)
                    )
                
                VStack(alignment: .leading, spacing: 4) {
                    // 共有者名
                    Text(sharedRecord.ownerName)
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    // 通話情報
                    Text("\(formatTimestamp(sharedRecord.callRecord.timestamp)) • \(formatDuration(sharedRecord.callRecord.duration))")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    // 要約プレビュー
                    Text(sharedRecord.callRecord.summaryPreview)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    // 権限レベル
                    PermissionBadge(permission: sharedRecord.permission)
                    
                    // 共有日時
                    Text(formatRelativeTime(sharedRecord.sharedAt))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(PlainButtonStyle())
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                onRemove()
            } label: {
                Label("削除", systemImage: "trash")
            }
        }
    }
    
    private func formatTimestamp(_ timestamp: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    private func formatRelativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// 送信共有行
struct SentSharingRow: View {
    let sharedRecord: SharedCallRecord
    let onTap: () -> Void
    let onRevoke: () -> Void
    
    @State private var showingRevokeConfirmation = false
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // 通話アイコン
                Image(systemName: "phone.arrow.up.right")
                    .font(.title3)
                    .foregroundColor(.blue)
                    .frame(width: 24)
                
                VStack(alignment: .leading, spacing: 4) {
                    // 通話情報
                    Text("共有先: \(sharedRecord.ownerName)")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Text("\(formatTimestamp(sharedRecord.callRecord.timestamp)) • \(formatDuration(sharedRecord.callRecord.duration))")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    // 要約プレビュー
                    Text(sharedRecord.callRecord.summaryPreview)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    // 権限レベル
                    PermissionBadge(permission: sharedRecord.permission)
                    
                    // 共有日時
                    Text(formatRelativeTime(sharedRecord.sharedAt))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(PlainButtonStyle())
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                showingRevokeConfirmation = true
            } label: {
                Label("取り消し", systemImage: "arrow.uturn.backward")
            }
        }
        .confirmationDialog("共有を取り消し", isPresented: $showingRevokeConfirmation) {
            Button("取り消し", role: .destructive) {
                onRevoke()
            }
            Button("キャンセル", role: .cancel) { }
        } message: {
            Text("この共有を取り消しますか？相手はこの通話記録にアクセスできなくなります。")
        }
    }
    
    private func formatTimestamp(_ timestamp: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    private func formatRelativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// 共有リクエスト行
struct SharingRequestRow: View {
    let request: SharingRequest
    let onTap: () -> Void
    let onAccept: () -> Void
    let onReject: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onTap) {
                HStack(spacing: 12) {
                    // 送信者のアバター
                    Circle()
                        .fill(Color.green.opacity(0.2))
                        .frame(width: 40, height: 40)
                        .overlay(
                            Text(String(request.senderName.prefix(1)))
                                .font(.headline)
                                .fontWeight(.semibold)
                                .foregroundColor(.green)
                        )
                    
                    VStack(alignment: .leading, spacing: 4) {
                        // 送信者名
                        Text(request.senderName)
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        // リクエスト情報
                        Text("通話記録の共有を求めています")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        // メッセージ
                        if let message = request.message, !message.isEmpty {
                            Text(message)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                    }
                    
                    Spacer()
                    
                    VStack(alignment: .trailing, spacing: 4) {
                        // 権限レベル
                        PermissionBadge(permission: request.permissionLevel)
                        
                        // リクエスト日時
                        Text(formatRelativeTime(request.createdAt))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        
                        // 期限
                        if let expiryDate = request.expiryDate {
                            Text("期限: \(formatExpiryDate(expiryDate))")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                    }
                }
            }
            .buttonStyle(PlainButtonStyle())
            
            // アクションボタン
            if request.status == .pending {
                HStack(spacing: 12) {
                    Button(action: onReject) {
                        Text("拒否")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(8)
                    }
                    
                    Button(action: onAccept) {
                        Text("承認")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.blue)
                            .cornerRadius(8)
                    }
                }
            } else {
                HStack {
                    Image(systemName: statusIcon)
                        .foregroundColor(statusColor)
                    
                    Text(statusText)
                        .font(.subheadline)
                        .foregroundColor(statusColor)
                    
                    Spacer()
                }
            }
        }
        .padding(.vertical, 8)
    }
    
    private var statusIcon: String {
        switch request.status {
        case .accepted:
            return "checkmark.circle.fill"
        case .rejected:
            return "xmark.circle.fill"
        case .expired:
            return "clock.badge.exclamationmark"
        case .pending:
            return "clock"
        }
    }
    
    private var statusColor: Color {
        switch request.status {
        case .accepted:
            return .green
        case .rejected:
            return .red
        case .expired:
            return .orange
        case .pending:
            return .blue
        }
    }
    
    private var statusText: String {
        switch request.status {
        case .accepted:
            return "承認済み"
        case .rejected:
            return "拒否済み"
        case .expired:
            return "期限切れ"
        case .pending:
            return "保留中"
        }
    }
    
    private func formatRelativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
    
    private func formatExpiryDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        return formatter.string(from: date)
    }
}

/// 権限バッジ
struct PermissionBadge: View {
    let permission: SharingPermission
    
    var body: some View {
        Text(permissionText)
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(permissionColor.opacity(0.2))
            .foregroundColor(permissionColor)
            .cornerRadius(4)
    }
    
    private var permissionText: String {
        switch permission {
        case .read:
            return "読み取り"
        case .readWrite:
            return "編集可能"
        case .admin:
            return "管理者"
        }
    }
    
    private var permissionColor: Color {
        switch permission {
        case .read:
            return .blue
        case .readWrite:
            return .orange
        case .admin:
            return .red
        }
    }
}

// MARK: - Sheet Views

/// ユーザー検索シート
struct UserSearchSheet: View {
    @ObservedObject var viewModel: SharingViewModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var searchText = ""
    @State private var selectedUsers: Set<UserProfile> = []
    
    var body: some View {
        NavigationView {
            VStack {
                // 検索バー
                SearchBar(text: $searchText, onSearchButtonClicked: {
                    Task {
                        await viewModel.searchUsers(searchText)
                    }
                })
                
                // 検索結果
                if viewModel.searchResults.isEmpty && !searchText.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "person.crop.circle.badge.questionmark")
                            .font(.system(size: 50))
                            .foregroundColor(.secondary)
                        
                        Text("ユーザーが見つかりません")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        
                        Text("別のキーワードで検索してください")
                            .font(.body)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(viewModel.searchResults) { user in
                            UserSearchRow(
                                user: user,
                                isSelected: selectedUsers.contains(user),
                                onToggle: {
                                    if selectedUsers.contains(user) {
                                        selectedUsers.remove(user)
                                    } else {
                                        selectedUsers.insert(user)
                                    }
                                }
                            )
                        }
                    }
                    .listStyle(PlainListStyle())
                }
                
                Spacer()
            }
            .navigationTitle("ユーザーを検索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("キャンセル") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("選択") {
                        // 選択されたユーザーを処理
                        dismiss()
                    }
                    .disabled(selectedUsers.isEmpty)
                }
            }
        }
    }
}

/// 検索バー
struct SearchBar: View {
    @Binding var text: String
    let onSearchButtonClicked: () -> Void
    
    var body: some View {
        HStack {
            TextField("名前、メールアドレス、電話番号で検索", text: $text)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .onSubmit {
                    onSearchButtonClicked()
                }
            
            Button(action: onSearchButtonClicked) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.blue)
            }
            .disabled(text.isEmpty)
        }
        .padding()
    }
}

/// ユーザー検索行
struct UserSearchRow: View {
    let user: UserProfile
    let isSelected: Bool
    let onToggle: () -> Void
    
    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                // ユーザーアバター
                AsyncImage(url: user.avatar.flatMap(URL.init)) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Circle()
                        .fill(Color.gray.opacity(0.2))
                        .overlay(
                            Text(String(user.displayName.prefix(1)))
                                .font(.headline)
                                .fontWeight(.semibold)
                                .foregroundColor(.gray)
                        )
                }
                .frame(width: 40, height: 40)
                .clipShape(Circle())
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(user.displayName)
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    if let email = user.email {
                        Text(email)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    
                    HStack(spacing: 8) {
                        if user.isOnline {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 8, height: 8)
                                
                                Text("オンライン")
                                    .font(.caption)
                                    .foregroundColor(.green)
                            }
                        } else {
                            Text("オフライン")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.blue)
                        .font(.title2)
                }
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

/// 共有リクエストシート
struct ShareRequestSheet: View {
    @ObservedObject var viewModel: SharingViewModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var selectedCallRecords: Set<CallRecord> = []
    @State private var selectedUsers: Set<UserProfile> = []
    
    var body: some View {
        NavigationView {
            VStack {
                // 共有対象の通話記録選択
                Text("共有する通話記録を選択")
                    .font(.headline)
                    .padding()
                
                // ここに通話記録選択UI
                
                Spacer()
            }
            .navigationTitle("共有リクエスト")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("キャンセル") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("送信") {
                        // 共有リクエスト送信
                        dismiss()
                    }
                    .disabled(selectedCallRecords.isEmpty || selectedUsers.isEmpty)
                }
            }
        }
    }
}

/// 共有リクエスト詳細ビュー
struct SharingRequestDetailView: View {
    let request: SharingRequest
    @ObservedObject var viewModel: SharingViewModel
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // リクエスト情報
                    VStack(alignment: .leading, spacing: 12) {
                        Text("共有リクエスト詳細")
                            .font(.title2)
                            .fontWeight(.bold)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            InfoRow(title: "送信者", value: request.senderName)
                            InfoRow(title: "権限レベル", value: request.permissionLevel.rawValue)
                            InfoRow(title: "作成日時", value: formatDate(request.createdAt))
                            
                            if let expiryDate = request.expiryDate {
                                InfoRow(title: "有効期限", value: formatDate(expiryDate))
                            }
                            
                            InfoRow(title: "状態", value: request.status.rawValue)
                        }
                        
                        if let message = request.message, !message.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("メッセージ")
                                    .font(.headline)
                                
                                Text(message)
                                    .font(.body)
                                    .padding()
                                    .background(Color(UIColor.secondarySystemBackground))
                                    .cornerRadius(8)
                            }
                        }
                    }
                    
                    Spacer()
                    
                    // アクションボタン
                    if request.status == .pending {
                        VStack(spacing: 12) {
                            Button(action: {
                                Task {
                                    await viewModel.acceptSharingRequest(request)
                                    dismiss()
                                }
                            }) {
                                Text("リクエストを承認")
                                    .font(.headline)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Color.blue)
                                    .cornerRadius(12)
                            }
                            
                            Button(action: {
                                Task {
                                    await viewModel.rejectSharingRequest(request)
                                    dismiss()
                                }
                            }) {
                                Text("リクエストを拒否")
                                    .font(.headline)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.red)
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Color.red.opacity(0.1))
                                    .cornerRadius(12)
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("共有リクエスト")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("閉じる") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

/// 情報行
struct InfoRow: View {
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

// MARK: - Sharing View Model

/// 共有ViewModel
@MainActor
class SharingViewModel: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published var receivedSharedRecords: [SharedCallRecord] = []
    @Published var sentSharedRecords: [SharedCallRecord] = []
    @Published var sharingRequests: [SharingRequest] = []
    @Published var searchResults: [UserProfile] = []
    
    @Published var isLoading = false
    @Published var showingError = false
    @Published var errorMessage = ""
    
    // MARK: - Private Properties
    
    private var serviceContainer: ServiceContainer?
    private let logger = Logger(subsystem: "com.telreq.app", category: "SharingViewModel")
    
    // MARK: - Public Methods
    
    /// サービスコンテナを設定
    func setServiceContainer(_ container: ServiceContainer) {
        self.serviceContainer = container
    }
    
    /// 初期データを読み込み
    func loadInitialData() async {
        isLoading = true
        
        do {
            try await loadReceivedSharedRecords()
            try await loadSentSharedRecords()
            try await loadSharingRequests()
            
            logger.info("Sharing data loaded successfully")
        } catch {
            logger.error("Failed to load sharing data: \(error.localizedDescription)")
            showError("共有データの読み込みに失敗しました")
        }
        
        isLoading = false
    }
    
    /// データを更新
    func refreshData() async {
        await loadInitialData()
    }
    
    /// ユーザーを検索
    func searchUsers(_ query: String) async {
        guard !query.isEmpty else {
            searchResults = []
            return
        }
        
        do {
            searchResults = try await serviceContainer?.sharingService.searchUsers(query: query) ?? []
            logger.info("Found \(self.searchResults.count) users for query: \(query)")
        } catch {
            logger.error("Failed to search users: \(error.localizedDescription)")
            showError("ユーザー検索に失敗しました")
        }
    }
    
    /// 共有リクエストを承認
    func acceptSharingRequest(_ request: SharingRequest) async {
        do {
            try await serviceContainer?.sharingService.acceptSharingRequest(request)
            
            // リストから削除し、受信済み共有に追加
            sharingRequests.removeAll { $0.id == request.id }
            try? await loadReceivedSharedRecords()
            
            logger.info("Accepted sharing request: \(request.id)")
        } catch {
            logger.error("Failed to accept sharing request: \(error.localizedDescription)")
            showError("共有リクエストの承認に失敗しました")
        }
    }
    
    /// 共有リクエストを拒否
    func rejectSharingRequest(_ request: SharingRequest) async {
        // 実際の実装では適切なサービスメソッドを呼び出し
        
        // リストから削除
        sharingRequests.removeAll { $0.id == request.id }
        
        logger.info("Rejected sharing request: \(request.id)")
    }
    
    /// 共有記録を削除
    func removeSharedRecord(_ sharedRecord: SharedCallRecord) async {
        // 実際の実装では適切なサービスメソッドを呼び出し
        
        receivedSharedRecords.removeAll { $0.id == sharedRecord.id }
        
        logger.info("Removed shared record: \(sharedRecord.id)")
    }
    
    /// 共有を取り消し
    func revokeSharing(_ sharedRecord: SharedCallRecord) async {
        do {
            try await serviceContainer?.sharingService.revokeSharing(
                callId: sharedRecord.originalCallId,
                userId: sharedRecord.ownerId
            )
            
            sentSharedRecords.removeAll { $0.id == sharedRecord.id }
            
            logger.info("Revoked sharing: \(sharedRecord.id)")
        } catch {
            logger.error("Failed to revoke sharing: \(error.localizedDescription)")
            showError("共有の取り消しに失敗しました")
        }
    }
    
    /// エラーを非表示
    func dismissError() {
        showingError = false
        errorMessage = ""
    }
    
    // MARK: - Private Methods
    
    /// 受信済み共有記録を読み込み
    private func loadReceivedSharedRecords() async throws {
        let records = try await serviceContainer?.sharingService.getSharedRecords() ?? []
        receivedSharedRecords = records
    }
    
    /// 送信済み共有記録を読み込み
    private func loadSentSharedRecords() async throws {
        guard let serviceContainer = serviceContainer else {
            throw AppError.invalidConfiguration
        }
        
        let records = try await serviceContainer.sharingService.getSentSharedRecords()
        sentSharedRecords = records
    }
    
    /// 共有リクエストを読み込み
    private func loadSharingRequests() async throws {
        guard let serviceContainer = serviceContainer else {
            throw AppError.invalidConfiguration
        }
        
        let requests = try await serviceContainer.sharingService.getSharingRequests()
        sharingRequests = requests
    }
    
    /// エラーを表示
    private func showError(_ message: String) {
        errorMessage = message
        showingError = true
    }
}

// MARK: - Preview

#Preview {
    SharingView()
        .environmentObject(ServiceContainer.shared)
}