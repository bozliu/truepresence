import AVFoundation
import Foundation

enum CameraPermissionState: String {
    case unknown
    case authorized
    case denied
    case restricted

    var isGranted: Bool {
        self == .authorized
    }
}

struct CameraPermissionService {
    func currentState() -> CameraPermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
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

    func requestAccess() async -> CameraPermissionState {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        return granted ? .authorized : .denied
    }
}
