import AppKit
import Darwin
import os
import SwiftUI

// 无宿主测试编译同一份源码, 仅移除可执行入口以避免启动常驻服务
#if !CODEXBAR_TESTING
    @main
#endif
nonisolated enum CodexBarMain {
    static func main() {
        if WorkflowHookEventRecorder.handleIfRequested() {
            return
        }

        do {
            // Hook 不参与 GUI 实例互斥, 普通启动则先锁定再创建 AppDelegate 和服务
            guard let descriptor = try AppInstanceLock.acquire(in: AppInstanceLock.directoryURL()) else {
                return
            }
            defer { AppInstanceLock.release(descriptor) }

            MainActor.assumeIsolated {
                CodexBarApp.main()
            }
        } catch {
            AppLog.app.error("App 实例锁获取失败")
            exit(EXIT_FAILURE)
        }
    }
}

struct CodexBarApp: App {
    @NSApplicationDelegateAdaptor(CodexBarAppDelegate.self) private var appDelegate

    init() {
        // 缩短系统工具提示首次出现的延迟 (毫秒)
        UserDefaults.standard.set(500, forKey: "NSInitialToolTipDelay")
    }

    var body: some Scene {
        // 菜单栏 UI 由 AppDelegate 驱动; 系统设置命令转交给自定义设置窗口
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("app.command.settings") {
                    appDelegate.openSettingsFromCommand()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

nonisolated extension Bundle {
    var shortVersionString: String? {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// `v1.2.3` 形式的版本文案; 缺失时回退 `--`
    var displayVersionLabel: String {
        guard let version = shortVersionString else { return "--" }
        return "v\(version)"
    }
}
