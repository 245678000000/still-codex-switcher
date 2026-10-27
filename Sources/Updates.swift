import Foundation
import AppKit

// Semantic precedence, including numeric prerelease identifiers; build metadata is ignored.
struct ReleaseVersion: Comparable {
    let core: [Int]
    let pre: [String]
    init?(_ text: String) {
        guard text.utf8.count <= 128 else { return nil }
        let build = text.split(separator: "+", omittingEmptySubsequences: false)
        guard build.count <= 2 else { return nil }
        func identifiers(_ value: String) -> [String]? {
            let parts = value.components(separatedBy: ".")
            guard parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 } }) else { return nil }
            return parts
        }
        if build.count == 2 && identifiers(String(build[1])) == nil { return nil }
        let halves = build[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = halves[0].components(separatedBy: ".")
        guard numbers.count == 3, numbers.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } && ($0 == "0" || !$0.hasPrefix("0")) }), numbers.allSatisfy({ Int($0) != nil }) else { return nil }
        core = numbers.map { Int($0)! }
        if halves.count == 2 {
            guard let parts = identifiers(String(halves[1])), parts.allSatisfy({ !$0.allSatisfy(\.isNumber) || $0 == "0" || !$0.hasPrefix("0") }) else { return nil }
            pre = parts
        } else { pre = [] }
    }
    static func == (a: Self, b: Self) -> Bool { a.core == b.core && a.pre == b.pre }
    static func < (a: Self, b: Self) -> Bool {
        if a.core != b.core { return a.core.lexicographicallyPrecedes(b.core) }
        if a.pre.isEmpty || b.pre.isEmpty { return !a.pre.isEmpty && b.pre.isEmpty }
        for (x, y) in zip(a.pre, b.pre) where x != y {
            let xn = x.utf8.allSatisfy { (48...57).contains($0) }, yn = y.utf8.allSatisfy { (48...57).contains($0) }
            if xn != yn { return xn }
            if xn && x.count != y.count { return x.count < y.count }
            return x < y
        }
        return a.pre.count < b.pre.count
    }
}

enum AppRelease {
    static let fallbackVersion = "1.5.0-preview.1"
    static var current: String { Bundle.main.object(forInfoDictionaryKey: "StillUpdateVersion") as? String ?? fallbackVersion }
    static var short: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.5.0" }
    static let repository = "245678000000/still-codex-switcher"
    static let assetName = "Codex-Account-Switcher-macOS.zip"
    static let releasesURL = URL(string: "https://github.com/\(repository)/releases")!
}

struct MacRelease: Equatable {
    let tag: String
    let version: ReleaseVersion
    let versionText: String
    let preview: Bool
    let notes: String
    let pageURL: URL
    static func parse(_ item: [String: Any]) -> MacRelease? {
        guard item["draft"] as? Bool == false, let prerelease = item["prerelease"] as? Bool,
              let published = item["published_at"] as? String, ISO8601DateFormatter().date(from: published) != nil,
              let tag = item["tag_name"] as? String else { return nil }
        let text: String
        if tag.hasPrefix("macos-v") { text = String(tag.dropFirst(7)) }
        else { return nil } // Historical mixed-platform tags can carry an older Mac binary.
        guard let version = ReleaseVersion(text),
              let assets = item["assets"] as? [[String: Any]],
              let asset = assets.first(where: { $0["name"] as? String == AppRelease.assetName }),
              asset["state"] as? String == "uploaded", let size = QuotaSnapshot.number(asset["size"]), size > 0,
              let page = URL(string: "https://github.com/\(AppRelease.repository)/releases/tag/\(tag)"),
              let download = URL(string: "https://github.com/\(AppRelease.repository)/releases/download/\(tag)/\(AppRelease.assetName)"),
              item["html_url"] as? String == page.absoluteString,
              asset["browser_download_url"] as? String == download.absoluteString else { return nil }
        let raw = item["body"] as? String ?? "发布者尚未填写版本说明。"
        let notes = String(String.UnicodeScalarView(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" }).prefix(6000))
        return MacRelease(tag: tag, version: version, versionText: text, preview: prerelease || !version.pre.isEmpty, notes: notes, pageURL: page)
    }
    static func newest(_ releases: [MacRelease], current: ReleaseVersion, previews: Bool) -> MacRelease? {
        releases.filter { $0.version > current && (previews || !$0.preview) }.max { $0.version < $1.version }
    }
}

private final class UpdateRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum UpdateFeed {
    static let maxBytes = 4_000_000
    static func decode(_ data: Data) throws -> [MacRelease] {
        guard data.count <= maxBytes, let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw SwitchError("更新列表格式异常，请稍后检查。") }
        return items.compactMap(MacRelease.parse)
    }
    static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw SwitchError("更新服务器响应异常。") }
        if http.statusCode == 403 || http.statusCode == 429 { throw SwitchError("GitHub 暂时限制检查频率，请稍后重试。") }
        guard http.statusCode == 200 else { throw SwitchError("更新服务器暂时未返回列表，请稍后重试。") }
        guard response.expectedContentLength <= Int64(maxBytes) else { throw SwitchError("更新列表过大，请打开发布页查看。") }
    }
    static func fetch() async throws -> [MacRelease] {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 45
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil; config.urlCache = nil
        let session = URLSession(configuration: config, delegate: UpdateRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var result: [MacRelease] = []
        // Read up to three fixed API pages, rather than trusting arbitrary Link URLs.
        for page in 1...3 {
            try Task.checkCancellation()
            let url = URL(string: "https://api.github.com/repos/\(AppRelease.repository)/releases?per_page=100&page=\(page)")!
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("StillCodexSwitcher-macOS", forHTTPHeaderField: "User-Agent")
            let (bytes, response) = try await session.bytes(for: request)
            try validate(response)
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation(); data.append(byte)
                guard data.count <= maxBytes else { throw SwitchError("更新列表过大，请打开发布页查看。") }
            }
            result += try decode(data)
            let count = (try JSONSerialization.jsonObject(with: data) as? [Any])?.count ?? 0
            if count < 100 { return result }
        }
        throw SwitchError("发布记录较多，请打开发布页查看最新版。")
    }
}

@MainActor final class UpdateController: ObservableObject {
    @Published private(set) var automaticallyChecks: Bool
    @Published private(set) var includesPreviews: Bool
    @Published private(set) var checking = false
    @Published private(set) var available: MacRelease?
    @Published private(set) var status = "尚未检查更新"
    @Published private(set) var lastChecked: Date?
    private let defaults: UserDefaults?
    private let demo: Bool
    private let current: ReleaseVersion?
    private let fetch: () async throws -> [MacRelease]
    private var task: Task<Void, Never>?
    private var lastAttempt: Date?
    private var automaticTask = false
    init(demo: Bool = false, defaults: UserDefaults? = nil, version: String = AppRelease.current, fetch: @escaping () async throws -> [MacRelease] = UpdateFeed.fetch) {
        self.demo = demo; self.defaults = demo ? nil : (defaults ?? .standard); self.current = ReleaseVersion(version); self.fetch = fetch
        automaticallyChecks = self.defaults?.object(forKey: "updates.automatic") as? Bool ?? true
        includesPreviews = self.defaults?.object(forKey: "updates.previews") as? Bool ?? !(current?.pre.isEmpty ?? true)
        // Each launch checks afresh; the twelve-hour throttle applies to this running app.
        // Persisting only a throttle (without a cached release) would hide known updates after restart.
        lastChecked = self.defaults?.object(forKey: "updates.lastChecked") as? Date
    }
    static func due(last: Date?, now: Date, automatic: Bool) -> Bool {
        guard let last else { return true }
        let elapsed = now.timeIntervalSince(last)
        return elapsed < 0 || elapsed >= (automatic ? 12 * 3600 : 60)
    }
    func setAutomatic(_ value: Bool) {
        automaticallyChecks = value; defaults?.set(value, forKey: "updates.automatic")
        if !value && automaticTask { cancel() }
        if value { check(automatic: true) }
    }
    func setPreviews(_ value: Bool) {
        includesPreviews = value; defaults?.set(value, forKey: "updates.previews")
        cancel(); available = nil; status = "更新渠道已更改，请检查更新。"
    }
    func check(automatic: Bool = false, now: Date = Date()) {
        guard !checking, !automatic || automaticallyChecks else { return }
        guard !demo else { status = "演示模式 · 未连接更新服务器"; return }
        guard let current else { status = "本机版本格式异常，请打开发布页检查。"; return }
        guard Self.due(last: lastAttempt, now: now, automatic: automatic) else {
            if !automatic { status = "刚刚检查过，请稍后再试。" }; return
        }
        checking = true; automaticTask = automatic; status = "正在检查更新…"; lastAttempt = now
        let previews = includesPreviews
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.checking = false; self.task = nil }
            do {
                let releases = try await self.fetch(); try Task.checkCancellation()
                self.available = MacRelease.newest(releases, current: current, previews: previews)
                self.lastChecked = Date(); self.defaults?.set(self.lastChecked, forKey: "updates.lastChecked")
                self.status = self.available.map { "发现新版本 " + $0.versionText } ?? "未发现所选渠道适用的新版本。"
            } catch {
                guard !Task.isCancelled else { return }
                self.status = (error as? SwitchError)?.message ?? "检查更新未完成，请检查网络后重试。"
            }
        }
    }
    func cancel() { task?.cancel(); if checking { status = "已停止检查更新。" } }
    func waitForCheck() async { await task?.value }
    func openRelease() {
        guard !demo else { status = "演示模式 · 正式版会打开 GitHub 发布页"; return }
        NSWorkspace.shared.open(available?.pageURL ?? AppRelease.releasesURL)
    }
    func seedPreview(_ release: MacRelease) { guard demo else { return }; available = release; status = "演示：发现新版本 " + release.versionText }
}
