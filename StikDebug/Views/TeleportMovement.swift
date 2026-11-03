//
//  TeleportMovement.swift
//  Teleport
//
//  Moves the simulated location smoothly: joystick walking, or following
//  a path (a driving route or a line drawn on the map).
//

import SwiftUI
import CoreLocation
import MapKit

enum MoveMode: String, CaseIterable, Identifiable {
    case pin, joystick, drive, draw

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .pin: return "mappin.and.ellipse"
        case .joystick: return "gamecontroller.fill"
        case .drive: return "car.fill"
        case .draw: return "pencil.tip"
        }
    }

    var label: String {
        switch self {
        case .pin: return "Pin"
        case .joystick: return "Joystick"
        case .drive: return "Drive"
        case .draw: return "Draw"
        }
    }
}

enum MoveSpeed: String, CaseIterable, Identifiable {
    case walk, run, bike, drive

    var id: String { rawValue }

    /// Meters per second.
    var metersPerSecond: Double {
        switch self {
        case .walk: return 1.4      // ~3 mph
        case .run: return 3.0       // ~7 mph
        case .bike: return 5.5      // ~12 mph
        case .drive: return 11.2    // ~25 mph (base speed)
        }
    }

    var label: String {
        switch self {
        case .walk: return "Walk"
        case .run: return "Run"
        case .bike: return "Bike"
        case .drive: return "Drive"
        }
    }

    var icon: String {
        switch self {
        case .walk: return "figure.walk"
        case .run: return "figure.run"
        case .bike: return "bicycle"
        case .drive: return "car.fill"
        }
    }
}

final class MoveEngine: ObservableObject {
    enum Kind { case idle, joystick, path }

    @Published private(set) var kind: Kind = .idle
    @Published var current: CLLocationCoordinate2D?
    @Published private(set) var progress: Double = 0

    /// Joystick direction: dx = east, dy = north, each -1...1.
    var vector = CGVector.zero
    var speed: Double = MoveSpeed.walk.metersPerSecond
    var onError: ((Int32) -> Void)?
    var onFinish: ((CLLocationCoordinate2D) -> Void)?

    var isMoving: Bool { kind != .idle }

    private let tickInterval: TimeInterval = 0.5
    private var timer: Timer?
    private var path: [CLLocationCoordinate2D] = []
    private var cumulative: [Double] = []
    private var traveled: Double = 0
    private var inFlight = false
    private var idleTicks = 0
    private var failures = 0
    private var pairingPath = ""
    private var deviceIP = ""

    func startJoystick(at coordinate: CLLocationCoordinate2D) {
        begin(.joystick, at: coordinate)
    }

    func follow(_ coordinates: [CLLocationCoordinate2D]) {
        guard coordinates.count > 1 else { return }
        path = coordinates
        cumulative = [0]
        for (a, b) in zip(coordinates, coordinates.dropFirst()) {
            cumulative.append(cumulative.last! + Self.distance(a, b))
        }
        traveled = 0
        progress = 0
        begin(.path, at: coordinates[0])
    }

    /// Stops moving and returns where it stopped.
    @discardableResult
    func stop() -> CLLocationCoordinate2D? {
        timer?.invalidate()
        timer = nil
        kind = .idle
        vector = .zero
        return current
    }

    private func begin(_ kind: Kind, at coordinate: CLLocationCoordinate2D) {
        timer?.invalidate()
        self.kind = kind
        current = coordinate
        failures = 0
        idleTicks = 0
        pairingPath = PairingFileStore.prepareURL().path
        deviceIP = DeviceConnectionContext.targetIPAddress
        LocationSimulationSession.shared.pauseResending()
        send(coordinate, force: true)
        let timer = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            self?.step()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func step() {
        guard let coordinate = current else { return }
        switch kind {
        case .idle:
            return
        case .joystick:
            let magnitude = hypot(vector.dx, vector.dy)
            guard magnitude > 0.08 else {
                // Standing still: keep the spot alive every ~4 seconds.
                idleTicks += 1
                if idleTicks % 8 == 0 { send(coordinate, force: false) }
                return
            }
            idleTicks = 0
            let meters = speed * tickInterval * min(Double(magnitude), 1)
            let next = Self.offset(
                coordinate,
                east: meters * Double(vector.dx / magnitude),
                north: meters * Double(vector.dy / magnitude)
            )
            current = next
            send(next, force: false)
        case .path:
            traveled += speed * tickInterval
            let total = cumulative.last ?? 0
            if traveled >= total, let end = path.last {
                current = end
                progress = 1
                send(end, force: true)
                timer?.invalidate()
                timer = nil
                kind = .idle
                onFinish?(end)
                return
            }
            let point = point(atDistance: traveled)
            current = point
            progress = total > 0 ? traveled / total : 0
            send(point, force: false)
        }
    }

    private func send(_ coordinate: CLLocationCoordinate2D, force: Bool) {
        // Skip a frame instead of piling up requests if the last one is still going.
        if inFlight && !force { return }
        inFlight = true
        let ip = deviceIP
        let pairing = pairingPath
        LocationSimulationCommandQueue.shared.async { [weak self] in
            let code = simulate_location(ip, coordinate.latitude, coordinate.longitude, pairing)
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                if code == 0 {
                    self.failures = 0
                    let session = LocationSimulationSession.shared
                    if session.isActive {
                        session.updateCoordinate(coordinate)
                    } else {
                        session.start(at: coordinate)
                    }
                } else {
                    self.failures += 1
                    if self.failures >= 4, self.isMoving {
                        self.stop()
                        self.onError?(code)
                    }
                }
            }
        }
    }

    private func point(atDistance distance: Double) -> CLLocationCoordinate2D {
        guard path.count > 1 else { return path.first ?? current ?? CLLocationCoordinate2D() }
        for index in 0..<(path.count - 1) where cumulative[index + 1] >= distance {
            let segment = cumulative[index + 1] - cumulative[index]
            let fraction = segment > 0 ? (distance - cumulative[index]) / segment : 0
            let a = path[index], b = path[index + 1]
            return CLLocationCoordinate2D(
                latitude: a.latitude + (b.latitude - a.latitude) * fraction,
                longitude: a.longitude + (b.longitude - a.longitude) * fraction
            )
        }
        return path.last!
    }

    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    static func offset(_ c: CLLocationCoordinate2D, east: Double, north: Double) -> CLLocationCoordinate2D {
        let metersPerDegree = 111_111.0
        let latitude = c.latitude + north / metersPerDegree
        let longitude = c.longitude + east / (metersPerDegree * max(cos(c.latitude * .pi / 180), 0.01))
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    static func coordinates(of polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        var coordinates = [CLLocationCoordinate2D](
            repeating: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            count: polyline.pointCount
        )
        polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: polyline.pointCount))
        return coordinates
    }

    static func length(of coordinates: [CLLocationCoordinate2D]) -> Double {
        zip(coordinates, coordinates.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
    }
}
