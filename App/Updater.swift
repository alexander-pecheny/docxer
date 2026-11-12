import AppKit
import Security

/// Updates the app from its GitHub releases. It looks at launch, at most once a day, and only in a Developer ID build:
/// a local build is ad-hoc signed and never updates. A release it finds is remembered until the app is that version.
@MainActor final class Updater: NSObject {
    static let shared = Updater()
    static let changed = Notification.Name("DocxerUpdateChanged")

    private static let latest = URL(string: "https://api.github.com/repos/alexander-pecheny/docxer/releases/latest")!
    private static let checkEvery: TimeInterval = 24 * 60 * 60
    private let defaults = UserDefaults.standard
    private let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    private let team = Updater.teamIdentifier(of: Bundle.main.bundleURL)

    private struct Release: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        let tag_name: String
        let assets: [Asset]
        var version: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }
    }

    /// The newer version found, if any.
    private(set) var available: String? {
        get { enabled ? defaults.string(forKey: "UpdateAvailable").flatMap { Self.newer($0, than: current) ? $0 : nil } : nil }
        set { defaults.set(newValue, forKey: "UpdateAvailable"); NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
    private(set) var installing = false

    var enabled: Bool { team != nil }

    func checkAtLaunch() {
        guard enabled else { return }
        let last = defaults.object(forKey: "UpdateCheckedAt") as? Date ?? .distantPast
        if Date().timeIntervalSince(last) >= Self.checkEvery { Task { _ = try? await check() } }
    }

    @objc func checkFromMenu(_ sender: Any?) {
        guard enabled else { return alert("Updates are off in this build", "Only a release build from GitHub updates itself.") }
        if available != nil { return confirm() }
        Task {
            do {
                if try await check() == nil { alert("Docxer \(current) is the newest version", "") } else { confirm() }
            } catch {
                alert("Could not check for updates", error.localizedDescription)
            }
        }
    }

    private func confirm() {
        guard let version = available else { return }
        let a = NSAlert()
        a.messageText = "Update to Docxer \(version)?"
        a.informativeText = "Docxer will download the update and restart. You will be asked to save any unsaved documents."
        a.addButton(withTitle: "Update and Restart")
        a.addButton(withTitle: "Later")
        if a.runModal() == .alertFirstButtonReturn { install(nil) }
    }

    @discardableResult
    private func check() async throws -> Release? {
        let release = try await fetchLatest()
        defaults.set(Date(), forKey: "UpdateCheckedAt")
        let found = Self.newer(release.version, than: current) ? release : nil
        available = found?.version
        return found
    }

    private func fetchLatest() async throws -> Release {
        var req = URLRequest(url: Self.latest, timeoutInterval: 30)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Docxer", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("GitHub answered \((response as? HTTPURLResponse)?.statusCode ?? 0).") }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    /// Downloads the release, checks that our team signed it, puts it in place of this app and relaunches.
    @objc func install(_ sender: Any?) {
        guard !installing, let version = available else { return }
        installing = true
        NotificationCenter.default.post(name: Self.changed, object: nil)
        Task {
            do {
                let app = try await download(version)
                let target = Bundle.main.bundleURL
                _ = try FileManager.default.replaceItemAt(target, withItemAt: app)
                relaunch(target)
            } catch {
                installing = false
                NotificationCenter.default.post(name: Self.changed, object: nil)
                alert("Could not update to Docxer \(version)", error.localizedDescription)
            }
        }
    }

    private func download(_ version: String) async throws -> URL {
        let release = try await fetchLatest()
        guard release.version == version, let asset = release.assets.first(where: { $0.name == "Docxer-\(version).zip" }) else {
            throw UpdateError("The release has no Docxer-\(version).zip.")
        }
        let (zip, _) = try await URLSession.shared.download(from: asset.browser_download_url)
        // On the app's own volume, so that swapping the bundles is a rename.
        let dir = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: Bundle.main.bundleURL, create: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, dir.path]
        try unzip.run()
        unzip.waitUntilExit()
        let app = dir.appendingPathComponent("Docxer.app")
        guard unzip.terminationStatus == 0, FileManager.default.fileExists(atPath: app.path) else { throw UpdateError("The download did not unpack.") }
        guard let team, Self.teamIdentifier(of: app) == team else { throw UpdateError("The download is not signed by the Docxer developer.") }
        return app
    }

    /// Opens the app again once this process has quit. Quitting asks about unsaved documents as usual.
    private func relaunch(_ app: URL) {
        let wait = Process()
        wait.executableURL = URL(fileURLWithPath: "/bin/sh")
        wait.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.3; done; open \"$0\"", app.path]
        try? wait.run()
        NSApp.terminate(nil)
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    /// The team of a valid Developer ID signature, or nil for an ad-hoc or broken one.
    private static func teamIdentifier(of app: URL) -> String? {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString("anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13]" as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    var menuTitle: String {
        if installing { return "Updating…" }
        return available.map { "Update to Docxer \($0)…" } ?? "Check for Updates…"
    }

    static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0 ..< max(x.count, y.count) where (i < x.count ? x[i] : 0) != (i < y.count ? y[i] : 0) {
            return (i < x.count ? x[i] : 0) > (i < y.count ? y[i] : 0)
        }
        return false
    }
}

struct UpdateError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
