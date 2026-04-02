import Foundation

struct APIHealthPayload: Codable, Hashable {
    let status: String
}

struct EnrollmentSessionPayload: Codable, Hashable {
    let id: String
    let tenantID: String
    let personID: String
    let consentReference: String
    let retentionApproved: Bool
    let status: String

    enum CodingKeys: String, CodingKey {
        case id
        case tenantID = "tenant_id"
        case personID = "person_id"
        case consentReference = "consent_reference"
        case retentionApproved = "retention_approved"
        case status
    }
}

struct EnrollmentSessionCreatePayload: Codable, Hashable {
    let tenantID: String
    let personID: String
    let consentReference: String
    let retentionApproved: Bool

    enum CodingKeys: String, CodingKey {
        case tenantID = "tenant_id"
        case personID = "person_id"
        case consentReference = "consent_reference"
        case retentionApproved = "retention_approved"
    }
}

struct EnrollmentCaptureRequestPayload: Codable, Hashable {
    let captureToken: String
    let protectedTemplate: ProtectedTemplatePayload
    let qualityScore: Double
    let livenessScore: Double
    let bboxConfidence: Double
    let deviceModel: String
    let providerManifests: [ProviderManifestPayload]

    enum CodingKeys: String, CodingKey {
        case captureToken = "capture_token"
        case protectedTemplate = "protected_template"
        case qualityScore = "quality_score"
        case livenessScore = "liveness_score"
        case bboxConfidence = "bbox_confidence"
        case deviceModel = "device_model"
        case providerManifests = "provider_manifests"
    }
}

struct EnrollmentCaptureRecordPayload: Codable, Hashable {
    let captureID: String
    let qualityScore: Double
    let livenessScore: Double
    let bboxConfidence: Double
    let protectedTemplate: ProtectedTemplatePayload

    enum CodingKeys: String, CodingKey {
        case captureID = "capture_id"
        case qualityScore = "quality_score"
        case livenessScore = "liveness_score"
        case bboxConfidence = "bbox_confidence"
        case protectedTemplate = "protected_template"
    }
}

struct EnrollmentFinalizePayload: Codable, Hashable {
    let sessionID: String
    let personID: String
    let templatesCreated: Int

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case personID = "person_id"
        case templatesCreated = "templates_created"
    }
}

struct DemoSessionStartRequestPayload: Codable, Hashable {
    let tenantID: String
    let personID: String
    let gps: GPSPayload

    enum CodingKeys: String, CodingKey {
        case tenantID = "tenant_id"
        case personID = "person_id"
        case gps
    }
}

struct DemoSessionStartResponsePayload: Codable, Hashable {
    let person: RosterIdentity
    let site: WorkSitePayload
    let bootstrap: MobileBootstrapPayload
    let sessionMode: String

    enum CodingKeys: String, CodingKey {
        case person
        case site
        case bootstrap
        case sessionMode = "session_mode"
    }
}

struct DemoServerClearResponsePayload: Codable, Hashable {
    let scope: String
    let clearedEventCount: Int

    enum CodingKeys: String, CodingKey {
        case scope
        case clearedEventCount = "cleared_event_count"
    }
}

struct DeviceLinkClaimRequestPayload: Codable, Hashable {
    let token: String
    let deviceAttestation: DeviceAttestationPayload

    enum CodingKeys: String, CodingKey {
        case token
        case deviceAttestation = "device_attestation"
    }
}

struct DeviceLinkClaimResponsePayload: Codable, Hashable {
    let linkedPerson: RosterIdentity
    let bootstrap: MobileBootstrapPayload
    let linkedAt: String

    enum CodingKeys: String, CodingKey {
        case linkedPerson = "linked_person"
        case bootstrap
        case linkedAt = "linked_at"
    }
}

struct DeviceLinkClearRequestPayload: Codable, Hashable {
    let tenantID: String
    let deviceAttestation: DeviceAttestationPayload

    enum CodingKeys: String, CodingKey {
        case tenantID = "tenant_id"
        case deviceAttestation = "device_attestation"
    }
}

struct DeviceLinkClearResponsePayload: Codable, Hashable {
    let cleared: Bool
    let tenantID: String
    let deviceID: String

    enum CodingKeys: String, CodingKey {
        case cleared
        case tenantID = "tenant_id"
        case deviceID = "device_id"
    }
}

enum AttendanceAPIError: LocalizedError {
    case invalidBaseURL
    case unexpectedStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Configure a valid backend URL before continuing."
        case let .unexpectedStatus(code):
            return "The backend returned HTTP \(code)."
        }
    }
}

struct AttendanceAPIClient {
    func health(baseURL: URL) async throws -> APIHealthPayload {
        let response: APIHealthPayload = try await sendWithoutBody(
            baseURL: baseURL,
            path: "/health",
            method: "GET"
        )
        return response
    }

    func bootstrap(baseURL: URL, tenantID: String, deviceID: String?) async throws -> MobileBootstrapPayload {
        var queryItems = [
            URLQueryItem(name: "tenant_id", value: tenantID),
        ]
        if let deviceID, deviceID.isEmpty == false {
            queryItems.append(URLQueryItem(name: "device_id", value: deviceID))
        }
        let response: MobileBootstrapPayload = try await sendWithoutBody(
            baseURL: baseURL,
            path: "/v1/mobile/bootstrap",
            method: "GET",
            queryItems: queryItems
        )
        return response
    }

    func claimDeviceLink(
        baseURL: URL,
        token: String,
        attestation: DeviceAttestationPayload
    ) async throws -> DeviceLinkClaimResponsePayload {
        try await send(
            baseURL: baseURL,
            path: "/v1/mobile/device-link/claim",
            method: "POST",
            body: DeviceLinkClaimRequestPayload(token: token, deviceAttestation: attestation)
        )
    }

    func clearDeviceLink(
        baseURL: URL,
        tenantID: String,
        attestation: DeviceAttestationPayload
    ) async throws -> DeviceLinkClearResponsePayload {
        try await send(
            baseURL: baseURL,
            path: "/v1/mobile/device-link/clear",
            method: "POST",
            body: DeviceLinkClearRequestPayload(
                tenantID: tenantID,
                deviceAttestation: attestation
            )
        )
    }

    func events(
        baseURL: URL,
        tenantID: String,
        personID: String,
        limit: Int
    ) async throws -> [AttendanceEventPayload] {
        let response: [AttendanceEventPayload] = try await sendWithoutBody(
            baseURL: baseURL,
            path: "/v1/attendance/events",
            method: "GET",
            queryItems: [
                URLQueryItem(name: "tenant_id", value: tenantID),
                URLQueryItem(name: "person_id", value: personID),
                URLQueryItem(name: "limit", value: String(limit)),
            ]
        )
        return response
    }

    func submit(baseURL: URL, claim: AttendanceClaimPayload) async throws -> AttendanceDecisionPayload {
        try await send(baseURL: baseURL, path: "/v1/attendance/claims", method: "POST", body: claim)
    }

    func startDemoSession(
        baseURL: URL,
        tenantID: String,
        personID: String,
        gps: GPSPayload
    ) async throws -> DemoSessionStartResponsePayload {
        try await send(
            baseURL: baseURL,
            path: "/v1/mobile/demo-session/start",
            method: "POST",
            body: DemoSessionStartRequestPayload(
                tenantID: tenantID,
                personID: personID,
                gps: gps
            )
        )
    }

    func clearDemoServerHistory(baseURL: URL, tenantID: String) async throws -> DemoServerClearResponsePayload {
        let response: DemoServerClearResponsePayload = try await sendWithoutBody(
            baseURL: baseURL,
            path: "/v1/demo/control/events/clear",
            method: "POST",
            queryItems: [
                URLQueryItem(name: "tenant_id", value: tenantID),
            ]
        )
        return response
    }

    func createEnrollmentSession(
        baseURL: URL,
        tenantID: String,
        personID: String,
        consentReference: String
    ) async throws -> EnrollmentSessionPayload {
        try await send(
            baseURL: baseURL,
            path: "/v1/enrollment/sessions",
            method: "POST",
            body: EnrollmentSessionCreatePayload(
                tenantID: tenantID,
                personID: personID,
                consentReference: consentReference,
                retentionApproved: true
            )
        )
    }

    func addEnrollmentCapture(
        baseURL: URL,
        sessionID: String,
        request: EnrollmentCaptureRequestPayload
    ) async throws -> EnrollmentCaptureRecordPayload {
        try await send(
            baseURL: baseURL,
            path: "/v1/enrollment/sessions/\(sessionID)/captures",
            method: "POST",
            body: request
        )
    }

    func finalizeEnrollment(baseURL: URL, sessionID: String) async throws -> EnrollmentFinalizePayload {
        let response: EnrollmentFinalizePayload = try await sendWithoutBody(
            baseURL: baseURL,
            path: "/v1/enrollment/sessions/\(sessionID)/finalize",
            method: "POST",
            queryItems: []
        )
        return response
    }

    private func sendWithoutBody<Response: Decodable>(
        baseURL: URL,
        path: String,
        method: String,
        queryItems: [URLQueryItem] = []
    ) async throws -> Response {
        try await send(
            baseURL: baseURL,
            path: path,
            method: method,
            queryItems: queryItems,
            body: Optional<EmptyRequestBody>.none
        )
    }

    private func send<Response: Decodable, RequestBody: Encodable>(
        baseURL: URL,
        path: String,
        method: String,
        queryItems: [URLQueryItem] = [],
        body: RequestBody?
    ) async throws -> Response {
        let url: URL
        if path.hasPrefix("/") {
            guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
                throw AttendanceAPIError.invalidBaseURL
            }
            components.path = path
            if queryItems.isEmpty == false {
                components.queryItems = queryItems
            }
            guard let resolved = components.url else {
                throw AttendanceAPIError.invalidBaseURL
            }
            url = resolved
        } else {
            guard
                let resolved = URL(string: path, relativeTo: baseURL)?.absoluteURL,
                var components = URLComponents(url: resolved, resolvingAgainstBaseURL: false)
            else {
                throw AttendanceAPIError.invalidBaseURL
            }
            if queryItems.isEmpty == false {
                components.queryItems = queryItems
            }
            guard let finalURL = components.url else {
                throw AttendanceAPIError.invalidBaseURL
            }
            url = finalURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AttendanceAPIError.unexpectedStatus(http.statusCode)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}

private struct EmptyRequestBody: Encodable {}
