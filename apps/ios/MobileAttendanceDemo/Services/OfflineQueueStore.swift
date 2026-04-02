import Foundation

private struct LegacyQueuedClaim: Codable {
    let id: UUID?
    let createdAt: Date
    let summary: String
}

struct OfflineQueueStore {
    private let key = "truepresence-queued-claims"

    func load() -> [QueuedAttendanceClaim] {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return []
        }
        if let claims = try? JSONDecoder().decode([QueuedAttendanceClaim].self, from: data) {
            return claims
        }
        if let legacy = try? JSONDecoder().decode([LegacyQueuedClaim].self, from: data) {
            return legacy.map {
                QueuedAttendanceClaim(
                    id: $0.id ?? UUID(),
                    createdAt: $0.createdAt,
                    claim: AttendanceClaimPayload(
                        tenantID: "truepresence-demo",
                        personID: "student-one",
                        siteID: "classroom-a",
                        claimedIdentityMode: "1:1",
                        clientTimestamp: ISO8601DateFormatter().string(from: $0.createdAt),
                        gps: GPSPayload(latitude: 0, longitude: 0, accuracyM: 999, isMocked: false),
                        deviceAttestation: DeviceAttestationPayload(
                            provider: "legacy-migration",
                            token: "legacy",
                            secureEnclaveBacked: false,
                            isTrusted: false,
                            deviceID: "legacy"
                        ),
                        appVersion: "legacy",
                        captureToken: "legacy",
                        faceImageBase64: nil,
                        protectedTemplate: nil,
                        qualityScore: 0,
                        livenessScore: 0,
                        bboxConfidence: 0,
                        depthPresent: nil,
                        depthCoverage: nil,
                        depthVariance: nil,
                        depthEvidencePassed: nil,
                        providerManifests: [],
                        optionalEvidenceRef: nil,
                        claimSource: "local_demo_replay",
                        requestSignature: "legacy"
                    ),
                    personDisplayName: "Legacy queued claim",
                    siteLabel: "Legacy",
                    retryCount: 0,
                    lastError: $0.summary,
                    localEventID: nil
                )
            }
        }
        return []
    }

    func save(_ claims: [QueuedAttendanceClaim]) {
        guard let data = try? JSONEncoder().encode(claims) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
