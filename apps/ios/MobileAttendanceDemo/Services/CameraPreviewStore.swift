@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import Observation

struct CameraFramePacket {
    let pixelBuffer: CVPixelBuffer
    let depthData: AVDepthData?
    let timestamp: CMTime
}

private final class CameraFrameStore {
    private let lock = NSLock()
    private var latestPacket: CameraFramePacket?

    func update(pixelBuffer: CVPixelBuffer, depthData: AVDepthData?, timestamp: CMTime) {
        lock.lock()
        latestPacket = CameraFramePacket(pixelBuffer: pixelBuffer, depthData: depthData, timestamp: timestamp)
        lock.unlock()
    }

    func latest() -> CameraFramePacket? {
        lock.lock()
        defer { lock.unlock() }
        return latestPacket
    }
}

private final class CameraStreamDelegate: NSObject, AVCaptureDataOutputSynchronizerDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let frameStore: CameraFrameStore
    private let onFrame: @MainActor (Date) -> Void

    init(frameStore: CameraFrameStore, onFrame: @escaping @MainActor (Date) -> Void) {
        self.frameStore = frameStore
        self.onFrame = onFrame
    }

    func dataOutputSynchronizer(
        _ synchronizer: AVCaptureDataOutputSynchronizer,
        didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection
    ) {
        guard
            let synchronizedVideo = synchronizedDataCollection.synchronizedData(for: synchronizer.dataOutputs[0]) as? AVCaptureSynchronizedSampleBufferData,
            !synchronizedVideo.sampleBufferWasDropped,
            let pixelBuffer = CMSampleBufferGetImageBuffer(synchronizedVideo.sampleBuffer)
        else {
            return
        }

        var depthData: AVDepthData?
        if synchronizer.dataOutputs.count > 1,
           let synchronizedDepth = synchronizedDataCollection.synchronizedData(for: synchronizer.dataOutputs[1]) as? AVCaptureSynchronizedDepthData,
           !synchronizedDepth.depthDataWasDropped
        {
            depthData = synchronizedDepth.depthData
        }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(synchronizedVideo.sampleBuffer)
        frameStore.update(
            pixelBuffer: pixelBuffer,
            depthData: depthData,
            timestamp: timestamp
        )
        let capturedAt = Date(timeIntervalSince1970: timestamp.seconds)
        Task { @MainActor in
            self.onFrame(capturedAt)
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        frameStore.update(
            pixelBuffer: pixelBuffer,
            depthData: nil,
            timestamp: timestamp
        )
        let capturedAt = Date(timeIntervalSince1970: timestamp.seconds)
        Task { @MainActor in
            self.onFrame(capturedAt)
        }
    }
}

@MainActor
@Observable
final class CameraPreviewStore {
    @ObservationIgnored let session = AVCaptureSession()

    var isRunning = false
    var usingTrueDepth = false
    var deviceName = "Front camera"
    var lastError: String?

    var latestFrameTimestamp: Date?
    @ObservationIgnored var onStateChange: (@MainActor () -> Void)?

    @ObservationIgnored private let frameStore = CameraFrameStore()
    @ObservationIgnored private lazy var streamDelegate = CameraStreamDelegate(frameStore: frameStore) { [weak self] capturedAt in
        guard let self else { return }
        self.latestFrameTimestamp = capturedAt
        self.onStateChange?()
    }
    @ObservationIgnored private let outputQueue = DispatchQueue(label: "mobile-attendance.camera.output", qos: .userInitiated)
    @ObservationIgnored private let videoOutput = AVCaptureVideoDataOutput()
    @ObservationIgnored private let depthOutput = AVCaptureDepthDataOutput()
    @ObservationIgnored private var dataSynchronizer: AVCaptureDataOutputSynchronizer?
    @ObservationIgnored private var configured = false
    var analysisOrientation: CGImagePropertyOrientation {
        .up
    }

    var depthAvailable: Bool {
        latestFrame()?.depthData != nil
    }

    func latestFrame() -> CameraFramePacket? {
        let packet = frameStore.latest()
        if let packet {
            latestFrameTimestamp = Date(timeIntervalSince1970: packet.timestamp.seconds)
        }
        return packet
    }

    func start() {
        configureIfNeeded()
        guard lastError == nil else { return }
        guard !session.isRunning else {
            isRunning = true
            onStateChange?()
            return
        }
        let captureSession = session
        DispatchQueue.global(qos: .userInitiated).async {
            captureSession.startRunning()
            Task { @MainActor in
                self.isRunning = true
                self.onStateChange?()
            }
        }
    }

    func stop() {
        guard session.isRunning else {
            isRunning = false
            return
        }
        let captureSession = session
        DispatchQueue.global(qos: .userInitiated).async {
            captureSession.stopRunning()
            Task { @MainActor in
                self.isRunning = false
                self.onStateChange?()
            }
        }
    }

    func configureIfNeeded() {
        guard !configured else { return }

        session.beginConfiguration()
        session.sessionPreset = .high

        defer {
            session.commitConfiguration()
            configured = true
        }

        guard
            let device = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        else {
            lastError = "Front camera unavailable on this device."
            onStateChange?()
            return
        }

        usingTrueDepth = device.deviceType == .builtInTrueDepthCamera
        deviceName = usingTrueDepth ? "Front TrueDepth camera" : "Front RGB camera"

        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            lastError = "Unable to configure the front camera input."
            onStateChange?()
            return
        }
        session.addInput(input)

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        ]
        guard session.canAddOutput(videoOutput) else {
            lastError = "Unable to attach the video output."
            onStateChange?()
            return
        }
        session.addOutput(videoOutput)

        if let connection = videoOutput.connection(with: .video) {
            connection.videoRotationAngle = 90
            if connection.isVideoMirroringSupported {
                connection.isVideoMirrored = true
            }
        }

        if usingTrueDepth,
           !device.activeFormat.supportedDepthDataFormats.isEmpty,
           session.canAddOutput(depthOutput)
        {
            depthOutput.isFilteringEnabled = true
            session.addOutput(depthOutput)

            if let bestDepthFormat = device.activeFormat.supportedDepthDataFormats
                .filter({
                    let subtype = CMFormatDescriptionGetMediaSubType($0.formatDescription)
                    return subtype == kCVPixelFormatType_DepthFloat16 || subtype == kCVPixelFormatType_DepthFloat32
                })
                .max(by: { lhs, rhs in
                    let left = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
                    let right = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
                    return Int(left.width * left.height) < Int(right.width * right.height)
                })
            {
                do {
                    try device.lockForConfiguration()
                    device.activeDepthDataFormat = bestDepthFormat
                    device.unlockForConfiguration()
                } catch {
                    lastError = "Unable to lock the TrueDepth camera for depth capture."
                    onStateChange?()
                }
            }

            if let depthConnection = depthOutput.connection(with: .depthData) {
                depthConnection.isEnabled = true
            }

            dataSynchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [videoOutput, depthOutput])
            dataSynchronizer?.setDelegate(streamDelegate, queue: outputQueue)
        } else {
            videoOutput.setSampleBufferDelegate(streamDelegate, queue: outputQueue)
            if usingTrueDepth == false {
                lastError = "TrueDepth unavailable. This iPhone demo expects a Face ID-class front camera."
            }
        }

        onStateChange?()
    }
}
