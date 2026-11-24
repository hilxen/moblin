import CoreMotion

/// Device-motion-derived heading (true-north-relative degrees), used as a fallback
/// for the server-side map overlay when GPS course isn't meaningful (stationary, or
/// too slow for CLLocation's course to mean anything). Mirrors GForceManager's shape
/// — a thin wrapper around a shared CMMotionManager instance.
class HeadingManager {
    private let motionManager: CMMotionManager
    private var latest: Double?
    private var started = false

    init(motionManager: CMMotionManager) {
        self.motionManager = motionManager
    }

    func start() {
        guard !started, CMMotionManager().isDeviceMotionAvailable else {
            return
        }
        started = true
        motionManager.deviceMotionUpdateInterval = 0.1
        motionManager.startDeviceMotionUpdates(using: .xMagneticNorthZVertical, to: .main) { data, error in
            guard let data, error == nil else {
                return
            }
            self.handleDeviceMotionUpdate(data: data)
        }
    }

    func stop() {
        guard started else {
            return
        }
        started = false
        motionManager.stopDeviceMotionUpdates()
    }

    func getLatest() -> Double? {
        latest
    }

    private func handleDeviceMotionUpdate(data: CMDeviceMotion) {
        guard data.heading >= 0 else {
            // Negative means invalid/unavailable per CMDeviceMotion's documented contract.
            return
        }
        latest = data.heading
    }
}
