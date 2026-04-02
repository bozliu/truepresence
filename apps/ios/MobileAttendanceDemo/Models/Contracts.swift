import CryptoKit
import Foundation

enum AppBackendMode: String, Codable, Hashable, CaseIterable {
    case remote
    case lan
    case standaloneDemoAutoFallback = "standalone_demo_auto_fallback"

    var label: String {
        switch self {
        case .remote:
            return "Cloud backend"
        case .lan:
            return "LAN realtime"
        case .standaloneDemoAutoFallback:
            return "Bundled bootstrap"
        }
    }
}

enum BootstrapSource: String, Codable, Hashable {
    case remote
    case lan
    case cache
    case bundledDemo = "bundled_demo"

    var label: String {
        switch self {
        case .remote:
            return "Cloud"
        case .lan:
            return "LAN"
        case .cache:
            return "Cached"
        case .bundledDemo:
            return "Bundled bootstrap"
        }
    }
}

enum DecisionOrigin: String, Codable, Hashable {
    case server
    case localDemo = "local_demo"
}

enum SyncStatus: String, Codable, Hashable {
    case idle
    case pending
    case localOnly = "local_only"
    case synced
    case failed

    var label: String {
        switch self {
        case .idle:
            return "idle"
        case .pending:
            return "pending"
        case .localOnly:
            return "local only"
        case .synced:
            return "synced"
        case .failed:
            return "failed"
        }
    }
}

enum LocalHistorySyncState: String, Codable, Hashable {
    case localOnly = "local_only"
    case queued
    case synced
    case failed
    case archived

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        switch rawValue {
        case "pending":
            self = .queued
        case "local_only":
            self = .localOnly
        case "queued":
            self = .queued
        case "synced":
            self = .synced
        case "failed":
            self = .failed
        case "archived":
            self = .archived
        default:
            self = .localOnly
        }
    }

    var label: String {
        switch self {
        case .localOnly:
            return "local only"
        case .queued:
            return "queued"
        case .synced:
            return "synced"
        case .failed:
            return "sync failed"
        case .archived:
            return "archived"
        }
    }
}

struct AppSettings: Codable, Hashable {
    var backendMode: AppBackendMode = .lan
    var remoteBackendBaseURLString = ""
    var lanBackendBaseURLString = ""
    var selectedTenantID = "truepresence-demo"
    var selectedPersonID: String?
    var selectedSiteID: String?
    var liveDemoDisplayName = ""
    var standaloneDemoEnabled = true
    var lastSuccessfulBootstrapSource: BootstrapSource?
    var lastSuccessfulBootstrapAt: Date?

    init() {
        lanBackendBaseURLString = Self.defaultLANBackendBaseURLString()
    }

    enum CodingKeys: String, CodingKey {
        case backendMode = "backend_mode"
        case remoteBackendBaseURLString = "remote_backend_base_url"
        case lanBackendBaseURLString = "lan_backend_base_url"
        case legacyBackendBaseURLString = "backendBaseURLString"
        case selectedTenantID = "selected_tenant_id"
        case selectedPersonID = "selected_person_id"
        case selectedSiteID = "selected_site_id"
        case liveDemoDisplayName = "live_demo_display_name"
        case standaloneDemoEnabled = "standalone_demo_enabled"
        case lastSuccessfulBootstrapSource = "last_successful_bootstrap_source"
        case lastSuccessfulBootstrapAt = "last_successful_bootstrap_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        backendMode = try container.decodeIfPresent(AppBackendMode.self, forKey: .backendMode)
            ?? .lan
        remoteBackendBaseURLString = try container.decodeIfPresent(
            String.self,
            forKey: .remoteBackendBaseURLString
        ) ?? ""
        let legacyBackendURL = try container.decodeIfPresent(String.self, forKey: .legacyBackendBaseURLString)
        let decodedLANURL = try container.decodeIfPresent(
            String.self,
            forKey: .lanBackendBaseURLString
        )
        let normalizedLegacyLANURL = Self.normalizeStoredLANBackendBaseURLString(legacyBackendURL)
        let normalizedDecodedLANURL = Self.normalizeStoredLANBackendBaseURLString(decodedLANURL)
        lanBackendBaseURLString = normalizedDecodedLANURL
            ?? normalizedLegacyLANURL
            ?? Self.defaultLANBackendBaseURLString()
        selectedTenantID = try container.decodeIfPresent(String.self, forKey: .selectedTenantID)
            ?? "truepresence-demo"
        selectedPersonID = try container.decodeIfPresent(String.self, forKey: .selectedPersonID)
        selectedSiteID = try container.decodeIfPresent(String.self, forKey: .selectedSiteID)
        liveDemoDisplayName = try container.decodeIfPresent(String.self, forKey: .liveDemoDisplayName)
            ?? ""
        standaloneDemoEnabled = try container.decodeIfPresent(Bool.self, forKey: .standaloneDemoEnabled)
            ?? true
        lastSuccessfulBootstrapSource = try container.decodeIfPresent(
            BootstrapSource.self,
            forKey: .lastSuccessfulBootstrapSource
        )
        lastSuccessfulBootstrapAt = try container.decodeIfPresent(
            Date.self,
            forKey: .lastSuccessfulBootstrapAt
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(backendMode, forKey: .backendMode)
        try container.encode(remoteBackendBaseURLString, forKey: .remoteBackendBaseURLString)
        try container.encode(lanBackendBaseURLString, forKey: .lanBackendBaseURLString)
        try container.encode(selectedTenantID, forKey: .selectedTenantID)
        try container.encodeIfPresent(selectedPersonID, forKey: .selectedPersonID)
        try container.encodeIfPresent(selectedSiteID, forKey: .selectedSiteID)
        try container.encode(liveDemoDisplayName, forKey: .liveDemoDisplayName)
        try container.encode(standaloneDemoEnabled, forKey: .standaloneDemoEnabled)
        try container.encodeIfPresent(lastSuccessfulBootstrapSource, forKey: .lastSuccessfulBootstrapSource)
        try container.encodeIfPresent(lastSuccessfulBootstrapAt, forKey: .lastSuccessfulBootstrapAt)
    }

    var remoteBackendURL: URL? {
        url(from: remoteBackendBaseURLString)
    }

    var lanBackendURL: URL? {
        url(from: lanBackendBaseURLString)
    }

    var backendURL: URL? {
        switch backendMode {
        case .remote:
            return remoteBackendURL
        case .lan:
            return lanBackendURL
        case .standaloneDemoAutoFallback:
            return remoteBackendURL
        }
    }

    private func url(from value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        return URL(string: trimmed)
    }

    private static func defaultLANBackendBaseURLString() -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "MobileAttendanceDefaultLANURL") as? String else {
            return ""
        }
        return normalizeStoredLANBackendBaseURLString(value) ?? ""
    }

    private static func normalizeStoredLANBackendBaseURLString(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return nil
        }
        guard trimmed.localizedCaseInsensitiveContains(".local") == false else {
            return nil
        }
        guard trimmed.contains("198.18.") == false, trimmed.contains("198.19.") == false else {
            return nil
        }
        return trimmed
    }
}

enum AppTab: String, Codable, Hashable {
    case home
    case history
    case profile
}

struct ProviderManifestPayload: Codable, Hashable, Identifiable {
    var id: String { "\(provider)-\(version)-\(runtime)" }
    let provider: String
    let family: String
    let version: String
    let runtime: String
}

struct DeviceAttestationPayload: Codable, Hashable {
    let provider: String
    let token: String
    let secureEnclaveBacked: Bool
    let isTrusted: Bool
    let deviceID: String

    enum CodingKeys: String, CodingKey {
        case provider
        case token
        case secureEnclaveBacked = "secure_enclave_backed"
        case isTrusted = "is_trusted"
        case deviceID = "device_id"
    }
}

struct BoundingBoxPayload: Codable, Hashable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let confidence: Double
}

struct ProtectedTemplatePayload: Codable, Hashable {
    let scheme: String
    let dimension: Int
    let bitstring: String
    let digest: String
}

struct TenantThresholdPayload: Codable, Hashable {
    let minQualityScore: Double
    let minLivenessScore: Double
    let minMatchScore: Double
    let reviewMatchFloor: Double

    enum CodingKeys: String, CodingKey {
        case minQualityScore = "min_quality_score"
        case minLivenessScore = "min_liveness_score"
        case minMatchScore = "min_match_score"
        case reviewMatchFloor = "review_match_floor"
    }
}

struct AttendanceWindowPayload: Codable, Hashable {
    let startHourLocal: Int
    let endHourLocal: Int

    enum CodingKeys: String, CodingKey {
        case startHourLocal = "start_hour_local"
        case endHourLocal = "end_hour_local"
    }
}

struct TenantPolicyPayload: Codable, Hashable {
    let thresholds: TenantThresholdPayload
    let attendanceWindow: AttendanceWindowPayload
    let requireDeviceAttestation: Bool
    let allowOneNFallback: Bool
    let stepUpTriggers: [String]

    enum CodingKeys: String, CodingKey {
        case thresholds
        case attendanceWindow = "attendance_window"
        case requireDeviceAttestation = "require_device_attestation"
        case allowOneNFallback = "allow_1_n_fallback"
        case stepUpTriggers = "step_up_triggers"
    }
}

struct TenantPayload: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let timezone: String
}

struct WorkSitePayload: Codable, Hashable, Identifiable {
    let id: String
    let tenantID: String
    let label: String
    let latitude: Double
    let longitude: Double
    let radiusM: Double

    enum CodingKeys: String, CodingKey {
        case id
        case tenantID = "tenant_id"
        case label
        case latitude
        case longitude
        case radiusM = "radius_m"
    }
}

struct RosterIdentity: Codable, Hashable, Identifiable {
    let id: String
    let tenantID: String
    let employeeCode: String
    let displayName: String
    let siteIDs: [String]
    let active: Bool
    let templateIDs: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case tenantID = "tenant_id"
        case employeeCode = "employee_code"
        case displayName = "display_name"
        case siteIDs = "site_ids"
        case active
        case templateIDs = "template_ids"
    }

    init(
        id: String,
        tenantID: String,
        employeeCode: String,
        displayName: String,
        siteIDs: [String],
        active: Bool,
        templateIDs: [String] = []
    ) {
        self.id = id
        self.tenantID = tenantID
        self.employeeCode = employeeCode
        self.displayName = displayName
        self.siteIDs = siteIDs
        self.active = active
        self.templateIDs = templateIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        tenantID = try container.decode(String.self, forKey: .tenantID)
        employeeCode = try container.decode(String.self, forKey: .employeeCode)
        displayName = try container.decode(String.self, forKey: .displayName)
        siteIDs = try container.decodeIfPresent([String].self, forKey: .siteIDs) ?? []
        active = try container.decodeIfPresent(Bool.self, forKey: .active) ?? true
        templateIDs = try container.decodeIfPresent([String].self, forKey: .templateIDs) ?? []
    }

    var isDemoPerson: Bool {
        id.hasPrefix("demo-person-")
    }
}

struct DeploymentProfileSummaryPayload: Codable, Hashable {
    let profileID: String
    let label: String
    let commercialReleaseSafe: Bool
    let summary: String

    enum CodingKeys: String, CodingKey {
        case profileID = "profile_id"
        case label
        case commercialReleaseSafe = "commercial_release_safe"
        case summary
    }
}

struct MethodComponentPayload: Codable, Hashable, Identifiable {
    var id: String { "\(role)-\(name)" }
    let role: String
    let name: String
    let status: String
    let selectedOn: String
    let paperDate: String?
    let rationale: String
    let sourceURL: String

    enum CodingKeys: String, CodingKey {
        case role
        case name
        case status
        case selectedOn = "selected_on"
        case paperDate = "paper_date"
        case rationale
        case sourceURL = "source_url"
    }
}

struct MethodStackSummaryPayload: Codable, Hashable {
    let profileID: String
    let effectiveDate: String
    let summary: String
    let components: [MethodComponentPayload]

    enum CodingKeys: String, CodingKey {
        case profileID = "profile_id"
        case effectiveDate = "effective_date"
        case summary
        case components
    }
}

struct ActiveClassSessionPayload: Codable, Hashable, Identifiable {
    let id: String
    let tenantID: String
    let siteID: String
    let siteLabel: String
    let classLabel: String
    let canonicalLANURL: String?
    let startedAt: String
    let endsAt: String?
    let active: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case tenantID = "tenant_id"
        case siteID = "site_id"
        case siteLabel = "site_label"
        case classLabel = "class_label"
        case canonicalLANURL = "canonical_lan_url"
        case startedAt = "started_at"
        case endsAt = "ends_at"
        case active
    }
}

struct MobileBootstrapPayload: Codable, Hashable {
    let tenant: TenantPayload
    let policy: TenantPolicyPayload
    let people: [RosterIdentity]
    let sites: [WorkSitePayload]
    let linkedPerson: RosterIdentity?
    let activeClassSession: ActiveClassSessionPayload?
    let livePerson: RosterIdentity?
    let liveSite: WorkSitePayload?
    let wifiIPv4: String?
    let canonicalLANURL: String?
    let backendBindHost: String?
    let lanReady: Bool?
    let networkHint: String?
    let serverTime: String
    let methodStack: MethodStackSummaryPayload
    let captureProfile: DeploymentProfileSummaryPayload

    enum CodingKeys: String, CodingKey {
        case tenant
        case policy
        case people
        case sites
        case linkedPerson = "linked_person"
        case activeClassSession = "active_class_session"
        case livePerson = "live_person"
        case liveSite = "live_site"
        case wifiIPv4 = "wifi_ipv4"
        case canonicalLANURL = "canonical_lan_url"
        case backendBindHost = "backend_bind_host"
        case lanReady = "lan_ready"
        case networkHint = "network_hint"
        case serverTime = "server_time"
        case methodStack = "method_stack"
        case captureProfile = "capture_profile"
    }
}

struct BootstrapCachePayload: Codable, Hashable {
    let payload: MobileBootstrapPayload
    let source: BootstrapSource
    let backendURL: String?
    let fetchedAt: Date
}

struct DemoPersonaDraft: Codable, Hashable {
    var displayName: String = ""
}

struct LiveDemoSessionState: Codable, Hashable {
    let displayName: String
    let personID: String
    let employeeCode: String
    let siteID: String
    let siteLabel: String
    let latitude: Double
    let longitude: Double
    let radiusM: Double
    let source: BootstrapSource
    let syncedToBackend: Bool
    let updatedAt: Date
}

struct ReplayEligibility: Hashable {
    let isEligible: Bool
    let reason: String?
}

struct DepthEvidenceSnapshot: Hashable {
    let hasDepth: Bool
    let coverage: Double
    let variance: Double
    let range: Double
    let passed: Bool
}

struct CapturePayload: Codable, Hashable {
    let captureToken: String
    let qualityScore: Double
    let livenessScore: Double
    let bboxConfidence: Double
    let providerManifests: [ProviderManifestPayload]

    enum CodingKeys: String, CodingKey {
        case captureToken = "capture_token"
        case qualityScore = "quality_score"
        case livenessScore = "liveness_score"
        case bboxConfidence = "bbox_confidence"
        case providerManifests = "provider_manifests"
    }
}

struct GPSPayload: Codable, Hashable {
    let latitude: Double
    let longitude: Double
    let accuracyM: Double
    let isMocked: Bool

    enum CodingKeys: String, CodingKey {
        case latitude
        case longitude
        case accuracyM = "accuracy_m"
        case isMocked = "is_mocked"
    }
}

struct AttendanceClaimPayload: Codable, Hashable {
    let tenantID: String
    let personID: String
    let siteID: String
    let claimedIdentityMode: String
    let clientTimestamp: String
    let gps: GPSPayload
    let deviceAttestation: DeviceAttestationPayload
    let appVersion: String
    let captureToken: String
    let faceImageBase64: String?
    let protectedTemplate: ProtectedTemplatePayload?
    let qualityScore: Double
    let livenessScore: Double
    let bboxConfidence: Double
    let depthPresent: Bool?
    let depthCoverage: Double?
    let depthVariance: Double?
    let depthEvidencePassed: Bool?
    let providerManifests: [ProviderManifestPayload]
    let optionalEvidenceRef: String?
    let claimSource: String
    let requestSignature: String

    enum CodingKeys: String, CodingKey {
        case tenantID = "tenant_id"
        case personID = "person_id"
        case siteID = "site_id"
        case claimedIdentityMode = "claimed_identity_mode"
        case clientTimestamp = "client_timestamp"
        case gps
        case deviceAttestation = "device_attestation"
        case appVersion = "app_version"
        case captureToken = "capture_token"
        case faceImageBase64 = "face_image_base64"
        case protectedTemplate = "protected_template"
        case qualityScore = "quality_score"
        case livenessScore = "liveness_score"
        case bboxConfidence = "bbox_confidence"
        case depthPresent = "depth_present"
        case depthCoverage = "depth_coverage"
        case depthVariance = "depth_variance"
        case depthEvidencePassed = "depth_evidence_passed"
        case providerManifests = "provider_manifests"
        case optionalEvidenceRef = "optional_evidence_ref"
        case claimSource = "claim_source"
        case requestSignature = "request_signature"
    }

    static func makeDemoClaim(
        tenantID: String,
        personID: String,
        siteID: String,
        latitude: Double,
        longitude: Double,
        accuracyM: Double,
        appVersion: String,
        capture: CapturePayload,
        faceImageBase64: String?,
        protectedTemplate: ProtectedTemplatePayload?,
        depthEvidence: DepthEvidenceSnapshot?,
        attestation: DeviceAttestationPayload,
        claimSource: String = "server_live"
    ) -> AttendanceClaimPayload {
        let timestamp = canonicalClaimTimestamp(from: .now)
        let signatureBase = [
            tenantID,
            personID,
            siteID,
            "1:1",
            timestamp,
            String(format: "%.6f", latitude),
            String(format: "%.6f", longitude),
            appVersion,
        ].joined(separator: "|")
        let secret = "demo-secret-truepresence-2026"

        return AttendanceClaimPayload(
            tenantID: tenantID,
            personID: personID,
            siteID: siteID,
            claimedIdentityMode: "1:1",
            clientTimestamp: timestamp,
            gps: GPSPayload(latitude: latitude, longitude: longitude, accuracyM: accuracyM, isMocked: false),
            deviceAttestation: attestation,
            appVersion: appVersion,
            captureToken: capture.captureToken,
            faceImageBase64: faceImageBase64,
            protectedTemplate: protectedTemplate,
            qualityScore: capture.qualityScore,
            livenessScore: capture.livenessScore,
            bboxConfidence: capture.bboxConfidence,
            depthPresent: depthEvidence?.hasDepth,
            depthCoverage: depthEvidence?.coverage,
            depthVariance: depthEvidence?.variance,
            depthEvidencePassed: depthEvidence?.passed,
            providerManifests: capture.providerManifests,
            optionalEvidenceRef: nil,
            claimSource: claimSource,
            requestSignature: signatureBase.hmacSHA256Hex(secret: secret)
        )
    }
}

struct AttendanceDecisionPayload: Codable, Hashable {
    let accepted: Bool
    let reasonCode: String
    let confidenceBand: String
    let stepUpRequired: Bool
    let reviewTicket: String?
    let matchedPersonID: String?
    let matchScore: Double
    let qualityScore: Double
    let livenessScore: Double
    let geofenceResult: String
    let decisionOrigin: DecisionOrigin

    enum CodingKeys: String, CodingKey {
        case accepted
        case reasonCode = "reason_code"
        case confidenceBand = "confidence_band"
        case stepUpRequired = "step_up_required"
        case reviewTicket = "review_ticket"
        case matchedPersonID = "matched_person_id"
        case matchScore = "match_score"
        case qualityScore = "quality_score"
        case livenessScore = "liveness_score"
        case geofenceResult = "geofence_result"
        case decisionOrigin = "decision_origin"
    }

    var isTransportFailure: Bool {
        reasonCode == "lan_backend_unavailable"
    }

    var statusLabel: String {
        if isTransportFailure { return "LAN Unavailable" }
        if accepted { return "Accepted" }
        if stepUpRequired { return "Review Required" }
        return "Rejected"
    }

    var displayReason: String {
        switch reasonCode {
        case "accepted":
            return "This check-in passed device, face, and policy checks."
        case "outside_geofence":
            return "You are outside the approved work-site area."
        case "mock_location_detected":
            return "The phone reported a simulated location."
        case "untrusted_device":
            return "Device trust needs an extra review step."
        case "outside_attendance_window":
            return "This check-in is outside the configured attendance window."
        case "low_liveness":
            return "Move closer and face the TrueDepth camera directly."
        case "low_quality":
            return "Hold the phone steady and improve framing or lighting."
        case "low_match":
            return "The captured face did not match the enrolled identity."
        case "marginal_match":
            return "The face match is borderline and needs review."
        case "bad_signature":
            return "The request signing check failed."
        case "site_not_found":
            return "The selected work site could not be found."
        case "person_not_found":
            return "The selected identity could not be found."
        case "site_not_allowed":
            return "This identity is not allowed to check in at that site."
        case "lan_backend_unavailable":
            return "The iPhone could not reach the Mac LAN backend. Reconnect to the same Wi-Fi and try again."
        default:
            return reasonCode.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

struct AttendanceEventPayload: Codable, Hashable, Identifiable {
    let id: String
    let createdAt: String
    let tenantID: String
    let personID: String?
    let matchedPersonID: String?
    let personDisplayName: String?
    let matchedPersonDisplayName: String?
    let siteID: String
    let siteLabel: String?
    let claimedIdentityMode: String
    let clientTimestamp: String
    let gps: GPSPayload
    let appVersion: String
    let reasonCode: String
    let accepted: Bool
    let stepUpRequired: Bool
    let qualityScore: Double
    let livenessScore: Double
    let matchScore: Double
    let geofenceResult: String
    let decisionOrigin: DecisionOrigin
    let claimSource: String
    let captureID: String?
    let captureFilePath: String?

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case tenantID = "tenant_id"
        case personID = "person_id"
        case matchedPersonID = "matched_person_id"
        case personDisplayName = "person_display_name"
        case matchedPersonDisplayName = "matched_person_display_name"
        case siteID = "site_id"
        case siteLabel = "site_label"
        case claimedIdentityMode = "claimed_identity_mode"
        case clientTimestamp = "client_timestamp"
        case gps
        case appVersion = "app_version"
        case reasonCode = "reason_code"
        case accepted
        case stepUpRequired = "step_up_required"
        case qualityScore = "quality_score"
        case livenessScore = "liveness_score"
        case matchScore = "match_score"
        case geofenceResult = "geofence_result"
        case decisionOrigin = "decision_origin"
        case claimSource = "claim_source"
        case captureID = "capture_id"
        case captureFilePath = "capture_file_path"
    }

    var statusLabel: String {
        if accepted { return "Accepted" }
        if stepUpRequired { return "Review" }
        return "Rejected"
    }

    var primaryPersonLabel: String {
        personDisplayName ?? personID ?? "Unknown person"
    }

    var matchedPersonLabel: String {
        matchedPersonDisplayName ?? matchedPersonID ?? "No match"
    }

    var primarySiteLabel: String {
        siteLabel ?? siteID
    }

    var displayReason: String {
        AttendanceDecisionPayload(
            accepted: accepted,
            reasonCode: reasonCode,
            confidenceBand: "low",
            stepUpRequired: stepUpRequired,
            reviewTicket: nil,
            matchedPersonID: matchedPersonID,
            matchScore: matchScore,
            qualityScore: qualityScore,
            livenessScore: livenessScore,
            geofenceResult: geofenceResult,
            decisionOrigin: decisionOrigin
        ).displayReason
    }
}

enum BackendReachabilityState: String, Codable, Hashable {
    case unknown
    case reachable
    case unreachable
    case connecting
}

enum LocationPermissionState: String, Codable, Hashable {
    case unknown
    case authorized
    case denied
    case restricted

    var isGranted: Bool {
        self == .authorized
    }
}

struct LocationReading: Codable, Hashable {
    let latitude: Double
    let longitude: Double
    let accuracyM: Double
    let isMocked: Bool
    let recordedAt: Date
}

enum SiteResolutionMode: String, Codable, Hashable {
    case identityRequired
    case noLocation
    case noAllowedSite
    case insideApprovedSite
    case nearestAllowedSite
}

struct SiteSelectionState: Hashable {
    let selectedSiteID: String?
    let presentationTitle: String
    let selectedSiteLabel: String
    let distanceM: Double?
    let insideGeofence: Bool
    let statusText: String
    let resolutionMode: SiteResolutionMode
}

struct CaptureFrameSnapshot: Hashable {
    let faceDetected: Bool
    let qualityScore: Double
    let livenessScore: Double
    let bboxConfidence: Double
    let brightnessScore: Double
    let sharpnessScore: Double
    let hasDepth: Bool
    let depthCoverage: Double
    let depthVariance: Double
    let depthRange: Double
    let depthEvidencePassed: Bool
    let faceCount: Int
    let bbox: BoundingBoxPayload?
    let capturedAt: Date
}

struct CaptureRuntimeStatus: Hashable {
    let mode: String
    let ready: Bool
    let summary: String
    let blockedReason: String?
    let providerManifests: [ProviderManifestPayload]
}

struct DiagnosticsSnapshot: Hashable {
    var appVersion = "ios-student-1.0.0"
    var offlineQueueDepth = 0
    var backendBaseURL = ""
    var configuredLANBackendURL = ""
    var backendReachability: BackendReachabilityState = .unknown
    var transportMode = "LAN Realtime"
    var lanResolutionMode = "fixed_ip"
    var lanReady = false
    var wifiIPv4 = ""
    var canonicalLANURL = ""
    var backendBindHost = ""
    var activeMethodProfileID = "unknown"
    var activeCaptureProfileLabel = "unknown"
    var runtimeMode = "uninitialized"
    var runtimeSummary = "Capture runtime not prepared."
    var cameraStatus = "not_started"
    var cameraActivity = "inactive"
    var locationStatus = "unknown"
    var deviceTrustProvider = "unknown"
    var signingMode = "hmac-sha256-local-secret-v1"
    var activeBootstrapSource = "uninitialized"
    var selectedIdentity = "none"
    var selectedSite = "none"
    var siteResolutionMode = "unknown"
    var syncStatus = SyncStatus.idle.rawValue
    var lastSyncTime: Date?
    var decisionOrigin = "none"
    var lastRequestResult = "idle"
    var lastCapture: CapturePayload?
    var lastError: String?
    var capturePath = "coreml+truedepth"
    var depthPresent = false
    var depthCoverage = 0.0
    var depthVariance = 0.0
    var depthEvidencePassed = false
    var replayEligible = false
    var lastNetworkErrorCategory: String?
    var queueSuppressedReason: String?
}

struct LocalEnrollmentRecord: Codable, Identifiable, Hashable {
    let id: String
    let personDisplayName: String
    let createdAt: Date
    let protectedTemplate: ProtectedTemplatePayload
    var syncStatus: SyncStatus
    var lastSyncError: String?

    init(
        id: String,
        personDisplayName: String,
        createdAt: Date,
        protectedTemplate: ProtectedTemplatePayload,
        syncStatus: SyncStatus = .synced,
        lastSyncError: String? = nil
    ) {
        self.id = id
        self.personDisplayName = personDisplayName
        self.createdAt = createdAt
        self.protectedTemplate = protectedTemplate
        self.syncStatus = syncStatus
        self.lastSyncError = lastSyncError
    }

    enum CodingKeys: String, CodingKey {
        case id
        case personDisplayName
        case createdAt
        case protectedTemplate
        case syncStatus
        case lastSyncError
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        personDisplayName = try container.decode(String.self, forKey: .personDisplayName)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        protectedTemplate = try container.decode(ProtectedTemplatePayload.self, forKey: .protectedTemplate)
        syncStatus = try container.decodeIfPresent(SyncStatus.self, forKey: .syncStatus) ?? .synced
        lastSyncError = try container.decodeIfPresent(String.self, forKey: .lastSyncError)
    }
}

struct QueuedAttendanceClaim: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    let createdAt: Date
    var claim: AttendanceClaimPayload
    var personDisplayName: String
    var siteLabel: String
    var retryCount: Int
    var lastError: String?
    var localEventID: String?
}

struct LocalAttendanceEvent: Codable, Identifiable, Hashable {
    let id: String
    let createdAt: Date
    let tenantID: String
    let personID: String
    let personDisplayName: String
    let siteID: String
    let siteLabel: String
    let reasonCode: String
    let accepted: Bool
    let stepUpRequired: Bool
    let qualityScore: Double
    let livenessScore: Double
    let matchScore: Double
    let geofenceResult: String
    let decisionOrigin: DecisionOrigin
    let claimSource: String
    var syncStatus: LocalHistorySyncState

    init(
        id: String,
        createdAt: Date,
        tenantID: String,
        personID: String,
        personDisplayName: String,
        siteID: String,
        siteLabel: String,
        reasonCode: String,
        accepted: Bool,
        stepUpRequired: Bool,
        qualityScore: Double,
        livenessScore: Double,
        matchScore: Double,
        geofenceResult: String,
        decisionOrigin: DecisionOrigin,
        claimSource: String,
        syncStatus: LocalHistorySyncState
    ) {
        self.id = id
        self.createdAt = createdAt
        self.tenantID = tenantID
        self.personID = personID
        self.personDisplayName = personDisplayName
        self.siteID = siteID
        self.siteLabel = siteLabel
        self.reasonCode = reasonCode
        self.accepted = accepted
        self.stepUpRequired = stepUpRequired
        self.qualityScore = qualityScore
        self.livenessScore = livenessScore
        self.matchScore = matchScore
        self.geofenceResult = geofenceResult
        self.decisionOrigin = decisionOrigin
        self.claimSource = claimSource
        self.syncStatus = syncStatus
    }

    var statusLabel: String {
        if reasonCode == "lan_backend_unavailable" { return "LAN Unavailable" }
        if accepted { return "Accepted" }
        if stepUpRequired { return "Review" }
        return "Rejected"
    }

    var displayReason: String {
        AttendanceDecisionPayload(
            accepted: accepted,
            reasonCode: reasonCode,
            confidenceBand: "low",
            stepUpRequired: stepUpRequired,
            reviewTicket: nil,
            matchedPersonID: personID,
            matchScore: matchScore,
            qualityScore: qualityScore,
            livenessScore: livenessScore,
            geofenceResult: geofenceResult,
            decisionOrigin: decisionOrigin
        ).displayReason
    }

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case tenantID
        case personID
        case personDisplayName
        case siteID
        case siteLabel
        case reasonCode
        case accepted
        case stepUpRequired
        case qualityScore
        case livenessScore
        case matchScore
        case geofenceResult
        case decisionOrigin
        case claimSource
        case syncStatus
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        tenantID = try container.decode(String.self, forKey: .tenantID)
        personID = try container.decode(String.self, forKey: .personID)
        personDisplayName = try container.decode(String.self, forKey: .personDisplayName)
        siteID = try container.decode(String.self, forKey: .siteID)
        siteLabel = try container.decode(String.self, forKey: .siteLabel)
        reasonCode = try container.decode(String.self, forKey: .reasonCode)
        accepted = try container.decode(Bool.self, forKey: .accepted)
        stepUpRequired = try container.decode(Bool.self, forKey: .stepUpRequired)
        qualityScore = try container.decode(Double.self, forKey: .qualityScore)
        livenessScore = try container.decode(Double.self, forKey: .livenessScore)
        matchScore = try container.decode(Double.self, forKey: .matchScore)
        geofenceResult = try container.decode(String.self, forKey: .geofenceResult)
        decisionOrigin = try container.decode(DecisionOrigin.self, forKey: .decisionOrigin)
        claimSource = try container.decode(String.self, forKey: .claimSource)
        syncStatus = try container.decodeIfPresent(LocalHistorySyncState.self, forKey: .syncStatus)
            ?? .localOnly
    }
}

private extension String {
    func hmacSHA256Hex(secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let code = HMAC<SHA256>.authenticationCode(for: Data(utf8), using: key)
        return Data(code).map { String(format: "%02x", $0) }.joined()
    }
}

private func canonicalClaimTimestamp(from date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    return formatter.string(from: date) + "+00:00"
}
