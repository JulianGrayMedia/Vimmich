//
//  AlbumDetailView.swift
//  ImmichVisionProClient
//
//  Created by Julian Gray on 1/12/26.
//

import SwiftUI

struct AlbumDetailView: View {
    let album: Album
    @EnvironmentObject var api: ImmichAPI
    @EnvironmentObject var spatialPhotoManager: SpatialPhotoManager
    @EnvironmentObject var spatialCache: SpatialAssetCache
    @EnvironmentObject var shareManager: ShareManager
    @State private var albumDetails: AlbumDetails?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var isOpeningViewer = false
    @State private var hasRestoredScroll = false
    @State private var wasDisplayingImmersive = false
    @State private var assetIdsForAlbumPicker: [String]?
    @State private var assetForDeletion: Asset?

    // Selection mode state
    @State private var isSelectionMode = false
    @State private var selectedAssetIds: Set<String> = []
    @State private var isPerformingBatchAction = false
    @State private var showBatchDeleteConfirmation = false

    @Environment(\.openWindow) var openWindow
    @Environment(\.dismissWindow) var dismissWindow
    @Environment(\.openImmersiveSpace) var openImmersiveSpace

    let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 5)

    var body: some View {
        Group {
            if !spatialPhotoManager.isDisplaying {
                ZStack {
                    ScrollViewReader { proxy in
                        ScrollView {
                            if isLoading {
                                ProgressView("Loading photos...")
                                    .font(.title)
                                    .padding()
                            } else if let error = errorMessage {
                                Text("Error: \(error)")
                                    .foregroundStyle(.red)
                                    .padding()
                            } else if let details = albumDetails {
                                LazyVGrid(columns: columns, spacing: 0) {
                                    ForEach(Array(details.assets.enumerated()), id: \.element.id) { index, asset in
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
                                            .overlay(alignment: .topTrailing) {
                                                if DiskCache.shared.isAvailableOffline(assetId: asset.id) {
                                                    Image(systemName: "checkmark.icloud.fill")
                                                        .font(.system(size: 12))
                                                        .foregroundStyle(.white)
                                                        .shadow(color: .black.opacity(0.5), radius: 2)
                                                        .padding(6)
                                                }
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
                                                guard !isOpeningViewer else { return }
                                                if isSelectionMode {
                                                    toggleSelection(asset.id)
                                                } else {
                                                    Task {
                                                        await openAssetsInImmersiveSpace(startingAt: index)
                                                    }
                                                }
                                            }
                                            .contextMenuIfNotSelecting(isSelectionMode: isSelectionMode) {
                                                Button {
                                                    assetIdsForAlbumPicker = [asset.id]
                                                } label: {
                                                    Label("Add to Album", systemImage: "rectangle.stack.badge.plus")
                                                }

                                                Button {
                                                    Task {
                                                        await toggleOffline(asset: asset)
                                                    }
                                                } label: {
                                                    if DiskCache.shared.isAvailableOffline(assetId: asset.id) {
                                                        Label("Remove Offline", systemImage: "icloud.slash")
                                                    } else {
                                                        Label("Make Available Offline", systemImage: "arrow.down.circle")
                                                    }
                                                }

                                                Button {
                                                    Task { await shareAsset(asset) }
                                                } label: {
                                                    Label("Share", systemImage: "square.and.arrow.up")
                                                }

                                                Divider()

                                                Button {
                                                    Task { await removeFromAlbum(asset) }
                                                } label: {
                                                    Label("Remove from Album", systemImage: "rectangle.stack.badge.minus")
                                                }

                                                Button {
                                                    Task { await hideAsset(asset) }
                                                } label: {
                                                    Label("Hide", systemImage: "eye.slash")
                                                }

                                                Button(role: .destructive) {
                                                    assetForDeletion = asset
                                                } label: {
                                                    Label("Delete", systemImage: "trash")
                                                }
                                            }
                                            .id(asset.id)
                                            .onAppear {
                                                prefetchThumbnails(aroundIndex: index, in: details.assets)
                                                preloadNearbyAssets(aroundIndex: index)
                                            }
                                    }
                                }

                                // Extra bottom padding for batch action bar
                                if isSelectionMode && !selectedAssetIds.isEmpty {
                                    Spacer().frame(height: 80)
                                }
                            }
                        }
                        .opacity(hasRestoredScroll ? 1 : 0)
                        .task(id: spatialPhotoManager.isDisplaying) {
                            if !spatialPhotoManager.isDisplaying && wasDisplayingImmersive {
                                if let lastViewedId = spatialPhotoManager.lastViewedAssetId(forAlbum: album.id) {
                                    spatialPhotoManager.isRestoringScrollPosition = true
                                    while albumDetails == nil && !Task.isCancelled {
                                        try? await Task.sleep(for: .milliseconds(100))
                                    }
                                    try? await Task.sleep(for: .milliseconds(100))
                                    proxy.scrollTo(lastViewedId, anchor: .center)
                                }
                                spatialPhotoManager.isRestoringScrollPosition = false
                                wasDisplayingImmersive = false
                            }
                            hasRestoredScroll = true
                        }
                    }

                    if isOpeningViewer {
                        ZStack {
                            Color.black.opacity(0.5)
                                .ignoresSafeArea()

                            VStack(spacing: 20) {
                                ProgressView()
                                    .tint(.white)
                                    .scaleEffect(1.5)
                                Text("Opening viewer...")
                                    .font(.title2)
                                    .foregroundStyle(.white)
                            }
                            .padding(40)
                            .background(.ultraThinMaterial)
                            .cornerRadius(20)
                        }
                    }
                }
            }
        }
        .ornament(attachmentAnchor: .scene(.bottom)) {
            if isSelectionMode && !selectedAssetIds.isEmpty {
                BatchActionBar(
                    selectedCount: selectedAssetIds.count,
                    actionSet: .standard,
                    isPerformingAction: isPerformingBatchAction,
                    onAddToAlbum: { batchAddToAlbum() },
                    onMakeOffline: { Task { await batchMakeOffline() } },
                    onShare: { Task { await batchShare() } },
                    onHideOrUnhide: { Task { await batchHide() } },
                    onDelete: { showBatchDeleteConfirmation = true }
                )
            }
        }
        .onChange(of: spatialPhotoManager.isDisplaying) { oldValue, newValue in
            if newValue {
                wasDisplayingImmersive = true
                hasRestoredScroll = false
            }
        }
        .onChange(of: isSelectionMode) { _, newValue in
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                shareManager.isSelectionModeActive = newValue
            }
        }
        .navigationTitle(album.albumName)
        .toolbar {
            if let details = albumDetails, !details.assets.isEmpty {
                if isSelectionMode {
                    SelectionToolbarContent(
                        selectedCount: selectedAssetIds.count,
                        totalCount: details.assets.count,
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
            await loadAlbumDetails()
            if !spatialPhotoManager.isDisplaying && spatialPhotoManager.lastViewedAssetId(forAlbum: album.id) == nil {
                hasRestoredScroll = true
            }
        }
        .sheet(isPresented: Binding(
            get: { assetIdsForAlbumPicker != nil },
            set: { if !$0 { assetIdsForAlbumPicker = nil } }
        )) {
            AlbumPickerView(
                selectedAssetIds: assetIdsForAlbumPicker ?? [],
                currentAlbumId: album.id
            ) {
                assetIdsForAlbumPicker = nil
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
        guard let details = albumDetails else { return }
        if selectedAssetIds.count == details.assets.count {
            selectedAssetIds.removeAll()
        } else {
            selectedAssetIds = Set(details.assets.map(\.id))
        }
    }

    private func exitSelectionMode() {
        isSelectionMode = false
        selectedAssetIds.removeAll()
    }

    // MARK: - Batch actions

    private func batchAddToAlbum() {
        assetIdsForAlbumPicker = Array(selectedAssetIds)
    }

    private func batchMakeOffline() async {
        isPerformingBatchAction = true
        for id in selectedAssetIds {
            guard let url = api.getOriginalImageURL(assetId: id) else { continue }
            do {
                let data = try await api.loadImageData(from: url)
                DiskCache.shared.saveOffline(assetId: id, data: data)
            } catch {
                print("❌ Failed to download asset \(id) for offline: \(error)")
            }
        }
        exitSelectionMode()
        isPerformingBatchAction = false
    }

    private func batchShare() async {
        isPerformingBatchAction = true
        let ids = Array(selectedAssetIds)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

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
            guard let asset = albumDetails?.assets.first(where: { $0.id == id }),
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

    private func batchHide() async {
        isPerformingBatchAction = true
        let ids = Array(selectedAssetIds)
        do {
            try await api.updateAssetVisibility(assetIds: ids, visibility: "locked")
            await MainActor.run {
                albumDetails?.assets.removeAll { ids.contains($0.id) }
                for id in ids { spatialCache.removeSpatialAsset(id) }
                exitSelectionMode()
                isPerformingBatchAction = false
            }
        } catch {
            print("❌ Failed to hide assets: \(error)")
            await MainActor.run { isPerformingBatchAction = false }
        }
    }

    private func batchDelete() async {
        isPerformingBatchAction = true
        let ids = Array(selectedAssetIds)
        do {
            try await api.deleteAssets(assetIds: ids)
            await MainActor.run {
                albumDetails?.assets.removeAll { ids.contains($0.id) }
                exitSelectionMode()
                isPerformingBatchAction = false
            }
        } catch {
            print("❌ Failed to delete assets: \(error)")
            await MainActor.run { isPerformingBatchAction = false }
        }
    }

    // MARK: - Single-item actions

    private func toggleOffline(asset: Asset) async {
        if DiskCache.shared.isAvailableOffline(assetId: asset.id) {
            DiskCache.shared.removeOffline(assetId: asset.id)
        } else {
            guard let url = api.getOriginalImageURL(assetId: asset.id) else { return }
            do {
                let data = try await api.loadImageData(from: url)
                DiskCache.shared.saveOffline(assetId: asset.id, data: data)
            } catch {
                print("❌ Failed to download for offline: \(error)")
            }
        }
    }

    private func deleteAsset(_ asset: Asset) async {
        do {
            try await api.deleteAsset(assetId: asset.id)
            await MainActor.run {
                albumDetails?.assets.removeAll { $0.id == asset.id }
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

    private func removeFromAlbum(_ asset: Asset) async {
        do {
            try await api.removeAssetFromAlbum(albumId: album.id, assetIds: [asset.id])
            await MainActor.run {
                albumDetails?.assets.removeAll { $0.id == asset.id }
            }
        } catch {
            print("❌ Failed to remove asset from album: \(error)")
        }
    }

    private func hideAsset(_ asset: Asset) async {
        do {
            try await api.updateAssetVisibility(assetIds: [asset.id], visibility: "locked")
            await MainActor.run {
                albumDetails?.assets.removeAll { $0.id == asset.id }
                spatialCache.removeSpatialAsset(asset.id)
            }
        } catch {
            print("❌ Failed to hide asset: \(error)")
        }
    }

    private func loadAlbumDetails() async {
        do {
            albumDetails = try await api.fetchAlbumDetails(albumId: album.id)
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func prefetchThumbnails(aroundIndex index: Int, in assets: [Asset]) {
        let prefetchAhead = 25
        let prefetchBehind = 10

        let start = max(0, index - prefetchBehind)
        let end = min(assets.count - 1, index + prefetchAhead)

        guard start <= end else { return }

        let assetIds = (start...end).map { assets[$0].id }
        ThumbnailCache.shared.prefetch(assetIds: assetIds, api: api)
    }

    private func preloadNearbyAssets(aroundIndex index: Int) {
        guard let details = albumDetails else { return }

        let preloadRadius = 5
        let start = max(0, index - preloadRadius)
        let end = min(details.assets.count - 1, index + preloadRadius)
        let visibleIndices = Array(start...end)

        spatialPhotoManager.preloadVisibleAssets(
            details.assets,
            visibleIndices: visibleIndices,
            api: api,
            spatialCache: spatialCache
        )
    }

    private func openAssetsInImmersiveSpace(startingAt index: Int) async {
        guard let details = albumDetails else { return }

        isOpeningViewer = true

        spatialPhotoManager.configure(
            api: api,
            assets: details.assets,
            startingAt: index,
            album: album,
            spatialCache: spatialCache
        )

        try? await Task.sleep(for: .milliseconds(100))

        isOpeningViewer = false
        await openImmersiveSpace(id: "SpatialPhotoViewer")
    }
}

struct AsyncThumbnailView: View {
    let assetId: String
    @EnvironmentObject var api: ImmichAPI
    @State private var image: UIImage?
    @State private var isLoading = true

    /// Falls back to the cache synchronously so the first render after a @State reset
    /// (e.g. visionOS context menu lift/dismiss) never shows a transparent placeholder frame.
    private var displayImage: UIImage? {
        image ?? ThumbnailCache.shared.get(assetId)
    }

    var body: some View {
        GeometryReader { geometry in
            if let image = displayImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .transition(.identity)
            } else if isLoading {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .overlay {
                        ProgressView()
                    }
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .task(id: assetId) {
            image = nil
            isLoading = true
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        // Check cache first — disable animation so context menu dismiss doesn't cause a visible fade-in
        if let cached = ThumbnailCache.shared.get(assetId) {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                image = cached
                isLoading = false
            }
            return
        }

        guard let url = api.getThumbnailURL(assetId: assetId) else {
            isLoading = false
            return
        }

        do {
            let loadedImage = try await api.loadImage(from: url)
            ThumbnailCache.shared.set(assetId, image: loadedImage)
            image = loadedImage
            isLoading = false
        } catch {
            isLoading = false
        }
    }
}

// MARK: - Album Picker View

struct AlbumPickerView: View {
    let selectedAssetIds: [String]
    let currentAlbumId: String
    let onDismiss: () -> Void

    @EnvironmentObject var api: ImmichAPI
    @Environment(\.dismiss) var dismiss
    @State private var isAdding = false
    @State private var addedToAlbum: String?
    @State private var showNewAlbumField = false
    @State private var newAlbumName = ""
    @State private var isCreatingAlbum = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if showNewAlbumField {
                        HStack(spacing: 12) {
                            TextField("Album name", text: $newAlbumName)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit {
                                    Task { await createAndAddAlbum() }
                                }
                            Button {
                                Task { await createAndAddAlbum() }
                            } label: {
                                if isCreatingAlbum {
                                    ProgressView()
                                        .frame(width: 60)
                                } else {
                                    Text("Create")
                                        .frame(width: 60)
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(newAlbumName.trimmingCharacters(in: .whitespaces).isEmpty || isCreatingAlbum)
                            Button {
                                showNewAlbumField = false
                                newAlbumName = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal)
                    }

                    if api.albums.isEmpty && !showNewAlbumField {
                        ProgressView("Loading albums...")
                            .padding(.top, 100)
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 4), spacing: 16) {
                            ForEach(api.albums.filter { $0.id != currentAlbumId }) { album in
                                Button {
                                    Task {
                                        await addToAlbum(album)
                                    }
                                } label: {
                                    ZStack(alignment: .bottom) {
                                        if let thumbnailId = album.albumThumbnailAssetId {
                                            AsyncThumbnailView(assetId: thumbnailId)
                                                .aspectRatio(1, contentMode: .fill)
                                                .clipped()
                                        } else {
                                            Rectangle()
                                                .fill(Color.gray.opacity(0.3))
                                                .aspectRatio(1, contentMode: .fill)
                                                .overlay {
                                                    Image(systemName: "photo.on.rectangle")
                                                        .font(.title)
                                                        .foregroundStyle(.secondary)
                                                }
                                        }

                                        // Title overlay at bottom, matching AlbumCard style
                                        Text(album.albumName)
                                            .font(.caption)
                                            .fontWeight(.medium)
                                            .foregroundStyle(.white)
                                            .lineLimit(1)
                                            .shadow(color: .black.opacity(0.4), radius: 2)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.horizontal, 8)
                                            .padding(.bottom, 6)

                                        // Success overlay when added — tint + corner checkmark
                                        if addedToAlbum == album.id {
                                            Color.black.opacity(0.35)
                                            VStack {
                                                HStack {
                                                    Spacer()
                                                    Image(systemName: "checkmark.circle.fill")
                                                        .font(.system(size: 22, weight: .semibold))
                                                        .foregroundStyle(.white)
                                                        .shadow(color: .black.opacity(0.3), radius: 2)
                                                        .padding(8)
                                                }
                                                Spacer()
                                            }
                                        }
                                    }
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 12))
                                    .hoverEffect(.highlight)
                                }
                                .buttonStyle(.plain)
                                .disabled(isAdding)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.bottom)
                    }
                }
                .padding(.top, 8)
            }
            .navigationTitle("Add to Album")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showNewAlbumField.toggle()
                        if !showNewAlbumField { newAlbumName = "" }
                    } label: {
                        Label("New Album", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        onDismiss()
                        dismiss()
                    }
                }
            }
        }
        .task {
            if api.albums.isEmpty {
                await api.fetchAlbums()
            }
        }
    }

    private func addToAlbum(_ album: Album) async {
        guard !selectedAssetIds.isEmpty else { return }

        isAdding = true
        do {
            try await api.addAssetsToAlbum(albumId: album.id, assetIds: selectedAssetIds)
            await MainActor.run {
                addedToAlbum = album.id
            }
        } catch {
            print("❌ Failed to add to album: \(error)")
        }
        isAdding = false
    }

    private func createAndAddAlbum() async {
        let name = newAlbumName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        isCreatingAlbum = true
        do {
            let newAlbum = try await api.createAlbum(name: name, assetIds: selectedAssetIds)
            await MainActor.run {
                addedToAlbum = newAlbum.id
                showNewAlbumField = false
                newAlbumName = ""
            }
        } catch {
            print("❌ Failed to create album: \(error)")
        }
        isCreatingAlbum = false
    }
}
