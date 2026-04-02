import AVFoundation
import CoreImage
import CoreML
import CryptoKit
import Foundation
import ImageIO
import UIKit
import Vision

enum CapturePipelineError: LocalizedError {
    case runtimeUnavailable(String)
    case noFrameAvailable
    case noFaceDetected
    case noDepthData
    case depthEvidenceFailed
    case modelPredictionFailed

    var errorDescription: String? {
        switch self {
        case let .runtimeUnavailable(message):
            return message
        case .noFrameAvailable:
            return "Move into view of the front camera before continuing."
        case .noFaceDetected:
            return "No face was detected in the current frame."
        case .noDepthData:
            return "TrueDepth data is not available yet. Keep the iPhone pointed at your face and try again."
        case .depthEvidenceFailed:
            return "The TrueDepth scan is not strong enough yet. Move closer and keep your full face inside the frame."
        case .modelPredictionFailed:
            return "The on-device recognition model did not return a valid embedding."
        }
    }
}

struct CalibrationCaptureResult {
    let capture: CapturePayload
    let frameSnapshot: CaptureFrameSnapshot
    let protectedTemplate: ProtectedTemplatePayload
    let faceImageBase64: String
}

struct VerificationCaptureResult {
    let capture: CapturePayload
    let frameSnapshot: CaptureFrameSnapshot
    let protectedTemplate: ProtectedTemplatePayload
    let faceImageBase64: String
    let matchScore: Double
}

private struct RawCaptureAnalysis {
    let capture: CapturePayload
    let frameSnapshot: CaptureFrameSnapshot
    let protectedTemplate: ProtectedTemplatePayload
    let faceImageBase64: String
}

private struct DepthAnalysis {
    let score: Double
    let hasDepth: Bool
    let coverage: Double
    let variance: Double
    let range: Double
    let passed: Bool
}

private struct FaceCropAnalysis {
    let resizedPixelBuffer: CVPixelBuffer
    let observations: [VNFaceObservation]
    let selectedObservation: VNFaceObservation
    let bbox: BoundingBoxPayload
    let brightnessScore: Double
    let sharpnessScore: Double
    let qualityScore: Double
    let faceImageBase64: String
}

private struct RecognitionTemplateProtector {
    private let secret = Data("truepresence-blueprint-secret-2026".utf8)

    func protect(_ embedding: [Double], dimension: Int = 256) -> ProtectedTemplatePayload {
        let normalized = normalize(embedding)
        var bits = String()
        bits.reserveCapacity(dimension)

        for index in 0..<dimension {
            var score = 0.0
            for projectionRound in 0..<8 {
                var payload = secret
                payload.append(contentsOf: Array(":\(index):\(projectionRound)".utf8))
                let digest = SHA256.hash(data: payload)
                let bytes = Array(digest)
                let position = Int(bytes[0]) % max(normalized.count, 1)
                let sign = bytes[1].isMultiple(of: 2) ? 1.0 : -1.0
                let weight = 0.5 + (Double(bytes[2]) / 255.0)
                score += normalized[position] * sign * weight
            }
            bits.append(score >= 0 ? "1" : "0")
        }

        let digest = HMAC<SHA256>.authenticationCode(for: Data(bits.utf8), using: SymmetricKey(data: secret))
        let digestHex = Data(digest).map { String(format: "%02x", $0) }.joined()
        return ProtectedTemplatePayload(
            scheme: "signed-random-projection-v1",
            dimension: dimension,
            bitstring: bits,
            digest: digestHex
        )
    }

    func similarity(_ lhs: ProtectedTemplatePayload, _ rhs: ProtectedTemplatePayload) -> Double {
        guard lhs.dimension == rhs.dimension else { return 0 }
        let matches = zip(lhs.bitstring, rhs.bitstring).reduce(0) { partial, pair in
            partial + (pair.0 == pair.1 ? 1 : 0)
        }
        return Double(matches) / Double(max(lhs.dimension, 1))
    }

    private func normalize(_ vector: [Double]) -> [Double] {
        let magnitude = sqrt(vector.reduce(0.0) { $0 + ($1 * $1) })
        guard magnitude > 0 else { return vector }
        return vector.map { $0 / magnitude }
    }
}

@MainActor
final class CapturePipeline {
    private let ciContext = CIContext()
    private let protector = RecognitionTemplateProtector()
    private lazy var modelLoadResult = loadModel()

    private var providerManifests: [ProviderManifestPayload] {
        [
            ProviderManifestPayload(
                provider: "apple-vision-face",
                family: "vision-face-detection",
                version: "ios17",
                runtime: "device"
            ),
            ProviderManifestPayload(
                provider: "arcface-mobileface-coreml",
                family: "arcface-mobileface-embedder",
                version: "w600k_mbf-coreml-2026-03-30",
                runtime: "device"
            ),
            ProviderManifestPayload(
                provider: "apple-truedepth-depth-gate",
                family: "truedepth-liveness",
                version: "depth-heuristic-2026-03-30",
                runtime: "device"
            ),
        ]
    }

    func runtimeStatus(previewStore: CameraPreviewStore) -> CaptureRuntimeStatus {
        if case let .failure(error) = modelLoadResult {
            return CaptureRuntimeStatus(
                mode: "coreml+truedepth",
                ready: false,
                summary: "Core ML runtime unavailable.",
                blockedReason: error.localizedDescription,
                providerManifests: providerManifests
            )
        }
        if previewStore.lastError != nil {
            return CaptureRuntimeStatus(
                mode: "coreml+truedepth",
                ready: false,
                summary: "Front camera runtime unavailable.",
                blockedReason: previewStore.lastError,
                providerManifests: providerManifests
            )
        }
        if previewStore.isRunning == false {
            return CaptureRuntimeStatus(
                mode: "coreml+truedepth",
                ready: false,
                summary: "Check-In camera is off until you start capture on this screen.",
                blockedReason: "Start the TrueDepth camera on the Check-In tab to run face verification.",
                providerManifests: providerManifests
            )
        }
        if previewStore.usingTrueDepth == false {
            return CaptureRuntimeStatus(
                mode: "coreml+truedepth",
                ready: false,
                summary: "TrueDepth is required for the iPhone attendance demo.",
                blockedReason: "This device is not exposing front TrueDepth capture.",
                providerManifests: providerManifests
            )
        }
        if previewStore.latestFrame() == nil {
            return CaptureRuntimeStatus(
                mode: "coreml+truedepth",
                ready: false,
                summary: "Waiting for the front camera stream.",
                blockedReason: "No camera frame has arrived yet.",
                providerManifests: providerManifests
            )
        }
        if previewStore.depthAvailable == false {
            return CaptureRuntimeStatus(
                mode: "coreml+truedepth",
                ready: false,
                summary: "Waiting for the TrueDepth map.",
                blockedReason: "The front depth stream has not produced a usable map yet.",
                providerManifests: providerManifests
            )
        }
        return CaptureRuntimeStatus(
            mode: "coreml+truedepth",
            ready: true,
            summary: "TrueDepth depth and Core ML are ready for local face verification.",
            blockedReason: nil,
            providerManifests: providerManifests
        )
    }

    func calibrate(previewStore: CameraPreviewStore) throws -> CalibrationCaptureResult {
        let analysis = try analyze(previewStore: previewStore)
        return CalibrationCaptureResult(
            capture: analysis.capture,
            frameSnapshot: analysis.frameSnapshot,
            protectedTemplate: analysis.protectedTemplate,
            faceImageBase64: analysis.faceImageBase64
        )
    }

    func verify(
        previewStore: CameraPreviewStore,
        enrolledTemplate: ProtectedTemplatePayload
    ) throws -> VerificationCaptureResult {
        let analysis = try analyze(previewStore: previewStore)
        return VerificationCaptureResult(
            capture: analysis.capture,
            frameSnapshot: analysis.frameSnapshot,
            protectedTemplate: analysis.protectedTemplate,
            faceImageBase64: analysis.faceImageBase64,
            matchScore: protector.similarity(enrolledTemplate, analysis.protectedTemplate)
        )
    }

    private func analyze(previewStore: CameraPreviewStore) throws -> RawCaptureAnalysis {
        guard runtimeStatus(previewStore: previewStore).ready else {
            throw CapturePipelineError.runtimeUnavailable(
                runtimeStatus(previewStore: previewStore).blockedReason ?? "Capture runtime unavailable."
            )
        }
        guard let packet = previewStore.latestFrame() else {
            throw CapturePipelineError.noFrameAvailable
        }

        let faceAnalysis = try detectAndCropFace(
            pixelBuffer: packet.pixelBuffer,
            orientation: previewStore.analysisOrientation
        )
        let depthAnalysis = try analyzeDepth(packet.depthData)
        guard depthAnalysis.passed else {
            throw CapturePipelineError.depthEvidenceFailed
        }
        let embedding = try predictEmbedding(from: faceAnalysis.resizedPixelBuffer)
        let protectedTemplate = protector.protect(embedding)

        let capture = CapturePayload(
            captureToken: "ios-capture-\(UUID().uuidString.lowercased())",
            qualityScore: faceAnalysis.qualityScore,
            livenessScore: depthAnalysis.score,
            bboxConfidence: faceAnalysis.bbox.confidence,
            providerManifests: providerManifests
        )
        let frameSnapshot = CaptureFrameSnapshot(
            faceDetected: true,
            qualityScore: faceAnalysis.qualityScore,
            livenessScore: depthAnalysis.score,
            bboxConfidence: faceAnalysis.bbox.confidence,
            brightnessScore: faceAnalysis.brightnessScore,
            sharpnessScore: faceAnalysis.sharpnessScore,
            hasDepth: depthAnalysis.hasDepth,
            depthCoverage: depthAnalysis.coverage,
            depthVariance: depthAnalysis.variance,
            depthRange: depthAnalysis.range,
            depthEvidencePassed: depthAnalysis.passed,
            faceCount: faceAnalysis.observations.count,
            bbox: faceAnalysis.bbox,
            capturedAt: .now
        )
        return RawCaptureAnalysis(
            capture: capture,
            frameSnapshot: frameSnapshot,
            protectedTemplate: protectedTemplate,
            faceImageBase64: faceAnalysis.faceImageBase64
        )
    }

    private func detectAndCropFace(
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation
    ) throws -> FaceCropAnalysis {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        try handler.perform([request])
        let observations = request.results ?? []
        guard let selected = observations.max(by: {
            let lhsArea = $0.boundingBox.width * $0.boundingBox.height
            let rhsArea = $1.boundingBox.width * $1.boundingBox.height
            return lhsArea < rhsArea
        }) else {
            throw CapturePipelineError.noFaceDetected
        }

        let orientedImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        let extent = orientedImage.extent.integral
        let faceRect = VNImageRectForNormalizedRect(selected.boundingBox, Int(extent.width), Int(extent.height))
        let modelInsetX = faceRect.width * 0.12
        let modelInsetY = faceRect.height * 0.18
        let modelRect = faceRect.insetBy(dx: -modelInsetX, dy: -modelInsetY).intersection(extent)
        let previewInsetX = faceRect.width * 0.32
        let previewInsetY = faceRect.height * 0.40
        let previewRect = faceRect.insetBy(dx: -previewInsetX, dy: -previewInsetY).intersection(extent)
        let modelCrop = orientedImage.cropped(to: modelRect)
        let normalizedModelCrop = modelCrop.transformed(
            by: CGAffineTransform(
                translationX: -modelRect.origin.x,
                y: -modelRect.origin.y
            )
        )
        let previewCrop = orientedImage.cropped(to: previewRect)
        let normalizedPreviewCrop = previewCrop.transformed(
            by: CGAffineTransform(
                translationX: -previewRect.origin.x,
                y: -previewRect.origin.y
            )
        )

        let scaled = normalizedModelCrop
            .transformed(
                by: CGAffineTransform(
                    scaleX: 112.0 / max(normalizedModelCrop.extent.width, 1),
                    y: 112.0 / max(normalizedModelCrop.extent.height, 1)
                )
            )

        guard let resized = makePixelBuffer(width: 112, height: 112) else {
            throw CapturePipelineError.modelPredictionFailed
        }
        ciContext.render(
            scaled,
            to: resized,
            bounds: CGRect(x: 0, y: 0, width: 112, height: 112),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        let metrics = computeImageMetrics(pixelBuffer: resized)
        let faceAreaScore = min(1.0, (selected.boundingBox.width * selected.boundingBox.height) / 0.22)
        let qualityScore = clamp(
            (Double(selected.confidence) * 0.30)
                + (metrics.brightnessScore * 0.25)
                + (metrics.sharpnessScore * 0.30)
                + (faceAreaScore * 0.15)
        )

        return FaceCropAnalysis(
            resizedPixelBuffer: resized,
            observations: observations,
            selectedObservation: selected,
            bbox: BoundingBoxPayload(
                x: Double(faceRect.origin.x),
                y: Double(faceRect.origin.y),
                width: Double(faceRect.width),
                height: Double(faceRect.height),
                confidence: Double(selected.confidence)
            ),
            brightnessScore: metrics.brightnessScore,
            sharpnessScore: metrics.sharpnessScore,
            qualityScore: qualityScore,
            faceImageBase64: ciImageToJPEGBase64(normalizedPreviewCrop, maxDimension: 720)
        )
    }

    private func analyzeDepth(_ depthData: AVDepthData?) throws -> DepthAnalysis {
        guard let depthData else {
            throw CapturePipelineError.noDepthData
        }
        let converted = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let depthBuffer = converted.depthDataMap
        CVPixelBufferLockBaseAddress(depthBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(depthBuffer) else {
            throw CapturePipelineError.noDepthData
        }

        let width = CVPixelBufferGetWidth(depthBuffer)
        let height = CVPixelBufferGetHeight(depthBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthBuffer)
        let patchX0 = width * 3 / 10
        let patchX1 = width * 7 / 10
        let patchY0 = height * 2 / 10
        let patchY1 = height * 8 / 10

        var values: [Float] = []
        values.reserveCapacity((patchX1 - patchX0) * (patchY1 - patchY0))

        for y in patchY0..<patchY1 {
            let row = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float32.self)
            for x in patchX0..<patchX1 {
                let depth = row[x]
                if depth.isFinite, depth > 0.05, depth < 1.5 {
                    values.append(depth)
                }
            }
        }

        guard values.count > 64 else {
            return DepthAnalysis(
                score: 0.1,
                hasDepth: true,
                coverage: 0.0,
                variance: 0.0,
                range: 0.0,
                passed: false
            )
        }

        let count = Double(values.count)
        let mean = values.reduce(0.0) { $0 + Double($1) } / count
        let variance = values.reduce(0.0) { partial, value in
            let delta = Double(value) - mean
            return partial + (delta * delta)
        } / count
        let stddev = sqrt(variance)
        let minDepth = Double(values.min() ?? 0)
        let maxDepth = Double(values.max() ?? 0)
        let range = maxDepth - minDepth
        let coverage = count / Double(max((patchX1 - patchX0) * (patchY1 - patchY0), 1))

        let surfaceScore = clamp((stddev - 0.002) / 0.018)
        let rangeScore = clamp((range - 0.010) / 0.060)
        let coverageScore = clamp((coverage - 0.20) / 0.60)
        let total = clamp((surfaceScore * 0.50) + (rangeScore * 0.35) + (coverageScore * 0.15))
        let passed = coverage >= 0.24 && range >= 0.012 && stddev >= 0.0035
        return DepthAnalysis(
            score: total,
            hasDepth: true,
            coverage: coverage,
            variance: variance,
            range: range,
            passed: passed
        )
    }

    private func predictEmbedding(from pixelBuffer: CVPixelBuffer) throws -> [Double] {
        let model = try modelLoadResult.get()
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "input": MLFeatureValue(pixelBuffer: pixelBuffer),
        ])
        let prediction = try model.prediction(from: provider)
        guard let outputName = prediction.featureNames.first,
              let multiArray = prediction.featureValue(for: outputName)?.multiArrayValue
        else {
            throw CapturePipelineError.modelPredictionFailed
        }

        let pointer = UnsafeMutablePointer<Double>.allocate(capacity: multiArray.count)
        defer { pointer.deallocate() }

        var result = Array(repeating: 0.0, count: multiArray.count)
        switch multiArray.dataType {
        case .double:
            let values = UnsafeBufferPointer(
                start: multiArray.dataPointer.assumingMemoryBound(to: Double.self),
                count: multiArray.count
            )
            result = Array(values)
        case .float32:
            let values = UnsafeBufferPointer(
                start: multiArray.dataPointer.assumingMemoryBound(to: Float32.self),
                count: multiArray.count
            )
            result = values.map(Double.init)
        case .float16:
            for index in 0..<multiArray.count {
                result[index] = multiArray[index].doubleValue
            }
        default:
            for index in 0..<multiArray.count {
                result[index] = multiArray[index].doubleValue
            }
        }

        let magnitude = sqrt(result.reduce(0.0) { $0 + ($1 * $1) })
        guard magnitude > 0 else {
            throw CapturePipelineError.modelPredictionFailed
        }
        return result.map { $0 / magnitude }
    }

    private func computeImageMetrics(pixelBuffer: CVPixelBuffer) -> (brightnessScore: Double, sharpnessScore: Double) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return (0.0, 0.0)
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        var luminanceTotal = 0.0
        var luminanceValues = Array(repeating: 0.0, count: width * height)

        for y in 0..<height {
            let row = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let offset = x * 4
                let blue = Double(row[offset]) / 255.0
                let green = Double(row[offset + 1]) / 255.0
                let red = Double(row[offset + 2]) / 255.0
                let luma = (0.299 * red) + (0.587 * green) + (0.114 * blue)
                let index = (y * width) + x
                luminanceValues[index] = luma
                luminanceTotal += luma
            }
        }

        let mean = luminanceTotal / Double(max(width * height, 1))
        let brightnessScore = clamp(1.0 - abs(mean - 0.55) / 0.40)

        var edgeTotal = 0.0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let center = luminanceValues[(y * width) + x]
                let left = luminanceValues[(y * width) + (x - 1)]
                let right = luminanceValues[(y * width) + (x + 1)]
                let top = luminanceValues[((y - 1) * width) + x]
                let bottom = luminanceValues[((y + 1) * width) + x]
                edgeTotal += abs((4 * center) - left - right - top - bottom)
            }
        }
        let edgeMean = edgeTotal / Double(max((width - 2) * (height - 2), 1))
        let sharpnessScore = clamp(edgeMean / 0.22)
        return (brightnessScore, sharpnessScore)
    }

    private func loadModel() -> Result<MLModel, Error> {
        do {
            guard let url = bundledModelURL() else {
                throw CapturePipelineError.runtimeUnavailable("Bundled Core ML face model not found in the app resources.")
            }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            return .success(try MLModel(contentsOf: url, configuration: configuration))
        } catch {
            return .failure(error)
        }
    }

    private func bundledModelURL() -> URL? {
        let directCandidates = [
            Bundle.main.url(forResource: "ArcFaceMobileFace", withExtension: "mlmodelc"),
            Bundle.main.url(forResource: "ArcFaceMobileFace", withExtension: "mlmodelc", subdirectory: "Models"),
            Bundle.main.url(forResource: "ArcFaceMobileFace", withExtension: "mlmodelc", subdirectory: "Support/Models"),
        ]
        if let first = directCandidates.compactMap({ $0 }).first {
            return first
        }
        return Bundle.main.urls(forResourcesWithExtension: "mlmodelc", subdirectory: nil)?
            .first(where: { $0.lastPathComponent == "ArcFaceMobileFace.mlmodelc" })
    }

    private func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
        ]
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
        return buffer
    }

    private func ciImageToJPEGBase64(_ ciImage: CIImage, maxDimension: CGFloat? = nil) -> String {
        let normalizedImage = ciImage.transformed(
            by: CGAffineTransform(
                translationX: -ciImage.extent.origin.x,
                y: -ciImage.extent.origin.y
            )
        )
        let extent = normalizedImage.extent.integral
        guard extent.isNull == false, extent.isEmpty == false else {
            return ""
        }
        let imageForEncoding: CIImage
        if let maxDimension, maxDimension > 0 {
            let scale = min(maxDimension / max(extent.width, extent.height), 1.0)
            imageForEncoding = normalizedImage.transformed(
                by: CGAffineTransform(scaleX: scale, y: scale)
            )
        } else {
            imageForEncoding = normalizedImage
        }
        let renderExtent = imageForEncoding.extent.integral
        guard let cgImage = ciContext.createCGImage(imageForEncoding, from: renderExtent) else {
            return ""
        }
        let image = UIImage(cgImage: cgImage)
        guard let data = image.jpegData(compressionQuality: 0.90) else {
            return ""
        }
        return data.base64EncodedString()
    }

    private func clamp(_ value: Double) -> Double {
        min(max(value, 0.0), 1.0)
    }
}
