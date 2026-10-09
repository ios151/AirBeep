import Combine
import Network
import SwiftUI

/// 完成 Airlift 后端所需的两个前提条件：
/// 设备配对记录 + 活跃的回环隧道（LocalDevVPN 或代理工具）。
struct AirBeepAirliftSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var pairing = PairingController.shared
    @ObservedObject private var service = CallRecordingToneService.shared
    @StateObject private var wifiMonitor = AirliftWiFiMonitor()

    @State private var paired = FileManager.default.fileExists(
        atPath: PairingController.pairingFilePath()
    )
    @State private var connected = false
    @State private var checking  = false
    @State private var pairingError: String?
    @State private var connectionError: String?

    var body: some View {
        NavigationStack {
            Group {
                switch wifiMonitor.status {
                case .checking:     AirliftWiFiCheckingView()
                case .disconnected: AirliftWiFiRequiredView()
                case .connected:
                    if connected {
                        readyView
                    } else if paired {
                        AirliftVPNView(
                            tunnelSource: $service.tunnelSource,
                            connectionError: connectionError,
                            checking: checking,
                            onCheck: checkConnection,
                            onPairAgain: {
                                paired = false
                                pairingError = nil
                                connectionError = nil
                            }
                        )
                    } else {
                        AirliftPairingView(
                            running: pairing.running,
                            pin: pairing.pairingPIN,
                            error: pairingError,
                            onStart: startPairing
                        )
                    }
                }
            }
            .navigationTitle("Airlift 设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { pairing.softCancel(); dismiss() }
                }
            }
        }
    }

    private var readyView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 54, weight: .semibold))
                .foregroundStyle(.green)
            Text("Airlift 已就绪").font(.largeTitle.bold())
            Text("配对与 \(service.tunnelSource.displayName) 均已就绪，返回 AirBeep 即可读取或更改录音提示音。")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button("完成") { dismiss() }
                .buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity)
        }
        .padding(24)
    }

    private func startPairing() {
        guard !pairing.running else { return }
        pairingError = nil
        Task {
            do { _ = try await pairing.startAndWait(); paired = true }
            catch { pairingError = error.localizedDescription }
        }
    }

    private func checkConnection() {
        guard !checking else { return }
        checking = true; connectionError = nil
        Task {
            defer { checking = false }
            do {
                _ = try await TendiesEngine.shared.detectPosterBoardContainer(
                    pairingPath: PairingController.pairingFilePath()
                )
                connected = true
            } catch { connectionError = error.localizedDescription }
        }
    }
}

#Preview { AirBeepAirliftSetupView() }
