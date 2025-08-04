//
//  TelreqApp.swift
//  Telreq
//
//  Created by Suguru Hirayama on 2025/08/03.
//

import SwiftUI
#if canImport(Speech) && !os(macOS)
import Speech
#endif
import AVFoundation

@available(iOS 15.0, *)
@main
struct TelreqApp: App {
    @StateObject private var serviceContainer = ServiceContainer.shared
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(serviceContainer)
                .task {
                    do {
                        try await serviceContainer.initializeServices()
                    } catch {
                        print("Failed to initialize services: \(error)")
                    }
                }
                .onAppear {
                    requestPermissions()
                }
        }
    }
    
    private func requestPermissions() {
        // マイクの権限をリクエスト (iOS のみ)
        #if canImport(AVFoundation) && !os(macOS)
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            DispatchQueue.main.async {
                if granted {
                    print("Microphone access granted")
                } else {
                    print("Microphone access denied")
                }
            }
        }
        #endif
        
        // 音声認識の権限をリクエスト (iOS のみ)
        #if canImport(Speech) && !os(macOS)
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                switch status {
                case .authorized:
                    print("Speech recognition authorized")
                case .denied:
                    print("Speech recognition denied")
                case .restricted:
                    print("Speech recognition restricted")
                case .notDetermined:
                    print("Speech recognition not determined")
                @unknown default:
                    print("Speech recognition unknown status")
                }
            }
        }
        #endif
    }
}
