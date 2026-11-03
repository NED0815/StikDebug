//
//  QuickSpotsView.swift
//  StikDebug
//
//  A simple, one-screen location picker: pick a spot, tap Go,
//  save favorites and jump between them with one tap.
//  Shares saved spots with the full Location tool ("locationBookmarks").
//

import SwiftUI
import MapKit
import UIKit

struct QuickSpotsView: View {
    @ObservedObject private var tunnel = TunnelManager.shared
    @ObservedObject private var session = LocationSimulationSession.shared
    @StateObject private var searchCompleter = LocationSearchCompleter()

    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var selected: CLLocationCoordinate2D?
    @State private var selectedName: String?
    @State private var activeName: String?

    @State private var spots: [LocationBookmark] = []
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    @State private var isBusy = false
    @State private var showSaveSheet = false
    @State private var saveName = ""
    @State private var renamingSpot: LocationBookmark?
    @State private var renameText = ""
    @State private var errorMessage: String?
    @State private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    private static let storageKey = "locationBookmarks"

    private var pairingPath: String { PairingFileStore.prepareURL().path }
    private var hasPairingFile: Bool { FileManager.default.fileExists(atPath: pairingPath) }
    private var isActive: Bool { session.isActive && session.routeCoordinates == nil }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    statusCard
                    mapCard
                    actionButtons
                    spotsSection
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Spots")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if let coordinate = session.coordinate ?? selected {
                            withAnimation { position = .region(region(around: coordinate)) }
                        } else {
                            withAnimation { position = .userLocation(fallback: .automatic) }
                        }
                    } label: {
                        Image(systemName: "scope")
                    }
                    .accessibilityLabel("Recenter map")
                }
            }
        }
        .onAppear {
            loadSpots()
            if let coordinate = session.coordinate, isActive {
                selected = coordinate
                position = .region(region(around: coordinate))
            }
        }
        .sheet(isPresented: $showSaveSheet) { saveSheet }
        .alert("Rename Spot", isPresented: Binding(
            get: { renamingSpot != nil },
            set: { if !$0 { renamingSpot = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Save") { commitRename() }
            Button("Cancel", role: .cancel) { renamingSpot = nil }
        }
        .alert("Couldn't Change Location", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Status

    private var statusCard: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.18))
                    .frame(width: 44, height: 44)
                Image(systemName: statusIcon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(statusColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.headline)
                Text(statusSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var statusColor: Color {
        if !hasPairingFile { return .red }
        if isActive { return .green }
        return tunnel.isConnected ? .blue : .orange
    }

    private var statusIcon: String {
        if !hasPairingFile { return "exclamationmark.triangle.fill" }
        if isActive { return "location.fill" }
        return tunnel.isConnected ? "checkmark" : "wifi.exclamationmark"
    }

    private var statusTitle: String {
        if !hasPairingFile { return "Pairing file needed" }
        if isActive { return "Location is set" }
        return "Using real location"
    }

    private var statusSubtitle: String {
        if !hasPairingFile { return "Import your pairing file in Settings first." }
        if isActive {
            if let activeName { return activeName }
            if let coordinate = session.coordinate { return format(coordinate) }
            return "Simulated location active"
        }
        return tunnel.isConnected
            ? "Pick a spot or tap a saved one."
            : "Turn on LocalDevVPN, then try again."
    }

    // MARK: - Map

    private var mapCard: some View {
        VStack(spacing: 0) {
            searchBar
            if !searchCompleter.results.isEmpty && searchFocused {
                searchResults
            }
            MapReader { proxy in
                Map(position: $position) {
                    UserAnnotation()
                    if let active = session.coordinate, isActive {
                        Annotation(activeName ?? "Here", coordinate: active) {
                            pin(color: .green, icon: "location.fill")
                        }
                    }
                    if let selected, !isSame(selected, session.coordinate) || !isActive {
                        Annotation(selectedName ?? "Selected", coordinate: selected) {
                            pin(color: .blue, icon: "mappin")
                        }
                    }
                }
                .mapControls { MapCompass() }
                .onTapGesture { point in
                    searchFocused = false
                    if let coordinate = proxy.convert(point, from: .local) {
                        select(coordinate, name: nil)
                    }
                }
            }
            .frame(height: 300)
            .overlay(alignment: .bottomLeading) {
                if let selected {
                    Text(selectedName ?? format(selected))
                        .font(.footnote.weight(.medium))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(10)
                } else {
                    Text("Tap the map to drop a pin")
                        .font(.footnote)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(10)
                }
            }
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func pin(color: Color, icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(color, in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 3))
            .shadow(radius: 3)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search a place or paste coordinates", text: $searchText)
                .focused($searchFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onChange(of: searchText) { _, value in searchCompleter.update(query: value) }
                .onSubmit { submitSearchText() }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchCompleter.update(query: "")
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
    }

    private var searchResults: some View {
        VStack(spacing: 0) {
            ForEach(Array(searchCompleter.results.prefix(5).enumerated()), id: \.offset) { _, result in
                Button {
                    resolve(result)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.title).font(.subheadline).foregroundStyle(.primary)
                        if !result.subtitle.isEmpty {
                            Text(result.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
                Divider().padding(.leading, 14)
            }
        }
    }

    // MARK: - Actions

    private var actionButtons: some View {
        VStack(spacing: 10) {
            if isActive {
                bigButton(title: "Stop – Use Real Location", icon: "stop.fill", color: .red) {
                    stop()
                }
            }
            if let selected, !(isActive && isSame(selected, session.coordinate)) {
                bigButton(title: "Go Here", icon: "location.fill", color: .accentColor) {
                    go(to: selected, name: selectedName)
                }
            }
            if selected != nil {
                Button {
                    saveName = selectedName ?? ""
                    showSaveSheet = true
                } label: {
                    Label("Save This Spot", systemImage: "star")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
        .disabled(isBusy)
        .overlay {
            if isBusy { ProgressView().controlSize(.large) }
        }
    }

    private func bigButton(title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(color, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .opacity(isBusy ? 0.5 : 1)
    }

    // MARK: - Saved spots

    private var spotsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Saved Spots").font(.title3.weight(.bold))
                Spacer()
                if !spots.isEmpty {
                    Text("\(spots.count)").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if spots.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "star").font(.title2).foregroundStyle(.secondary)
                    Text("No saved spots yet").font(.subheadline.weight(.semibold))
                    Text("Drop a pin, then tap Save This Spot.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    ForEach(spots) { spot in
                        spotRow(spot)
                        if spot.id != spots.last?.id {
                            Divider().padding(.leading, 60)
                        }
                    }
                }
                .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                Text("Tap a spot to go there. Press and hold to rename or delete.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func spotRow(_ spot: LocationBookmark) -> some View {
        let isCurrent = isActive && isSame(spot.coordinate, session.coordinate)
        return Button {
            select(spot.coordinate, name: spot.name)
            go(to: spot.coordinate, name: spot.name)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isCurrent ? "location.fill" : "mappin.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(isCurrent ? Color.green : Color.accentColor, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(spot.name).font(.body.weight(.semibold)).foregroundStyle(.primary)
                    Text(isCurrent ? "You're here" : format(spot.coordinate))
                        .font(.caption)
                        .foregroundStyle(isCurrent ? .green : .secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .disabled(isBusy)
        .contextMenu {
            Button { select(spot.coordinate, name: spot.name) } label: {
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

    private var saveSheet: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Main Gate", text: $saveName)
                }
                if let selected {
                    Section("Coordinates") {
                        Text(format(selected)).font(.body.monospaced())
                    }
                }
            }
            .navigationTitle("Save Spot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showSaveSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveSelected() }
                        .disabled(saveName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Logic

    private func select(_ coordinate: CLLocationCoordinate2D, name: String?) {
        selected = coordinate
        selectedName = name
        withAnimation { position = .region(region(around: coordinate)) }
    }

    private func go(to coordinate: CLLocationCoordinate2D, name: String?) {
        guard hasPairingFile else {
            errorMessage = "Import your pairing file in Settings first."
            return
        }
        guard !isBusy else { return }
        isBusy = true
        let path = pairingPath
        let ip = DeviceConnectionContext.targetIPAddress
        LocationSimulationCommandQueue.shared.async {
            let code = simulate_location(ip, coordinate.latitude, coordinate.longitude, path)
            DispatchQueue.main.async {
                isBusy = false
                guard code == 0 else {
                    errorMessage = "Error \(code). Make sure LocalDevVPN is on and you're on Wi-Fi, then try again."
                    return
                }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                activeName = name
                beginBackgroundTask()
                session.clearRoute()
                session.startResending(at: coordinate) {
                    LocationSimulationCommandQueue.shared.async {
                        _ = simulate_location(ip, coordinate.latitude, coordinate.longitude, path)
                    }
                }
            }
        }
    }

    private func stop() {
        guard !isBusy else { return }
        isBusy = true
        session.pauseResending()
        LocationSimulationCommandQueue.shared.async {
            let code = clear_simulated_location()
            DispatchQueue.main.async {
                isBusy = false
                session.stop()
                activeName = nil
                endBackgroundTask()
                if code != 0 {
                    errorMessage = "The app stopped sending the fake location. If Maps still shows it, restart your iPhone."
                } else {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
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
                select(item.placemark.coordinate, name: completion.title)
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
            searchFocused = false
            searchText = ""
            searchCompleter.update(query: "")
            select(CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1]), name: nil)
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
        persistSpots()
        showSaveSheet = false
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

    // MARK: - Helpers

    private func region(around coordinate: CLLocationCoordinate2D) -> MKCoordinateRegion {
        MKCoordinateRegion(center: coordinate, latitudinalMeters: 800, longitudinalMeters: 800)
    }

    private func isSame(_ a: CLLocationCoordinate2D?, _ b: CLLocationCoordinate2D?) -> Bool {
        guard let a, let b else { return false }
        return abs(a.latitude - b.latitude) < 0.000001 && abs(a.longitude - b.longitude) < 0.000001
    }

    private func format(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
    }
}
