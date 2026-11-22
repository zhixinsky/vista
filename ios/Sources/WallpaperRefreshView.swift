// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import WebKit

struct WallpaperRefreshButton: View {
    var title = "重启 CarPlay"
    var systemImage = "arrow.clockwise"
    @EnvironmentObject private var model: WorkshopModel
    @Environment(\.scenePhase) private var phase
    @StateObject private var controller = RespringController()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                controller.start()
            } label: {
                Text(controller.active ? "正在刷新…" : (title == "注销" ? "注销并刷新" : title))
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .foregroundStyle(.white)
                    .background(Color.black, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(model.busy || controller.active)
            .accessibilityIdentifier(title == "注销" ? "wallpaper.logout" : "wallpaper.refresh")

            if controller.active, let webView = controller.webView {
                // Preserve the original execution surface from the second sheet.
                // The reload document needs a real, attached WKWebView.
                RespringSurface(webView: webView)
                    .frame(height: 180)
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)
                    .onAppear { controller.loadIfNeeded() }
                ProgressView("正在尝试重载系统界面…")
                    .font(.caption)
                Button("停止尝试") {
                    controller.stop("已停止，未确认是否刷新。")
                }
                .font(.caption)
            } else if controller.message != RespringController.initialMessage {
                Text(controller.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("respring.status")
            }
        }
        .onChange(of: phase) { _, value in
            if value != .active && controller.active {
                controller.stop("尝试已结束，请重新连接 CarPlay 检查壁纸效果。")
            }
        }
        .onDisappear {
            if controller.active { controller.stop("已停止。") }
        }
    }
}

@MainActor
final class RespringController: ObservableObject {
    static let initialMessage = "让系统重新加载界面和壁纸，可能短暂黑屏并返回桌面。请停车后操作。"
    @Published private(set) var active = false
    @Published private(set) var message = initialMessage
    private var timer: Task<Void, Never>?
    private(set) var webView: WKWebView?
    private var didLoad = false

    func loadIfNeeded() {
        guard active, !didLoad, let webView else { return }
        didLoad = true
        webView.loadHTMLString(RespringDocument.document, baseURL: nil)
    }

    func start() {
        guard !active else { return }
        #if targetEnvironment(simulator)
        message = "模拟器不执行界面重载，请在真机验证。"
        #else
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        config.defaultWebpagePreferences = preferences
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = true
        view.backgroundColor = .black
        view.scrollView.isScrollEnabled = false
        didLoad = false
        webView = view
        active = true
        message = "正在尝试重载系统界面，请稍后到车机确认壁纸是否生效…"
        // Loading occurs after the web view has been mounted in SwiftUI.
        timer = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
            self?.stop("尝试已停止。若没有返回桌面或壁纸仍未更新，请手动重启 iPhone。")
        }
        #endif
    }

    func stop(_ text: String) {
        timer?.cancel(); timer = nil
        webView?.stopLoading()
        webView?.loadHTMLString("<html><body></body></html>", baseURL: nil)
        webView?.removeFromSuperview()
        webView = nil
        didLoad = false
        active = false
        message = text
    }
}

private struct RespringSurface: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    static func dismantleUIView(_ uiView: WKWebView, coordinator: ()) {
        uiView.stopLoading()
        uiView.loadHTMLString("<html><body></body></html>", baseURL: nil)
    }
}

private struct WallpaperRefreshView: View {
    var title = "重启 CarPlay"
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @EnvironmentObject var model: WorkshopModel
    @StateObject private var controller = RespringController()
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text(controller.message).accessibilityIdentifier("respring.status")
                Text("此操作只尝试重载系统界面，不写入或删除壁纸。当前系统是否支持、车机壁纸是否刷新，需要实际检查。")
                    .font(.subheadline).foregroundStyle(.secondary)
                if controller.active, let webView = controller.webView {
                    RespringSurface(webView: webView).frame(height: 180).allowsHitTesting(false)
                    ProgressView("正在尝试…")
                    Button("停止尝试") { controller.stop("已停止，未确认是否刷新。") }
                } else {
                    Button(title == "注销" ? "注销" : "重载界面，让壁纸生效") { controller.start() }
                        .buttonStyle(.borderedProminent).disabled(model.busy)
                        .accessibilityIdentifier("respring.start")
                    Text("若无效果，请手动重启 iPhone 后重新连接 CarPlay。无需配置快捷指令。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(20).navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("完成") { dismiss() } }
                .onChange(of: phase) { _, value in
                    if value != .active, controller.active {
                        controller.stop("尝试已结束，请重新连接 CarPlay 检查壁纸效果。")
                    }
                }
                .onDisappear { controller.stop("已停止。") }
        }.tint(CanvasTheme.accent)
    }
}
