//
//  QuickSpotsView.swift
//  Teleport
//
//  Full-screen map with floating Liquid Glass controls.
//  Pick a spot, tap Teleport, save favorites and jump between them.
//  Saved spots are shared with the full Location tool ("locationBookmarks").
//

import SwiftUI
import MapKit
import UIKit

// MARK: - Glass helpers

private extension View {
    /// Real Liquid Glass on iOS 26+, frosted material on older versions.
    @ViewBuilder
    func teleportGlass<S: Shape>(_ shape: S, tint: Color? = nil) -> some View {
        if #available(iOS 26, *) {
            if let tint {
                self.glassEffect(.regular.tint(tint.opacity(0.35)).interactive(), in: shape)
            } else {
                self.glassEffect(.regular.interactive(), in: shape)
            }
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(.white.opacity(0.35), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        }
    }
}

/// Quick shrink-and-bounce so every tap feels instant.
private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

private enum PendingAction {
    case go(CLLocationCoordinate2D, String?)
    case stop
}

private enum TeleportMapStyle: Int, CaseIterable {
    case standard, hybrid, satellite

    var next: TeleportMapStyle {
        TeleportMapStyle(rawValue: (rawValue + 1) % TeleportMapStyle.allCases.count) ?? .standard
    }

    var mapStyle: MapStyle {
        switch self {
        case .standard: return .standard(elevation: .realistic)
        case .hybrid: return .hybrid(elevation: .realistic)
        case .satellite: return .imagery(elevation: .realistic)
        }
    }

    var icon: String {
        switch self {
        case .standard: return "map"
        case .hybrid: return "map.fill"
        case .satellite: return "globe.americas.fill"
        }
    }

    var label: String {
        switch self {
        case .standard: return "Standard"
        case .hybrid: return "Hybrid"
        case .satellite: return "Satellite"
        }
    }
}

// MARK: - Main view

struct QuickSpotsView: View {
    @ObservedObject private var tunnel = TunnelManager.shared
    @ObservedObject private var session = LocationSimulationSession.shared
    @StateObject private var searchCompleter = LocationSearchCompleter()

    @AppStorage("teleportMapStyle") private var mapStyleRaw = TeleportMapStyle.standard.rawValue
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var selected: CLLocationCoordinate2D?
    @State private var selectedName: String?
    @State private var activeName: String?

    @State private var spots: [LocationBookmark] = []
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    @Environment(\.scenePhase) private var scenePhase
    @State private var refreshTick = 0
    @State private var isBusy = false
    @State private var pending: PendingAction?
    @State private var showSavePrompt = false
    @State private var saveName = ""
    @State private var renamingSpot: LocationBookmark?
    @State private var renameText = ""
    @State private var errorMessage: String?
    @State private var showMenu = false
    @State private var styleToast: String?
    @State private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    // Movement modes
    @StateObject private var engine = MoveEngine()
    @State private var mode: MoveMode = .pin
    @State private var moveSpeed: MoveSpeed = .walk
    @State private var mapCenter: CLLocationCoordinate2D?
    @State private var cameraDistance: Double = 1200
    @State private var driveStart: CLLocationCoordinate2D?
    @State private var driveEnd: CLLocationCoordinate2D?
    @State private var driveRoute: [CLLocationCoordinate2D] = []
    @State private var isRouting = false
    @State private var drawPath: [CLLocationCoordinate2D] = []
    @State private var penOn = false
    @State private var strokeActive = false

    private static let storageKey = "locationBookmarks"

    private var mapStyle: TeleportMapStyle { TeleportMapStyle(rawValue: mapStyleRaw) ?? .standard }
    private var pairingPath: String { PairingFileStore.prepareURL().path }
    private var hasPairingFile: Bool { FileManager.default.fileExists(atPath: pairingPath) }
    private var isActive: Bool { session.isActive && session.routeCoordinates == nil }

    var body: some View {
        ZStack {
            mapLayer
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                if searchFocused && !searchCompleter.results.isEmpty {
                    searchResults
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                VStack(spacing: 0) {
                    if !searchFocused {
                        modePanel
                            .padding(.bottom, 10)
                        modePicker
                            .padding(.bottom, 10)
                    }
                    bottomBar
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }
                .padding(.top, 6)
                .contentShape(Rectangle())
                .onTapGesture { }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: searchFocused)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: mode)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: searchCompleter.results.count)
        }
        .toolbar(.hidden, for: .tabBar)
        .onAppear {
            loadSpots()
            connectIfNeeded()
            engine.onError = { code in
                errorMessage = "Movement stopped (error \(code)). Make sure LocalDevVPN is on and you're on Wi-Fi."
                if let last = engine.current { resumeResending(at: last) }
            }
            engine.onFinish = { end in
                activeName = "Arrived"
                resumeResending(at: end)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
            if isActive, let coordinate = session.coordinate {
                selected = coordinate
                position = .region(region(around: coordinate))
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Re-check the pairing file and connection whenever the app comes back.
            if phase == .active {
                refreshTick += 1
                connectIfNeeded()
            }
        }
        .onChange(of: showMenu) { _, open in
            if !open {
                refreshTick += 1
                connectIfNeeded()
            }
        }
        .onReceive(engine.$current) { coordinate in
            guard engine.isMoving, let coordinate else { return }
            withAnimation(.linear(duration: 0.5)) {
                position = .camera(MapCamera(centerCoordinate: coordinate, distance: cameraDistance))
            }
        }
        .sheet(isPresented: $showMenu) { menuSheet }
        .alert("Save Spot", isPresented: $showSavePrompt) {
            TextField("e.g. Main Gate", text: $saveName)
            Button("Save") { saveSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(selected.map { format($0) } ?? "")
        }
        .alert("Rename Spot", isPresented: Binding(
            get: { renamingSpot != nil },
            set: { if !$0 { renamingSpot = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Save") { commitRename() }
            Button("Cancel", role: .cancel) { renamingSpot = nil }
        }
        .alert("Couldn't Teleport", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Map

    private var mapLayer: some View {
        MapReader { proxy in
            Map(position: $position) {
                UserAnnotation()
                if let selected, !(isActive && isSame(selected, session.coordinate)) {
                    Marker(selectedName ?? "Selected", systemImage: "mappin", coordinate: selected)
                        .tint(.red)
                }
                if mode == .drive {
                    if driveRoute.count > 1 {
                        MapPolyline(coordinates: driveRoute)
                            .stroke(Color.blue.opacity(0.85), lineWidth: 6)
                    }
                    if let driveStart {
                        Marker("Start", systemImage: "flag.fill", coordinate: driveStart)
                            .tint(.green)
                    }
                    if let driveEnd {
                        Marker("End", systemImage: "flag.checkered", coordinate: driveEnd)
                            .tint(.red)
                    }
                }
                if mode == .draw, drawPath.count > 1 {
                    MapPolyline(coordinates: drawPath)
                        .stroke(Color.purple.opacity(0.9), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                }
                if isActive, let active = session.coordinate {
                    Annotation(activeName ?? "Teleported", coordinate: active, anchor: .center) {
                        ZStack {
                            Circle().fill(Color.blue.opacity(0.18)).frame(width: 54, height: 54)
                            Circle().fill(Color.white).frame(width: 24, height: 24)
                            Circle().fill(Color.blue).frame(width: 16, height: 16)
                        }
                    }
                }
            }
            .mapStyle(mapStyle.mapStyle)
            .mapControls { }
            .onMapCameraChange(frequency: .onEnd) { context in
                mapCenter = context.region.center
                cameraDistance = context.camera.distance
            }
            .overlay {
                if mode == .draw && penOn {
                    // Finger draws a path instead of moving the map.
                    Color.white.opacity(0.001)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    if !strokeActive {
                                        strokeActive = true
                                        drawPath = []
                                    }
                                    guard let coordinate = proxy.convert(value.location, from: .local) else { return }
                                    if let last = drawPath.last, MoveEngine.distance(last, coordinate) < 3 { return }
                                    drawPath.append(coordinate)
                                }
                                .onEnded { _ in
                                    strokeActive = false
                                    penOn = false
                                    if drawPath.count > 1 {
                                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                                    }
                                }
                        )
                }
            }
            .onTapGesture { point in
                if searchFocused {
                    searchFocused = false
                    return
                }
                guard let coordinate = proxy.convert(point, from: .local) else { return }
                UISelectionFeedbackGenerator().selectionChanged()
                switch mode {
                case .drive:
                    handleDriveTap(coordinate)
                case .draw:
                    break
                case .pin, .joystick:
                    selected = coordinate
                    selectedName = nil
                }
            }
        }
    }

    // MARK: Top

    private var topBar: some View {
        HStack(alignment: .top) {
            statusPill
            Spacer()
            VStack(spacing: 10) {
                circleButton(icon: mapStyle.icon, label: "Map style") {
                    mapStyleRaw = mapStyle.next.rawValue
                    flashStyleToast(mapStyle.label)
                }
                circleButton(icon: "location.fill", label: "Recenter") { recenter() }
                circleButton(icon: "gearshape.fill", label: "Settings") { showMenu = true }
            }
            .padding(6)
            .contentShape(Rectangle())
            .onTapGesture { }
            .padding(-6)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .overlay(alignment: .top) {
            if let styleToast {
                Text(styleToast)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .teleportGlass(Capsule())
                    .padding(.top, 54)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
    }

    private var statusPill: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
            Text(statusText)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .teleportGlass(Capsule())
        .onTapGesture {
            if isActive, let coordinate = session.coordinate {
                withAnimation { position = .region(region(around: coordinate)) }
            } else if !tunnel.isConnected {
                connectIfNeeded()
            }
        }
    }

    private var statusColor: Color {
        if !hasPairingFile { return .red }
        if isActive { return .green }
        if tunnel.isConnected { return .gray }
        return tunnel.isStarting ? .yellow : .orange
    }

    private var statusText: String {
        _ = refreshTick
        if !hasPairingFile { return "Pairing file needed" }
        if engine.isMoving {
            if engine.kind == .joystick { return "Joystick · \(moveSpeed.label)" }
            return "\(activeName ?? "Moving") · \(Int(engine.progress * 100))%"
        }
        if isActive { return "Teleport on: \(activeName ?? "Pinned spot")" }
        if tunnel.isConnected { return "Real location" }
        if tunnel.isStarting { return "Connecting…" }
        return "Not connected – tap to retry"
    }

    // MARK: Bottom

    @ViewBuilder
    private var spotChips: some View {
        if spots.isEmpty {
            Text(selected == nil ? "Tap the map to drop a pin" : "Tap the star to save this spot")
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .teleportGlass(Capsule())
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(spots) { spot in
                        spotChip(spot)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
        }
    }

    private func spotChip(_ spot: LocationBookmark) -> some View {
        let isCurrent = isActive && isSame(spot.coordinate, session.coordinate)
        return Button {
            selected = spot.coordinate
            selectedName = spot.name
            withAnimation { position = .region(region(around: spot.coordinate)) }
            go(to: spot.coordinate, name: spot.name)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isCurrent ? "location.fill" : "mappin")
                    .font(.caption.weight(.bold))
                Text(spot.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isCurrent ? Color.white : Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .teleportGlass(Capsule(), tint: isCurrent ? .blue : nil)
        }
        .buttonStyle(PressableStyle())
        .contextMenu {
            Button {
                selected = spot.coordinate
                selectedName = spot.name
                withAnimation { position = .region(region(around: spot.coordinate)) }
            } label: {
                Label("Show on Map", systemImage: "map")
            }
            Button {
                renameText = spot.name
                renamingSpot = spot
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive) { delete(spot) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search", text: $searchText)
                    .focused($searchFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onChange(of: searchText) { _, value in searchCompleter.update(query: value) }
                    .onSubmit { submitSearchText() }
                if searchFocused || !searchText.isEmpty {
                    Button {
                        searchText = ""
                        searchCompleter.update(query: "")
                        searchFocused = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Cancel search")
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .teleportGlass(Capsule())

            if !searchFocused {
                switch mode {
                case .pin, .joystick:
                    roundAction(icon: "location.north.fill", color: .blue, label: "Teleport here",
                                enabled: canTeleport, loading: isBusy) {
                        if let selected { go(to: selected, name: selectedName) }
                    }
                case .drive:
                    roundAction(icon: "play.fill", color: .blue, label: "Start drive",
                                enabled: driveRoute.count > 1 && !engine.isMoving, loading: isRouting) {
                        startPath(driveRoute, label: "Driving")
                    }
                case .draw:
                    roundAction(icon: "play.fill", color: .blue, label: "Follow drawing",
                                enabled: drawPath.count > 1 && !engine.isMoving) {
                        startPath(drawPath, label: "Following line")
                    }
                }
                roundAction(icon: engine.isMoving ? "pause.fill" : "stop.fill", color: .red,
                            label: engine.isMoving ? "Stop moving" : "Stop teleport",
                            enabled: isActive || engine.isMoving) {
                    if engine.isMoving {
                        stopMoving()
                    } else {
                        stop()
                    }
                }
                roundAction(icon: isSelectedSaved ? "star.fill" : "star", color: .yellow, label: "Save spot",
                            enabled: selected != nil && !isSelectedSaved) {
                    saveName = selectedName ?? ""
                    showSavePrompt = true
                }
            }
        }
    }

    private var canTeleport: Bool {
        guard let selected else { return false }
        return !(isActive && isSame(selected, session.coordinate))
    }

    private var isSelectedSaved: Bool {
        guard let selected else { return false }
        return spots.contains { isSame($0.coordinate, selected) }
    }

    private var searchResults: some View {
        VStack(spacing: 0) {
            ForEach(Array(searchCompleter.results.prefix(5).enumerated()), id: \.offset) { index, result in
                Button {
                    resolve(result)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if !result.subtitle.isEmpty {
                                Text(result.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if index < min(searchCompleter.results.count, 5) - 1 {
                    Divider().padding(.leading, 52)
                }
            }
        }
        .padding(.vertical, 4)
        .teleportGlass(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    // MARK: Modes

    private var modePicker: some View {
        HStack(spacing: 4) {
            ForEach(MoveMode.allCases) { item in
                Button {
                    switchMode(to: item)
                } label: {
                    Image(systemName: item.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(mode == item ? Color.white : Color.primary)
                        .frame(width: 48, height: 36)
                        .background {
                            if mode == item {
                                Capsule().fill(Color.blue.opacity(0.85))
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(item.label)
            }
        }
        .padding(4)
        .teleportGlass(Capsule())
    }

    @ViewBuilder
    private var modePanel: some View {
        switch mode {
        case .pin:
            spotChips
        case .joystick:
            VStack(spacing: 10) {
                HStack {
                    JoystickPad(
                        onStart: { startJoystickIfNeeded() },
                        onChange: { vector in engine.vector = vector }
                    )
                    Spacer()
                }
                .padding(.horizontal, 16)
                speedRow
            }
        case .drive:
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    hintChip(driveHint, icon: "car.fill")
                    if driveStart != nil {
                        smallChip("Reset", icon: "arrow.counterclockwise", selected: false) { resetDrive() }
                    }
                }
                speedRow
            }
        case .draw:
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    smallChip(penOn ? "Draw with your finger" : (drawPath.isEmpty ? "Tap to draw a path" : "Draw again"),
                              icon: "pencil.tip", selected: penOn) {
                        penOn.toggle()
                    }
                    if !drawPath.isEmpty && !penOn {
                        smallChip("Clear", icon: "trash", selected: false) { drawPath = [] }
                    }
                }
                speedRow
            }
        }
    }

    private var speedRow: some View {
        HStack(spacing: 8) {
            ForEach(MoveSpeed.allCases) { item in
                smallChip(item.label, icon: item.icon, selected: moveSpeed == item) {
                    moveSpeed = item
                    engine.speed = item.metersPerSecond
                }
            }
        }
    }

    private var driveHint: String {
        if driveStart == nil { return "Tap the map to set the start" }
        if driveEnd == nil { return "Now tap where to end" }
        if isRouting { return "Finding a route…" }
        if engine.isMoving { return "Driving…" }
        let miles = MoveEngine.length(of: driveRoute) / 1609.34
        return String(format: "%.1f mi route · tap ▶ to drive", miles)
    }

    private func smallChip(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            UISelectionFeedbackGenerator().selectionChanged()
            action()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption.weight(.bold))
                Text(title).font(.footnote.weight(.semibold)).lineLimit(1)
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .teleportGlass(Capsule(), tint: selected ? .blue : nil)
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
    }

    private func hintChip(_ text: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption.weight(.bold))
            Text(text).font(.footnote.weight(.semibold)).lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .teleportGlass(Capsule())
    }

    private func switchMode(to newMode: MoveMode) {
        guard newMode != mode else { return }
        if engine.kind == .joystick { stopMoving() }
        penOn = (newMode == .draw && drawPath.isEmpty)
        switch newMode {
        case .drive:
            if moveSpeed != .drive { moveSpeed = .drive }
        case .joystick, .draw:
            if moveSpeed == .drive { moveSpeed = .walk }
        case .pin:
            break
        }
        engine.speed = moveSpeed.metersPerSecond
        mode = newMode
    }

    private var startingPoint: CLLocationCoordinate2D? {
        engine.current.flatMap { engine.isMoving ? $0 : nil }
            ?? (isActive ? session.coordinate : nil)
            ?? selected
            ?? mapCenter
    }

    private func startJoystickIfNeeded() {
        guard engine.kind != .joystick else { return }
        guard hasPairingFile else {
            errorMessage = "Import your pairing file first (gear button → Settings & Pairing File)."
            return
        }
        guard let start = startingPoint else {
            errorMessage = "Drop a pin first so the joystick knows where to start."
            return
        }
        activeName = "Joystick"
        engine.speed = moveSpeed.metersPerSecond
        engine.startJoystick(at: start)
        beginBackgroundTask()
    }

    private func startPath(_ coordinates: [CLLocationCoordinate2D], label: String) {
        guard hasPairingFile else {
            errorMessage = "Import your pairing file first (gear button → Settings & Pairing File)."
            return
        }
        guard coordinates.count > 1, !isBusy else { return }
        activeName = label
        engine.speed = moveSpeed.metersPerSecond
        engine.follow(coordinates)
        beginBackgroundTask()
    }

    private func stopMoving() {
        if let last = engine.stop() {
            activeName = "Stopped here"
            resumeResending(at: last)
        }
    }

    private func handleDriveTap(_ coordinate: CLLocationCoordinate2D) {
        guard !engine.isMoving else { return }
        if driveStart == nil || driveEnd != nil {
            driveStart = coordinate
            driveEnd = nil
            driveRoute = []
        } else {
            driveEnd = coordinate
            buildDriveRoute()
        }
    }

    private func resetDrive() {
        if engine.kind == .path { stopMoving() }
        driveStart = nil
        driveEnd = nil
        driveRoute = []
    }

    private func buildDriveRoute() {
        guard let start = driveStart, let end = driveEnd else { return }
        isRouting = true
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end))
        request.transportType = .automobile
        MKDirections(request: request).calculate { response, _ in
            DispatchQueue.main.async {
                isRouting = false
                // Ignore a stale answer if the pins changed meanwhile.
                guard driveStart.map({ isSame($0, start) }) == true,
                      driveEnd.map({ isSame($0, end) }) == true else { return }
                if let route = response?.routes.first {
                    var coordinates = MoveEngine.coordinates(of: route.polyline)
                    coordinates.insert(start, at: 0)
                    coordinates.append(end)
                    driveRoute = coordinates
                } else {
                    // No road found (e.g. off-road): drive in a straight line instead.
                    driveRoute = [start, end]
                }
            }
        }
    }

    // MARK: Buttons

    private func circleButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 46, height: 46)
                .teleportGlass(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(label)
    }

    private func roundAction(icon: String, color: Color, label: String, enabled: Bool,
                             loading: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button {
            // Buttons stay "live" at all times so a tap can never fall through to the map.
            guard enabled else {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                return
            }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            action()
        } label: {
            ZStack {
                if loading {
                    ProgressView()
                        .tint(color)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(enabled ? color : Color.secondary.opacity(0.6))
                }
            }
            .frame(width: 52, height: 52)
            .teleportGlass(Circle())
            .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(label)
    }

    // MARK: Menu sheet

    private var menuSheet: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("Settings & Pairing File", systemImage: "gearshape")
                    }
                    NavigationLink {
                        ToolsView()
                    } label: {
                        Label("Advanced Tools", systemImage: "wrench.and.screwdriver")
                    }
                    NavigationLink {
                        HomeView()
                    } label: {
                        Label("JIT", systemImage: "bolt.fill")
                    }
                }
                Section("Saved Spots") {
                    if spots.isEmpty {
                        Text("No saved spots yet")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(spots) { spot in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(spot.name)
                            Text(format(spot.coordinate))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { offsets in
                        spots.remove(atOffsets: offsets)
                        persistSpots()
                    }
                    .onMove { source, destination in
                        spots.move(fromOffsets: source, toOffset: destination)
                        persistSpots()
                    }
                }
            }
            .navigationTitle("Teleport")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !spots.isEmpty { EditButton() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showMenu = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: Logic

    private func go(to coordinate: CLLocationCoordinate2D, name: String?) {
        guard hasPairingFile else {
            errorMessage = "Import your pairing file first (gear button → Settings & Pairing File)."
            return
        }
        searchFocused = false
        if engine.isMoving { engine.stop() }
        guard !isBusy else {
            // Still finishing the last request: remember the newest tap and run it next.
            pending = .go(coordinate, name)
            return
        }
        isBusy = true
        // Stop re-sending the old spot so it can't overwrite the new one.
        session.pauseResending()
        let path = pairingPath
        let ip = DeviceConnectionContext.targetIPAddress
        LocationSimulationCommandQueue.shared.async {
            var code = simulate_location(ip, coordinate.latitude, coordinate.longitude, path)
            if code != 0 {
                // One automatic retry: the first connection after a pause can be slow.
                Thread.sleep(forTimeInterval: 0.6)
                code = simulate_location(ip, coordinate.latitude, coordinate.longitude, path)
            }
            DispatchQueue.main.async {
                isBusy = false
                defer { runPending() }
                guard code == 0 else {
                    connectIfNeeded()
                    errorMessage = "Error \(code). Make sure LocalDevVPN is on and you're on Wi-Fi, then try again."
                    if isActive, let previous = session.coordinate {
                        resumeResending(at: previous)
                    }
                    return
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                activeName = name
                beginBackgroundTask()
                session.clearRoute()
                resumeResending(at: coordinate)
            }
        }
    }

    /// Teleport is the only visible screen now, so it has to start the device connection itself.
    private func connectIfNeeded() {
        guard hasPairingFile, !tunnel.isConnected, !tunnel.isStarting else { return }
        startTunnelInBackground(showErrorUI: false)
    }

    private func resumeResending(at coordinate: CLLocationCoordinate2D) {
        let path = pairingPath
        let ip = DeviceConnectionContext.targetIPAddress
        session.startResending(at: coordinate) {
            LocationSimulationCommandQueue.shared.async {
                _ = simulate_location(ip, coordinate.latitude, coordinate.longitude, path)
            }
        }
    }

    private func runPending() {
        guard let next = pending else { return }
        pending = nil
        switch next {
        case .go(let coordinate, let name): go(to: coordinate, name: name)
        case .stop: stop()
        }
    }

    private func stop() {
        if engine.isMoving { engine.stop() }
        guard !isBusy else {
            pending = .stop
            return
        }
        isBusy = true
        session.pauseResending()
        LocationSimulationCommandQueue.shared.async {
            let code = clear_simulated_location()
            DispatchQueue.main.async {
                isBusy = false
                defer { runPending() }
                session.stop()
                activeName = nil
                endBackgroundTask()
                if code != 0 {
                    errorMessage = "Teleport stopped sending the fake location. If Maps still shows it, restart your iPhone."
                }
            }
        }
    }

    private func recenter() {
        if isActive, let coordinate = session.coordinate {
            withAnimation { position = .region(region(around: coordinate)) }
        } else if let selected {
            withAnimation { position = .region(region(around: selected)) }
        } else {
            withAnimation { position = .userLocation(fallback: .automatic) }
        }
    }

    private func flashStyleToast(_ text: String) {
        withAnimation { styleToast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if styleToast == text {
                withAnimation { styleToast = nil }
            }
        }
    }

    private func resolve(_ completion: MKLocalSearchCompletion) {
        searchFocused = false
        searchText = ""
        searchCompleter.update(query: "")
        MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start { response, _ in
            guard let item = response?.mapItems.first else { return }
            DispatchQueue.main.async {
                let coordinate = item.placemark.coordinate
                selected = coordinate
                selectedName = completion.title
                withAnimation { position = .region(region(around: coordinate)) }
            }
        }
    }

    private func submitSearchText() {
        // Accept "lat, lon" typed or pasted straight into the search box.
        let parts = searchText
            .replacingOccurrences(of: ";", with: ",")
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .compactMap { Double($0) }
        if parts.count == 2, abs(parts[0]) <= 90, abs(parts[1]) <= 180 {
            let coordinate = CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1])
            searchFocused = false
            searchText = ""
            searchCompleter.update(query: "")
            selected = coordinate
            selectedName = nil
            withAnimation { position = .region(region(around: coordinate)) }
        } else if let first = searchCompleter.results.first {
            resolve(first)
        }
    }

    private func saveSelected() {
        guard let selected else { return }
        let name = saveName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        spots.append(LocationBookmark(name: name, latitude: selected.latitude, longitude: selected.longitude))
        selectedName = name
        if isActive && isSame(selected, session.coordinate) { activeName = name }
        persistSpots()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func commitRename() {
        guard let target = renamingSpot,
              let index = spots.firstIndex(where: { $0.id == target.id }) else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            spots[index].name = name
            persistSpots()
        }
        renamingSpot = nil
    }

    private func delete(_ spot: LocationBookmark) {
        spots.removeAll { $0.id == spot.id }
        persistSpots()
    }

    private func loadSpots() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([LocationBookmark].self, from: data) else { return }
        spots = decoded
    }

    private func persistSpots() {
        if let data = try? JSONEncoder().encode(spots) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    private func beginBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask { endBackgroundTask() }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    // MARK: Helpers

    private func region(around coordinate: CLLocationCoordinate2D) -> MKCoordinateRegion {
        MKCoordinateRegion(center: coordinate, latitudinalMeters: 700, longitudinalMeters: 700)
    }

    private func isSame(_ a: CLLocationCoordinate2D?, _ b: CLLocationCoordinate2D?) -> Bool {
        guard let a, let b else { return false }
        return abs(a.latitude - b.latitude) < 0.000001 && abs(a.longitude - b.longitude) < 0.000001
    }

    private func format(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
    }
}

// MARK: - Joystick

private struct JoystickPad: View {
    let onStart: () -> Void
    let onChange: (CGVector) -> Void

    @State private var knob: CGSize = .zero
    @State private var dragging = false
    private let radius: CGFloat = 44

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.clear)
                .frame(width: 132, height: 132)
                .teleportGlass(Circle())
            Image(systemName: "chevron.up")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .offset(y: -50)
            Image(systemName: "chevron.down")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .offset(y: 50)
            Image(systemName: "chevron.left")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .offset(x: -50)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .offset(x: 50)
            Circle()
                .fill(Color.white.opacity(dragging ? 0.95 : 0.8))
                .frame(width: 54, height: 54)
                .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                .offset(knob)
        }
        .frame(width: 132, height: 132)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !dragging {
                        dragging = true
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        onStart()
                    }
                    var dx = value.translation.width
                    var dy = value.translation.height
                    let length = hypot(dx, dy)
                    if length > radius {
                        dx = dx / length * radius
                        dy = dy / length * radius
                    }
                    knob = CGSize(width: dx, height: dy)
                    // Screen "up" is north.
                    onChange(CGVector(dx: dx / radius, dy: -dy / radius))
                }
                .onEnded { _ in
                    dragging = false
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { knob = .zero }
                    onChange(.zero)
                }
        )
        .accessibilityLabel("Joystick")
    }
}
