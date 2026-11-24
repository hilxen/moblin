import CoreLocation

extension Model {
    func updateLocation() {
        var location = locationManager.status()
        if let realtimeIrl {
            location += realtimeIrl.status()
        }
        if location != statusTopRight.location {
            statusTopRight.location = location
        }
    }

    func reloadLocation() {
        locationManager.stop()
        headingManager?.stop()
        if isLocationEnabled() {
            locationManager.start(accuracy: database.location.desiredAccuracy,
                                  distanceFilter: database.location.distanceFilter,
                                  onUpdate: handleLocationUpdate)
            // Fallback heading source for the server-side map overlay telemetry —
            // see handleLocationUpdate() below. Harmless/no-op on a device without
            // the needed sensors (HeadingManager checks availability itself).
            headingManager?.start()
        }
        reloadRealtimeIrl()
    }

    func resetLocationData() {
        resetDistance()
        resetAltitude()
        resetAverageSpeed()
        resetSlope()
    }

    func resetSplitLocationData() {
        resetSplitDistance()
        resetSplitAltitude()
    }

    func isLocationEnabled() -> Bool {
        database.location.enabled
    }

    func isLocationInPrivacyRegion(location: CLLocation) -> Bool {
        for region in database.location.privacyRegions
            where region.contains(coordinate: location.coordinate)
        {
            return true
        }
        return false
    }

    func getLatestKnownLocation() -> (Double, Double)? {
        if let location = locationManager.getLatestKnownLocation() {
            (location.coordinate.latitude, location.coordinate.longitude)
        } else {
            nil
        }
    }

    func isRealtimeIrlConfigured() -> Bool {
        stream.realtimeIrlEnabled && !stream.realtimeIrlBaseUrl.isEmpty && !stream.realtimeIrlPushKey
            .isEmpty
    }

    func reloadRealtimeIrl() {
        realtimeIrl?.stop()
        realtimeIrl = nil
        if isRealtimeIrlConfigured() {
            realtimeIrl = RealtimeIrl(baseUrl: stream.realtimeIrlBaseUrl, pushKey: stream.realtimeIrlPushKey)
        }
    }

    func updateDistance() {
        let location = locationManager.getLatestKnownLocation()
        if let latestKnownLocation {
            let distance = location?.distance(from: latestKnownLocation) ?? 0
            if distance > latestKnownLocation.horizontalAccuracy {
                database.location.distance += distance
                database.location.splitDistance += distance
                self.latestKnownLocation = location
            }
        } else {
            latestKnownLocation = location
        }
    }

    func updateAltitude() {
        guard let location = locationManager.getLatestKnownLocation(), location.verticalAccuracy > 0 else {
            return
        }
        guard let altitudeReference else {
            altitudeReference = location.altitude
            return
        }
        let deltaAltitude = location.altitude - altitudeReference
        guard abs(deltaAltitude) >= max(location.verticalAccuracy, 3.0) else {
            return
        }
        if deltaAltitude > 0 {
            database.location.altitudeAscent += deltaAltitude
            database.location.splitAltitudeAscent += deltaAltitude
        } else {
            database.location.altitudeDescent += -deltaAltitude
            database.location.splitAltitudeDescent += -deltaAltitude
        }
        self.altitudeReference = location.altitude
    }

    func resetSlope() {
        slopePercent = 0.0
        previousSlopeAltitude = nil
        previousSlopeDistance = database.location.distance
    }

    func updateSlope() {
        guard let location = locationManager.getLatestKnownLocation() else {
            return
        }
        let deltaDistance = database.location.distance - previousSlopeDistance
        guard deltaDistance != 0 else {
            return
        }
        previousSlopeDistance = database.location.distance
        let deltaAltitude = location.altitude - (previousSlopeAltitude ?? location.altitude)
        previousSlopeAltitude = location.altitude
        slopePercent = 0.7 * slopePercent + 0.3 * (100 * deltaAltitude / deltaDistance)
    }

    func resetAverageSpeed() {
        averageSpeed = 0.0
        averageSpeedStartTime = .now
        averageSpeedStartDistance = database.location.distance
    }

    func updateAverageSpeed(now: ContinuousClock.Instant) {
        let distance = database.location.distance - averageSpeedStartDistance
        let elapsed = averageSpeedStartTime.duration(to: now)
        averageSpeed = distance / elapsed.seconds
    }

    func isShowingStatusLocation() -> Bool {
        database.show.location && isLocationEnabled()
    }

    private func resetDistance() {
        database.location.distance = 0.0
        latestKnownLocation = nil
        resetSplitDistance()
    }

    private func resetSplitDistance() {
        database.location.splitDistance = 0.0
    }

    private func resetAltitude() {
        database.location.altitudeAscent = 0.0
        database.location.altitudeDescent = 0.0
        altitudeReference = nil
        resetSplitAltitude()
    }

    private func resetSplitAltitude() {
        database.location.splitAltitudeAscent = 0.0
        database.location.splitAltitudeDescent = 0.0
    }

    private func handleLocationUpdate(location: CLLocation) {
        guard isLive, !isLocationInPrivacyRegion(location: location) else {
            return
        }
        realtimeIrl?.update(location: location)
        sendTelemetryIfDue(location: location)
    }

    /// Throttles telemetry pushes to the server-side map overlay bridge to a fixed
    /// rate (independent of this device's actual GPS update interval, which varies
    /// with distanceFilter/accuracy settings and real-world movement) — see
    /// RemoteControlTelemetry's docs for why capturedAt needs a clock-offset
    /// correction applied here, not assumed correct downstream.
    private func sendTelemetryIfDue(location: CLLocation) {
        let now = Date()
        if let lastTelemetrySentAt, now.timeIntervalSince(lastTelemetrySentAt) < telemetryMinIntervalS {
            return
        }
        lastTelemetrySentAt = now
        let data = RemoteControlTelemetry(
            location: RemoteControlRemoteSceneDataLocation(location: location),
            deviceHeadingDegrees: headingManager?.getLatest(),
            horizontalAccuracy: location.horizontalAccuracy,
            capturedAt: remoteControlStreamer?.correctedCapturedAt(localCapturedAt: now) ?? now
        )
        remoteControlStreamer?.sendTelemetry(data: data)
    }
}
