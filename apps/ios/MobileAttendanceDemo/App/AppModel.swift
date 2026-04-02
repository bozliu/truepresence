import CoreLocation
import Foundation
import Network
import Observation
import UIKit

private enum StoreKey {
    static let settings = "mobile-attendance.settings"
    static let enrollments = "mobile-attendance.local-enrollments"
    static let bootstrapCache = "mobile-attendance.bootstrap-cache"
    static let localHistory = "mobile-attendance.local-history"
    static let liveDemoSession = "mobile-attendance.live-demo-session"
}

private struct LiveBootstrapTarget {
    let source: BootstrapSource
    let url: URL
}

private struct DefaultsStore<Value: Codable> {
    let key: String

    func load(default defaultValue: Value) -> Value {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return defaultValue
        }
        return (try? JSONDecoder().decode(Value.self, from: data)) ?? defaultValue
    }

    func save(_ value: Value) {
        let data = try? JSONEncoder().encode(value)
        UserDefaults.standard.set(data, forKey: key)
    }
}

private final class MobileLocationService: NSObject, CLLocationManagerDelegate {
    var onUpdate: ((LocationPermissionState, LocationReading?) -> Void)?

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
    }

    func currentState() -> LocationPermissionState {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return .authorized
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .unknown
        @unknown default:
            return .unknown
        }
    }

    func requestAccess() {
        manager.requestWhenInUseAuthorization()
    }

    func refreshLocation() {
        guard currentState().isGranted else { return }
        manager.requestLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let state = currentState()
        Task { @MainActor in
            onUpdate?(state, nil)
        }
        if state.isGranted {
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            Task { @MainActor in
                onUpdate?(currentState(), nil)
            }
            return
        }
        let isMocked: Bool
        if #available(iOS 15.0, *) {
            isMocked = location.sourceInformation?.isSimulatedBySoftware ?? false
        } else {
            isMocked = false
        }
        Task { @MainActor in
            onUpdate?(
                currentState(),
                LocationReading(
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    accuracyM: max(location.horizontalAccuracy, 0),
                    isMocked: isMocked,
                    recordedAt: location.timestamp
                )
            )
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            onUpdate?(currentState(), nil)
        }
    }
}

@MainActor
private final class ReachabilityService {
    var onChange: ((BackendReachabilityState) -> Void)?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "mobile-attendance.reachability")

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let state: BackendReachabilityState = path.status == .satisfied ? .reachable : .unreachable
            Task { @MainActor in
                self?.onChange?(state)
            }
        }
        monitor.start(queue: queue)
    }
}

@MainActor
@Observable
final class AppModel {
    var selectedTab: AppTab = .home
    var cameraPermission: CameraPermissionState = .unknown
    var locationPermission: LocationPermissionState = .unknown
    var settings: AppSettings
    var bootstrap: MobileBootstrapPayload?
    var bootstrapSource: BootstrapSource?
    var locationReading: LocationReading?
    var siteSelection = SiteSelectionState(
        selectedSiteID: nil,
        presentationTitle: "Approved Work Site",
        selectedSiteLabel: "Choose a work site",
        distanceM: nil,
        insideGeofence: false,
        statusText: "Location unavailable.",
        resolutionMode: .noLocation
    )
    var statusMessage = "Preparing TruePresence."
    var lastDecision: AttendanceDecisionPayload?
    var successDecision: AttendanceDecisionPayload?
    var recentEvents: [AttendanceEventPayload] = []
    var highlightedServerEventID: String?
    var localEvents: [LocalAttendanceEvent] = []
    var liveDemoSession: LiveDemoSessionState?
    var diagnostics = DiagnosticsSnapshot()
    var queuedClaims: [QueuedAttendanceClaim] = []
    var localEnrollments: [String: LocalEnrollmentRecord]
    var isSubmitting = false
    var isCalibrating = false
    var isBootstrapping = false
    var isRefreshingHistory = false
    var isReplayingQueue = false
    var checkInCameraRequested = false
    var captureRuntimeStatus = CaptureRuntimeStatus(
        mode: "coreml+truedepth",
        ready: false,
        summary: "Capture runtime not prepared.",
        blockedReason: "Camera not started yet.",
        providerManifests: []
    )
    var lastFrameSnapshot: CaptureFrameSnapshot?

    private let api = AttendanceAPIClient()
    private let capturePipeline = CapturePipeline()
    private let cameraPermissionService = CameraPermissionService()
    private let deviceTrustService = DeviceTrustService()
    private let queueStore = OfflineQueueStore()
    private let settingsStore = DefaultsStore<AppSettings>(key: StoreKey.settings)
    private let enrollmentStore = DefaultsStore<[String: LocalEnrollmentRecord]>(key: StoreKey.enrollments)
    private let bootstrapCacheStore = DefaultsStore<BootstrapCachePayload?>(key: StoreKey.bootstrapCache)
    private let localHistoryStore = DefaultsStore<[LocalAttendanceEvent]>(key: StoreKey.localHistory)
    private let liveDemoSessionStore = DefaultsStore<LiveDemoSessionState?>(key: StoreKey.liveDemoSession)
    private let locationService = MobileLocationService()
    private let reachabilityService = ReachabilityService()
    private var sceneIsActive = true

    let cameraPreviewStore = CameraPreviewStore()

    init() {
        settings = settingsStore.load(default: AppSettings())
        localEnrollments = enrollmentStore.load(default: [:])
        localEvents = localHistoryStore.load(default: [])
        liveDemoSession = liveDemoSessionStore.load(default: nil)
        queuedClaims = queueStore.load()
        diagnostics.offlineQueueDepth = queuedClaims.count
        diagnostics.backendBaseURL = displayBackendURLString()
        diagnostics.configuredLANBackendURL = configuredLANBackendURLLabel()
        diagnostics.transportMode = transportModeLabel()
        diagnostics.selectedIdentity = settings.selectedPersonID ?? "none"
        diagnostics.selectedSite = settings.selectedSiteID ?? "none"
        diagnostics.activeBootstrapSource = settings.lastSuccessfulBootstrapSource?.rawValue ?? "uninitialized"
        diagnostics.lastSyncTime = settings.lastSuccessfulBootstrapAt
        diagnostics.syncStatus = queuedClaims.isEmpty ? SyncStatus.idle.rawValue : SyncStatus.pending.rawValue
        diagnostics.capturePath = "truedepth+coreml"
        if queuedClaims.isEmpty, localEvents.contains(where: { $0.syncStatus == .localOnly }) {
            diagnostics.syncStatus = SyncStatus.localOnly.rawValue
        }

        cameraPermission = cameraPermissionService.currentState()
        locationPermission = locationService.currentState()
        locationService.onUpdate = { [weak self] state, reading in
            self?.handleLocationUpdate(state: state, reading: reading)
        }
        reachabilityService.onChange = { [weak self] state in
            self?.handleReachability(state)
        }
        cameraPreviewStore.onStateChange = { [weak self] in
            self?.refreshRuntimeStatus()
        }
        reachabilityService.start()

        if locationPermission.isGranted {
            locationService.refreshLocation()
            diagnostics.locationStatus = "requesting"
        }
        suppressStandaloneQueueIfNeeded()
        updateNetworkDiagnostics()
        refreshRuntimeStatus()
    }

    var allPeople: [RosterIdentity] {
        bootstrap?.people.filter { $0.active } ?? []
    }

    var linkedStudent: RosterIdentity? {
        bootstrap?.linkedPerson
    }

    var activeClassSession: ActiveClassSessionPayload? {
        bootstrap?.activeClassSession
    }

    var permissionsReady: Bool {
        cameraPermission.isGranted && locationPermission.isGranted
    }

    var needsStudentBinding: Bool {
        permissionsReady && linkedStudent == nil
    }

    var hasActiveClassSession: Bool {
        activeClassSession?.active == true
    }

    var isClassroomLANReady: Bool {
        settings.backendMode == .lan
            && diagnostics.backendReachability == .reachable
            && diagnostics.lanReady
    }

    var people: [RosterIdentity] {
        switch settings.backendMode {
        case .lan:
            if let linkedStudent {
                return allPeople.filter { $0.id == linkedStudent.id }
            }
            if let livePersonID = liveDemoSession?.personID {
                return allPeople.filter { $0.id == livePersonID }
            }
            return []
        case .remote, .standaloneDemoAutoFallback:
            return allPeople
        }
    }

    var sites: [WorkSitePayload] {
        bootstrap?.sites ?? []
    }

    var selectedPerson: RosterIdentity? {
        guard let personID = settings.selectedPersonID else { return nil }
        return people.first(where: { $0.id == personID })
    }

    var selectedEnrollment: LocalEnrollmentRecord? {
        guard let personID = settings.selectedPersonID else { return nil }
        return localEnrollments[personID]
    }

    var selectedPersonHasServerEnrollment: Bool {
        guard let person = selectedPerson else { return false }
        return person.templateIDs.isEmpty == false
    }

    var replayEligibility: ReplayEligibility {
        currentReplayEligibility()
    }

    var selectedPersonUsesLiveDemoSession: Bool {
        liveDemoSession?.personID == settings.selectedPersonID
    }

    var selectedPersonCanStartLiveDemo: Bool {
        selectedPerson?.isDemoPerson == true
    }

    var onboardingComplete: Bool {
        permissionsReady && bootstrap != nil && linkedStudent != nil
    }

    var needsCalibration: Bool {
        guard selectedPerson != nil else { return false }
        if settings.backendMode == .lan && selectedPersonHasServerEnrollment {
            return false
        }
        return selectedEnrollment == nil
    }

    var isCheckInCameraLive: Bool {
        cameraPreviewStore.isRunning
    }

    var canOpenCameraFlow: Bool {
        onboardingComplete
            && hasActiveClassSession
            && isClassroomLANReady
            && selectedPerson != nil
    }

    var canSubmit: Bool {
        canOpenCameraFlow
            && captureRuntimeStatus.ready
            && (selectedEnrollment != nil || (settings.backendMode == .lan && selectedPersonHasServerEnrollment))
            && siteSelection.selectedSiteID != nil
            && (settings.backendMode != .lan || shouldAttemptServerSubmission())
            && isSubmitting == false
    }

    func ensureBootstrapIfPossible(force: Bool = false) async {
        guard cameraPermission.isGranted, locationPermission.isGranted else { return }
        guard isBootstrapping == false else { return }
        if bootstrap != nil, force == false, bootstrapSource == .remote || bootstrapSource == .lan {
            let shouldRefreshStaleLANClassroomState =
                settings.backendMode == .lan
                && linkedStudent != nil
                && (activeClassSession == nil || isClassroomLANReady == false)
            if shouldRefreshStaleLANClassroomState == false {
                return
            }
        }
        await refreshBootstrap()
    }

    func initialize() async {
        if cameraPermission == .unknown {
            await requestCameraAccess()
        }

        if cameraPermission.isGranted, locationPermission == .unknown {
            await requestLocationAccess()
        }

        await refreshBootstrap()
        await refreshHistory()
        await syncPendingEnrollmentsIfPossible()
        await replayQueuedClaimsIfPossible()
        refreshRuntimeStatus()
    }

    func requestCameraAccess() async {
        let nextState: CameraPermissionState
        if cameraPermission == .unknown {
            nextState = await cameraPermissionService.requestAccess()
        } else {
            nextState = cameraPermissionService.currentState()
        }
        cameraPermission = nextState
        if nextState.isGranted {
            diagnostics.cameraStatus = cameraPreviewStore.deviceName
            statusMessage = "Front camera permission granted. The camera stays off until you start capture on Check-In."
        } else {
            cameraPreviewStore.stop()
            diagnostics.cameraStatus = "permission_denied"
            statusMessage = "Camera access is required before face verification can begin."
        }
        refreshRuntimeStatus()
        syncCameraSession()
        if nextState.isGranted, locationPermission.isGranted {
            await ensureBootstrapIfPossible()
        }
    }

    func requestLocationAccess() async {
        locationService.requestAccess()
        locationPermission = locationService.currentState()
        diagnostics.locationStatus = locationPermission.rawValue
        if locationPermission.isGranted {
            locationService.refreshLocation()
            await ensureBootstrapIfPossible()
        }
    }

    func refreshBootstrap() async {
        isBootstrapping = true
        diagnostics.lastError = nil
        diagnostics.lastNetworkErrorCategory = nil
        diagnostics.backendReachability = .connecting
        defer { isBootstrapping = false }

        for target in liveBootstrapTargets() {
            do {
                let _ = try await api.health(baseURL: target.url)
                let payload = try await api.bootstrap(
                    baseURL: target.url,
                    tenantID: settings.selectedTenantID,
                    deviceID: deviceTrustService.currentDeviceID()
                )
                applyBootstrap(
                    payload,
                    source: target.source,
                    backendURL: target.url.absoluteString,
                    fetchedAt: .now
                )
                diagnostics.backendReachability = .reachable
                diagnostics.lastError = nil
                diagnostics.lastRequestResult = "bootstrap_loaded"
                statusMessage = if settings.backendMode == .lan && linkedStudent == nil {
                    "Classroom LAN is ready. Scan the teacher QR code to link this iPhone to a student."
                } else if settings.backendMode == .lan && activeClassSession == nil {
                    "Student linked. Waiting for the teacher to start the current class session."
                } else if settings.backendMode == .lan && selectedPersonHasServerEnrollment == false {
                    "Student linked. The teacher still needs to enroll the reference face on the Mac."
                } else if selectedEnrollment == nil && settings.backendMode != .lan {
                    "Identity ready. Calibrate your face once on this iPhone."
                } else {
                    "Ready for classroom check-in."
                }
                return
            } catch {
                diagnostics.lastError = error.localizedDescription
                diagnostics.lastNetworkErrorCategory = networkErrorCategory(for: error)
            }
        }

        diagnostics.backendReachability = .unreachable

        if settings.backendMode == .lan {
            if let cached = bootstrapCacheStore.load(default: nil), cached.source == .lan {
                applyBootstrap(
                    cached.payload,
                    source: .cache,
                    backendURL: cached.backendURL,
                    fetchedAt: cached.fetchedAt,
                    persistCache: false
                )
                diagnostics.lastRequestResult = "bootstrap_cached_lan_loaded"
                statusMessage = "LAN backend unavailable. Showing cached LAN data only. Reconnect to the same Wi-Fi before submitting."
                return
            }

            diagnostics.lastRequestResult = "bootstrap_lan_unavailable"
            statusMessage = "LAN backend unavailable. Keep the iPhone and Mac on the same Wi-Fi and use the fixed Mac Wi-Fi IP from the Mac console."
            updateNetworkDiagnostics()
            return
        }

        if let cached = bootstrapCacheStore.load(default: nil) {
            applyBootstrap(
                cached.payload,
                source: .cache,
                backendURL: cached.backendURL,
                fetchedAt: cached.fetchedAt,
                persistCache: false
            )
            diagnostics.lastRequestResult = "bootstrap_cache_loaded"
            statusMessage = liveDemoSession == nil
                ? "Backend unavailable. Using cached classroom data on this iPhone. Reconnect to the teacher Mac before check-in."
                : "Backend unavailable. Using cached roster and policy on this iPhone."
            return
        }

        if let bundled = loadBundledDemoBootstrap() {
            applyBootstrap(
                bundled,
                source: .bundledDemo,
                backendURL: nil,
                fetchedAt: .now,
                persistCache: false
            )
            diagnostics.lastRequestResult = "bootstrap_bundled_demo_loaded"
            statusMessage = liveDemoSession == nil
                ? "Backend unavailable. Using bundled classroom bootstrap data. Reconnect to the teacher Mac before check-in."
                : "Backend unavailable. Using bundled classroom bootstrap data."
            return
        }

        bootstrap = nil
        bootstrapSource = nil
        diagnostics.lastRequestResult = "bootstrap_failed"
        statusMessage = "No backend, cache, or bundled classroom bootstrap is available."
    }

    func refreshHistory() async {
        guard let personID = settings.selectedPersonID else {
            recentEvents = []
            highlightedServerEventID = nil
            return
        }
        guard let baseURL = configuredLiveBackendURL() else {
            if settings.backendMode != .lan {
                recentEvents = []
                highlightedServerEventID = nil
            }
            return
        }
        guard diagnostics.backendReachability == .reachable else {
            if settings.backendMode != .lan {
                recentEvents = []
                highlightedServerEventID = nil
            }
            return
        }
        isRefreshingHistory = true
        defer { isRefreshingHistory = false }
        do {
            recentEvents = try await api.events(
                baseURL: baseURL,
                tenantID: settings.selectedTenantID,
                personID: personID,
                limit: 20
            )
            if highlightedServerEventID == nil {
                highlightedServerEventID = recentEvents.first?.id
            }
        } catch {
            diagnostics.lastError = error.localizedDescription
        }
    }

    func claimDeviceBinding(qrPayload: String) async {
        guard let baseURL = configuredLiveBackendURL() else {
            statusMessage = "Classroom LAN backend is not configured yet."
            return
        }
        diagnostics.lastError = nil
        diagnostics.lastRequestResult = "device_binding_claiming"
        statusMessage = "Binding this iPhone to the selected student."

        do {
            let attestation = try await deviceTrustService.attestation()
            let response = try await api.claimDeviceLink(
                baseURL: baseURL,
                token: qrPayload,
                attestation: attestation
            )
            successDecision = nil
            highlightedServerEventID = nil
            applyBootstrap(
                response.bootstrap,
                source: .lan,
                backendURL: baseURL.absoluteString,
                fetchedAt: .now
            )
            diagnostics.lastRequestResult = "device_binding_ready"
            statusMessage = "\(response.linkedPerson.displayName) is now linked to this iPhone."
            await refreshHistory()
        } catch {
            diagnostics.lastError = error.localizedDescription
            diagnostics.lastRequestResult = "device_binding_failed"
            statusMessage = "Binding failed. Make sure the QR code is still valid and the Mac console is reachable."
        }
    }

    func clearDeviceBinding() async {
        guard let baseURL = configuredLiveBackendURL() else {
            settings.selectedPersonID = nil
            settingsStore.save(settings)
            bootstrap = nil
            statusMessage = "Student link cleared on this iPhone."
            return
        }

        do {
            let attestation = try await deviceTrustService.attestation()
            _ = try await api.clearDeviceLink(
                baseURL: baseURL,
                tenantID: settings.selectedTenantID,
                attestation: attestation
            )
            settings.selectedPersonID = nil
            settingsStore.save(settings)
            recentEvents = []
            highlightedServerEventID = nil
            await refreshBootstrap()
            diagnostics.lastRequestResult = "device_binding_cleared"
            statusMessage = "This iPhone is no longer bound to a student."
        } catch {
            diagnostics.lastError = error.localizedDescription
            diagnostics.lastRequestResult = "device_binding_clear_failed"
            statusMessage = "Could not clear the student binding on the Mac backend."
        }
    }

    func selectPerson(_ personID: String?) async {
        if settings.backendMode == .lan, let linkedStudent {
            settings.selectedPersonID = linkedStudent.id
            settingsStore.save(settings)
            diagnostics.selectedIdentity = linkedStudent.id
            highlightedServerEventID = nil
            updateSiteSelection()
            await refreshHistory()
            return
        }
        let candidatePersonID = personID?.isEmpty == false ? personID : nil
        let normalizedPersonID =
            candidatePersonID.flatMap { candidate in
                people.contains(where: { $0.id == candidate }) ? candidate : nil
            }
        settings.selectedPersonID = normalizedPersonID
        settingsStore.save(settings)
        diagnostics.selectedIdentity = normalizedPersonID ?? "none"
        highlightedServerEventID = nil
        updateSiteSelection()
        await refreshHistory()
    }

    func startLiveDemoSession() async {
        guard let person = selectedPerson else {
            statusMessage = "Choose the teacher-created student record first."
            return
        }
        guard person.isDemoPerson else {
            statusMessage = "The classroom session can only be started for students created on the teacher Mac."
            return
        }
        guard let locationReading else {
            statusMessage = "Current location is required before the classroom site can be created."
            return
        }

        diagnostics.lastError = nil
        diagnostics.lastRequestResult = "demo_session_starting"
        statusMessage = "Binding \(person.displayName) to the current classroom location."

        if let baseURL = configuredLiveBackendURL(), diagnostics.backendReachability == .reachable {
            do {
                let response = try await api.startDemoSession(
                    baseURL: baseURL,
                    tenantID: settings.selectedTenantID,
                    personID: person.id,
                    gps: GPSPayload(
                        latitude: locationReading.latitude,
                        longitude: locationReading.longitude,
                        accuracyM: locationReading.accuracyM,
                        isMocked: locationReading.isMocked
                    )
                )
                let source = liveBootstrapTargets().first?.source ?? .remote
                let session = LiveDemoSessionState(
                    displayName: response.person.displayName,
                    personID: response.person.id,
                    employeeCode: response.person.employeeCode,
                    siteID: response.site.id,
                    siteLabel: response.site.label,
                    latitude: response.site.latitude,
                    longitude: response.site.longitude,
                    radiusM: response.site.radiusM,
                    source: source,
                    syncedToBackend: true,
                    updatedAt: .now
                )
                liveDemoSession = session
                liveDemoSessionStore.save(session)
                applyBootstrap(
                    response.bootstrap,
                    source: source,
                    backendURL: baseURL.absoluteString,
                    fetchedAt: .now
                )
                diagnostics.lastRequestResult = "demo_session_live_ready"
                diagnostics.lastError = nil
                statusMessage = "Classroom site is ready. Start TrueDepth capture and submit check-in."
                await refreshHistory()
                return
            } catch {
                diagnostics.lastError = error.localizedDescription
            }
        }

        let session = makeLocalLiveDemoSession(person: person, location: locationReading)
        liveDemoSession = session
        liveDemoSessionStore.save(session)
        if let bootstrap {
            applyBootstrap(
                bootstrap,
                source: bootstrapSource ?? .bundledDemo,
                backendURL: configuredLiveBackendURL()?.absoluteString,
                fetchedAt: .now,
                persistCache: false
            )
        } else if let bundled = loadBundledDemoBootstrap() {
            applyBootstrap(
                bundled,
                source: .bundledDemo,
                backendURL: nil,
                fetchedAt: .now,
                persistCache: false
            )
        }
        diagnostics.lastRequestResult = "demo_session_local_ready"
        diagnostics.lastError = nil
        statusMessage = "A local classroom session is ready on this iPhone."
    }

    func updateBackendBaseURL(_ value: String) async {
        switch settings.backendMode {
        case .remote, .standaloneDemoAutoFallback:
            settings.remoteBackendBaseURLString = value
        case .lan:
            settings.lanBackendBaseURLString = value
        }
        settingsStore.save(settings)
        updateNetworkDiagnostics()
        suppressStandaloneQueueIfNeeded()
        await refreshBootstrap()
        await syncPendingEnrollmentsIfPossible()
        await replayQueuedClaimsIfPossible()
        await refreshHistory()
    }

    func updateBackendConfiguration(
        mode: AppBackendMode,
        remoteURL: String,
        lanURL: String
    ) async {
        settings.backendMode = mode
        settings.remoteBackendBaseURLString = remoteURL
        settings.lanBackendBaseURLString = lanURL
        settingsStore.save(settings)
        updateNetworkDiagnostics()
        suppressStandaloneQueueIfNeeded()
        await refreshBootstrap()
        await syncPendingEnrollmentsIfPossible()
        await replayQueuedClaimsIfPossible()
        await refreshHistory()
    }

    func setBackendMode(_ mode: AppBackendMode) async {
        settings.backendMode = mode
        settingsStore.save(settings)
        updateNetworkDiagnostics()
        suppressStandaloneQueueIfNeeded()
        await refreshBootstrap()
        await syncPendingEnrollmentsIfPossible()
        await replayQueuedClaimsIfPossible()
        await refreshHistory()
    }

    func setSelectedTab(_ tab: AppTab) {
        selectedTab = tab
        syncCameraSession()
        refreshRuntimeStatus()
        if tab == .history {
            Task {
                await refreshHistory()
            }
        }
    }

    func setSceneIsActive(_ isActive: Bool) {
        sceneIsActive = isActive
        if isActive == false {
            checkInCameraRequested = false
        }
        syncCameraSession()
        refreshRuntimeStatus()
    }

    func activateCheckInCamera() {
        guard onboardingComplete else {
            statusMessage = "Finish camera, location, and identity setup before starting live capture."
            return
        }
        checkInCameraRequested = true
        syncCameraSession()
        refreshRuntimeStatus()
    }

    func stopCheckInCamera() {
        checkInCameraRequested = false
        syncCameraSession()
        refreshRuntimeStatus()
    }

    func submitCheckIn() async {
        guard let person = selectedPerson else {
            statusMessage = "Choose your identity before check-in."
            return
        }
        guard let siteID = siteSelection.selectedSiteID else {
            statusMessage = "A work site is required before check-in."
            return
        }
        guard let location = locationReading else {
            statusMessage = "Current location is not available yet."
            return
        }
        let allowsServerOnlyRecognition = settings.backendMode == .lan && selectedPersonHasServerEnrollment
        let enrollment = selectedEnrollment
        guard enrollment != nil || allowsServerOnlyRecognition else {
            statusMessage = "Calibrate your face on this iPhone before the first secure check-in."
            return
        }
        isSubmitting = true
        lastDecision = nil
        successDecision = nil
        diagnostics.lastError = nil
        diagnostics.lastRequestResult = "submitting_check_in"
        defer { isSubmitting = false }
        refreshRuntimeStatus()
        var pendingClaim: AttendanceClaimPayload?

        do {
            let capture: CapturePayload
            let captureTemplate: ProtectedTemplatePayload
            let faceImageBase64: String
            let localMatchScore: Double

            if let enrollment {
                let verification = try capturePipeline.verify(
                    previewStore: cameraPreviewStore,
                    enrolledTemplate: enrollment.protectedTemplate
                )
                lastFrameSnapshot = verification.frameSnapshot
                diagnostics.lastCapture = verification.capture
                capture = verification.capture
                captureTemplate = verification.protectedTemplate
                faceImageBase64 = verification.faceImageBase64
                localMatchScore = verification.matchScore
            } else {
                let calibration = try capturePipeline.calibrate(previewStore: cameraPreviewStore)
                lastFrameSnapshot = calibration.frameSnapshot
                diagnostics.lastCapture = calibration.capture
                capture = calibration.capture
                captureTemplate = calibration.protectedTemplate
                faceImageBase64 = calibration.faceImageBase64
                localMatchScore = 0.0
            }
            let attestation = try await deviceTrustService.attestation()
            let shouldAttemptServer = shouldAttemptServerSubmission()
            if settings.backendMode == .lan && shouldAttemptServer == false {
                handleLANBackendUnavailable(detail: "LAN backend unavailable")
                return
            }
            let prefersServerFaceMatching = settings.backendMode == .lan && selectedPersonHasServerEnrollment
            let claimSource = shouldAttemptServer
                ? "server_live"
                : (replayEligibility.isEligible ? "local_demo_replay" : "local_demo_local_only")
            let claim = AttendanceClaimPayload.makeDemoClaim(
                tenantID: settings.selectedTenantID,
                personID: person.id,
                siteID: siteID,
                latitude: location.latitude,
                longitude: location.longitude,
                accuracyM: location.accuracyM,
                appVersion: diagnostics.appVersion,
                capture: capture,
                faceImageBase64: shouldAttemptServer ? faceImageBase64 : nil,
                protectedTemplate: prefersServerFaceMatching ? nil : captureTemplate,
                depthEvidence: lastFrameSnapshot.map {
                    DepthEvidenceSnapshot(
                        hasDepth: $0.hasDepth,
                        coverage: $0.depthCoverage,
                        variance: $0.depthVariance,
                        range: $0.depthRange,
                        passed: $0.depthEvidencePassed
                    )
                },
                attestation: attestation,
                claimSource: claimSource
            )
            pendingClaim = claim
            if shouldAttemptServer, let baseURL = configuredLiveBackendURL() {
                do {
                    let decision = try await api.submit(baseURL: baseURL, claim: claim)
                    lastDecision = decision
                    diagnostics.lastError = nil
                    diagnostics.lastNetworkErrorCategory = nil
                    diagnostics.lastRequestResult = decision.accepted
                        ? "check_in_accepted"
                        : (decision.stepUpRequired ? "check_in_review" : "check_in_rejected")
                    diagnostics.decisionOrigin = decision.decisionOrigin.rawValue
                    statusMessage = decision.accepted
                        ? "Attendance accepted for \(person.displayName)."
                        : decision.displayReason
                    await refreshHistory()
                    if recentEvents.isEmpty {
                        try? await Task.sleep(for: .milliseconds(250))
                        await refreshHistory()
                    }
                    highlightedServerEventID = recentEvents.first?.id
                    if decision.accepted {
                        successDecision = decision
                    } else {
                        selectedTab = .history
                    }
                    syncCameraSession()
                    refreshRuntimeStatus()
                    return
                } catch {
                    if settings.backendMode == .lan {
                        handleLANBackendUnavailable(detail: error.localizedDescription)
                        return
                    }
                    if error is URLError {
                        diagnostics.lastError = error.localizedDescription
                        diagnostics.lastNetworkErrorCategory = networkErrorCategory(for: error)
                    } else {
                        throw error
                    }
                }
            }

            let localDecision = makeLocalDemoDecision(
                person: person,
                verification: VerificationCaptureResult(
                    capture: capture,
                    frameSnapshot: lastFrameSnapshot ?? CaptureFrameSnapshot(
                        faceDetected: false,
                        qualityScore: 0,
                        livenessScore: 0,
                        bboxConfidence: 0,
                        brightnessScore: 0,
                        sharpnessScore: 0,
                        hasDepth: false,
                        depthCoverage: 0,
                        depthVariance: 0,
                        depthRange: 0,
                        depthEvidencePassed: false,
                        faceCount: 0,
                        bbox: nil,
                        capturedAt: .now
                    ),
                    protectedTemplate: captureTemplate,
                    faceImageBase64: faceImageBase64,
                    matchScore: localMatchScore
                ),
                attestation: attestation,
                location: location,
                siteID: siteID
            )
            lastDecision = localDecision
            successDecision = localDecision.accepted ? localDecision : nil
            diagnostics.lastError = nil
            diagnostics.lastRequestResult = localDecision.accepted
                ? "local_demo_check_in_accepted"
                : (localDecision.stepUpRequired ? "local_demo_check_in_review" : "local_demo_check_in_rejected")
            diagnostics.decisionOrigin = localDecision.decisionOrigin.rawValue
            statusMessage = localDecision.accepted
                ? "Local demo check-in accepted for \(person.displayName)."
                : localDecision.displayReason
            let localEvent = recordLocalAttendanceEvent(
                person: person,
                siteLabel: siteSelection.selectedSiteLabel,
                decision: localDecision,
                claimSource: claim.claimSource,
                syncState: replayEligibility.isEligible ? .queued : .localOnly
            )
            if replayEligibility.isEligible {
                queueClaimForReplay(
                    claim: claim,
                    error: URLError(.notConnectedToInternet),
                    personDisplayName: person.displayName,
                    siteLabel: siteSelection.selectedSiteLabel,
                    localEventID: localEvent.id
                )
            } else {
                diagnostics.queueSuppressedReason = replayEligibility.reason
                diagnostics.syncStatus = SyncStatus.localOnly.rawValue
            }
        } catch {
            diagnostics.lastError = error.localizedDescription
            diagnostics.lastRequestResult = lastRequestResult(for: error)
            if let personName = selectedPerson?.displayName,
               let pendingClaim,
               shouldQueueClaim(for: error)
            {
                let replayEligibility = currentReplayEligibility()
                if replayEligibility.isEligible {
                    statusMessage = "Saved locally. The app will retry this check-in when the backend is reachable."
                    queueClaimForReplay(
                        claim: pendingClaim,
                        error: error,
                        personDisplayName: personName,
                        siteLabel: siteSelection.selectedSiteLabel,
                        localEventID: nil
                    )
                } else {
                    diagnostics.queueSuppressedReason = replayEligibility.reason
                    statusMessage = userFacingSubmissionMessage(for: error)
                }
            } else {
                statusMessage = userFacingSubmissionMessage(for: error)
            }
        }
    }

    func calibrateSelectedPersona() async {
        guard let person = selectedPerson else {
            statusMessage = "Choose your identity before calibration."
            return
        }
        isCalibrating = true
        diagnostics.lastError = nil
        diagnostics.lastRequestResult = "calibrating_identity"
        defer { isCalibrating = false }
        refreshRuntimeStatus()

        do {
            let calibration = try capturePipeline.calibrate(previewStore: cameraPreviewStore)
            let record = LocalEnrollmentRecord(
                id: person.id,
                personDisplayName: person.displayName,
                createdAt: .now,
                protectedTemplate: calibration.protectedTemplate,
                syncStatus: shouldAttemptLiveSubmission() ? .pending : .localOnly
            )
            localEnrollments[person.id] = record
            enrollmentStore.save(localEnrollments)
            diagnostics.lastCapture = calibration.capture
            diagnostics.lastError = nil

            if shouldAttemptLiveSubmission(), let baseURL = configuredLiveBackendURL() {
                let syncedRecord = try await syncEnrollmentRecord(record, for: person, baseURL: baseURL)
                localEnrollments[person.id] = syncedRecord
                enrollmentStore.save(localEnrollments)
                diagnostics.lastRequestResult = "calibration_saved"
                diagnostics.syncStatus = syncedRecord.syncStatus.rawValue
                diagnostics.lastSyncTime = .now
                statusMessage = "Calibration saved for \(person.displayName). You can check in now."
            } else {
                diagnostics.lastRequestResult = "calibration_saved_local_only"
                diagnostics.syncStatus = SyncStatus.localOnly.rawValue
                statusMessage = "Calibration saved on this iPhone. This identity is ready for local live verification."
            }
        } catch {
            diagnostics.lastError = error.localizedDescription
            diagnostics.lastRequestResult = "calibration_failed"
            statusMessage = "Calibration failed: \(error.localizedDescription)"
        }
    }

    func clearCalibrationForSelectedPersona() {
        guard let personID = settings.selectedPersonID else { return }
        localEnrollments.removeValue(forKey: personID)
        enrollmentStore.save(localEnrollments)
        statusMessage = "Local calibration cleared for the selected identity."
    }

    func clearAllLocalHistory() {
        localEvents.removeAll()
        localHistoryStore.save(localEvents)
        statusMessage = "Local history cleared on this iPhone."
        diagnostics.syncStatus = recentEvents.isEmpty ? SyncStatus.idle.rawValue : SyncStatus.synced.rawValue
    }

    func clearHighlightedServerEvent() {
        highlightedServerEventID = nil
    }

    func acknowledgeSuccessDecision() {
        successDecision = nil
        selectedTab = .history
        highlightedServerEventID = recentEvents.first?.id ?? highlightedServerEventID
        syncCameraSession()
        refreshRuntimeStatus()
    }

    func clearDemoServerHistory() async {
        guard settings.backendMode == .lan else {
            statusMessage = "Server history can only be cleared in LAN realtime mode."
            return
        }
        guard let baseURL = configuredLiveBackendURL(), diagnostics.backendReachability == .reachable else {
            statusMessage = "LAN backend unavailable. Reconnect to the Mac backend first."
            return
        }
        do {
            _ = try await api.clearDemoServerHistory(baseURL: baseURL, tenantID: settings.selectedTenantID)
            recentEvents = []
            highlightedServerEventID = nil
            diagnostics.lastRequestResult = "server_history_cleared"
            statusMessage = "Classroom history cleared on the Mac backend."
        } catch {
            diagnostics.lastError = error.localizedDescription
            diagnostics.lastRequestResult = "server_history_clear_failed"
            statusMessage = "Could not clear classroom history."
        }
    }

    func clearQueue() {
        queuedClaims.removeAll()
        queueStore.save(queuedClaims)
        diagnostics.offlineQueueDepth = 0
        diagnostics.syncStatus = localEvents.contains(where: { $0.syncStatus == .localOnly })
            ? SyncStatus.localOnly.rawValue
            : SyncStatus.idle.rawValue
        diagnostics.queueSuppressedReason = currentReplayEligibility().reason
        statusMessage = "Pending queue cleared."
    }

    func resetLiveDemoSession() async {
        liveDemoSession = nil
        liveDemoSessionStore.save(nil)
        if let bootstrap {
            applyBootstrap(
                bootstrap,
                source: bootstrapSource ?? .bundledDemo,
                backendURL: configuredLiveBackendURL()?.absoluteString,
                fetchedAt: .now,
                persistCache: false
            )
        }
        await refreshHistory()
        statusMessage = "Classroom session cache reset."
    }

    func clearAllLocalDemoData() async {
        clearQueue()
        clearAllLocalHistory()
        localEnrollments.removeAll()
        enrollmentStore.save(localEnrollments)
        await resetLiveDemoSession()
        statusMessage = "Local history, queue, calibration, and classroom session cache were cleared."
    }

    func replayQueuedClaimsIfPossible() async {
        guard diagnostics.backendReachability == .reachable else { return }
        guard let baseURL = configuredLiveBackendURL() else { return }
        guard queuedClaims.isEmpty == false else {
            diagnostics.syncStatus = localEvents.contains(where: { $0.syncStatus == .localOnly })
                ? SyncStatus.localOnly.rawValue
                : SyncStatus.synced.rawValue
            return
        }

        isReplayingQueue = true
        defer { isReplayingQueue = false }

        var surviving: [QueuedAttendanceClaim] = []
        for var queued in queuedClaims {
            do {
                _ = try await api.submit(baseURL: baseURL, claim: queued.claim)
                markLocalEventSynced(queued.localEventID)
            } catch {
                queued.retryCount += 1
                queued.lastError = error.localizedDescription
                markLocalEventFailed(queued.localEventID)
                surviving.append(queued)
            }
        }

        queuedClaims = surviving
        queueStore.save(queuedClaims)
        diagnostics.offlineQueueDepth = queuedClaims.count
        diagnostics.syncStatus = queuedClaims.isEmpty
            ? (localEvents.contains(where: { $0.syncStatus == .localOnly })
                ? SyncStatus.localOnly.rawValue
                : SyncStatus.synced.rawValue)
            : SyncStatus.pending.rawValue
        diagnostics.lastSyncTime = .now
    }

    private func queueClaimForReplay(
        claim: AttendanceClaimPayload,
        error: Error,
        personDisplayName: String,
        siteLabel: String,
        localEventID: String?
    ) {
        let queued = QueuedAttendanceClaim(
            createdAt: .now,
            claim: claim,
            personDisplayName: personDisplayName,
            siteLabel: siteLabel,
            retryCount: 0,
            lastError: error.localizedDescription,
            localEventID: localEventID
        )
        queuedClaims.insert(queued, at: 0)
        queueStore.save(queuedClaims)
        diagnostics.offlineQueueDepth = queuedClaims.count
        diagnostics.syncStatus = SyncStatus.pending.rawValue
    }

    private func handleReachability(_ state: BackendReachabilityState) {
        guard state == .reachable else {
            diagnostics.backendReachability = .unreachable
            return
        }

        diagnostics.backendReachability = .connecting
        Task {
            await verifyConfiguredBackendReachability()
        }
    }

    private func verifyConfiguredBackendReachability() async {
        guard let baseURL = configuredLiveBackendURL() else {
            diagnostics.backendReachability = settings.backendMode == .lan ? .unreachable : .unknown
            return
        }

        do {
            let _ = try await api.health(baseURL: baseURL)
            diagnostics.backendReachability = .reachable
            diagnostics.lastError = nil
            diagnostics.lastNetworkErrorCategory = nil
            await ensureBootstrapIfPossible(force: true)
            await syncPendingEnrollmentsIfPossible()
            await replayQueuedClaimsIfPossible()
            await refreshHistory()
        } catch {
            diagnostics.backendReachability = .unreachable
            diagnostics.lastError = error.localizedDescription
            diagnostics.lastNetworkErrorCategory = networkErrorCategory(for: error)
        }
    }

    private func handleLocationUpdate(state: LocationPermissionState, reading: LocationReading?) {
        locationPermission = state
        diagnostics.locationStatus = state.rawValue
        if let reading {
            locationReading = reading
        }
        updateSiteSelection()
        if state.isGranted {
            Task {
                await ensureBootstrapIfPossible()
            }
        }
    }

    private func updateSiteSelection() {
        diagnostics.selectedIdentity = settings.selectedPersonID ?? "none"
        guard let person = selectedPerson else {
            let emptyStateText = settings.backendMode == .lan
                ? "Scan the teacher QR code to link this iPhone to a student first."
                : "Choose your identity to load the approved site list."
            siteSelection = SiteSelectionState(
                selectedSiteID: nil,
                presentationTitle: "Classroom",
                selectedSiteLabel: "No linked student",
                distanceM: nil,
                insideGeofence: false,
                statusText: emptyStateText,
                resolutionMode: .identityRequired
            )
            diagnostics.selectedSite = "none"
            diagnostics.siteResolutionMode = SiteResolutionMode.identityRequired.rawValue
            return
        }

        if let activeClassSession {
            let classSite = sites.first(where: { $0.id == activeClassSession.siteID })
            guard let classSite else {
                siteSelection = SiteSelectionState(
                    selectedSiteID: nil,
                    presentationTitle: "Classroom Session",
                    selectedSiteLabel: activeClassSession.classLabel,
                    distanceM: nil,
                    insideGeofence: false,
                    statusText: "The active classroom site is not available in the latest bootstrap payload.",
                    resolutionMode: .noAllowedSite
                )
                diagnostics.selectedSite = activeClassSession.siteLabel
                diagnostics.siteResolutionMode = SiteResolutionMode.noAllowedSite.rawValue
                return
            }

            guard let locationReading else {
                siteSelection = SiteSelectionState(
                    selectedSiteID: classSite.id,
                    presentationTitle: "Classroom Session",
                    selectedSiteLabel: classSite.label,
                    distanceM: nil,
                    insideGeofence: false,
                    statusText: "Location is still loading before classroom verification can begin.",
                    resolutionMode: .noLocation
                )
                settings.selectedSiteID = classSite.id
                settingsStore.save(settings)
                diagnostics.selectedSite = classSite.label
                diagnostics.siteResolutionMode = SiteResolutionMode.noLocation.rawValue
                return
            }

            let distance = haversineMeters(
                latitude1: locationReading.latitude,
                longitude1: locationReading.longitude,
                latitude2: classSite.latitude,
                longitude2: classSite.longitude
            )
            let inside = distance <= classSite.radiusM
            siteSelection = SiteSelectionState(
                selectedSiteID: classSite.id,
                presentationTitle: inside ? "Classroom Ready" : "Classroom Site",
                selectedSiteLabel: classSite.label,
                distanceM: distance,
                insideGeofence: inside,
                statusText: inside
                    ? "You are inside the active classroom site for \(activeClassSession.classLabel)."
                    : "Move closer to the configured classroom area before checking in.",
                resolutionMode: inside ? .insideApprovedSite : .nearestAllowedSite
            )
            settings.selectedSiteID = classSite.id
            settingsStore.save(settings)
            diagnostics.selectedSite = classSite.label
            diagnostics.siteResolutionMode = inside
                ? SiteResolutionMode.insideApprovedSite.rawValue
                : SiteResolutionMode.nearestAllowedSite.rawValue
            return
        }

        let allowedSites = sites.filter { person.siteIDs.contains($0.id) || person.siteIDs.isEmpty }
        guard let firstSite = nearestSite(from: allowedSites, for: locationReading) ?? allowedSites.first else {
            siteSelection = SiteSelectionState(
                selectedSiteID: nil,
                presentationTitle: "Approved Work Site",
                selectedSiteLabel: "No allowed site",
                distanceM: nil,
                insideGeofence: false,
                statusText: "This identity has no approved work site in the current tenant.",
                resolutionMode: .noAllowedSite
            )
            diagnostics.selectedSite = "none"
            diagnostics.siteResolutionMode = SiteResolutionMode.noAllowedSite.rawValue
            return
        }

        guard let locationReading else {
            siteSelection = SiteSelectionState(
                selectedSiteID: firstSite.id,
                presentationTitle: "Approved Work Site",
                selectedSiteLabel: firstSite.label,
                distanceM: nil,
                insideGeofence: false,
                statusText: "Current location is still loading. The nearest approved site will appear once GPS is ready.",
                resolutionMode: .noLocation
            )
            settings.selectedSiteID = firstSite.id
            settingsStore.save(settings)
            diagnostics.selectedSite = firstSite.label
            diagnostics.siteResolutionMode = SiteResolutionMode.noLocation.rawValue
            return
        }

        let distance = haversineMeters(
            latitude1: locationReading.latitude,
            longitude1: locationReading.longitude,
            latitude2: firstSite.latitude,
            longitude2: firstSite.longitude
        )
        let inside = distance <= firstSite.radiusM
        let isLiveDemoSite = liveDemoSession?.siteID == firstSite.id
        let isSeededPerson = person.isDemoPerson == false
        siteSelection = SiteSelectionState(
            selectedSiteID: firstSite.id,
            presentationTitle: inside
                ? (isLiveDemoSite ? "Classroom Ready" : (isSeededPerson ? "Approved Sample Site" : "Approved Work Site"))
                : (isSeededPerson ? "Nearest Allowed Sample Site" : "Nearest Allowed Site"),
            selectedSiteLabel: firstSite.label,
            distanceM: distance,
            insideGeofence: inside,
            statusText: inside
                ? (isLiveDemoSite
                    ? "You are inside the classroom site created from the current location."
                    : (isSeededPerson
                        ? "This is a bundled sample student and sample site. Switch back to the active class student for the main check-in flow."
                        : "Inside the \(firstSite.label) geofence."))
                : (isSeededPerson
                    ? "This bundled sample student is mapped to a sample site, not your current classroom location."
                    : "You are outside all approved site geofences. The backend will accept or reject this check-in in realtime."),
            resolutionMode: inside ? .insideApprovedSite : .nearestAllowedSite
        )
        settings.selectedSiteID = firstSite.id
        settingsStore.save(settings)
        diagnostics.selectedSite = firstSite.label
        diagnostics.siteResolutionMode = inside
            ? SiteResolutionMode.insideApprovedSite.rawValue
            : SiteResolutionMode.nearestAllowedSite.rawValue
    }

    private func liveBootstrapTargets() -> [LiveBootstrapTarget] {
        switch settings.backendMode {
        case .remote:
            if let url = settings.remoteBackendURL {
                return [LiveBootstrapTarget(source: .remote, url: url)]
            }
            return []
        case .lan:
            if let url = settings.lanBackendURL {
                return [LiveBootstrapTarget(source: .lan, url: url)]
            }
            return []
        case .standaloneDemoAutoFallback:
            if let url = settings.remoteBackendURL {
                return [LiveBootstrapTarget(source: .remote, url: url)]
            }
            return []
        }
    }

    private func configuredLiveBackendURL() -> URL? {
        liveBootstrapTargets().first?.url
    }

    private func configuredLANBackendURLLabel() -> String {
        let trimmed = settings.lanBackendBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Not configured" : trimmed
    }

    private func displayBackendURLString() -> String {
        switch settings.backendMode {
        case .remote:
            let trimmed = settings.remoteBackendBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Not configured" : trimmed
        case .lan:
            return configuredLANBackendURLLabel()
        case .standaloneDemoAutoFallback:
            return settings.remoteBackendBaseURLString.isEmpty
                ? "Bundled classroom bootstrap"
                : settings.remoteBackendBaseURLString
        }
    }

    private func transportModeLabel() -> String {
        switch settings.backendMode {
        case .remote:
            return "Cloud"
        case .lan:
            return "LAN Realtime"
        case .standaloneDemoAutoFallback:
            return "Bundled Bootstrap"
        }
    }

    private func usesAuthoritativeServerBootstrap(_ source: BootstrapSource) -> Bool {
        source == .remote || source == .lan
    }

    private func shouldAttemptLiveSubmission() -> Bool {
        diagnostics.backendReachability == .reachable && configuredLiveBackendURL() != nil
    }

    private func shouldAttemptServerSubmission() -> Bool {
        diagnostics.backendReachability == .reachable && configuredLiveBackendURL() != nil
    }

    private func updateNetworkDiagnostics(using payload: MobileBootstrapPayload? = nil) {
        let effectivePayload = payload ?? bootstrap
        diagnostics.backendBaseURL = displayBackendURLString()
        diagnostics.configuredLANBackendURL = configuredLANBackendURLLabel()
        diagnostics.transportMode = transportModeLabel()
        diagnostics.wifiIPv4 = effectivePayload?.wifiIPv4 ?? ""
        diagnostics.canonicalLANURL = effectivePayload?.canonicalLANURL ?? ""
        diagnostics.backendBindHost = effectivePayload?.backendBindHost ?? ""
        diagnostics.lanReady = effectivePayload?.lanReady ?? false
        diagnostics.lanResolutionMode =
            settings.lanBackendBaseURLString.localizedCaseInsensitiveContains(".local")
            ? "bonjour_fallback"
            : "fixed_ip"
    }

    private func adoptCanonicalLANURLIfNeeded(from payload: MobileBootstrapPayload) {
        guard let canonicalLANURL = payload.canonicalLANURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              canonicalLANURL.isEmpty == false
        else {
            return
        }
        if settings.lanBackendBaseURLString == canonicalLANURL {
            return
        }
        settings.lanBackendBaseURLString = canonicalLANURL
        settingsStore.save(settings)
    }

    private func networkErrorCategory(for error: Error) -> String? {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotFindHost, .dnsLookupFailed:
                return "dns_resolution_failed"
            case .cannotConnectToHost:
                return "cannot_connect"
            case .timedOut:
                return "timed_out"
            case .notConnectedToInternet, .networkConnectionLost:
                return "not_connected"
            default:
                return "network_error"
            }
        }
        if let apiError = error as? AttendanceAPIError,
           case .unexpectedStatus = apiError {
            return "http_error"
        }
        return nil
    }

    private func applyBootstrap(
        _ payload: MobileBootstrapPayload,
        source: BootstrapSource,
        backendURL: String?,
        fetchedAt: Date,
        persistCache: Bool = true
    ) {
        syncLiveDemoSessionFromBootstrap(payload, source: source)
        reconcileLiveDemoSessionIfNeeded(with: payload, source: source)
        adoptCanonicalLANURLIfNeeded(from: payload)
        let effectivePayload = payloadAddingLiveDemoSessionIfNeeded(payload, source: source)
        bootstrap = effectivePayload
        bootstrapSource = source
        diagnostics.activeBootstrapSource = source.rawValue
        diagnostics.activeMethodProfileID = effectivePayload.methodStack.profileID
        diagnostics.activeCaptureProfileLabel = effectivePayload.captureProfile.label
        diagnostics.lastNetworkErrorCategory = nil
        if let linkedPerson = effectivePayload.linkedPerson,
           people.contains(where: { $0.id == linkedPerson.id }) {
            settings.selectedPersonID = linkedPerson.id
        } else if let activeClassSession = effectivePayload.activeClassSession,
                  people.contains(where: { $0.siteIDs.contains(activeClassSession.siteID) || $0.siteIDs.isEmpty }) {
            settings.selectedPersonID = people.first(where: {
                $0.siteIDs.contains(activeClassSession.siteID) || $0.siteIDs.isEmpty
            })?.id
        } else if let liveDemoSession,
                  people.contains(where: { $0.id == liveDemoSession.personID }) {
            settings.selectedPersonID = liveDemoSession.personID
        } else if let selectedPersonID = settings.selectedPersonID,
                  people.contains(where: { $0.id == selectedPersonID }) {
            settings.selectedPersonID = selectedPersonID
        } else {
            settings.selectedPersonID = people.first?.id
        }
        settings.lastSuccessfulBootstrapSource = source
        settings.lastSuccessfulBootstrapAt = fetchedAt
        settingsStore.save(settings)
        diagnostics.selectedIdentity = settings.selectedPersonID ?? "none"
        diagnostics.lastSyncTime = fetchedAt
        if persistCache {
            bootstrapCacheStore.save(
                BootstrapCachePayload(
                    payload: effectivePayload,
                    source: source,
                    backendURL: backendURL,
                    fetchedAt: fetchedAt
                )
            )
        }
        updateNetworkDiagnostics(using: effectivePayload)
        updateSiteSelection()
        refreshRuntimeStatus()
    }

    private func syncLiveDemoSessionFromBootstrap(
        _ payload: MobileBootstrapPayload,
        source: BootstrapSource
    ) {
        guard source == .lan || source == .remote else { return }

        guard let livePerson = payload.livePerson, let liveSite = payload.liveSite else {
            if source == .lan {
                liveDemoSession = nil
                liveDemoSessionStore.save(nil)
            }
            return
        }

        let session = LiveDemoSessionState(
            displayName: livePerson.displayName,
            personID: livePerson.id,
            employeeCode: livePerson.employeeCode,
            siteID: liveSite.id,
            siteLabel: liveSite.label,
            latitude: liveSite.latitude,
            longitude: liveSite.longitude,
            radiusM: liveSite.radiusM,
            source: source,
            syncedToBackend: true,
            updatedAt: .now
        )
        liveDemoSession = session
        liveDemoSessionStore.save(session)
    }

    private func loadBundledDemoBootstrap() -> MobileBootstrapPayload? {
        guard settings.standaloneDemoEnabled else { return nil }
        guard let url = Bundle.main.url(forResource: "BundledDemoBootstrap", withExtension: "json") else {
            return nil
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MobileBootstrapPayload.self, from: data)
    }

    private func currentReplayEligibility() -> ReplayEligibility {
        guard settings.backendMode != .lan else {
            return ReplayEligibility(
                isEligible: false,
                reason: "LAN realtime mode disables queueing and waits for a live backend response."
            )
        }
        guard settings.backendMode != .standaloneDemoAutoFallback else {
            return ReplayEligibility(
                isEligible: false,
                reason: "This mode suppresses replay queueing until you switch to a live classroom backend."
            )
        }
        guard configuredLiveBackendURL() != nil else {
            return ReplayEligibility(
                isEligible: false,
                reason: "Configure a live backend URL before queue replay is allowed."
            )
        }
        guard diagnostics.backendReachability == .reachable else {
            return ReplayEligibility(
                isEligible: false,
                reason: "The configured live backend is not reachable right now."
            )
        }
        return ReplayEligibility(isEligible: true, reason: nil)
    }

    private func suppressStandaloneQueueIfNeeded() {
        let replay = currentReplayEligibility()
        diagnostics.replayEligible = replay.isEligible
        diagnostics.queueSuppressedReason = replay.reason

        guard settings.backendMode == .standaloneDemoAutoFallback || settings.backendMode == .lan else { return }
        guard queuedClaims.isEmpty == false else {
            for index in localEvents.indices where localEvents[index].syncStatus == .queued {
                localEvents[index].syncStatus = settings.backendMode == .lan ? .archived : .localOnly
            }
            localHistoryStore.save(localEvents)
            diagnostics.offlineQueueDepth = 0
            if settings.backendMode == .lan {
                diagnostics.syncStatus = SyncStatus.idle.rawValue
            } else if localEvents.contains(where: { $0.syncStatus == .localOnly }) {
                diagnostics.syncStatus = SyncStatus.localOnly.rawValue
            }
            return
        }

        let localEventIDs = Set(queuedClaims.compactMap(\.localEventID))
        for index in localEvents.indices {
            if localEventIDs.contains(localEvents[index].id) {
                localEvents[index].syncStatus = settings.backendMode == .lan ? .archived : .localOnly
            }
        }
        queuedClaims.removeAll()
        queueStore.save(queuedClaims)
        localHistoryStore.save(localEvents)
        diagnostics.offlineQueueDepth = 0
        diagnostics.syncStatus = settings.backendMode == .lan ? SyncStatus.idle.rawValue : SyncStatus.localOnly.rawValue
    }

    private func reconcileLiveDemoSessionIfNeeded(
        with payload: MobileBootstrapPayload,
        source: BootstrapSource
    ) {
        guard let liveDemoSession else { return }
        guard usesAuthoritativeServerBootstrap(source) else { return }

        let siteExists = payload.sites.contains(where: { $0.id == liveDemoSession.siteID })
        let personStillOwnsSite = payload.people.contains { person in
            person.id == liveDemoSession.personID && person.siteIDs.contains(liveDemoSession.siteID)
        }
        guard siteExists == false || personStillOwnsSite == false else { return }

        self.liveDemoSession = nil
        liveDemoSessionStore.save(nil)
        diagnostics.lastRequestResult = "demo_session_reset"
    }

    private func payloadAddingLiveDemoSessionIfNeeded(
        _ payload: MobileBootstrapPayload,
        source: BootstrapSource
    ) -> MobileBootstrapPayload {
        guard let liveDemoSession else { return payload }
        guard usesAuthoritativeServerBootstrap(source) == false else { return payload }

        let liveDemoPerson = RosterIdentity(
            id: liveDemoSession.personID,
            tenantID: payload.tenant.id,
            employeeCode: liveDemoSession.employeeCode,
            displayName: liveDemoSession.displayName,
            siteIDs: [liveDemoSession.siteID],
            active: true
        )
        let liveDemoSite = WorkSitePayload(
            id: liveDemoSession.siteID,
            tenantID: payload.tenant.id,
            label: liveDemoSession.siteLabel,
            latitude: liveDemoSession.latitude,
            longitude: liveDemoSession.longitude,
            radiusM: liveDemoSession.radiusM
        )

        let mergedPeople = [liveDemoPerson] + payload.people.filter { $0.id != liveDemoSession.personID }
        let mergedSites = [liveDemoSite] + payload.sites.filter { $0.id != liveDemoSession.siteID }

        return MobileBootstrapPayload(
            tenant: payload.tenant,
            policy: payload.policy,
            people: mergedPeople,
            sites: mergedSites,
            linkedPerson: payload.linkedPerson,
            activeClassSession: payload.activeClassSession,
            livePerson: liveDemoPerson,
            liveSite: liveDemoSite,
            wifiIPv4: payload.wifiIPv4,
            canonicalLANURL: payload.canonicalLANURL,
            backendBindHost: payload.backendBindHost,
            lanReady: payload.lanReady,
            networkHint: payload.networkHint,
            serverTime: payload.serverTime,
            methodStack: payload.methodStack,
            captureProfile: payload.captureProfile
        )
    }

    private func makeLocalLiveDemoSession(
        person: RosterIdentity,
        location: LocationReading
    ) -> LiveDemoSessionState {
        let slug = slugifyDisplayName(person.displayName)
        let siteID = "demo-site-\(slug)"
        return LiveDemoSessionState(
            displayName: person.displayName,
            personID: person.id,
            employeeCode: person.employeeCode,
            siteID: siteID,
            siteLabel: "\(person.displayName) Classroom Site",
            latitude: location.latitude,
            longitude: location.longitude,
            radiusM: max(location.accuracyM * 4.0, 180.0),
            source: bootstrapSource ?? .bundledDemo,
            syncedToBackend: false,
            updatedAt: .now
        )
    }

    private func syncEnrollmentRecord(
        _ record: LocalEnrollmentRecord,
        for person: RosterIdentity,
        baseURL: URL
    ) async throws -> LocalEnrollmentRecord {
        let session = try await api.createEnrollmentSession(
            baseURL: baseURL,
            tenantID: settings.selectedTenantID,
            personID: person.id,
            consentReference: "ios-local-calibration"
        )
        let capture = diagnostics.lastCapture ?? CapturePayload(
            captureToken: "ios-enrollment-\(UUID().uuidString.lowercased())",
            qualityScore: 0.9,
            livenessScore: 0.9,
            bboxConfidence: 0.9,
            providerManifests: []
        )
        let _ = try await api.addEnrollmentCapture(
            baseURL: baseURL,
            sessionID: session.id,
            request: EnrollmentCaptureRequestPayload(
                captureToken: capture.captureToken,
                protectedTemplate: record.protectedTemplate,
                qualityScore: capture.qualityScore,
                livenessScore: capture.livenessScore,
                bboxConfidence: capture.bboxConfidence,
                deviceModel: UIDevice.current.model,
                providerManifests: capture.providerManifests
            )
        )
        let _ = try await api.finalizeEnrollment(baseURL: baseURL, sessionID: session.id)
        return LocalEnrollmentRecord(
            id: record.id,
            personDisplayName: record.personDisplayName,
            createdAt: record.createdAt,
            protectedTemplate: record.protectedTemplate,
            syncStatus: .synced,
            lastSyncError: nil
        )
    }

    func syncPendingEnrollmentsIfPossible() async {
        guard diagnostics.backendReachability == .reachable else { return }
        guard let baseURL = configuredLiveBackendURL() else { return }

        var changed = false
        for person in allPeople {
            guard var record = localEnrollments[person.id], record.syncStatus != .synced else { continue }
            do {
                record = try await syncEnrollmentRecord(record, for: person, baseURL: baseURL)
                localEnrollments[person.id] = record
                changed = true
                diagnostics.lastSyncTime = .now
            } catch {
                record.syncStatus = .failed
                record.lastSyncError = error.localizedDescription
                localEnrollments[person.id] = record
                changed = true
            }
        }

        if changed {
            enrollmentStore.save(localEnrollments)
        }
    }

    private func makeLocalDemoDecision(
        person: RosterIdentity,
        verification: VerificationCaptureResult,
        attestation: DeviceAttestationPayload,
        location: LocationReading,
        siteID: String
    ) -> AttendanceDecisionPayload {
        let policy = bootstrap?.policy ?? TenantPolicyPayload(
            thresholds: TenantThresholdPayload(
                minQualityScore: 0.35,
                minLivenessScore: 0.76,
                minMatchScore: 0.80,
                reviewMatchFloor: 0.74
            ),
            attendanceWindow: AttendanceWindowPayload(startHourLocal: 6, endHourLocal: 22),
            requireDeviceAttestation: true,
            allowOneNFallback: false,
            stepUpTriggers: []
        )
        let matchScore = verification.matchScore
        let geofenceResult = siteSelection.insideGeofence ? "pass" : "fail"
        var accepted = true
        var stepUpRequired = false
        var reasonCode = "accepted"

        if location.isMocked {
            accepted = false
            reasonCode = "mock_location_detected"
        } else if geofenceResult == "fail" {
            accepted = false
            reasonCode = "outside_geofence"
        } else if policy.requireDeviceAttestation && attestation.isTrusted == false {
            accepted = false
            stepUpRequired = true
            reasonCode = "untrusted_device"
        } else if verification.capture.livenessScore < policy.thresholds.minLivenessScore {
            accepted = false
            stepUpRequired = true
            reasonCode = "low_liveness"
        } else if verification.capture.qualityScore < policy.thresholds.minQualityScore {
            accepted = false
            stepUpRequired = true
            reasonCode = "low_quality"
        } else if matchScore < policy.thresholds.reviewMatchFloor {
            accepted = false
            reasonCode = "low_match"
        } else if matchScore < policy.thresholds.minMatchScore {
            accepted = false
            stepUpRequired = true
            reasonCode = "marginal_match"
        } else if person.id != settings.selectedPersonID {
            accepted = false
            reasonCode = "person_not_found"
        } else if siteID != siteSelection.selectedSiteID {
            accepted = false
            reasonCode = "site_not_allowed"
        }

        return AttendanceDecisionPayload(
            accepted: accepted,
            reasonCode: reasonCode,
            confidenceBand: confidenceBand(for: matchScore, policy: policy),
            stepUpRequired: stepUpRequired,
            reviewTicket: nil,
            matchedPersonID: person.id,
            matchScore: matchScore,
            qualityScore: verification.capture.qualityScore,
            livenessScore: verification.capture.livenessScore,
            geofenceResult: geofenceResult,
            decisionOrigin: .localDemo
        )
    }

    private func confidenceBand(for score: Double, policy: TenantPolicyPayload) -> String {
        if score >= policy.thresholds.minMatchScore {
            return "high"
        }
        if score >= policy.thresholds.reviewMatchFloor {
            return "medium"
        }
        return "low"
    }

    private func recordLocalAttendanceEvent(
        person: RosterIdentity,
        siteLabel: String,
        decision: AttendanceDecisionPayload,
        claimSource: String,
        syncState: LocalHistorySyncState
    ) -> LocalAttendanceEvent {
        let event = LocalAttendanceEvent(
            id: "local-\(UUID().uuidString.lowercased())",
            createdAt: .now,
            tenantID: settings.selectedTenantID,
            personID: person.id,
            personDisplayName: person.displayName,
            siteID: siteSelection.selectedSiteID ?? "unknown-site",
            siteLabel: siteLabel,
            reasonCode: decision.reasonCode,
            accepted: decision.accepted,
            stepUpRequired: decision.stepUpRequired,
            qualityScore: decision.qualityScore,
            livenessScore: decision.livenessScore,
            matchScore: decision.matchScore,
            geofenceResult: decision.geofenceResult,
            decisionOrigin: .localDemo,
            claimSource: claimSource,
            syncStatus: syncState
        )
        localEvents.insert(event, at: 0)
        localHistoryStore.save(localEvents)
        return event
    }

    private func handleLANBackendUnavailable(detail: String) {
        lastDecision = nil
        highlightedServerEventID = nil
        diagnostics.lastError = detail
        diagnostics.lastNetworkErrorCategory =
            if detail == "LAN backend unavailable" {
                "backend_unavailable"
            } else if detail.localizedCaseInsensitiveContains("dns") || detail.localizedCaseInsensitiveContains("host") {
                "dns_resolution_failed"
            } else {
                "cannot_connect"
            }
        diagnostics.lastRequestResult = "lan_backend_unavailable"
        diagnostics.decisionOrigin = "none"
        diagnostics.syncStatus = SyncStatus.idle.rawValue
        diagnostics.queueSuppressedReason = currentReplayEligibility().reason
        statusMessage = "LAN backend unavailable. Keep the iPhone and Mac on the same Wi-Fi, confirm the fixed Mac Wi-Fi IP, then try again."
        refreshRuntimeStatus()
    }

    private func markLocalEventSynced(_ eventID: String?) {
        guard let eventID else { return }
        guard let index = localEvents.firstIndex(where: { $0.id == eventID }) else { return }
        localEvents[index].syncStatus = .synced
        localHistoryStore.save(localEvents)
    }

    private func markLocalEventFailed(_ eventID: String?) {
        guard let eventID else { return }
        guard let index = localEvents.firstIndex(where: { $0.id == eventID }) else { return }
        localEvents[index].syncStatus = .failed
        localHistoryStore.save(localEvents)
    }

    private func nearestSite(from sites: [WorkSitePayload], for reading: LocationReading?) -> WorkSitePayload? {
        guard let reading else { return nil }
        return sites.min(by: { lhs, rhs in
            haversineMeters(
                latitude1: reading.latitude,
                longitude1: reading.longitude,
                latitude2: lhs.latitude,
                longitude2: lhs.longitude
            ) < haversineMeters(
                latitude1: reading.latitude,
                longitude1: reading.longitude,
                latitude2: rhs.latitude,
                longitude2: rhs.longitude
            )
        })
    }

    private func refreshRuntimeStatus() {
        captureRuntimeStatus = capturePipeline.runtimeStatus(previewStore: cameraPreviewStore)
        updateNetworkDiagnostics()
        diagnostics.runtimeMode = captureRuntimeStatus.mode
        diagnostics.runtimeSummary = captureRuntimeStatus.summary
        diagnostics.cameraStatus = cameraPreviewStore.deviceName
        diagnostics.cameraActivity = cameraPreviewStore.isRunning ? "active" : "inactive"
        diagnostics.deviceTrustProvider = deviceTrustService.currentProvider()
        diagnostics.signingMode = "hmac-sha256-local-secret-v1"
        diagnostics.transportMode = transportModeLabel()
        diagnostics.capturePath = "truedepth+coreml"
        if let frame = lastFrameSnapshot {
            diagnostics.depthPresent = frame.hasDepth
            diagnostics.depthCoverage = frame.depthCoverage
            diagnostics.depthVariance = frame.depthVariance
            diagnostics.depthEvidencePassed = frame.depthEvidencePassed
        } else {
            diagnostics.depthPresent = cameraPreviewStore.depthAvailable
            diagnostics.depthCoverage = 0.0
            diagnostics.depthVariance = 0.0
            diagnostics.depthEvidencePassed = false
        }
        let replay = currentReplayEligibility()
        diagnostics.replayEligible = replay.isEligible
        diagnostics.queueSuppressedReason = replay.reason
    }

    private func syncCameraSession() {
        let shouldRun =
            sceneIsActive
            && selectedTab == .home
            && onboardingComplete
            && checkInCameraRequested
            && cameraPermission.isGranted

        if shouldRun {
            cameraPreviewStore.start()
        } else {
            cameraPreviewStore.stop()
        }
        diagnostics.cameraActivity = shouldRun ? "active" : "inactive"
    }

    private func shouldQueueClaim(for error: Error) -> Bool {
        guard currentReplayEligibility().isEligible else { return false }
        if error is URLError {
            return true
        }
        if let apiError = error as? AttendanceAPIError,
           case .unexpectedStatus = apiError
        {
            return true
        }
        return false
    }

    private func lastRequestResult(for error: Error) -> String {
        if error is CapturePipelineError {
            return "local_capture_error"
        }
        if error is URLError {
            return "network_unreachable"
        }
        if let apiError = error as? AttendanceAPIError,
           case .unexpectedStatus = apiError
        {
            return "backend_http_error"
        }
        return "request_failed"
    }

    private func userFacingSubmissionMessage(for error: Error) -> String {
        if let captureError = error as? CapturePipelineError {
            return captureError.localizedDescription
        }
        if error is URLError {
            if settings.backendMode == .lan {
                return "LAN backend unavailable. Keep the iPhone and Mac on the same Wi-Fi, confirm the fixed Mac Wi-Fi IP, and try again."
            }
            return "The backend is offline right now. The app can keep running locally and will sync again once a backend is reachable."
        }
        if let apiError = error as? AttendanceAPIError {
            switch apiError {
            case .invalidBaseURL:
                return "No classroom backend is configured right now. Configure the teacher LAN backend and try again."
            case .unexpectedStatus:
                return "The backend rejected the check-in request. Review Diagnostics for the exact response."
            }
        }
        return error.localizedDescription
    }
}

private func haversineMeters(
    latitude1: Double,
    longitude1: Double,
    latitude2: Double,
    longitude2: Double
) -> Double {
    let earthRadius = 6_371_000.0
    let lat1 = latitude1 * .pi / 180
    let lon1 = longitude1 * .pi / 180
    let lat2 = latitude2 * .pi / 180
    let lon2 = longitude2 * .pi / 180

    let deltaLat = lat2 - lat1
    let deltaLon = lon2 - lon1
    let a = sin(deltaLat / 2) * sin(deltaLat / 2)
        + cos(lat1) * cos(lat2) * sin(deltaLon / 2) * sin(deltaLon / 2)
    let c = 2 * atan2(sqrt(a), sqrt(1 - a))
    return earthRadius * c
}

private func slugifyDisplayName(_ value: String) -> String {
    let lowered = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let replaced = lowered.map { character -> Character in
        if character.isLetter || character.isNumber {
            return character
        }
        return "-"
    }
    let collapsed = String(replaced).replacingOccurrences(
        of: "-+",
        with: "-",
        options: .regularExpression
    )
    let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return trimmed.isEmpty ? "student" : trimmed
}
