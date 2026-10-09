//
//  TendiesEngine.swift
//  AirCard-iOS
//
//  Minimal Airlift bridge: device container lookup and respring, used for
//  pairing/VPN connectivity checks. Wallpaper-specific logic was removed.
//

import Foundation
import AirliftFFI

public final class TendiesEngine {
    public static let shared = TendiesEngine()

    private init() {}

    // AirliftFFI 默认目标地址为 172.16.0.1（LocalDevVPN 旧地址），
    // 代理工具使用 10.7.0.1，每次操作前统一设置。
    private static let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
    private static func configureTargetHost() {
        typealias Fn = @convention(c) (UnsafePointer<CChar>?) -> Int32
        guard let sym = dlsym(rtldDefault, "al_set_target_host") else { return }
        let fn = unsafeBitCast(sym, to: Fn.self)
        _ = "10.7.0.1".withCString { fn($0) }
    }

    // MARK: - Auto-detect PosterBoard Container

    public func detectPosterBoardContainer(pairingPath: String) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                Self.configureTargetHost()
                var outContainer: UnsafeMutablePointer<CChar>? = nil
                var outError: UnsafeMutablePointer<CChar>? = nil

                let rc = pairingPath.withCString { pairC in
                    "com.apple.PosterBoard".withCString { bundleC in
                        al_find_app_container(pairC, bundleC, nil, nil, &outContainer, &outError)
                    }
                }

                if rc == 0, let p = outContainer {
                    let containerStr = String(cString: p)
                    al_string_free(p)
                    continuation.resume(returning: containerStr)
                } else {
                    let errStr = outError.flatMap { p in
                        let s = String(cString: p)
                        al_string_free(p)
                        return s
                    } ?? "Failed to find PosterBoard container"
                    continuation.resume(throwing: NSError(
                        domain: "TendiesEngine",
                        code: Int(rc),
                        userInfo: [NSLocalizedDescriptionKey: errStr]
                    ))
                }
            }
        }
    }

    // MARK: - Send Respring Signal via Tunnel

    public func sendRespringSignal(pairingPath: String) async -> Bool {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var outError: UnsafeMutablePointer<CChar>? = nil
                let rc = pairingPath.withCString { pC in
                    al_device_respring(pC, nil, nil, &outError)
                }
                if let p = outError {
                    al_string_free(p)
                }
                continuation.resume(returning: rc == 0)
            }
        }
    }
}
