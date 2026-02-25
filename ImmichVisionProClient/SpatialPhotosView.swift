//
//  SpatialPhotosView.swift
//  ImmichVisionProClient
//
//  Created by Julian Gray on 1/20/26.
//

import SwiftUI

struct SpatialPhotosView: View {
    @EnvironmentObject var api: ImmichAPI
    @EnvironmentObject var spatialPhotoManager: SpatialPhotoManager
    @EnvironmentObject var spatialCache: SpatialAssetCache
    @EnvironmentObject var shareManager: ShareManager

    @State private var allAssets: [Asset] = []
    @State private var isLoadingAssets = false
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

    var spatialAssets: [Asset] {
        spatialCache.spatialAssets.sorted {
            ($0.fileCreatedAt ?? "") > ($1.fileCreatedAt ?? "")
        }
    }

    var body: some View {
        Group {
            if !spatialPhotoManager.isDisplaying {
                ZStack(alignment: .bottom) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 0) {
                                if spatialAssets.isEmpty && !spatialCache.isScanning && !isLoadingAssets {
                                    emptyStateView
                                } else if !spatialAssets.isEmpty {
                                    LazyVGrid(columns: columns, spacing: 0) {
                                        ForEach(Array(spatialAssets.enumerated()), id: \.element.id) { index, asset in
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
                                                        Text("3D")
                                                            .font(.system(size: 10, weight: .bold))
                                                            .foregroundStyle(.white)
                                                            .padding(.horizontal, 4)
                                                            .padding(.vertical, 2)
                                                            .background(Color.black.opacity(0.5))
                                                            .cornerRadius(4)
                                                            .shadow(radius: 2)
                                                    }
                                                    .padding(6)
                                                }
                                                .contentShape(Rectangle())
                                                .onTapGesture {
                                                    if isSelectionMode {
                                                        toggleSelection(asset.id)
                                                    } else {
                                                        Task {
                                                            await openInViewer(asset: asset, index: index)
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
                                                prefetchThumbnails(aroundIndex: index)
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
                        }
                        .opacity(hasRestoredScroll ? 1 : 0)
                        .task(id: spatialPhotoManager.isDisplaying) {
                            if !spatialPhotoManager.isDisplaying && wasDisplayingImmersive {
                                if let lastViewedId = spatialPhotoManager.lastViewedAssetId(forAlbum: "spatial") {
                                    spatialPhotoManager.isRestoringScrollPosition = true
                                    while spatialAssets.isEmpty && !Task.isCancelled {
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
                        .onAppear {
                            if spatialPhotoManager.lastViewedAssetId(forAlbum: "spatial") == nil {
                                hasRestoredScroll = true
                            }
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
        .navigationTitle("Spatial")
        .toolbar {
            if isSelectionMode {
                SelectionToolbarContent(
                    selectedCount: selectedAssetIds.count,
                    totalCount: spatialAssets.count,
                    onSelectAll: { selectAll() },
                    onCancel: { exitSelectionMode() }
                )
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        if spatialCache.isScanning || isLoadingAssets {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text(isLoadingAssets ? "Loading..." : "\(spatialCache.overallScannedCount)/\(spatialCache.totalLibrarySize)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button("Cancel") {
                                    spatialCache.cancelScan()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .fixedSize()
                        } else {
                            Button(action: { Task { await startScan() } }) {
                                HStack(spacing: 8) {
                                    Image(systemName: "cube.transparent")
                                        .font(.system(size: 18))
                                    Text("Scan for Spatial Photos")
                                        .font(.subheadline)
                                }
                            }
                            .buttonStyle(.bordered)
                        }

                        if !spatialAssets.isEmpty {
                            SelectButton(isSelectionMode: isSelectionMode) { isSelectionMode = true }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { assetIdsForAlbumPicker != nil },
            set: { if !$0 { assetIdsForAlbumPicker = nil } }
        )) {
            AlbumPickerView(
                selectedAssetIds: assetIdsForAlbumPicker ?? [],
                currentAlbumId: "spatial"
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
        if selectedAssetIds.count == spatialAssets.count {
            selectedAssetIds.removeAll()
        } else {
            selectedAssetIds = Set(spatialAssets.map(\.id))
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
        await MainActor.run {
            exitSelectionMode()
            isPerformingBatchAction = false
        }
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
            guard let asset = spatialAssets.first(where: { $0.id == id }),
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
                for id in ids { spatialCache.removeSpatialAsset(id) }
                exitSelectionMode()
                isPerformingBatchAction = false
            }
        } catch {
            print("❌ Failed to delete assets: \(error)")
            await MainActor.run { isPerformingBatchAction = false }
        }
    }

    // MARK: - Existing helpers

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)

            Text("No Spatial Photos Found")
                .font(.title2)

            Text("Tap 'Scan Library' to search your library for spatial photos and videos.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
        .padding(.top, 60)
    }

    private func loadAllAssets() async {
        guard allAssets.isEmpty else { return }

        isLoadingAssets = true

        if api.timeBuckets.isEmpty {
            await api.fetchTimeBuckets()
        }

        var assets: [Asset] = []
        for bucket in api.timeBuckets {
            do {
                let bucketAssets = try await api.fetchAssetsForTimeBucket(timeBucket: bucket.timeBucket)
                assets.append(contentsOf: bucketAssets)
            } catch {
                print("Error loading bucket \(bucket.timeBucket): \(error)")
            }
        }

        await MainActor.run {
            allAssets = assets
            isLoadingAssets = false
        }

        print("📦 Loaded \(assets.count) total assets for spatial scanning")
    }

    private func startScan() async {
        if allAssets.isEmpty {
            await loadAllAssets()
        }
        spatialCache.scanLibrary(api: api, assets: allAssets)
    }

    private func prefetchThumbnails(aroundIndex index: Int) {
        guard !spatialAssets.isEmpty else { return }

        let prefetchAhead = 25
        let prefetchBehind = 10

        let start = max(0, index - prefetchBehind)
        let end = min(spatialAssets.count - 1, index + prefetchAhead)

        guard start <= end else { return }

        let assetIds = (start...end).map { spatialAssets[$0].id }
        ThumbnailCache.shared.prefetch(assetIds: assetIds, api: api)
    }

    private func preloadNearbyAssets(aroundIndex index: Int) {
        guard !spatialAssets.isEmpty else { return }

        let preloadRadius = 5
        let start = max(0, index - preloadRadius)
        let end = min(spatialAssets.count - 1, index + preloadRadius)
        let visibleIndices = Array(start...end)

        spatialPhotoManager.preloadVisibleAssets(
            spatialAssets,
            visibleIndices: visibleIndices,
            api: api,
            spatialCache: spatialCache
        )
    }

    private func openInViewer(asset: Asset, index: Int) async {
        spatialPhotoManager.configure(
            api: api,
            assets: spatialAssets,
            startingAt: index,
            album: Album(
                id: "spatial",
                albumName: "Spatial Photos",
                description: nil,
                albumThumbnailAssetId: nil,
                assetCount: spatialAssets.count,
                owner: Album.Owner(id: "", name: "")
            ),
            spatialCache: spatialCache
        )
        await openImmersiveSpace(id: "SpatialPhotoViewer")
    }

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
                spatialCache.removeSpatialAsset(asset.id)
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

    private func hideAsset(_ asset: Asset) async {
        do {
            try await api.updateAssetVisibility(assetIds: [asset.id], visibility: "locked")
            await MainActor.run {
                spatialCache.removeSpatialAsset(asset.id)
            }
        } catch {
            print("❌ Failed to hide asset: \(error)")
        }
    }
}
