import Combine
import Foundation

// 回环隧道来源
enum TunnelSource: String, CaseIterable, Identifiable {
    case localDevVPN = "LocalDevVPN"
    case proxyTool   = "proxy"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .localDevVPN: "LocalDevVPN"
        case .proxyTool:   "代理工具"
        }
    }

    var connectInstructions: String {
        switch self {
        case .localDevVPN:
            "打开 LocalDevVPN，点击连接，然后返回 AirBeep。"
        case .proxyTool:
            "在代理工具中启用回环反射（如 ClashMi loopback-address: 10.7.0.1 / Surge tun-included-routes），然后返回 AirBeep。"
        }
    }
}

enum CallRecordingToneError: LocalizedError {
    case unsupported
    case pairingRequired
    case airliftUnavailable
    case airliftFailed(String)
    case toneReadFailed(String, String)
    case missingTone(String)
    case missingBackup
    case invalidToneBundle
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupported:
            "此设备或系统版本不受支持。"
        case .pairingRequired:
            "BadQuery 不可用，请启用回环隧道（LocalDevVPN 或代理工具）并完成 Airlift 设置。"
        case .airliftUnavailable:
            "此构建缺少 AirLift 文件访问支持。"
        case .airliftFailed(let reason):
            "AirLift 操作失败：\(Self.localizeAirliftReason(reason))"
        case .toneReadFailed(let name, let reason):
            "无法读取 \(name)：\(Self.localizeAirliftReason(reason))"
        case .missingTone(let name):
            "系统提示音文件缺失：\(name)"
        case .missingBackup:
            "原始提示音备份不存在，无法恢复。"
        case .invalidToneBundle:
            "静音资源文件缺失，请重新安装。"
        case .verificationFailed(let name):
            "写入后校验失败：\(name)。请重新连接隧道后重试。"
        }
    }

    // 将 AirliftFFI 常见英文错误映射为中文
    static func localizeAirliftReason(_ reason: String) -> String {
        let r = reason
        if r.contains("timed out") || r.contains("RemoteXPC") || r.contains("connection failed") {
            return "连接超时。请确认 LocalDevVPN 或代理回环已激活，再点击「检查并进入」。"
        }
        if r.contains("did not recover") || r.contains("AirTraffic") || r.contains("moved copy remains") {
            return "文件写入后系统未能恢复，请重新连接隧道后重试。若反复失败，点击「重新配对」重新完成设置。"
        }
        if r.contains("permission") || r.contains("denied") || r.contains("sandbox") {
            return "权限被拒，请确认已完成配对并连接回环隧道。"
        }
        if r.contains("pairing") || r.contains("pair") {
            return "配对失败，请重新配对。"
        }
        if r.contains("not found") || r.contains("missing") {
            return "文件未找到，请确认设备已配对且系统文件完整。"
        }
        return reason
    }
}

@MainActor
final class CallRecordingToneService: ObservableObject {
    enum ToneMode: Equatable {
        case checking
        case systemTone
        case silentTone
        case unavailable
    }

    static let shared = CallRecordingToneService()

    @Published private(set) var mode: ToneMode = .checking
    @Published private(set) var isBusy = false
    @Published private(set) var lastError: String?
    @Published private(set) var statusDetail: String?
    @Published private(set) var needsAirliftSetup = false

    @Published var tunnelSource: TunnelSource = {
        let raw = UserDefaults.standard.string(forKey: "airliftTunnelSource") ?? ""
        return TunnelSource(rawValue: raw) ?? .localDevVPN
    }() {
        didSet { UserDefaults.standard.set(tunnelSource.rawValue, forKey: "airliftTunnelSource") }
    }

    private enum AccessBackend {
        case badQuery
        case airlift(pairingPath: String)
    }

    private struct ToneFile {
        let name: String
        let systemPath: String
        let backupName: String
        let resourceName: String
        let resourceExtension: String
    }

    private let files = [
        ToneFile(
            name: "StartDisclosureWithTone.m4a",
            systemPath: "/var/mobile/Library/CallServices/Greetings/default/StartDisclosureWithTone.m4a",
            backupName: "StartDisclosureWithTone.m4a",
            resourceName: "AirBeepStartSilence",
            resourceExtension: "m4a"
        ),
        ToneFile(
            name: "StopDisclosure.caf",
            systemPath: "/var/mobile/Library/CallServices/Greetings/default/StopDisclosure.caf",
            backupName: "StopDisclosure.caf",
            resourceName: "AirBeepStopSilence",
            resourceExtension: "caf"
        )
    ]

    private var backupDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "AirBeepBackups", directoryHint: .isDirectory)
    }

    private init() {}

    func refresh() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let backend = try accessBackend()
            mode = try await inspectMode(using: backend)
            statusDetail = nil; needsAirliftSetup = false; lastError = nil
        } catch {
            mode = .unavailable
            statusDetail = error.localizedDescription
            needsAirliftSetup = shouldOfferAirliftSetup(for: error)
            lastError = nil
        }
    }

    func clearError() { lastError = nil }

    func applySilentTone() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let backend = try accessBackend()
            let current = try await readTones(using: backend)
            let silent  = try silentTones()
            if current == silent {
                mode = .silentTone; statusDetail = nil; needsAirliftSetup = false; lastError = nil
                return
            }
            try ensureBackup(current)
            do {
                try await writeTones(silent, using: backend)
                mode = .silentTone; statusDetail = nil; needsAirliftSetup = false; lastError = nil
            } catch {
                try? await writeTones(current, using: backend)
                throw error
            }
        } catch { reportOperationError(error) }
    }

    func restoreSystemTone() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let backend = try accessBackend()
            let current = try await readTones(using: backend)
            guard let backup = try? readBackups() else {
                mode = .systemTone; statusDetail = nil; needsAirliftSetup = false; lastError = nil
                return
            }
            if current == backup {
                mode = .systemTone; statusDetail = nil; needsAirliftSetup = false; lastError = nil
                return
            }
            do {
                try await writeTones(backup, using: backend)
                mode = .systemTone; statusDetail = nil; needsAirliftSetup = false; lastError = nil
            } catch {
                try? await writeTones(current, using: backend)
                throw error
            }
        } catch { reportOperationError(error) }
    }

    private func reportOperationError(_ error: Error) {
        mode = .unavailable
        statusDetail = error.localizedDescription
        needsAirliftSetup = shouldOfferAirliftSetup(for: error)
        lastError = error.localizedDescription
    }

    // BadQuery 优先（iOS 26+/27），不需要任何 VPN 或代理。
    // BadQuery 不可用时才降级到 Airlift（需要回环隧道）。
    private func accessBackend() throws -> AccessBackend {
        guard SystemCompatibility.isSupported else {
            throw CallRecordingToneError.unsupported
        }
        if BadQuery.isAvailable { return .badQuery }

        let pairingPath = PairingController.pairingFilePath()
        let size = (try? FileManager.default.attributesOfItem(atPath: pairingPath)[.size] as? Int) ?? 0
        guard size > 0 else { throw CallRecordingToneError.pairingRequired }
        return .airlift(pairingPath: pairingPath)
    }

    private func shouldOfferAirliftSetup(for error: Error) -> Bool {
        guard let error = error as? CallRecordingToneError else { return false }
        switch error {
        case .pairingRequired, .airliftUnavailable, .airliftFailed: return true
        case .toneReadFailed: return !BadQuery.isAvailable
        case .unsupported, .missingTone, .missingBackup, .invalidToneBundle, .verificationFailed: return false
        }
    }

    private func inspectMode(using backend: AccessBackend) async throws -> ToneMode {
        let current = try await readTones(using: backend)
        return current == (try silentTones()) ? .silentTone : .systemTone
    }

    private func readTones(using backend: AccessBackend) async throws -> [Data] {
        var tones: [Data] = []
        tones.reserveCapacity(files.count)
        for file in files {
            do {
                switch backend {
                case .badQuery:
                    tones.append(try BadQuery.readData(at: file.systemPath))
                case .airlift(let pairingPath):
                    tones.append(try await AirliftToneTransport.shared.read(path: file.systemPath, pairingPath: pairingPath))
                }
            } catch { throw mapReadError(error, file: file) }
        }
        return tones
    }

    private func mapReadError(_ error: Error, file: ToneFile) -> Error {
        if let error = error as? CallRecordingToneError { return error }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoSuchFileError {
            return CallRecordingToneError.missingTone(file.name)
        }
        return CallRecordingToneError.toneReadFailed(file.name, error.localizedDescription)
    }

    private func silentTones() throws -> [Data] {
        try files.map { file in
            guard let url = resourceURL(for: file) else { throw CallRecordingToneError.invalidToneBundle }
            return try Data(contentsOf: url)
        }
    }

    private func resourceURL(for file: ToneFile) -> URL? {
        let bundle = Bundle.main
        return bundle.url(forResource: file.resourceName, withExtension: file.resourceExtension)
            ?? bundle.url(forResource: file.resourceName, withExtension: file.resourceExtension, subdirectory: "Resources")
            ?? bundle.url(forResource: file.resourceName, withExtension: file.resourceExtension, subdirectory: "SilentTones")
    }

    private func ensureBackup(_ current: [Data]) throws {
        if (try? readBackups()) != nil { return }
        guard current != (try silentTones()) else { throw CallRecordingToneError.missingBackup }
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        for (file, data) in zip(files, current) { try data.write(to: backupURL(for: file), options: .atomic) }
    }

    private func readBackups() throws -> [Data] {
        try files.map { file in
            let url = backupURL(for: file)
            guard FileManager.default.fileExists(atPath: url.path) else { throw CallRecordingToneError.missingBackup }
            return try Data(contentsOf: url)
        }
    }

    private func backupURL(for file: ToneFile) -> URL {
        backupDirectory.appending(path: file.backupName)
    }

    private func writeTones(_ tones: [Data], using backend: AccessBackend) async throws {
        switch backend {
        case .badQuery:
            for (file, data) in zip(files, tones) { try BadQuery.writeData(data, to: file.systemPath) }
        case .airlift(let pairingPath):
            let payload = zip(files, tones).map { AirliftToneFile(name: $0.name, data: $1) }
            try await AirliftToneTransport.shared.write(files: payload, pairingPath: pairingPath)
        }
        let verified = try await readTones(using: backend)
        for (index, file) in files.enumerated() {
            guard verified.indices.contains(index), verified[index] == tones[index] else {
                throw CallRecordingToneError.verificationFailed(file.name)
            }
        }
    }
}
