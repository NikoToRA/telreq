//
//  ContentView.swift
//  Telreq
//
//  Created by Suguru Hirayama on 2025/08/03.
//

import SwiftUI

@available(iOS 15.0, *)
struct ContentView: View {
    @StateObject private var contentViewModel = ContentViewModel()
    @StateObject private var serviceContainer = ServiceContainer.shared
    @State private var selectedTab = 0
    @State private var showingCallInterface = false
    @State private var showingOneButtonStart = false
    @State private var isCallActive = false
    @State private var callTranscription = ""
    
    var body: some View {
        TabView(selection: $selectedTab) {
            // ホーム画面
            NavigationView {
                VStack(spacing: 20) {
                    Image(systemName: "phone.circle.fill")
                        .font(.system(size: 80))
                        .foregroundColor(.blue)
                    
                    Text("Telreq")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    
                    Text("iPhone電話自動文字起こし・要約アプリ")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                    
                    // ワンボタン起動ボタン
                    Button(action: {
                        showingOneButtonStart = true
                    }) {
                        HStack {
                            Image(systemName: "record.circle.fill")
                                .font(.title2)
                            Text("ワンボタンで通話記録開始")
                                .fontWeight(.semibold)
                        }
                        .foregroundColor(.white)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.red)
                        .cornerRadius(12)
                    }
                    .buttonStyle(PlainButtonStyle())
                    
                    Button("通話開始") {
                        showingCallInterface = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    
                    Spacer()
                }
                .padding()
                .navigationTitle("ホーム")
                #if !os(macOS)
                .navigationBarTitleDisplayMode(.large)
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
            
            // リアルタイム転写
            RealTimeTranscriptionView()
                .tabItem {
                    Image(systemName: "waveform")
                    Text("転写")
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
        .sheet(isPresented: $showingOneButtonStart) {
            OneButtonCallView(
                isActive: $isCallActive,
                transcription: $callTranscription
            )
        }
        .environmentObject(serviceContainer)
        .task {
            do {
                try await serviceContainer.initializeServices()
                // CallManagerの監視を開始
                serviceContainer.callManager.delegate = contentViewModel
                serviceContainer.callManager.startMonitoring()
            } catch {
                print("Failed to initialize services: \(error)")
            }
        }
    }
}

// ワンボタン通話画面
@available(iOS 15.0, *)
struct OneButtonCallView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var isActive: Bool
    @Binding var transcription: String
    @StateObject private var serviceContainer = ServiceContainer.shared
    @State private var isProcessing = false
    @State private var processingMessage = ""
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                if isActive {
                    // 通話中
                    VStack(spacing: 16) {
                        Image(systemName: "phone.circle.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.green)
                        
                        Text("通話記録中...")
                            .font(.title2)
                            .fontWeight(.semibold)
                        
                        Text(transcription.isEmpty ? "音声を認識中..." : transcription)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(10)
                            .multilineTextAlignment(.leading)
                        
                        Button("通話終了") {
                            endCall()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .foregroundColor(.red)
                    }
                } else if isProcessing {
                    // 処理中
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                        
                        Text("テキスト処理中...")
                            .font(.title2)
                            .fontWeight(.semibold)
                        
                        Text(processingMessage)
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                } else {
                    // 開始前
                    VStack(spacing: 16) {
                        Image(systemName: "record.circle")
                            .font(.system(size: 60))
                            .foregroundColor(.red)
                        
                        Text("ワンボタン通話記録")
                            .font(.title2)
                            .fontWeight(.semibold)
                        
                        Text("ボタンを押すと通話記録が開始されます")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        
                        Button("記録開始") {
                            startCall()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .foregroundColor(.red)
                    }
                }
            }
            .padding()
            .navigationTitle("ワンボタン通話記録")
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
                    Button("閉じる") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private func startCall() {
        isActive = true
        transcription = ""
        
        // 実際の通話記録サービスを開始
        Task {
            do {
                try await serviceContainer.callManager.startCallRecording()
            } catch {
                print("Failed to start call recording: \(error)")
            }
        }
    }
    
    private func endCall() {
        isActive = false
        isProcessing = true
        processingMessage = "通話記録を終了しています..."
        
        // 実際の通話記録サービスを停止
        Task {
            do {
                let result = try await serviceContainer.callManager.stopCallRecording()
                await MainActor.run {
                    self.transcription = result.text
                    self.isProcessing = false
                    self.processingMessage = "処理完了"
                }
            } catch {
                await MainActor.run {
                    self.isProcessing = false
                    self.processingMessage = "エラーが発生しました: \(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - ContentViewModel

@available(iOS 15.0, *)
class ContentViewModel: ObservableObject, CallManagerDelegate {
    @Published var currentTranscription: String?
    
    func callManager(_ manager: CallManager, didStartCall callId: String) {
        print("Call started: \(callId)")
    }
    
    func callManager(_ manager: CallManager, didEndCall callId: String) {
        print("Call ended: \(callId)")
    }
    
    func callManager(_ manager: CallManager, didUpdateAudioLevel level: Float) {
        // 音声レベル更新
    }
    
    func callManager(_ manager: CallManager, didRecognizeText text: String, isFinal: Bool) {
        DispatchQueue.main.async {
            if isFinal {
                self.currentTranscription = text
            } else {
                self.currentTranscription = text
            }
        }
    }
    
    func callManager(_ manager: CallManager, didCompleteRecognition result: SpeechRecognitionResult) {
        DispatchQueue.main.async {
            self.currentTranscription = result.text
        }
    }
    
    func callManager(_ manager: CallManager, didEncounterError error: Error) {
        print("Call manager error: \(error.localizedDescription)")
    }
    
    func callManager(_ manager: CallManager, didCompleteTextProcessing data: StructuredCallData) {
        print("Text processing completed: \(data.summary.summary)")
    }
}

#Preview {
    ContentView()
}