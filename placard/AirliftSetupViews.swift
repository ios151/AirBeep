import SwiftUI
import UIKit
import Network
import Combine

@MainActor
final class AirliftWiFiMonitor: ObservableObject {
    enum Status { case checking, connected, disconnected }

    @Published private(set) var status: Status = .checking

    private let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private let queue   = DispatchQueue(label: "me.ssus.placard.airlift.wifi-monitor")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let s: Status = path.status == .satisfied ? .connected : .disconnected
            DispatchQueue.main.async { self?.status = s }
        }
        monitor.start(queue: queue)
    }
    deinit { monitor.cancel() }
}

struct AirliftWiFiCheckingView: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView().controlSize(.large)
            Text("正在检查 Wi-Fi...").font(.headline).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(24)
    }
}

struct AirliftWiFiRequiredView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer()
            Image(systemName: "wifi.exclamationmark").font(.system(size: 44)).foregroundStyle(.tint)
            Text("需要 Wi-Fi").font(.largeTitle.bold())
            Text("Airlift 初始配对需要 Wi-Fi 连接。")
                .foregroundStyle(.secondary)
            Text("请将 iPhone 连接到 Wi-Fi 网络，连接后 AirBeep 将自动继续。")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(24)
    }
}

struct AirliftPairingView: View {
    let running: Bool
    let pin: String?
    let error: String?
    let onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer()
            Image(systemName: "iphone.gen3.radiowaves.left.and.right").font(.system(size: 44)).foregroundStyle(.tint)
            Text("配对 iPhone").font(.largeTitle.bold())
            Text("点击「开始配对」，然后打开 设置 > 隐私与安全性 > 开发者模式 > 与 AirBeep 配对。")
                .foregroundStyle(.secondary)
            if let pin { Text(pin).font(.largeTitle.monospacedDigit()) }
            if let error { Text(error).foregroundStyle(.red) }
            Spacer()
            Button(action: onStart) {
                if running { ProgressView("等待配对...").frame(maxWidth: .infinity) }
                else { Text("开始配对").frame(maxWidth: .infinity) }
            }
            .buttonStyle(.borderedProminent).controlSize(.large).disabled(running)
        }
        .padding(24)
    }
}

// 支持 LocalDevVPN 和代理工具两种隧道来源。
// AirliftFFI 通过 pairing file 的 UDID 自动发现设备地址，
// 两种回环方式在代码层无差异，此视图只提供用户引导。
struct AirliftVPNView: View {
    @Binding var tunnelSource: TunnelSource
    let connectionError: String?
    let checking: Bool
    let onCheck: () -> Void
    let onPairAgain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer()
            Image(systemName: "network").font(.system(size: 44)).foregroundStyle(.tint)
            Text("连接隧道").font(.largeTitle.bold())

            Picker("隧道来源", selection: $tunnelSource) {
                ForEach(TunnelSource.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)

            Text(tunnelSource.connectInstructions).foregroundStyle(.secondary)

            if tunnelSource == .localDevVPN {
                Button("打开 LocalDevVPN", action: openLocalDevVPN)
                    .buttonStyle(.bordered).controlSize(.large)
            }

            if let connectionError {
                Text(connectionError).foregroundStyle(.red)
                Button("重新配对", action: onPairAgain).font(.footnote)
            }
            Spacer()
            Button(action: onCheck) {
                if checking { ProgressView("正在检查连接...").frame(maxWidth: .infinity) }
                else { Text("检查并进入").frame(maxWidth: .infinity) }
            }
            .buttonStyle(.borderedProminent).controlSize(.large).disabled(checking)
        }
        .padding(24)
    }

    private func openLocalDevVPN() {
        let appURL   = URL(string: "localdevvpn://")!
        let storeURL = URL(string: "https://apps.apple.com/app/id6755608044")!
        UIApplication.shared.open(appURL) { opened in
            guard !opened else { return }
            DispatchQueue.main.async { UIApplication.shared.open(storeURL) }
        }
    }
}

#Preview("需要 Wi-Fi")  { AirliftWiFiRequiredView() }
#Preview("配对")        { AirliftPairingView(running: false, pin: nil, error: nil, onStart: {}) }
#Preview("连接隧道") {
    @Previewable @State var src = TunnelSource.localDevVPN
    AirliftVPNView(tunnelSource: $src, connectionError: nil, checking: false, onCheck: {}, onPairAgain: {})
}
