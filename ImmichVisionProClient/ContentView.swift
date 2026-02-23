//
//  ContentView.swift
//  ImmichVisionProClient
//
//  Created by Julian Gray on 1/12/26.
//

import SwiftUI
import RealityKit
import RealityKitContent
import UIKit
import Photos

enum PhotoTab: String, CaseIterable {
    case upload = "Upload"
    case library = "Library"
    case collection = "Collection"
    case spatial = "Spatial"
    case settings = "Settings"

    var icon: String {
        switch self {
        case .upload: return "arrow.up.circle"
        case .library: return "photo.on.rectangle"
        case .collection: return "rectangle.stack"
        case .spatial: return "cube"
        case .settings: return "person.crop.circle"
        }
    }
}

enum CollectionType: Hashable, Codable {
    case years
    case albums
    case spatial
    case library
    case locked
    case settings
    case upload
}

// MARK: - Tab Animation Constants
enum TabAnimation {
    static let scaleDuration: Double = 0.2
    static let opacityDuration: Double = 0.15  // Shorter than scale
    static let scaleOut: CGFloat = 0.94   // Outgoing shrinks
    static let scaleIn: CGFloat = 1.06    // Incoming starts larger, settles to 1.0
}

struct ContentView: View {
    @EnvironmentObject var spatialPhotoManager: SpatialPhotoManager
    @EnvironmentObject var shareManager: ShareManager
    @StateObject private var api = ImmichAPI()
    @State private var selectedTab: PhotoTab = .collection
    @State private var navigationPath = NavigationPath()
    @State private var visuallySelectedTab: PhotoTab = .collection  // For ornament highlighting
    @State private var displayedTab: PhotoTab = .collection  // Which tab content is shown
    @State private var contentScale: CGFloat = 1.0  // Only used for outgoing animation
    @State private var contentOpacity: Double = 1.0
    @Environment(\.scenePhase) private var scenePhase

    // Login form state
    @State private var serverURL = ""
    @State private var email = ""
    @State private var password = ""
    @State private var isLoggingIn = false
    @State private var loginError: String?

    private enum LoginField { case serverURL, email, password }
    @FocusState private var focusedField: LoginField?

    var body: some View {
        Group {
            if !api.isLoggedIn {
                loginView
            } else {
                mainView
            }
        }
        .environmentObject(api)
        .sheet(isPresented: $shareManager.showShareSheet) {
            ShareSheetView(shareManager: shareManager)
        }
        .task {
            // If we have a saved session, validate it and load data
            if api.isLoggedIn {
                let isValid = await api.validateSession()
                if isValid {
                    await api.fetchAlbums()
                    await api.fetchTimeBuckets()
                }
            }
        }
    }

    private var loginView: some View {
        VStack(spacing: 36) {
            // Branding
            VStack(spacing: 14) {
                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)
                    .opacity(0.6)

                Text("Vimmich")
                    .font(.extraLargeTitle)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)

                Text("Connect to your Immich server")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.6))
            }

            // Form card — button lives inside so it's within the glass interaction surface
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Server URL")
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.6))
                    TextField("Server address", text: $serverURL)
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .tint(.white)
                        .focused($focusedField, equals: .serverURL)
                        .onSubmit { focusedField = .email }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Email")
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.6))
                    TextField("Email address", text: $email)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.emailAddress)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .tint(.white)
                        .focused($focusedField, equals: .email)
                        .onSubmit { focusedField = .password }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Password")
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.6))
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.password)
                        .tint(.white)
                        .focused($focusedField, equals: .password)
                        .onSubmit { Task { await performLogin() } }
                }

                if let error = loginError {
                    Text(error)
                        .foregroundStyle(.white)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                Button(action: {
                    Task { await performLogin() }
                }) {
                    HStack(spacing: 10) {
                        if isLoggingIn {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                        Text(isLoggingIn ? "Signing in..." : "Sign In")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(serverURL.isEmpty || email.isEmpty || password.isEmpty || isLoggingIn)
            }
            .frame(width: 360)
            .padding(28)
            .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 20))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(60)
    }

    private func performLogin() async {
        isLoggingIn = true
        loginError = nil

        do {
            try await api.login(serverURL: serverURL, email: email, password: password)
            // Clear password from memory after successful login
            password = ""
            // Load initial data
            await api.fetchAlbums()
            await api.fetchTimeBuckets()
        } catch {
            loginError = error.localizedDescription
        }

        isLoggingIn = false
    }

    private func handleTabSelection(_ tab: PhotoTab) {
        // Prevent re-selecting the same tab
        if visuallySelectedTab == tab && tab != .collection {
            return
        }
        if visuallySelectedTab == tab && tab == .collection && navigationPath.isEmpty {
            return
        }

        // Clear any pending album restoration since user is manually navigating
        spatialPhotoManager.currentAlbum = nil

        // Update ornament highlight immediately
        withAnimation(.easeInOut(duration: TabAnimation.scaleDuration)) {
            visuallySelectedTab = tab
        }

        // Phase 1: Animate out - opacity fades faster than scale
        withAnimation(.easeIn(duration: TabAnimation.scaleDuration)) {
            contentScale = TabAnimation.scaleOut
        }
        withAnimation(.easeIn(duration: TabAnimation.opacityDuration)) {
            contentOpacity = 0
        }

        // Phase 2: Switch tab and animate in (after scale completes)
        DispatchQueue.main.asyncAfter(deadline: .now() + TabAnimation.scaleDuration + 0.02) {
            // Reset state WITHOUT animation
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                displayedTab = tab
                contentScale = TabAnimation.scaleIn  // Start larger
                contentOpacity = 0
            }

            // Handle navigation path
            switch tab {
            case .collection:
                navigationPath = NavigationPath()
            case .library, .spatial, .upload, .settings:
                if !navigationPath.isEmpty {
                    navigationPath = NavigationPath()
                }
            }

            // Animate in - scale down to 1.0 + fade in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                withAnimation(.easeOut(duration: TabAnimation.scaleDuration)) {
                    contentScale = 1.0
                }
                withAnimation(.easeOut(duration: TabAnimation.opacityDuration)) {
                    contentOpacity = 1.0
                }
            }
        }
    }

    private var mainView: some View {
        ZStack {
            // Each tab has its own NavigationStack for proper toolbar/title support
            // The NavigationStack shows/hides, but content inside animates

            // Collection tab (always present for navigation path binding)
            NavigationStack(path: $navigationPath) {
                CollectionsView()
                    .navigationDestination(for: Album.self) { album in
                        AlbumDetailView(album: album)
                    }
                    .navigationDestination(for: Int.self) { year in
                        YearDetailView(year: year)
                    }
                    .navigationDestination(for: CollectionType.self) { collectionType in
                        switch collectionType {
                        case .years:
                            YearsView()
                        case .albums:
                            AlbumsGridView()
                        case .library:
                            LibraryView()
                        case .spatial:
                            SpatialPhotosView()
                        case .locked:
                            LockedFolderGateView()
                        case .upload:
                            UploadView()
                        case .settings:
                            SettingsView()
                        }
                    }
                    .navigationDestination(for: Memory.self) { memory in
                        MemoryDetailView(memory: memory)
                    }
                    .onAppear {
                        if let album = spatialPhotoManager.currentAlbum {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                if album.id.hasPrefix("year-") {
                                    if let yearString = album.id.split(separator: "-").last,
                                       let year = Int(yearString) {
                                        visuallySelectedTab = .collection
                                        displayedTab = .collection
                                        navigationPath.append(year)
                                    }
                                } else if album.id.hasPrefix("memory-") {
                                    visuallySelectedTab = .collection
                                    displayedTab = .collection
                                } else if album.id == "library" {
                                    visuallySelectedTab = .library
                                    displayedTab = .library
                                } else if album.id == "spatial" {
                                    visuallySelectedTab = .spatial
                                    displayedTab = .spatial
                                } else {
                                    visuallySelectedTab = .collection
                                    displayedTab = .collection
                                    navigationPath.append(album)
                                }
                                spatialPhotoManager.currentAlbum = nil
                            }
                        }
                    }
                    .geometryGroup()
                    .scaleEffect(displayedTab == .collection ? contentScale : 1)
                    .opacity(displayedTab == .collection ? contentOpacity : 0)
            }
            .clipped()
            .opacity(displayedTab == .collection ? 1 : 0)
            .allowsHitTesting(displayedTab == .collection)

            // Library tab
            if displayedTab == .library {
                NavigationStack {
                    LibraryView()
                        .scaleEffect(contentScale)
                        .opacity(contentOpacity)
                }
                .clipped()
            }

            // Spatial tab
            if displayedTab == .spatial {
                NavigationStack {
                    SpatialPhotosView()
                        .scaleEffect(contentScale)
                        .opacity(contentOpacity)
                }
                .clipped()
            }

            // Upload tab
            if displayedTab == .upload {
                NavigationStack {
                    UploadView()
                        .scaleEffect(contentScale)
                        .opacity(contentOpacity)
                }
                .clipped()
            }

            // Settings tab
            if displayedTab == .settings {
                NavigationStack {
                    SettingsView()
                        .scaleEffect(contentScale)
                        .opacity(contentOpacity)
                }
                .clipped()
            }
        }
        .ornament(attachmentAnchor: .scene(.bottom)) {
            HStack(spacing: 0) {
                ForEach(PhotoTab.allCases, id: \.self) { tab in
                    Button(action: {
                        handleTabSelection(tab)
                    }) {
                        VStack(spacing: 3) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 18))
                            Text(tab.rawValue)
                                .font(.caption2)
                        }
                        .frame(width: 64, height: 48)
                        .contentShape(RoundedRectangle(cornerRadius: 16))
                        .foregroundStyle(visuallySelectedTab == tab ? .white : .secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .glassBackgroundEffect(in: Capsule())
            .allowsHitTesting(!spatialPhotoManager.isDisplaying && !spatialPhotoManager.isRestoringScrollPosition && !shareManager.isSelectionModeActive)
            .opacity(spatialPhotoManager.isDisplaying || spatialPhotoManager.isRestoringScrollPosition || shareManager.isSelectionModeActive ? 0 : 1)
            .animation(.easeInOut(duration: 0.2).delay(0.15), value: spatialPhotoManager.isDisplaying)
            .animation(.easeInOut(duration: 0.2).delay(0.15), value: spatialPhotoManager.isRestoringScrollPosition)
            .animation(nil, value: shareManager.isSelectionModeActive)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                navigationPath = NavigationPath()
            }
        }
    }

}

// Extracted albums grid (was in AlbumListView)
struct AlbumsGridView: View {
    @EnvironmentObject var api: ImmichAPI

    var body: some View {
        ScrollView {
            if api.isLoading {
                ProgressView("Loading albums...")
                    .font(.title)
                    .padding()
            } else if let error = api.errorMessage {
                VStack(spacing: 20) {
                    Text("Error")
                        .font(.largeTitle)
                    Text(error)
                        .foregroundStyle(.red)
                    Button("Try Again") {
                        Task {
                            await api.fetchAlbums()
                        }
                    }
                }
                .padding()
            } else if api.albums.isEmpty {
                Text("No albums found")
                    .font(.title)
                    .padding()
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 5), spacing: 24) {
                    ForEach(api.albums) { album in
                        AlbumCard(album: album)
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("Albums")
    }
}

// MARK: - Locked Folder Gate View

struct LockedFolderGateView: View {
    @EnvironmentObject var api: ImmichAPI

    private let keychain = KeychainHelper.shared

    enum GateState: Equatable {
        case checking
        case needsPIN
        case noPINSetup
        case unlocked
        case error(String)
    }

    @State private var gateState: GateState = .checking
    @State private var pinCode = ""
    @State private var pinError: String?
    @State private var isUnlocking = false
    @State private var authCheckTask: Task<Void, Never>?
    @FocusState private var isPINFocused: Bool

    var body: some View {
        Group {
            switch gateState {
            case .checking:
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("Checking access...")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .needsPIN:
                pinEntryView

            case .noPINSetup:
                VStack(spacing: 20) {
                    Image(systemName: "lock.open.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("No PIN Set Up")
                        .font(.title2)
                    Text("Set up a PIN in Immich web settings to use the Locked Folder.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 400)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .unlocked:
                LockedFolderView()

            case .error(let message):
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)
                    Text("Error")
                        .font(.title2)
                    Text(message)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Try Again") {
                        gateState = .checking
                        Task { await checkAuthStatus() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Locked")
        .onAppear {
            // Guard prevents re-triggering if the view flickers during navigation animations
            guard gateState == .checking else { return }
            authCheckTask = Task { await checkAuthStatus() }
        }
        .onChange(of: gateState) { _, newState in
            if newState == .needsPIN {
                isPINFocused = true
            }
        }
        .onDisappear {
            authCheckTask?.cancel()
            authCheckTask = nil
            Task { try? await api.lockSession() }
        }
    }

    private var pinEntryView: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Enter PIN")
                .font(.title2)

            Text("Enter your Immich PIN to access hidden photos.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            SecureField("PIN", text: $pinCode)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .multilineTextAlignment(.center)
                .focused($isPINFocused)
                .onSubmit { Task { await unlock() } }

            if let error = pinError {
                Text(error)
                    .foregroundStyle(.white)
                    .font(.callout)
            }

            Button(action: {
                Task { await unlock() }
            }) {
                HStack {
                    if isUnlocking {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                    Text(isUnlocking ? "Unlocking..." : "Unlock")
                }
                .frame(width: 160)
            }
            .buttonStyle(.borderedProminent)
            .disabled(pinCode.isEmpty || isUnlocking)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func checkAuthStatus() async {
        do {
            let status = try await api.getAuthStatus()

            if status.isElevated {
                await MainActor.run { gateState = .unlocked }
                return
            }

            guard status.pinCode else {
                await MainActor.run { gateState = .noPINSetup }
                return
            }

            await MainActor.run { gateState = .needsPIN }
        } catch is CancellationError {
            // Task was cancelled (e.g. user navigated away), do nothing
            return
        } catch {
            await MainActor.run {
                gateState = .error("Could not check auth status: \(error.localizedDescription)")
            }
        }
    }

    private func unlock() async {
        isUnlocking = true
        pinError = nil

        do {
            try await api.unlockSession(pinCode: pinCode)

            await MainActor.run {
                gateState = .unlocked
                isUnlocking = false
            }
        } catch {
            await MainActor.run {
                pinError = "Wrong PIN. Please try again."
                pinCode = ""
                isUnlocking = false
            }
        }
    }
}

// MARK: - Locked Folder View

struct LockedFolderView: View {
    @EnvironmentObject var api: ImmichAPI
    @EnvironmentObject var spatialPhotoManager: SpatialPhotoManager
    @EnvironmentObject var spatialCache: SpatialAssetCache
    @EnvironmentObject var shareManager: ShareManager
    @State private var lockedAssets: [Asset] = []
    @State private var isLoading = false
    @State private var assetForDeletion: Asset?

    // Selection mode state
    @State private var isSelectionMode = false
    @State private var selectedAssetIds: Set<String> = []
    @State private var isPerformingBatchAction = false
    @State private var showBatchDeleteConfirmation = false

    @Environment(\.openImmersiveSpace) var openImmersiveSpace

    let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 5)

    var body: some View {
        Group {
            if isLoading && lockedAssets.isEmpty {
                VStack(spacing: 20) {
                    ProgressView("Loading hidden photos...")
                        .font(.title2)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 100)
            } else if lockedAssets.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("No Hidden Photos")
                        .font(.title2)
                    Text("Photos you hide will appear here.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 100)
            } else {
                ZStack(alignment: .bottom) {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 0) {
                            ForEach(Array(lockedAssets.enumerated()), id: \.element.id) { index, asset in
                                AsyncThumbnailView(assetId: asset.id)
                                    .aspectRatio(1, contentMode: .fill)
                                    .clipped()
                                    .contentShape(.hoverEffect, .rect)
                                    .hoverEffect(.highlight)
                                    .overlay(alignment: .topLeading) {
                                        SelectionOverlay(
                                            isSelected: selectedAssetIds.contains(asset.id),
                                            isSelectionMode: isSelectionMode
                                        )
                                    }
                                    .overlay(alignment: .bottomLeading) {
                                        HStack(spacing: 4) {
                                            if asset.type == .VIDEO {
                                                Image(systemName: "play.fill")
                                                    .font(.system(size: 12))
                                                    .foregroundStyle(.white)
                                                    .shadow(radius: 2)
                                            }
                                            if spatialCache.isSpatial(asset.id) {
                                                Text("3D")
                                                    .font(.system(size: 10, weight: .bold))
                                                    .foregroundStyle(.white)
                                                    .padding(.horizontal, 4)
                                                    .padding(.vertical, 2)
                                                    .background(Color.black.opacity(0.5))
                                                    .cornerRadius(4)
                                                    .shadow(radius: 2)
                                            }
                                        }
                                        .padding(6)
                                    }
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        if isSelectionMode {
                                            toggleSelection(asset.id)
                                        } else {
                                            Task {
                                                await openInViewer(startingAt: index)
                                            }
                                        }
                                    }
                                    .contextMenuIfNotSelecting(isSelectionMode: isSelectionMode) {
                                        Button {
                                            Task { await shareAsset(asset) }
                                        } label: {
                                            Label("Share", systemImage: "square.and.arrow.up")
                                        }

                                        Divider()

                                        Button {
                                            Task { await unhideAsset(asset) }
                                        } label: {
                                            Label("Unhide", systemImage: "eye")
                                        }

                                        Button(role: .destructive) {
                                            assetForDeletion = asset
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                        // Extra bottom padding for batch action bar
                        if isSelectionMode && !selectedAssetIds.isEmpty {
                            Spacer().frame(height: 80)
                        }
                    }

                    // Batch action bar
                    if isSelectionMode && !selectedAssetIds.isEmpty {
                        BatchActionBar(
                            selectedCount: selectedAssetIds.count,
                            actionSet: .locked,
                            isPerformingAction: isPerformingBatchAction,
                            onAddToAlbum: {},
                            onMakeOffline: {},
                            onShare: { Task { await batchShare() } },
                            onHideOrUnhide: { Task { await batchUnhide() } },
                            onDelete: { showBatchDeleteConfirmation = true }
                        )
                        .padding(.bottom, 8)
                    }
                }
            }
        }
        .toolbar {
            if !lockedAssets.isEmpty {
                if isSelectionMode {
                    SelectionToolbarContent(
                        selectedCount: selectedAssetIds.count,
                        totalCount: lockedAssets.count,
                        onSelectAll: { selectAll() },
                        onCancel: { exitSelectionMode() }
                    )
                } else {
                    ToolbarItem(placement: .topBarTrailing) {
                        SelectButton(isSelectionMode: isSelectionMode) { isSelectionMode = true }
                    }
                }
            }
        }
        .task {
            await loadLockedAssets()
        }
        .onChange(of: isSelectionMode) { _, newValue in
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                shareManager.isSelectionModeActive = newValue
            }
        }
        .alert("Delete Asset", isPresented: Binding(
            get: { assetForDeletion != nil },
            set: { if !$0 { assetForDeletion = nil } }
        )) {
            Button("Cancel", role: .cancel) {
                assetForDeletion = nil
            }
            Button("Delete", role: .destructive) {
                if let asset = assetForDeletion {
                    Task {
                        await deleteAsset(asset)
                    }
                }
            }
        } message: {
            Text("Are you sure you want to delete this asset? This cannot be undone.")
        }
        .alert("Delete \(selectedAssetIds.count) Assets", isPresented: $showBatchDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { await batchDelete() }
            }
        } message: {
            Text("Are you sure you want to delete \(selectedAssetIds.count) assets? This cannot be undone.")
        }
    }

    // MARK: - Selection helpers

    private func toggleSelection(_ assetId: String) {
        if selectedAssetIds.contains(assetId) {
            selectedAssetIds.remove(assetId)
        } else {
            selectedAssetIds.insert(assetId)
        }
    }

    private func selectAll() {
        if selectedAssetIds.count == lockedAssets.count {
            selectedAssetIds.removeAll()
        } else {
            selectedAssetIds = Set(lockedAssets.map(\.id))
        }
    }

    private func exitSelectionMode() {
        isSelectionMode = false
        selectedAssetIds.removeAll()
    }

    // MARK: - Batch actions

    private func batchShare() async {
        isPerformingBatchAction = true
        let ids = Array(selectedAssetIds)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Show the sheet immediately with a loading indicator
        await MainActor.run {
            shareManager.fileURLs = []
            shareManager.fileNames = []
            shareManager.fileIsVideo = []
            shareManager.isLoadingFiles = true
            shareManager.showShareSheet = true
        }

        var urls: [URL] = []
        var names: [String] = []
        var isVideoFlags: [Bool] = []

        for id in ids {
            guard let asset = lockedAssets.first(where: { $0.id == id }),
                  let url = api.getOriginalImageURL(assetId: id) else { continue }
            do {
                let data = try await api.loadImageData(from: url)
                let tempURL = tempDir.appendingPathComponent(asset.originalFileName)
                try data.write(to: tempURL)
                urls.append(tempURL)
                names.append(asset.originalFileName)
                isVideoFlags.append(asset.type == .VIDEO)
            } catch {
                print("❌ Failed to download asset \(id) for sharing: \(error)")
            }
        }

        await MainActor.run {
            shareManager.fileURLs = urls
            shareManager.fileNames = names
            shareManager.fileIsVideo = isVideoFlags
            shareManager.isLoadingFiles = false
            isPerformingBatchAction = false
        }
    }

    private func batchUnhide() async {
        isPerformingBatchAction = true
        let ids = Array(selectedAssetIds)
        do {
            try await api.updateAssetVisibility(assetIds: ids, visibility: "timeline")
            await MainActor.run {
                for id in ids {
                    if let asset = lockedAssets.first(where: { $0.id == id }) {
                        spatialCache.restoreSpatialAsset(id, asset: asset)
                    }
                }
                lockedAssets.removeAll { ids.contains($0.id) }
                exitSelectionMode()
                isPerformingBatchAction = false
            }
        } catch {
            print("❌ Failed to unhide assets: \(error)")
            await MainActor.run { isPerformingBatchAction = false }
        }
    }

    private func batchDelete() async {
        isPerformingBatchAction = true
        let ids = Array(selectedAssetIds)
        do {
            try await api.deleteAssets(assetIds: ids)
            await MainActor.run {
                lockedAssets.removeAll { ids.contains($0.id) }
                exitSelectionMode()
                isPerformingBatchAction = false
            }
        } catch {
            print("❌ Failed to delete assets: \(error)")
            await MainActor.run { isPerformingBatchAction = false }
        }
    }

    // MARK: - Single-item actions

    private func loadLockedAssets() async {
        guard !isLoading else { return }
        isLoading = true
        do {
            let assets = try await api.fetchLockedAssets()
            await MainActor.run {
                lockedAssets = assets
                isLoading = false
            }
        } catch {
            print("❌ Locked folder: Error loading assets: \(error)")
            await MainActor.run {
                isLoading = false
            }
        }
    }

    private func openInViewer(startingAt index: Int) async {
        spatialPhotoManager.configure(
            api: api,
            assets: lockedAssets,
            startingAt: index,
            album: Album(
                id: "locked",
                albumName: "Locked",
                description: nil,
                albumThumbnailAssetId: nil,
                assetCount: lockedAssets.count,
                owner: Album.Owner(id: "", name: "")
            ),
            spatialCache: spatialCache
        )
        await openImmersiveSpace(id: "SpatialPhotoViewer")
    }

    private func unhideAsset(_ asset: Asset) async {
        do {
            try await api.updateAssetVisibility(assetIds: [asset.id], visibility: "timeline")
            await MainActor.run {
                lockedAssets.removeAll { $0.id == asset.id }
                spatialCache.restoreSpatialAsset(asset.id, asset: asset)
            }
        } catch {
            print("❌ Failed to unhide asset: \(error)")
        }
    }

    private func deleteAsset(_ asset: Asset) async {
        do {
            try await api.deleteAsset(assetId: asset.id)
            await MainActor.run {
                lockedAssets.removeAll { $0.id == asset.id }
                assetForDeletion = nil
            }
        } catch {
            print("❌ Failed to delete asset: \(error)")
        }
    }

    private func shareAsset(_ asset: Asset) async {
        guard let url = api.getOriginalImageURL(assetId: asset.id) else { return }
        do {
            let data = try await api.loadImageData(from: url)
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let tempURL = tempDir.appendingPathComponent(asset.originalFileName)
            try data.write(to: tempURL)

            let isVideo = asset.type == .VIDEO
            let imageForSharing: UIImage? = isVideo ? nil : UIImage(data: data)

            await MainActor.run {
                shareManager.singleFileTempDir = tempDir
                shareManager.fileURL = tempURL
                shareManager.fileName = asset.originalFileName
                shareManager.isVideo = isVideo
                shareManager.imageForSharing = imageForSharing
                shareManager.showShareSheet = true
            }
        } catch {
            print("❌ Failed to prepare share: \(error)")
        }
    }
}

// MARK: - Share Sheet View

struct ShareSheetView: View {
    @ObservedObject var shareManager: ShareManager
    @Environment(\.dismiss) var dismiss
    @State private var saveSuccess = false
    @State private var saveError: String?
    @State private var isSaving = false

    private var isMultiFile: Bool {
        !shareManager.fileURLs.isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if shareManager.isLoadingFiles {
                    loadingContent
                } else if isMultiFile {
                    multiFileContent
                } else if let url = shareManager.fileURL {
                    singleFileContent(url: url)
                } else {
                    Text("No file to share")
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .navigationTitle("Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        shareManager.clear()
                        dismiss()
                    }
                }
            }
        }
    }

    private var loadingContent: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Preparing files...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private var multiFileContent: some View {
        VStack(spacing: 20) {
            // Multi-file icon
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 200, height: 150)
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "photo.stack")
                                .font(.system(size: 40))
                                .foregroundStyle(.secondary)
                            Text("\(shareManager.fileURLs.count) items")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
            }

            // Share all files
            ShareLink(items: shareManager.fileURLs, preview: { url in
                SharePreview(url.lastPathComponent)
            }) {
                Label("Share \(shareManager.fileURLs.count) Items", systemImage: "square.and.arrow.up")
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 40)

            // Save all to Photos
            if saveSuccess {
                Label("Saved to Photos", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
            } else if isSaving {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Saving...")
                        .font(.headline)
                }
            } else {
                Button(action: {
                    saveAllToPhotos()
                }) {
                    Label("Save All to Photos", systemImage: "photo.on.rectangle")
                        .font(.headline)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal, 40)
            }

            if let error = saveError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func singleFileContent(url: URL) -> some View {
        VStack(spacing: 20) {
            // Thumbnail preview
            ZStack {
                if let thumbnailData = shareManager.thumbnailData,
                   let uiImage = UIImage(data: thumbnailData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 280, maxHeight: 200)
                        .cornerRadius(12)
                        .shadow(radius: 4)
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: 200, height: 150)
                        .overlay {
                            Image(systemName: shareManager.isVideo ? "video" : "photo")
                                .font(.system(size: 40))
                                .foregroundStyle(.secondary)
                        }
                }

                // Video indicator
                if shareManager.isVideo {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.white)
                        .shadow(radius: 4)
                }
            }

            Text(shareManager.fileName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            // Use UIImage for photos (enables Save to Photos), URL for videos
            if let image = shareManager.imageForSharing {
                ShareLink(item: Image(uiImage: image), preview: SharePreview(shareManager.fileName, image: Image(uiImage: image))) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 40)
            } else {
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 40)
            }

            // Save to Photos button for images and videos
            if saveSuccess {
                Label("Saved to Photos", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
            } else if isSaving {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Saving...")
                        .font(.headline)
                }
            } else {
                Button(action: {
                    saveToPhotos()
                }) {
                    Label("Save to Photos", systemImage: "photo.on.rectangle")
                        .font(.headline)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal, 40)
            }

            if let error = saveError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer().frame(height: 1)
                .onChange(of: shareManager.fileURL) { oldValue, newValue in
                    // Close when file is cleared (after sharing)
                    if newValue == nil && oldValue != nil {
                        dismiss()
                    }
                }
        }
    }

    private func saveToPhotos() {
        guard let fileURL = shareManager.fileURL else {
            saveError = "No file to save"
            return
        }

        isSaving = true
        saveError = nil

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            DispatchQueue.main.async {
                switch status {
                case .authorized, .limited:
                    if shareManager.isVideo {
                        performSaveVideo(url: fileURL)
                    } else {
                        performSaveImage(url: fileURL)
                    }
                case .denied, .restricted:
                    isSaving = false
                    saveError = "Photo library access denied. Enable in Settings."
                case .notDetermined:
                    isSaving = false
                    saveError = "Permission not determined"
                @unknown default:
                    isSaving = false
                    saveError = "Unknown permission status"
                }
            }
        }
    }

    private func saveAllToPhotos() {
        let urls = shareManager.fileURLs
        let isVideoFlags = shareManager.fileIsVideo
        guard !urls.isEmpty else {
            saveError = "No files to save"
            return
        }

        isSaving = true
        saveError = nil

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    self.isSaving = false
                    self.saveError = "Photo library access denied. Enable in Settings."
                }
                return
            }

            let group = DispatchGroup()
            var savedCount = 0
            var failedCount = 0

            for (index, url) in urls.enumerated() {
                guard FileManager.default.fileExists(atPath: url.path) else {
                    failedCount += 1
                    continue
                }

                let isVideo = index < isVideoFlags.count && isVideoFlags[index]

                group.enter()
                PHPhotoLibrary.shared().performChanges({
                    if isVideo {
                        PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                    } else {
                        PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                    }
                }, completionHandler: { success, error in
                    if success {
                        savedCount += 1
                    } else {
                        print("❌ Failed to save \(url.lastPathComponent): \(error?.localizedDescription ?? "unknown")")
                        failedCount += 1
                    }
                    group.leave()
                })
            }

            group.notify(queue: .main) {
                self.isSaving = false
                if failedCount == 0 {
                    self.saveSuccess = true
                    self.saveError = nil
                } else if savedCount > 0 {
                    self.saveSuccess = true
                    self.saveError = "Saved \(savedCount) of \(urls.count) (\(failedCount) failed)"
                } else {
                    self.saveError = "Failed to save items to Photos"
                }
            }
        }
    }

    private func performSaveImage(url: URL) {
        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
        } completionHandler: { success, error in
            DispatchQueue.main.async {
                isSaving = false
                if success {
                    saveSuccess = true
                    saveError = nil
                } else {
                    saveError = error?.localizedDescription ?? "Failed to save image"
                }
            }
        }
    }

    private func performSaveVideo(url: URL) {
        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        } completionHandler: { success, error in
            DispatchQueue.main.async {
                isSaving = false
                if success {
                    saveSuccess = true
                    saveError = nil
                } else {
                    saveError = error?.localizedDescription ?? "Failed to save video"
                }
            }
        }
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
        .environmentObject(SpatialPhotoManager())
        .environmentObject(ShareManager())
}
