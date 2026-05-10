//
//  Utils.swift
//  NapCatInstaller
//
//  Created by hguandl on 2024/10/2.
//

import AppKit
import Foundation
import ZIPFoundation

let appURL = URL(fileURLWithPath: "/Applications/QQ.app/Contents/Resources/app")
let containerURL = URL(fileURLWithPath: "/Users/\(NSUserName())/Library/Containers/com.tencent.qq/Data")
let docURL = containerURL.appendingPathComponent("Documents", isDirectory: true)
let datURL = containerURL.appendingPathComponent("Library/Application Support/QQ/NapCat", isDirectory: true)
private let versionsConfigURL = containerURL.appendingPathComponent("Library/Application Support/QQ/versions/config.json")

private func getJSONObject(url: URL) throws -> [NSString: Any]? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let data = try Data(contentsOf: url)
    let obj = try JSONSerialization.jsonObject(with: data)
    return obj as? [NSString: Any]
}

enum QQVersion: Equatable {
    case loading
    case missing
    case installed(String)
    case failed(String)
}

private func getActiveAppURL() -> URL {
    guard let config = try? getJSONObject(url: versionsConfigURL),
        let currentVersion = config["curVersion"] as? String,
        !currentVersion.isEmpty
    else {
        return appURL
    }

    let hotUpdateAppURL =
        versionsConfigURL
        .deletingLastPathComponent()
        .appendingPathComponent(currentVersion, isDirectory: true)
        .appendingPathComponent("QQUpdate.app/Contents/Resources/app", isDirectory: true)
    let hotUpdatePackageURL = hotUpdateAppURL.appendingPathComponent("package.json")
    if FileManager.default.fileExists(atPath: hotUpdatePackageURL.path) {
        return hotUpdateAppURL
    }
    return appURL
}

private func getPatchTargetAppURLs() -> [URL] {
    let activeAppURL = getActiveAppURL()
    if activeAppURL == appURL {
        return [appURL]
    }
    return [appURL, activeAppURL]
}

private func getPackageURL() -> URL {
    getActiveAppURL().appendingPathComponent("package.json")
}

func getQQVersion() throws -> String? {
    guard let package = try getJSONObject(url: getPackageURL()) else { return nil }
    return package["version"] as? String
}

enum NapcatVersion: Equatable {
    case loading
    case missing
    case outdated(String, String)
    case latest(String)
    case failed(String)

    var installed: Bool {
        switch self {
        case .outdated, .latest:
            return true
        default:
            return false
        }
    }
}

private let napcatURL = docURL.appendingPathComponent("napcat")
private let napcatPackageURL = napcatURL.appendingPathComponent("package.json")
private let napcatMetadataURL = napcatURL.appendingPathComponent(".napcat-installer.json")

enum LocalNapcatVersion {
    case known(String)
    case unknown
}

private struct NapcatInstallationMetadata: Codable {
    let tagName: String
    let version: String
    let installedAt: Date
}

private struct NapcatRelease: Decodable {
    let tagName: String
    let assets: [NapcatReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }

    var version: String {
        normalizeVersion(tagName)
    }

    var shellAssetURL: URL? {
        assets.first { $0.name == "NapCat.Shell.zip" }
            .flatMap { URL(string: $0.browserDownloadURL) }
    }
}

private struct NapcatReleaseAsset: Decodable {
    let name: String
    let browserDownloadURL: String

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

private func normalizeVersion(_ version: String) -> String {
    let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.lowercased().hasPrefix("v") {
        return String(trimmed.dropFirst())
    }
    return trimmed
}

private func readNapcatMetadata() throws -> NapcatInstallationMetadata? {
    guard FileManager.default.fileExists(atPath: napcatMetadataURL.path) else { return nil }
    let data = try Data(contentsOf: napcatMetadataURL)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(NapcatInstallationMetadata.self, from: data)
}

private func writeNapcatMetadata(_ metadata: NapcatInstallationMetadata, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(metadata)
    try data.write(to: url.appendingPathComponent(".napcat-installer.json"), options: .atomic)
}

private func codesignNapcatNativeAddons(at url: URL) throws {
    guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else {
        return
    }

    for case let fileURL as URL in enumerator where fileURL.pathExtension == "node" {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", fileURL.path]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

private func getMajorURL(for appURL: URL) -> URL {
    appURL.appendingPathComponent("major.node")
}

private func parseAppId(from majorURL: URL) throws -> String? {
    let marker = Data("QQAppId/".utf8)
    let data = try Data(contentsOf: majorURL)
    var searchRange = data.startIndex..<data.endIndex

    while let markerRange = data.range(of: marker, options: [], in: searchRange) {
        let start = markerRange.upperBound
        guard let end = data[start...].firstIndex(of: 0) else { return nil }
        let valueData = data[start..<end]
        if let value = String(data: valueData, encoding: .utf8),
            !value.isEmpty,
            value.allSatisfy(\.isNumber)
        {
            return value
        }
        searchRange = end..<data.endIndex
    }

    return nil
}

private func qqQUA(for version: String) -> String? {
    let parts = version.split(separator: "-", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { return nil }
    return "V1_MAC_NQ_\(parts[0])_\(parts[1])_GW_B"
}

private func patchNapcatCompatibilityTable() throws {
    let activeAppURL = getActiveAppURL()
    guard let version = try getQQVersion(),
        let qua = qqQUA(for: version),
        let appid = try parseAppId(from: getMajorURL(for: activeAppURL))
    else {
        return
    }

    let napcatEntryURL = napcatURL.appendingPathComponent("napcat.mjs")
    guard FileManager.default.fileExists(atPath: napcatEntryURL.path) else { return }

    var source = try String(contentsOf: napcatEntryURL, encoding: .utf8)
    let entryPrefix = #"  "\#(version)": {"#
    if source.contains(entryPrefix) {
        return
    }

    let marker = "\n};\n\nclass QQBasicInfoWrapper"
    guard let range = source.range(of: marker) else { return }
    let entry = #"  "\#(version)": {"appid":\#(appid),"qua":"\#(qua)"},"# + "\n"
    source.replaceSubrange(range, with: "\n\(entry)};\n\nclass QQBasicInfoWrapper")
    try source.write(to: napcatEntryURL, atomically: true, encoding: .utf8)
}

func getLocalNapcat() throws -> LocalNapcatVersion? {
    if let metadata = try readNapcatMetadata() {
        return .known(normalizeVersion(metadata.version))
    }
    guard let dict = try getJSONObject(url: napcatPackageURL) else { return nil }
    guard let version = dict["version"] as? String else { return .unknown }
    let normalized = normalizeVersion(version)
    return normalized == "0.0.1" ? .unknown : .known(normalized)
}

private func getRemoteNapcatRelease() async throws -> NapcatRelease {
    let urls = [
        URL(string: "https://api.github.com/repos/NapNeko/NapCatQQ/releases/latest")!,
        URL(string: "https://nclatest.znin.net/")!,
    ]
    var lastError: Error?
    for url in urls {
        do {
            var request = URLRequest(url: url, timeoutInterval: 10)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
                !(200..<300).contains(httpResponse.statusCode)
            {
                throw URLError(.badServerResponse)
            }
            return try JSONDecoder().decode(NapcatRelease.self, from: data)
        } catch {
            lastError = error
        }
    }
    throw lastError!
}

func getRemoteNapcat() async throws -> String? {
    try await getRemoteNapcatRelease().version
}

func removeNapcat() throws {
    try? FileManager.default.removeItem(at: loaderURL)
    try? FileManager.default.removeItem(at: launcherURL)
    try FileManager.default.removeItem(at: napcatURL)
}

enum GitHubProxy: String, CaseIterable {
    case direct
    case moeyy
    case ghproxy
    case ghProxy
    case haod

    var name: String {
        switch self {
        case .direct:
            NSLocalizedString("不使用", comment: "")
        case .moeyy:
            NSLocalizedString("moeyy", comment: "")
        case .ghproxy:
            NSLocalizedString("ghproxy", comment: "")
        case .ghProxy:
            NSLocalizedString("gh-proxy", comment: "")
        case .haod:
            NSLocalizedString("haod", comment: "")
        }
    }

    func url(for resource: String) -> URL {
        switch self {
        case .direct:
            URL(string: resource)!
        case .moeyy:
            URL(string: "https://github.moeyy.xyz/\(resource)")!
        case .ghproxy:
            URL(string: "https://mirror.ghproxy.com/\(resource)")!
        case .ghProxy:
            URL(string: "https://gh-proxy.com/\(resource)")!
        case .haod:
            URL(string: "https://x.haod.me/\(resource)")!
        }
    }

    static func auto() async throws -> GitHubProxy {
        try await withThrowingTaskGroup(of: GitHubProxy.self) { group in
            let check = "https://raw.githubusercontent.com/NapNeko/NapCatQQ/main/package.json"
            for proxy in GitHubProxy.allCases {
                group.addTask {
                    let _ = try await URLSession.shared.data(from: proxy.url(for: check))
                    return proxy
                }
            }
            var failure: Error?
            while let result = await group.nextResult() {
                switch result {
                case .success(let proxy):
                    group.cancelAll()
                    return proxy
                case .failure(let error):
                    failure = error
                }
            }
            throw failure!
        }
    }
}

func installNapcat(proxy: GitHubProxy? = nil) async throws {
    let fileManager = FileManager.default
    let release = try await getRemoteNapcatRelease()
    let asset =
        release.shellAssetURL?.absoluteString
        ?? "https://github.com/NapNeko/NapCatQQ/releases/latest/download/NapCat.Shell.zip"
    let url: URL
    if let proxy {
        url = proxy.url(for: asset)
    } else {
        url = try await GitHubProxy.auto().url(for: asset)
    }
    let (zip, _) = try await URLSession.shared.download(from: url)
    let stagingURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: stagingURL) }
    try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
    try fileManager.unzipItem(at: zip, to: stagingURL)
    try writeNapcatMetadata(
        NapcatInstallationMetadata(tagName: release.tagName, version: release.version, installedAt: Date()),
        to: stagingURL
    )
    try codesignNapcatNativeAddons(at: stagingURL)

    try fileManager.createDirectory(at: docURL, withIntermediateDirectories: true)
    if fileManager.fileExists(atPath: napcatURL.path) {
        try fileManager.removeItem(at: napcatURL)
    }
    try fileManager.moveItem(at: stagingURL, to: napcatURL)
    try patchNapcatCompatibilityTable()
}

enum PatchStatus: Equatable {
    case loading
    case original
    case napcat
    case custom(String)
    case failed(String)

    var patched: Bool {
        return self == .napcat
    }

    static let originalLoaders = [
        "./application.asar/app_launcher/index.js",
        "./application/app_launcher/index.js",
        "./app_launcher/index.js",
    ]
}

private let loaderURL = docURL.appendingPathComponent("loadNapCat.js")
private let launcherURL = docURL.appendingPathComponent("startNapCat.command")
let napcatLoader = loaderURL.path
private let legacyNapcatLoader = "../../../../..\(docURL.path)/loadNapCat.js"
private let patchedMain = "./app_launcher/index.js"
private let patchedEntry = "require('\(loaderURL.path)');\n"
let napcatLoaders = [napcatLoader, legacyNapcatLoader]

private func appLauncherIndexURL(for appURL: URL) -> URL {
    appURL.appendingPathComponent("app_launcher/index.js")
}

private func backupURL(for url: URL) -> URL {
    URL(fileURLWithPath: url.path + ".napcat.bak")
}

func getAppLoader() throws -> String? {
    let packageURL = getPackageURL()
    guard FileManager.default.fileExists(atPath: packageURL.path) else { return nil }
    let data = try Data(contentsOf: packageURL)
    let obj = try JSONSerialization.jsonObject(with: data)
    guard let dict = obj as? [NSString: Any] else { return nil }
    return dict["main"] as? String
}

private func isPatched(appURL: URL) throws -> Bool {
    let packageURL = appURL.appendingPathComponent("package.json")
    guard let package = try getJSONObject(url: packageURL),
        let main = package["main"] as? String,
        main == patchedMain
    else {
        return false
    }

    let entryURL = appLauncherIndexURL(for: appURL)
    guard FileManager.default.fileExists(atPath: entryURL.path) else { return false }
    return try String(contentsOf: entryURL, encoding: .utf8) == patchedEntry
}

func getPatchStatus() throws -> PatchStatus {
    let targets = getPatchTargetAppURLs()
    if try targets.allSatisfy({ try isPatched(appURL: $0) }) {
        return .napcat
    }

    guard let loader = try getAppLoader() else {
        return .custom("")
    }
    switch loader {
    case let l where PatchStatus.originalLoaders.contains(l):
        return .original
    case let l where napcatLoaders.contains(l):
        return .napcat
    default:
        return .custom(loader)
    }
}

private func createLoader() throws {
    try #"""
    const fs = require('fs');
    const path = require('path');

    const baseAppPath = '\#(appURL.path)';
    const versionsConfigPath = '\#(versionsConfigURL.path)';

    function getActiveAppPath() {
        try {
            const config = JSON.parse(fs.readFileSync(versionsConfigPath, 'utf8'));
            if (config.curVersion) {
                const hotUpdatePath = path.join(
                    path.dirname(versionsConfigPath),
                    config.curVersion,
                    'QQUpdate.app/Contents/Resources/app',
                );
                if (fs.existsSync(path.join(hotUpdatePath, 'package.json'))) {
                    return hotUpdatePath;
                }
            }
        } catch {}
        return baseAppPath;
    }

    function getOriginalMain(buildVersion) {
        if (buildVersion >= 29271) return './application.asar/app_launcher/index.js';
        if (buildVersion >= 28060) return './application/app_launcher/index.js';
        return './app_launcher/index.js';
    }

    function configureNapcatRuntime(appPath) {
        process.env.NAPCAT_QQ_PACKAGE_INFO_PATH = path.join(appPath, 'package.json');
        process.env.NAPCAT_QQ_VERSION_CONFIG_PATH = versionsConfigPath;
        process.env.NAPCAT_WRAPPER_PATH = path.join(appPath, 'wrapper.node');

        const hotUpdateExecPath = path.resolve(appPath, '../../MacOS/QQUpdate');
        if (fs.existsSync(hotUpdateExecPath)) {
            try {
                process.execPath = hotUpdateExecPath;
            } catch {
                try {
                    Object.defineProperty(process, 'execPath', {
                        value: hotUpdateExecPath,
                        configurable: true,
                    });
                } catch {}
            }
        }
    }

    const shouldLoadNapcat =
        process.env.NAPCAT === '1' ||
        process.env.NAPCAT_INJECT === '1' ||
        process.argv.includes('--napcat') ||
        process.argv.includes('--no-sandbox');
    const appPath = getActiveAppPath();
    const package = require(path.join(appPath, 'package.json'));

    if (shouldLoadNapcat) {
        configureNapcatRuntime(appPath);
        (async () => {
            await import('file://\#(docURL.path)/napcat/napcat.mjs');
        })();
    } else {
        require(path.join(appPath, 'major.node')).load('internal_index', module);
        setImmediate(() => {
            if (global.launcher?.installPathPkgJson) {
                global.launcher.installPathPkgJson.main = getOriginalMain(package.buildVersion);
            }
        });
    }
    """#
    .write(to: loaderURL, atomically: true, encoding: .utf8)
}

private func createLauncher() throws {
    let launcher = #"""
    #!/bin/bash
    export NAPCAT=1
    export NAPCAT_DISABLE_MULTI_PROCESS=1
    export NAPCAT_DISABLE_PIPE=1
    export NAPCAT_DISABLE_BYPASS=1
    exec /Applications/QQ.app/Contents/MacOS/QQ --no-sandbox --napcat "$@"
    """#

    try launcher.write(to: launcherURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcherURL.path)
}

func getQQPackage() {
    NSWorkspace.shared.activateFileViewerSelecting([getPackageURL()])
}

func applyNapcatPatch() throws {
    try createLoader()
    try createLauncher()
    try patchNapcatCompatibilityTable()

    for appURL in getPatchTargetAppURLs() {
        let packageURL = appURL.appendingPathComponent("package.json")
        let entryURL = appLauncherIndexURL(for: appURL)
        let fileManager = FileManager.default

        let packageBackupURL = backupURL(for: packageURL)
        if !fileManager.fileExists(atPath: packageBackupURL.path) {
            try fileManager.copyItem(at: packageURL, to: packageBackupURL)
        }

        let entryBackupURL = backupURL(for: entryURL)
        if !fileManager.fileExists(atPath: entryBackupURL.path) {
            try fileManager.copyItem(at: entryURL, to: entryBackupURL)
        }

        guard var qq = try getJSONObject(url: packageURL) else { continue }
        qq["main"] = patchedMain
        let data = try JSONSerialization.data(withJSONObject: qq, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: packageURL, options: .atomic)
        try patchedEntry.write(to: entryURL, atomically: true, encoding: .utf8)
    }
}

func restoreNapcatPatch() throws {
    for appURL in getPatchTargetAppURLs() {
        let packageURL = appURL.appendingPathComponent("package.json")
        let entryURL = appLauncherIndexURL(for: appURL)
        let fileManager = FileManager.default

        let packageBackupURL = backupURL(for: packageURL)
        if fileManager.fileExists(atPath: packageBackupURL.path) {
            if fileManager.fileExists(atPath: packageURL.path) {
                try fileManager.removeItem(at: packageURL)
            }
            try fileManager.copyItem(at: packageBackupURL, to: packageURL)
        }

        let entryBackupURL = backupURL(for: entryURL)
        if fileManager.fileExists(atPath: entryBackupURL.path) {
            if fileManager.fileExists(atPath: entryURL.path) {
                try fileManager.removeItem(at: entryURL)
            }
            try fileManager.copyItem(at: entryBackupURL, to: entryURL)
        }
    }
}

let napcatInstructions = #"""
    # \#(NSLocalizedString("命令行启动，注入 NapCat", comment: ""))
    $ \#(launcherURL.path)
    # \#(NSLocalizedString("参数可以加 -q <QQ号> 快速登录", comment: ""))

    # \#(NSLocalizedString("正常启动 QQ GUI，不注入 NapCat", comment: ""))
    $ open -a QQ.app -n
    """#

private let webuiURL = datURL.appendingPathComponent("config/webui.json", isDirectory: false)

func getWebUILink() throws -> URL? {
    guard let dict = try getJSONObject(url: webuiURL),
        let port = dict["port"] as? Int,
        let prefix = dict["prefix"] as? String,
        let token = dict["token"] as? String
    else {
        return nil
    }
    return URL(string: "http://127.0.0.1:\(port)\(prefix)/webui?token=\(token)")
}
