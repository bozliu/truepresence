import SwiftUI

struct HomeView: View {
    @Bindable var model: AppModel
    @State private var showingCameraFlow = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HeroCard(model: model)
                    StudentIdentityCard(model: model)
                    ClassroomSessionCard(model: model)
                    ReadinessSection(model: model)
                    checkInAction
                }
                .padding()
            }
            .refreshable {
                await model.refreshBootstrap()
                await model.refreshHistory()
            }
            .navigationTitle("TruePresence")
            .navigationBarTitleDisplayMode(.large)
            .fullScreenCover(isPresented: $showingCameraFlow) {
                StudentCameraScreen(model: model)
            }
            .task(id: homeRefreshKey) {
                guard model.settings.backendMode == .lan, model.linkedStudent != nil else { return }
                guard model.hasActiveClassSession == false || model.isClassroomLANReady == false else { return }
                await model.ensureBootstrapIfPossible(force: true)
            }
        }
    }

    private var homeRefreshKey: String {
        [
            model.linkedStudent?.id ?? "no-linked-student",
            model.hasActiveClassSession ? "class-live" : "class-waiting",
            model.isClassroomLANReady ? "lan-ready" : "lan-waiting",
        ].joined(separator: "|")
    }

    private var checkInAction: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                showingCameraFlow = true
            } label: {
                Label("Enter classroom check-in", systemImage: "viewfinder.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.canOpenCameraFlow == false)

            Text(actionHint)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var actionHint: String {
        if model.linkedStudent == nil {
            return "Scan the teacher QR code first so this iPhone is linked to a student record."
        }
        if model.hasActiveClassSession == false {
            return "The teacher has not started a class session yet."
        }
        if model.isClassroomLANReady == false {
            return "Keep the iPhone and teacher Mac on the same Wi-Fi before checking in."
        }
        return "When all three readiness checks are green, open the camera and verify with TrueDepth."
    }
}

private struct HeroCard: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Student check-in")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text("Location, classroom LAN, and TrueDepth face verification in one flow.")
                .font(.system(size: 31, weight: .bold, design: .rounded))
            Text(model.statusMessage)
                .foregroundStyle(.secondary)
        }
    }
}

private struct StudentIdentityCard: View {
    let model: AppModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if let student = model.linkedStudent {
                    Text(student.displayName)
                        .font(.headline)
                    Text(student.employeeCode)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                    Text("This iPhone is linked to the selected student through the teacher QR code.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("This iPhone is not linked to a student yet.")
                        .font(.headline)
                    Text("Return to the onboarding sheet and scan the teacher QR code.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } label: {
            Label("Student", systemImage: "person.text.rectangle")
        }
    }
}

private struct ClassroomSessionCard: View {
    let model: AppModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if let session = model.activeClassSession {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.classLabel)
                                .font(.headline)
                            Text(session.siteLabel)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let distance = model.siteSelection.distanceM {
                            Text("\(Int(distance)) m")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(model.siteSelection.statusText)
                        .foregroundStyle(
                            model.siteSelection.insideGeofence
                                ? AnyShapeStyle(.secondary)
                                : AnyShapeStyle(Color.orange)
                        )
                        .font(.footnote)
                } else {
                    Text("No active class session")
                        .font(.headline)
                    Text("The teacher needs to start class on the Mac before student check-in becomes available.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if model.linkedStudent != nil, model.isClassroomLANReady {
                        Button("Refresh class status") {
                            Task {
                                await model.refreshBootstrap()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        } label: {
            Label(
                model.siteSelection.presentationTitle == "Classroom Ready" ? "Classroom Ready" : "Classroom",
                systemImage: "mappin.and.ellipse"
            )
        }
    }
}

private struct ReadinessSection: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Readiness")
                .font(.headline)
            HStack(spacing: 12) {
                ReadinessTile(
                    title: "Location",
                    subtitle: model.locationPermission.isGranted && model.siteSelection.insideGeofence
                        ? "Verified"
                        : (model.locationPermission.isGranted ? "Waiting for class site" : "Required"),
                    ready: model.locationPermission.isGranted && model.siteSelection.insideGeofence
                )
                ReadinessTile(
                    title: "Classroom LAN",
                    subtitle: model.isClassroomLANReady ? "Ready" : "Waiting",
                    ready: model.isClassroomLANReady
                )
                ReadinessTile(
                    title: "Face verification",
                    subtitle: model.cameraPermission.isGranted ? "Ready" : "Required",
                    ready: model.cameraPermission.isGranted
                )
            }
        }
    }
}

private struct ReadinessTile: View {
    let title: String
    let subtitle: String
    let ready: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: ready ? "checkmark.seal.fill" : "clock.fill")
                .font(.title3)
                .foregroundStyle(ready ? Color.green : Color.orange)
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct StudentCameraScreen: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    cameraStage
                    runtimeCard
                    submitSection
                    if let decision = model.lastDecision, decision.accepted == false {
                        ServerDecisionBanner(decision: decision)
                    }
                }
                .padding()
            }
            .navigationTitle("Camera")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .onDisappear {
                model.stopCheckInCamera()
            }
            .onChange(of: model.successDecision != nil) { _, hasSuccess in
                if hasSuccess {
                    dismiss()
                }
            }
        }
    }

    private var cameraStage: some View {
        GroupBox {
            if model.isCheckInCameraLive {
                ZStack(alignment: .bottomLeading) {
                    CameraPreviewView(session: model.cameraPreviewStore.session)
                        .frame(height: 420)
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))

                    VStack(alignment: .leading, spacing: 10) {
                        Text(model.captureRuntimeStatus.ready ? "TrueDepth ready" : "TrueDepth starting")
                            .font(.headline)
                        Text(model.captureRuntimeStatus.summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Button("Stop camera") {
                            model.stopCheckInCamera()
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(18)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .padding(16)
                }
            } else {
                VStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.black.opacity(0.08), Color.black.opacity(0.04)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(height: 420)
                        .overlay {
                            VStack(spacing: 12) {
                                Image(systemName: "camera.viewfinder")
                                    .font(.system(size: 36, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Text("Start the front TrueDepth camera")
                                    .font(.headline)
                                Text("The camera runs only while you are inside the classroom check-in flow.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(28)
                        }

                    Button("Start TrueDepth") {
                        model.activateCheckInCamera()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.canOpenCameraFlow == false)
                }
            }
        } label: {
            Label("Face verification", systemImage: "viewfinder")
        }
    }

    private var runtimeCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Capture path: \(model.diagnostics.capturePath)", systemImage: "camera.metering.center.weighted")
                Label(model.diagnostics.depthPresent ? "Depth map acquired" : "Depth map not ready", systemImage: "waveform.path.badge.plus")
                Label(
                    model.diagnostics.depthEvidencePassed ? "Depth-backed liveness passed" : "Depth-backed liveness not proven yet",
                    systemImage: model.diagnostics.depthEvidencePassed ? "checkmark.seal" : "exclamationmark.triangle"
                )
                if let frame = model.lastFrameSnapshot {
                    Text(
                        "Quality \(frame.qualityScore.formatted(.number.precision(.fractionLength(2)))) · Liveness \(frame.livenessScore.formatted(.number.precision(.fractionLength(2)))) · Sharpness \(frame.sharpnessScore.formatted(.number.precision(.fractionLength(2))))"
                    )
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
        } label: {
            Label("Runtime", systemImage: "cpu")
        }
    }

    private var submitSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                Task { await model.submitCheckIn() }
            } label: {
                if model.isSubmitting {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Label("Submit secure check-in", systemImage: "checkmark.shield.fill")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.canSubmit == false)

            Text("TruePresence submits only after location, classroom LAN, and TrueDepth evidence are ready.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

struct SuccessResultView: View {
    @Bindable var model: AppModel
    let decision: AttendanceDecisionPayload
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(Color.green)
                Text("Check-in accepted")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                Text(model.activeClassSession?.classLabel ?? model.siteSelection.selectedSiteLabel)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text(decision.displayReason)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("View history") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                Spacer()
            }
            .padding(32)
            .navigationTitle("Success")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
