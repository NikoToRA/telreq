import Foundation
import os.log
#if canImport(Darwin)
import Darwin
#endif
#if canImport(UIKit)
import UIKit
#endif

/// 非同期処理のデバッグとエラー追跡を支援するユーティリティ
final class AsyncDebugHelpers {
    static let shared = AsyncDebugHelpers()
    
    private let logger = Logger(subsystem: "com.telreq.app", category: "AsyncDebug")
    private var activeTasks: [String: Date] = [:]
    private let taskQueue = DispatchQueue(label: "async.debug.queue")
    
    private init() {}
    
    /// 非同期タスクを追跡し、デバッグ情報を記録
    func trackAsyncTask<T>(
        _ operation: @escaping () async throws -> T,
        name: String,
        timeout: TimeInterval = 30.0
    ) async throws -> T {
        
        let taskId = "\(name)_\(UUID().uuidString.prefix(8))"
        let startTime = Date()
        
        logger.info("🚀 Starting async task: \(taskId) on thread: \(Thread.current)")
        
        // タスクを記録
        _ = taskQueue.sync {
            self.activeTasks[taskId] = startTime
        }
        
        defer {
            let duration = Date().timeIntervalSince(startTime)
            logger.info("✅ Completed async task: \(taskId) in \(String(format: "%.2f", duration))s")
            
            _ = taskQueue.sync {
                self.activeTasks.removeValue(forKey: taskId)
            }
        }
        
        return try await withThrowingTaskGroup(of: T.self) { group in
            // メイン操作
            group.addTask {
                do {
                    let result = try await operation()
                    self.logger.info("🎯 Task \(taskId) completed successfully")
                    return result
                } catch {
                    self.logger.error("❌ Task \(taskId) failed with error: \(error.localizedDescription)")
                    throw error
                }
            }
            
            // タイムアウト監視
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.logger.warning("⏰ Task \(taskId) timed out after \(timeout)s")
                throw AsyncDebugError.timeout(taskId)
            }
            
            // 最初に完了した結果を返す
            guard let result = try await group.next() else {
                throw AsyncDebugError.noResult
            }
            
            group.cancelAll()
            return result
        }
    }
    
    /// メモリ使用量を取得
    func getMemoryUsage() -> Double {
        #if canImport(Darwin)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        
        guard kerr == KERN_SUCCESS else { return 0 }
        
        return Double(info.resident_size) / 1024 / 1024 // MB
        #else
        return 0
        #endif
    }
    
    /// アクティブなタスクの状況をログ出力
    func logActiveTasks() {
        taskQueue.sync {
            if self.activeTasks.isEmpty {
                logger.info("📊 No active async tasks")
            } else {
                logger.info("📊 Active async tasks: \(self.activeTasks.count)")
                for (taskId, startTime) in self.activeTasks {
                    let duration = Date().timeIntervalSince(startTime)
                    logger.info("  - \(taskId): running for \(String(format: "%.1f", duration))s")
                }
            }
            logger.info("📊 Memory usage: \(String(format: "%.1f", self.getMemoryUsage())) MB")
        }
    }
    
    /// クリティカルセクションでMainActorチェック
    func ensureMainActor(function: String = #function, file: String = #file, line: Int = #line) {
        if !Thread.isMainThread {
            logger.warning("⚠️ MainActor violation in \(function) (\(URL(fileURLWithPath: file).lastPathComponent):\(line))")
        }
    }
    
    /// 強制メモリクリーンアップ処理
    func forceMemoryCleanup() {
        logger.info("🧹 Starting memory cleanup")
        autoreleasepool {
            // 明示的なガベージコレクション促進
            #if canImport(Darwin)
            malloc_zone_pressure_relief(nil, 0)
            #endif
            
            // URLCacheクリア
            URLCache.shared.removeAllCachedResponses()
            
            // ImageCacheクリア（SwiftUIの内部キャッシュ）
            #if canImport(UIKit) && !os(macOS)
            if #available(iOS 15.0, *) {
                Task { @MainActor in
                    // SwiftUI内部キャッシュのクリア（間接的）
                    NotificationCenter.default.post(
                        name: UIApplication.didReceiveMemoryWarningNotification,
                        object: nil
                    )
                }
            }
            #endif
        }
        logger.info("🧹 Memory cleanup completed. New usage: \(String(format: "%.1f", self.getMemoryUsage())) MB")
    }
}

/// AsyncDebugHelpers用のエラー型
enum AsyncDebugError: LocalizedError {
    case timeout(String)
    case noResult
    case memoryPressure
    
    var errorDescription: String? {
        switch self {
        case .timeout(let taskId):
            return "Async task '\(taskId)' timed out"
        case .noResult:
            return "No result from async task group"
        case .memoryPressure:
            return "High memory pressure detected"
        }
    }
}