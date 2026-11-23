// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SwiftUI
import UIKit

struct AppRelease: Decodable, Identifiable {
    let id: String
    let version: String
    let build: String
    let notes: String
    let min_ios: String
    let bytes: Int64
    let sha256: String
    let download_url: URL
}
private struct AppUpdateResponse: Decodable {
    let api_version: Int
    let update_available: Bool
    let required: Bool
    let release: AppRelease?
}

@MainActor
final class AppUpdates: ObservableObject {
    static let shared = AppUpdates()
    @Published private(set) var checking = false
    @Published private(set) var checked = false
    @Published private(set) var release: AppRelease?
    @Published private(set) var required = false
    @Published private(set) var error: String?
    @Published var showPrompt = false
    @Published var includeBeta = UserDefaults.standard.bool(forKey: "CarVistaBetaUpdates") {
        didSet { UserDefaults.standard.set(includeBeta, forKey: "CarVistaBetaUpdates") }
    }
    private var lastAutomaticCheck = Date.distantPast

    func check(automatically: Bool = false) async {
        guard ServiceGate.enabled, !checking else { return }
        if automatically && Date().timeIntervalSince(lastAutomaticCheck) < 3600 { return }
        checking = true
        error = nil
        defer { checking = false }
        var components = URLComponents(url: ServiceGate.join("api/app/updates"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "build", value: ServiceClient.appBuild),
            URLQueryItem(name: "ios", value: UIDevice.current.systemVersion),
            URLQueryItem(name: "bundle_id", value: Bundle.main.object(forInfoDictionaryKey: "CarVistaUpdateBundleID") as? String ?? "local.carvista"),
            URLQueryItem(name: "channel", value: includeBeta ? "beta" : "stable")
        ]
        do {
            var request = URLRequest(url: components.url!, timeoutInterval: 20)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw UpdateError.message("暂时无法连接 V2 更新服务，请稍后重试。")
            }
            let result = try JSONDecoder().decode(AppUpdateResponse.self, from: data)
            guard result.api_version == 2 else { throw UpdateError.message("更新服务协议不匹配，请联系管理员。") }
            if result.update_available {
                guard let next = result.release, next.download_url.scheme == "https",
                      next.download_url.host == ServiceGate.baseURL.host else {
                    throw UpdateError.message("更新下载地址无效，请联系管理员。")
                }
                release = next
                required = result.required
                if automatically { showPrompt = true }
            } else {
                release = nil
                required = false
                showPrompt = false
            }
            checked = true
            if automatically { lastAutomaticCheck = Date() }
        } catch {
            self.error = (error as? UpdateError)?.description ?? "检查更新失败，请检查网络后重试。"
        }
    }
    private enum UpdateError: Error {
        case message(String)
        var description: String { switch self { case .message(let text): return text } }
    }
}

struct AppUpdateView: View {
    @ObservedObject private var updates = AppUpdates.shared
    @Environment(\.openURL) private var openURL
    var prompted = false
    private var currentVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        let channel = (Bundle.main.object(forInfoDictionaryKey: "CarVistaReleaseChannel") as? String)?.lowercased()
        let label = channel == "beta" ? "测试版" : channel == "stable" ? "稳定版" : "渠道未知"
        return "\(version)（\(label)）"
    }
    var body: some View {
        List {
            Section {
                LabeledContent("当前版本", value: currentVersion)
                LabeledContent("更新服务", value: "CarVista V2")
                Toggle("接收测试版更新", isOn: $updates.includeBeta)
                    .disabled(updates.checking || updates.required)
                    .onChange(of: updates.includeBeta) { _, _ in Task { await updates.check() } }
            }
            if let release = updates.release {
                Section(updates.required ? "此版本需要更新" : "发现新版本") {
                    LabeledContent("新版本", value: "\(release.version)（\(release.build)）")
                    LabeledContent("系统要求", value: "iOS \(release.min_ios) 及以上")
                    LabeledContent("安装包", value: ByteCountFormatter.string(fromByteCount: release.bytes, countStyle: .file))
                    Text(release.notes)
                    Button { openURL(release.download_url) } label: {
                        Label("下载 IPA", systemImage: "arrow.down.circle.fill")
                    }.accessibilityIdentifier("updates.download")
                    Text("下载后，请使用与你的设备和安装包签名匹配的方式安装。下载不会自动替换当前 App。")
                        .font(.footnote).foregroundStyle(.secondary)
                    DisclosureGroup("安装包校验值 SHA-256") {
                        Text(release.sha256).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            } else if updates.checked {
                Section { Label("当前没有适用于此设备的新版本", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
            }
            Section {
                Button { Task { await updates.check() } } label: {
                    HStack { Text(updates.checking ? "正在检查…" : "检查更新"); Spacer(); if updates.checking { ProgressView() } }
                }.disabled(updates.checking).accessibilityIdentifier("updates.check")
                if let error = updates.error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle("App 更新")
        .navigationBarTitleDisplayMode(.inline)
        .task { if !prompted { await updates.check() } }
        .toolbar {
            if prompted && !updates.required { ToolbarItem(placement: .confirmationAction) { Button("稍后") { updates.showPrompt = false } } }
        }
        .interactiveDismissDisabled(updates.required)
    }
}
