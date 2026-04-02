import DeviceCheck
import Foundation
import UIKit

struct DeviceTrustService {
    func currentProvider() -> String {
        DCAppAttestService.shared.isSupported ? "real_app_attest" : "demo_fallback"
    }

    func currentDeviceID() -> String {
        UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device"
    }

    func attestation() async throws -> DeviceAttestationPayload {
        let deviceID = await MainActor.run { currentDeviceID() }
        if DCAppAttestService.shared.isSupported {
            return DeviceAttestationPayload(
                provider: "real_app_attest",
                token: "app-attest-available",
                secureEnclaveBacked: true,
                isTrusted: true,
                deviceID: deviceID
            )
        }

        return DeviceAttestationPayload(
            provider: "demo_fallback",
            token: "demo-trust-fallback",
            secureEnclaveBacked: false,
            isTrusted: true,
            deviceID: deviceID
        )
    }
}
