//
//  YearsView.swift
//  ImmichVisionProClient
//
//  Created by Julian Gray on 1/13/26.
//

import SwiftUI

struct YearsView: View {
    @EnvironmentObject var api: ImmichAPI
    @State private var yearThumbnails: [Int: String] = [:] // year -> first asset ID for thumbnail
    @State private var yearCounts: [Int: Int] = [:] // year -> total photo count
    @State private var loadingYears: Set<Int> = []

    let columns = Array(repeating: GridItem(.flexible(), spacing: 16), count: 5)

    var body: some View {
        ScrollView {
            if api.timeBuckets.isEmpty {
                VStack(spacing: 20) {
                    ProgressView("Loading timeline...")
                        .font(.title2)
                    Text("Fetching photo timeline...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 100)
            } else if api.sortedYears.isEmpty {
                VStack(spacing: 20) {
                    Text("No photos found")
                        .font(.title2)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 100)
            } else {
                LazyVGrid(columns: columns, spacing: 24) {
                    ForEach(api.sortedYears, id: \.self) { year in
                        NavigationLink(value: year) {
                            YearCard(
                                year: year,
                                thumbnailAssetId: yearThumbnails[year],
                                photoCount: yearCounts[year] ?? api.yearGroups[year]?.reduce(0) { $0 + $1.count } ?? 0,
                                isLoading: loadingYears.contains(year)
                            )
                            .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 16))
                            .hoverEffect(.highlight)
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            Task {
                                await loadThumbnailForYear(year)
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("Years")
        .task {
            await api.fetchTimeBuckets()
        }
    }

    private func loadThumbnailForYear(_ year: Int) async {
        guard yearThumbnails[year] == nil, !loadingYears.contains(year) else { return }

        loadingYears.insert(year)

        // Get the first bucket for this year to fetch a thumbnail
        let bucketsForYear = api.yearGroups[year] ?? []
        guard let firstBucket = bucketsForYear.first else {
            loadingYears.remove(year)
            return
        }

        do {
            let assets = try await api.fetchAssetsForTimeBucket(timeBucket: firstBucket.timeBucket)
            if let firstAsset = assets.first {
                yearThumbnails[year] = firstAsset.id
            }
            // Calculate total count from all buckets
            yearCounts[year] = bucketsForYear.reduce(0) { $0 + $1.count }
            loadingYears.remove(year)
        } catch {
            print("❌ Years: Error loading thumbnail for year \(year): \(error)")
            loadingYears.remove(year)
        }
    }
}

struct YearCard: View {
    let year: Int
    let thumbnailAssetId: String?
    let photoCount: Int
    let isLoading: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            // Thumbnail
            if let assetId = thumbnailAssetId {
                // Blurred version behind
                AsyncThumbnailView(assetId: assetId)
                    .aspectRatio(1, contentMode: .fill)
                    .clipped()
                    .blur(radius: 20)

                // Sharp version on top, fading out at bottom
                AsyncThumbnailView(assetId: assetId)
                    .aspectRatio(1, contentMode: .fill)
                    .clipped()
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black, location: 0.65),
                                .init(color: .clear, location: 0.85)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            } else if isLoading {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .aspectRatio(1, contentMode: .fill)
                    .overlay {
                        ProgressView()
                    }
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .aspectRatio(1, contentMode: .fill)
                    .overlay {
                        Image(systemName: "photo.stack")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    }
            }

            // Year details overlay at bottom
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "%d", year))
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.3), radius: 2)

                Text("\(photoCount) items")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.3), radius: 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct YearDetailView: View {
    let year: Int
    @EnvironmentObject var api: ImmichAPI
    @EnvironmentObject var spatialPhotoManager: SpatialPhotoManager
    @EnvironmentObject var spatialCache: SpatialAssetCache
    @EnvironmentObject var shareManager: ShareManager
    @State private var assets: [Asset] = []
    @State private var isLoading = true
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
                ZStack(alignment: .bottom) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            if isLoading && assets.isEmpty {
                                VStack(spacing: 20) {
                                    ProgressView("Loading \(String(format: "%d", year))...")
                                        .font(.title2)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.top, 100)
                            } else {
                                LazyVGrid(columns: columns, spacing: 0) {
                                    ForEach(Array(assets.enumerated()), id: \.element.id) { index, asset in
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
                                if let lastViewedId = spatialPhotoManager.lastViewedAssetId(forAlbum: "year-\(year)") {
                                    spatialPhotoManager.isRestoringScrollPosition = true
                                    while assets.isEmpty && !Task.isCancelled {
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
        .navigationTitle(String(format: "%d", year))
        .toolbar {
            if !assets.isEmpty {
                if isSelectionMode {
                    SelectionToolbarContent(
                        selectedCount: selectedAssetIds.count,
                        totalCount: assets.count,
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
            await loadAssetsForYear()
            if !spatialPhotoManager.isDisplaying && spatialPhotoManager.lastViewedAssetId(forAlbum: "year-\(year)") == nil {
                hasRestoredScroll = true
            }
        }
        .sheet(isPresented: Binding(
            get: { assetIdsForAlbumPicker != nil },
            set: { if !$0 { assetIdsForAlbumPicker = nil } }
        )) {
            AlbumPickerView(
                selectedAssetIds: assetIdsForAlbumPicker ?? [],
                currentAlbumId: "year-\(year)"
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
        if selectedAssetIds.count == assets.count {
            selectedAssetIds.removeAll()
        } else {
            selectedAssetIds = Set(assets.map(\.id))
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
            guard let asset = assets.first(where: { $0.id == id }),
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
                assets.removeAll { ids.contains($0.id) }
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
                assets.removeAll { ids.contains($0.id) }
                exitSelectionMode()
                isPerformingBatchAction = false
            }
        } catch {
            print("❌ Failed to delete assets: \(error)")
            await MainActor.run { isPerformingBatchAction = false }
        }
    }

    // MARK: - Existing helpers

    private func loadAssetsForYear() async {
        if api.timeBuckets.isEmpty {
            await api.fetchTimeBuckets()
        }

        let bucketsForYear = api.yearGroups[year] ?? []
        print("📅 YearDetail: Loading year \(year), found \(bucketsForYear.count) buckets")

        var allAssets: [Asset] = []

        for bucket in bucketsForYear {
            do {
                let bucketAssets = try await api.fetchAssetsForTimeBucket(timeBucket: bucket.timeBucket)
                allAssets.append(contentsOf: bucketAssets)
            } catch {
                print("❌ YearDetail: Error loading bucket \(bucket.timeBucket): \(error)")
            }
        }

        print("📅 YearDetail: Loaded \(allAssets.count) total assets for year \(year)")

        await MainActor.run {
            assets = allAssets
            isLoading = false
        }
    }

    private func prefetchThumbnails(aroundIndex index: Int) {
        guard !assets.isEmpty else { return }

        let prefetchAhead = 25
        let prefetchBehind = 10

        let start = max(0, index - prefetchBehind)
        let end = min(assets.count - 1, index + prefetchAhead)

        guard start <= end else { return }

        let assetIds = (start...end).map { assets[$0].id }
        ThumbnailCache.shared.prefetch(assetIds: assetIds, api: api)
    }

    private func openInViewer(startingAt index: Int) async {
        spatialPhotoManager.configure(
            api: api,
            assets: assets,
            startingAt: index,
            album: Album(
                id: "year-\(year)",
                albumName: "\(year)",
                description: nil,
                albumThumbnailAssetId: nil,
                assetCount: assets.count,
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
                assets.removeAll { $0.id == asset.id }
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
                assets.removeAll { $0.id == asset.id }
                spatialCache.removeSpatialAsset(asset.id)
            }
        } catch {
            print("❌ Failed to hide asset: \(error)")
        }
    }
}
