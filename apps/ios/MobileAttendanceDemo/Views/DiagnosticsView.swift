import SwiftUI

struct ProfileView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                Section("Student") {
                    if let student = model.linkedStudent {
                        LabeledContent("Name", value: student.displayName)
                        LabeledContent("Code", value: student.employeeCode)
                    } else {
                        Text("No student is linked to this iPhone yet.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Current class") {
                    if let session = model.activeClassSession {
                        LabeledContent("Class", value: session.classLabel)
                        LabeledContent("Classroom", value: session.siteLabel)
                        LabeledContent("Started", value: session.startedAt)
                    } else {
                        Text("The teacher has not started a class session yet.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Permissions") {
                    LabeledContent("Camera", value: model.cameraPermission.isGranted ? "Granted" : "Required")
                    LabeledContent("Location", value: model.locationPermission.isGranted ? "Granted" : "Required")
                    LabeledContent("Local Network", value: model.isClassroomLANReady ? "Ready" : "Waiting")
                }

                Section("Connection & Support") {
                    if model.diagnostics.canonicalLANURL.isEmpty == false {
                        LabeledContent("Teacher Mac", value: model.diagnostics.canonicalLANURL)
                    }
                    Text("Keep the iPhone and teacher Mac on the same Wi-Fi. Classroom check-in only works when the Mac backend is reachable.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Device") {
                    Button("Unbind this iPhone", role: .destructive) {
                        Task { await model.clearDeviceBinding() }
                    }
                    .disabled(model.linkedStudent == nil)
                }

                Section("Support tools") {
                    if model.settings.backendMode == .lan {
                        Button("Clear server history", role: .destructive) {
                            Task { await model.clearDemoServerHistory() }
                        }
                    }
                    #if DEBUG
                    NavigationLink("Developer Diagnostics") {
                        DiagnosticsView(model: model)
                    }
                    #endif
                }
            }
            .navigationTitle("Profile")
        }
    }
}

struct DiagnosticsView: View {
    @Bindable var model: AppModel

    var body: some View {
        List {
            Section("Backend") {
                LabeledContent("Base URL", value: model.diagnostics.backendBaseURL)
                LabeledContent("Configured LAN URL", value: model.diagnostics.configuredLANBackendURL)
                LabeledContent("Reachability", value: model.diagnostics.backendReachability.rawValue)
                LabeledContent("Transport", value: model.diagnostics.transportMode)
                LabeledContent("LAN resolution", value: model.diagnostics.lanResolutionMode)
                LabeledContent("LAN ready", value: model.diagnostics.lanReady ? "true" : "false")
                if model.diagnostics.wifiIPv4.isEmpty == false {
                    LabeledContent("Mac Wi-Fi IPv4", value: model.diagnostics.wifiIPv4)
                }
                if model.diagnostics.canonicalLANURL.isEmpty == false {
                    LabeledContent("Canonical LAN URL", value: model.diagnostics.canonicalLANURL)
                }
                if model.diagnostics.backendBindHost.isEmpty == false {
                    LabeledContent("Bind host", value: model.diagnostics.backendBindHost)
                }
                LabeledContent("Bootstrap source", value: model.diagnostics.activeBootstrapSource)
                LabeledContent("Last request", value: model.diagnostics.lastRequestResult)
                if let lastNetworkErrorCategory = model.diagnostics.lastNetworkErrorCategory {
                    LabeledContent("Network error type", value: lastNetworkErrorCategory)
                }
            }

            Section("Runtime") {
                LabeledContent("Mode", value: model.captureRuntimeStatus.mode)
                LabeledContent("Summary", value: model.captureRuntimeStatus.summary)
                LabeledContent("Capture path", value: model.diagnostics.capturePath)
                LabeledContent("Camera", value: model.diagnostics.cameraStatus)
                LabeledContent("Camera activity", value: model.diagnostics.cameraActivity)
                LabeledContent("Location", value: model.diagnostics.locationStatus)
                LabeledContent("Trust provider", value: model.diagnostics.deviceTrustProvider)
                LabeledContent("Signing mode", value: model.diagnostics.signingMode)
                LabeledContent("Decision origin", value: model.diagnostics.decisionOrigin)
                LabeledContent("Selected identity", value: model.diagnostics.selectedIdentity)
                LabeledContent("Selected site", value: model.diagnostics.selectedSite)
                LabeledContent("Site resolution", value: model.diagnostics.siteResolutionMode)
                LabeledContent("Depth present", value: model.diagnostics.depthPresent ? "true" : "false")
                LabeledContent("Depth coverage", value: model.diagnostics.depthCoverage.formatted(.number.precision(.fractionLength(2))))
                LabeledContent("Depth variance", value: model.diagnostics.depthVariance.formatted(.number.precision(.fractionLength(4))))
                LabeledContent("Depth evidence", value: model.diagnostics.depthEvidencePassed ? "passed" : "not passed")
            }

            Section("Last capture") {
                if let capture = model.diagnostics.lastCapture {
                    LabeledContent("Token", value: capture.captureToken)
                    LabeledContent("Quality", value: capture.qualityScore.formatted(.number.precision(.fractionLength(2))))
                    LabeledContent("Liveness", value: capture.livenessScore.formatted(.number.precision(.fractionLength(2))))
                    LabeledContent("BBox", value: capture.bboxConfidence.formatted(.number.precision(.fractionLength(2))))
                    if let frame = model.lastFrameSnapshot {
                        LabeledContent("Face count", value: "\(frame.faceCount)")
                        LabeledContent("Depth passed", value: frame.depthEvidencePassed ? "true" : "false")
                        LabeledContent("Depth range", value: frame.depthRange.formatted(.number.precision(.fractionLength(3))))
                    }
                } else {
                    Text("Run one classroom check-in to inspect the on-device pipeline snapshot.")
                        .foregroundStyle(.secondary)
                }
            }

            if let lastError = model.diagnostics.lastError {
                Section("Last error") {
                    Text(lastError)
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("Developer Diagnostics")
    }
}
