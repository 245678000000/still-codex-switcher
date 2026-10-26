import Foundation

@MainActor enum UpdateTests {
    static func fixture(_ tag: String = "macos-v1.2.0-preview.1", preview: Bool = true) -> [String: Any] {
        ["tag_name": tag, "draft": false, "prerelease": preview, "published_at": "2026-10-26T05:20:30Z",
         "html_url": "https://github.com/\(AppRelease.repository)/releases/tag/\(tag)",
         "body": "新版体验\n• 自动检查 Mac 更新\n• 保留账号库与钥匙串\n• 由你确认下载和替换，不打断正在进行的工作。",
         "assets": [["name": AppRelease.assetName, "state": "uploaded", "size": 1_500_000,
                     "browser_download_url": "https://github.com/\(AppRelease.repository)/releases/download/\(tag)/\(AppRelease.assetName)"]]]
    }
    static func run(_ check: (Bool, String) -> Void) async throws {
        for bad in ["", "1", "1.2", "01.2.3", "1.2.03", "-1.2.3", "1.2.3-", "1.2.3+", "1.2.3-01", "1.2.3-alpha..1", "1.2.3/evil", "999999999999999999999999.0.0", "1.2.3+foo+bar", "1.2.3-你好"] {
            check(ReleaseVersion(bad) == nil, "update invalid version rejected")
        }
        let ordered = ["1.1.9", "1.2.0-alpha", "1.2.0-alpha.1", "1.2.0-alpha.beta", "1.2.0-beta", "1.2.0-beta.2", "1.2.0-beta.11", "1.2.0-rc.1", "1.2.0", "1.10.0", "2.0.0"]
        for (a,b) in zip(ordered, ordered.dropFirst()) { check(ReleaseVersion(a)! < ReleaseVersion(b)!, "update semantic order \(a) before \(b)") }
        check(ReleaseVersion("1.2.0+build.1") == ReleaseVersion("1.2.0+other"), "update build metadata ignores precedence")
        check(ReleaseVersion("1.2.0-preview.999999999999999999999")! < ReleaseVersion("1.2.0-preview.1000000000000000000000")!, "update large numeric prerelease ordering")
        let original = fixture(); let mac = MacRelease.parse(original)!
        check(mac.versionText == "1.2.0-preview.1" && mac.preview, "update Mac preview accepted")
        check(MacRelease.parse(fixture("windows-v9.0.0", preview: false)) == nil, "update Windows tag excluded")
        check(MacRelease.parse(fixture("v1.3.0", preview: false)) == nil, "update mixed-platform tag excluded even with Mac asset")
        for (key, value) in [("draft", true as Any), ("published_at", "invalid" as Any), ("html_url", "https://evil.example/release" as Any), ("assets", [] as Any), ("prerelease", "false" as Any), ("html_url", "https://github.com/other/repo/releases/tag/macos-v1.2.0-preview.1" as Any)] {
            var obj = original; obj[key] = value; check(MacRelease.parse(obj) == nil, "update invalid release rejected")
        }
        let expected = (original["assets"] as! [[String: Any]])[0]
        for (key,value) in [("name", "Codex-Account-Switcher-Windows-x64.zip" as Any), ("state", "new" as Any), ("size", 0 as Any), ("size", true as Any), ("browser_download_url", "https://github.com.evil.example/file.zip" as Any), ("browser_download_url", "http://github.com/\(AppRelease.repository)/releases/download/\(mac.tag)/\(AppRelease.assetName)" as Any)] {
            var asset = expected; asset[key] = value; var obj = original; obj["assets"] = [asset]
            check(MacRelease.parse(obj) == nil, "update invalid asset rejected")
        }
        var notes = original; notes["body"] = "\u{0000}" + String(repeating: "a", count: 7000)
        check(MacRelease.parse(notes)?.notes.count == 6000 && MacRelease.parse(notes)?.notes.contains("\u{0000}") == false, "update notes bounded and control chars removed")
        let stable = MacRelease.parse(fixture("macos-v1.2.0", preview: false))!
        let future = MacRelease.parse(fixture("macos-v1.10.0-preview.2"))!
        let list = [future, stable, mac]
        check(MacRelease.newest(list, current: ReleaseVersion("1.1.0")!, previews: false) == stable, "update stable channel filters previews")
        check(MacRelease.newest(list, current: ReleaseVersion("1.1.0")!, previews: true) == future, "update newest semantic version not list order")
        check(MacRelease.newest([mac], current: mac.version, previews: true) == nil, "update same version not offered")
        check(MacRelease.newest(list, current: ReleaseVersion("2.0.0")!, previews: true) == nil, "update downgrade not offered")
        check(MacRelease.newest([stable], current: mac.version, previews: false) == stable, "update preview to same core stable offered")
        let decoded = try UpdateFeed.decode(JSONSerialization.data(withJSONObject: [original, fixture("windows-v5.0.0")]))
        check(decoded == [mac], "update feed filters platform")
        do { _ = try UpdateFeed.decode(Data("{}".utf8)); check(false, "update non-array feed rejected") } catch { check(true, "update non-array feed rejected") }
        do { _ = try UpdateFeed.decode(Data(repeating: 32, count: UpdateFeed.maxBytes + 1)); check(false, "update oversized feed rejected") } catch { check(true, "update oversized feed rejected") }
        for code in [301, 403, 404, 429, 500] {
            let r = HTTPURLResponse(url: AppRelease.releasesURL, statusCode: code, httpVersion: nil, headerFields: nil)!
            do { try UpdateFeed.validate(r); check(false, "update HTTP \(code) is not success") } catch { check(true, "update HTTP \(code) is not success") }
        }
        let now = Date()
        check(UpdateController.due(last: nil, now: now, automatic: true), "update first run due")
        check(!UpdateController.due(last: now, now: now.addingTimeInterval(43199), automatic: true) && UpdateController.due(last: now, now: now.addingTimeInterval(43200), automatic: true), "update automatic twelve hour cadence")
        check(!UpdateController.due(last: now, now: now.addingTimeInterval(59), automatic: false) && UpdateController.due(last: now, now: now.addingTimeInterval(60), automatic: false), "update manual sixty second cooldown")
        check(UpdateController.due(last: now, now: now.addingTimeInterval(-1), automatic: true), "update clock rollback can recover")
        let suite = "app.local.still.tests.updates." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        var calls = 0
        let controller = UpdateController(defaults: defaults, version: "1.1.0-preview.1", fetch: { calls += 1; return list })
        check(controller.automaticallyChecks && controller.includesPreviews, "update preview build defaults")
        controller.check(now: now); controller.check(now: now); await controller.waitForCheck()
        check(calls == 1 && controller.available == future && !controller.checking, "update single-flight asynchronous selection")
        check(controller.lastChecked != nil, "update successful timestamp")
        controller.check(now: now.addingTimeInterval(10)); await controller.waitForCheck()
        check(calls == 1, "update repeat manual throttled")
        controller.setAutomatic(false); controller.check(automatic: true, now: now.addingTimeInterval(50000)); await controller.waitForCheck()
        check(calls == 1, "update disabled automatic makes no request")
        controller.setPreviews(false)
        controller.check(now: now.addingTimeInterval(61)); await controller.waitForCheck()
        check(controller.available == stable && calls == 2, "update manual works with automatic disabled")
        var reopenedCalls = 0
        let reopened = UpdateController(defaults: defaults, version: "1.1.0-preview.1", fetch: { reopenedCalls += 1; return [] })
        check(!reopened.automaticallyChecks && !reopened.includesPreviews && reopened.lastChecked != nil, "update preferences and last success persist")
        reopened.check(now: now); await reopened.waitForCheck()
        check(reopenedCalls == 1, "update new launch checks without stale throttle")
        let failing = UpdateController(defaults: defaults, fetch: { throw SwitchError("fixture offline") })
        failing.check(); await failing.waitForCheck()
        check(!failing.checking && failing.available == nil && failing.status.contains("offline"), "update network failure not called latest")
        let delayed = UpdateController(defaults: defaults, fetch: { try await Task.sleep(for: .seconds(3)); return list })
        delayed.check(); delayed.cancel(); await delayed.waitForCheck()
        check(!delayed.checking && delayed.available == nil, "update cancelled check never publishes")
        let demo = UpdateController(demo: true, fetch: { calls += 100; return [] })
        demo.check(); await demo.waitForCheck(); check(calls == 2, "update demo makes no requests")
    }
}
