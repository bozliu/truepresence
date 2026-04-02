import AVFoundation
import SwiftUI
import UIKit

struct CameraPermissionGateView: View {
    @Bindable var model: AppModel
    @State private var showingQRScanner = false
    @State private var bindingInFlight = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.93, green: 0.98, blue: 0.92),
                    Color(red: 0.78, green: 0.95, blue: 0.98),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("TruePresence")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    Text("Welcome to TruePresence")
                        .font(.system(size: 34, weight: .bold, design: .rounded))

                    Text("To protect classroom attendance, we need camera, location, and classroom network access before the first check-in.")
                        .font(.body)
                        .foregroundStyle(.secondary)

                    permissionsSection
                    bindingSection
                }
                .padding(24)
            }
        }
        .task {
            await model.ensureBootstrapIfPossible()
        }
        .sheet(isPresented: $showingQRScanner) {
            QRScannerSheet(
                isProcessing: bindingInFlight,
                onCancel: { showingQRScanner = false },
                onCodeScanned: { payload in
                    bindingInFlight = true
                    Task {
                        await model.claimDeviceBinding(qrPayload: payload)
                        bindingInFlight = false
                        if model.linkedStudent != nil {
                            showingQRScanner = false
                        }
                    }
                }
            )
        }
    }

    private var permissionsSection: some View {
        VStack(spacing: 14) {
            PermissionStepCard(
                title: "Camera",
                status: model.cameraPermission.isGranted ? "Ready" : "Required",
                detail: model.cameraPermission.isGranted
                    ? "Front TrueDepth camera access is available."
                    : "Allow the front camera so the app can capture live face evidence.",
                actionTitle: model.cameraPermission.isGranted ? "Camera ready" : "Allow camera",
                actionEnabled: model.cameraPermission.isGranted == false
            ) {
                Task { await model.requestCameraAccess() }
            }

            PermissionStepCard(
                title: "Location",
                status: model.locationPermission.isGranted ? "Ready" : "Required",
                detail: model.locationPermission.isGranted
                    ? "Location access is ready for classroom geofence checks."
                    : "Allow location so the app can confirm you are physically in the classroom area.",
                actionTitle: model.locationPermission.isGranted ? "Location ready" : "Allow location",
                actionEnabled: model.cameraPermission.isGranted && model.locationPermission.isGranted == false
            ) {
                Task { await model.requestLocationAccess() }
            }

            PermissionStepCard(
                title: "Local Network",
                status: lanStatus,
                detail: lanDetail,
                actionTitle: model.isClassroomLANReady ? "Network ready" : "Check classroom LAN",
                actionEnabled: model.permissionsReady && model.isBootstrapping == false && model.isClassroomLANReady == false
            ) {
                Task { await model.refreshBootstrap() }
            }
        }
    }

    private var bindingSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.diagnostics.canonicalLANURL.isEmpty == false {
                informationRow(title: "Teacher Mac LAN URL", value: model.diagnostics.canonicalLANURL)
            } else if model.settings.lanBackendBaseURLString.isEmpty == false {
                informationRow(title: "Configured LAN URL", value: model.settings.lanBackendBaseURLString)
            }

            if let error = model.diagnostics.lastError, model.linkedStudent == nil {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            HStack {
                Text("Student Binding")
                    .font(.headline)
                Spacer()
                statusCapsule(model.linkedStudent == nil ? "Required" : "Linked")
            }

            if let linkedStudent = model.linkedStudent {
                Text("\(linkedStudent.displayName) is already linked to this iPhone.")
                    .foregroundStyle(.secondary)
                informationRow(title: "Student", value: linkedStudent.displayName)
                informationRow(title: "Code", value: linkedStudent.employeeCode)
                if let session = model.activeClassSession {
                    informationRow(title: "Current class", value: session.classLabel)
                    informationRow(title: "Classroom", value: session.siteLabel)
                }
            } else {
                Text("Scan the teacher QR code to link this iPhone to an existing student record. The student app cannot create or edit students.")
                    .foregroundStyle(.secondary)
                Button("Scan student QR") {
                    showingQRScanner = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.permissionsReady == false || model.bootstrap == nil || model.isClassroomLANReady == false || bindingInFlight)
            }

            Text(model.statusMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var lanStatus: String {
        if model.isBootstrapping {
            return "Checking"
        }
        if model.isClassroomLANReady {
            return "Ready"
        }
        return "Required"
    }

    private var lanDetail: String {
        if model.isClassroomLANReady {
            return "This iPhone can already reach the teacher Mac on the classroom network."
        }
        return "Check the teacher Mac on the same Wi-Fi. TruePresence uses the teacher Mac LAN URL as classroom network proof."
    }

    @ViewBuilder
    private func statusCapsule(_ label: String) -> some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.06), in: Capsule())
    }

    @ViewBuilder
    private func informationRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

private struct PermissionStepCard: View {
    let title: String
    let status: String
    let detail: String
    let actionTitle: String
    let actionEnabled: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Text(status)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.06), in: Capsule())
            }

            Text(detail)
                .foregroundStyle(.secondary)

            Button(actionTitle, action: action)
                .buttonStyle(.borderedProminent)
                .disabled(actionEnabled == false)
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}

private struct QRScannerSheet: View {
    let isProcessing: Bool
    let onCancel: () -> Void
    let onCodeScanned: (String) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Text("Scan Teacher QR")
                    .font(.title2.weight(.bold))
                Text("Point the iPhone camera at the binding QR shown on the teacher Mac.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                QRCodeScannerRepresentable { payload in
                    guard isProcessing == false else { return }
                    onCodeScanned(payload)
                }
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .frame(maxHeight: 380)

                if isProcessing {
                    ProgressView("Linking this iPhone to the student record...")
                }
            }
            .padding(24)
            .navigationTitle("QR Binding")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }
}

private struct QRCodeScannerRepresentable: UIViewControllerRepresentable {
    let onCodeScanned: (String) -> Void

    func makeUIViewController(context: Context) -> QRCodeScannerViewController {
        let controller = QRCodeScannerViewController()
        controller.onCodeScanned = onCodeScanned
        return controller
    }

    func updateUIViewController(_ uiViewController: QRCodeScannerViewController, context: Context) {}
}

private final class QRCodeScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCodeScanned: ((String) -> Void)?

    private let captureSession = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if captureSession.isRunning == false {
            captureSession.startRunning()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if captureSession.isRunning {
            captureSession.stopRunning()
        }
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              captureSession.canAddInput(input)
        else {
            return
        }
        captureSession.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard captureSession.canAddOutput(output) else { return }
        captureSession.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: captureSession)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              object.type == .qr,
              let payload = object.stringValue
        else {
            return
        }
        captureSession.stopRunning()
        onCodeScanned?(payload)
    }
}
