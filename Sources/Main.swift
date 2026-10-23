import AppKit
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow?
    var model: SwitcherModel!
    var status: NSStatusItem?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if args.contains("--self-test") {
            Task { let success = await SelfTests.run(); exit(success ? 0 : 1) }; return
        }
        let demo = args.contains("--demo") || args.contains("--render")
        model = SwitcherModel(demo: demo)
        if args.contains("--dark") { model.library.appearance = "dark" }
        if args.contains("--empty") { model.library.accounts = []; model.current = nil }
        if args.contains("--settings") { model.page = "settings" }
        if args.contains("--render"), let index = args.firstIndex(of: "--render"), args.count > index + 1 {
            render(to: args[index + 1]); return
        }
        let host = NSHostingController(rootView: RootView(model: model))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.contentViewController = host; w.title = "栖言 · Codex 账号"; w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden; w.minSize = NSSize(width: 900, height: 670); w.isReleasedWhenClosed = false
        w.setFrameAutosaveName(demo ? "StillSwitcherDemo" : "StillSwitcherMain")
        w.delegate = self; w.center(); w.makeKeyAndOrderFront(nil); window = w
        installMenu(); installStatus(); NSApp.activate(ignoringOtherApps: true)
    }
    private func render(to path: String) {
        NSApp.appearance = NSAppearance(named: model.library.appearance == "dark" ? .darkAqua : .aqua)
        let view = NSHostingView(rootView: RootView(model: model))
        let frame = NSRect(x: 0, y: 0, width: 1060, height: 760)
        let w = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = view; view.frame = frame; w.displayIfNeeded(); view.layoutSubtreeIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(2) }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { exit(3) }
            do { try png.write(to: URL(fileURLWithPath: path)); print("Rendered interface fixture"); exit(0) } catch { exit(4) }
        }
    }
    private func installMenu() {
        let menu = NSMenu(); let app = NSMenuItem(); menu.addItem(app)
        let submenu = NSMenu(); app.submenu = submenu
        submenu.addItem(withTitle: "关于栖言", action: #selector(about), keyEquivalent: "")
        submenu.addItem(.separator())
        submenu.addItem(withTitle: "隐藏栖言", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        submenu.addItem(withTitle: "退出栖言", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let account = NSMenuItem(); account.title = "账号"; menu.addItem(account); let sub = NSMenu(); account.submenu = sub
        sub.addItem(withTitle: "保存当前账号", action: #selector(saveCurrent), keyEquivalent: "s").target = self
        sub.addItem(withTitle: "添加账号", action: #selector(add), keyEquivalent: "n").target = self
        // Native Edit menu keeps standard text editing and paste behavior in account labels.
        let edit = NSMenuItem(); edit.title = "编辑"; menu.addItem(edit); let edits = NSMenu(title: "编辑"); edit.submenu = edits
        for (title, action, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            edits.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        NSApp.mainMenu = menu
    }
    private func installStatus() {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status?.button?.image = NSImage(systemSymbolName: "person.2.badge.key", accessibilityDescription: "栖言账号切换器") ?? NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: "栖言")
        status?.button?.target = self; status?.button?.action = #selector(statusMenu)
    }
    @objc private func statusMenu() {
        let menu = NSMenu()
        let title = NSMenuItem(title: model.demo ? "栖言 · 演示模式" : "栖言 · Codex 账号", action: nil, keyEquivalent: ""); title.isEnabled = false; menu.addItem(title)
        menu.addItem(.separator())
        for account in model.library.accounts {
            let item = NSMenuItem(title: account.label, action: #selector(switchFromMenu(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = account.id.uuidString
            item.state = account.identityKey == model.current?.key ? .on : .off
            item.isEnabled = !model.busy && account.identityKey != model.current?.key
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "显示账号空间", action: #selector(showWindow), keyEquivalent: "").target = self
        menu.addItem(withTitle: "退出栖言", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        status?.menu = menu; status?.button?.performClick(nil); status?.menu = nil
    }
    @objc private func switchFromMenu(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String, let account = model.library.accounts.first(where: { $0.id.uuidString == id }) else { return }
        showWindow(); model.confirmSwitch(account)
    }
    @objc private func showWindow() { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc private func saveCurrent() { guard !model.busy else { return }; model.saveCurrent() }
    @objc private func add() { guard !model.busy else { return }; model.addAccount() }
    @objc private func about() {
        let alert = NSAlert(); alert.messageText = "栖言 · Codex 账号 1.0"
        alert.informativeText = "独立的本机账号切换工具。\nApple Silicon · macOS 14+\n与 OpenAI 无官方关联。"
        alert.runModal()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model?.busy == true && model?.loginWaiting == false { NSSound.beep(); showWindow(); return .terminateCancel }
        model?.broker.cancel()
        if model?.broker.cleaning == true {
            Task {
                for _ in 0..<100 {
                    if self.model?.broker.cleaning != true { NSApp.reply(toApplicationShouldTerminate: true); return }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                self.model?.message = "登录组件仍在清理临时资料，请稍后再退出。"
                NSApp.reply(toApplicationShouldTerminate: false)
            }
            return .terminateLater
        }
        return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
}
@main struct Main {
    @MainActor static func main() {
        let app = NSApplication.shared; let delegate = AppDelegate()
        app.setActivationPolicy(CommandLine.arguments.contains("--self-test") || CommandLine.arguments.contains("--render") ? .prohibited : .regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
