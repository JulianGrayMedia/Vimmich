//
//  OfflineAssetsView.swift
//  ImmichVisionProClient
//
//  Created by Julian Gray on 1/29/26.
//

import SwiftUI

struct OfflineAssetsView: View {
    @EnvironmentObject var api: ImmichAPI
    @EnvironmentObject var spatialPhotoManager: SpatialPhotoManager
    @EnvironmentObject var spatialCache: SpatialAssetCache
    @StateObject private var diskCache = DiskCache.shared

    @State private var isOpeningViewer = false
    @State private var showRemoveConfirmation = false
    @State private var assetToRemove: String?
    @State private var hasRestoredScroll = false

    @Environment(\.openWindow) var openWindow
    @Environment(\.dismissWindow) var dismissWindow
    @Environment(\.openImmersiveSpace) var openImmersiveSpace

    let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 5)

    var sortedAssetIds: [String] {
        Array(diskCache.offlineAssetIds).sorted()
    }

    var body: some View {
        Group {
            if !spatialPhotoManager.isDisplaying {
                ZStack {
                    if diskCache.offlineAssetIds.isEmpty {
                        VStack(spacing: 16) {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 60))
                                .foregroundStyle(.secondary)
                            Text("No Offline Assets")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            Text("Assets you save for offline viewing will appear here.")
                                .font(.body)
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                        }
                        .padding()
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVGrid(columns: columns, spacing: 0) {
                                    ForEach(Array(sortedAssetIds.enumerated()), id: \.element) { index, assetId in
                                        Button(action: {
                                            Task {
                                                await openOfflineAsset(assetId: assetId, index: index)
                                            }
                                        }) {
                                            OfflineThumbnailView(assetId: assetId)
                                                .aspectRatio(1, contentMode: .fill)
                                                .clipped()
                                                .contentShape(.hoverEffect, .rect)
                                                .hoverEffect(.highlight)
                                                .overlay(alignment: .topTrailing) {
                                                    // Offline indicator
                                                    Image(systemName: "arrow.down.circle.fill")
                                                        .font(.system(size: 14))
                                                        .foregroundStyle(.white)
                                                        .shadow(radius: 2)
                                                        .padding(6)
                                                }
                                                .overlay(alignment: .bottomLeading) {
                                                    HStack(spacing: 4) {
                                                        if spatialCache.isSpatial(assetId) {
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
                                                .contextMenu {
                                                    Button(role: .destructive) {
                                                        assetToRemove = assetId
                                                        showRemoveConfirmation = true
                                                    } label: {
                                                        Label("Remove from Offline", systemImage: "trash")
                                                    }
                                                }
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(isOpeningViewer)
                                        .id(assetId)
                                    }
                                }
                            }
                            .opacity(hasRestoredScroll ? 1 : 0)
                            .task(id: spatialPhotoManager.isDisplaying) {
                                // Scroll to last viewed position when returning from immersive view
                                if !spatialPhotoManager.isDisplaying {
                                    if let lastViewedId = spatialPhotoManager.lastViewedAssetId(forAlbum: "offline") {
                                        // Signal that we're restoring scroll position
                                        spatialPhotoManager.isRestoringScrollPosition = true
                                        // Additional delay for grid to render
                                        try? await Task.sleep(for: .milliseconds(100))
                                        proxy.scrollTo(lastViewedId, anchor: .center)
                                    }
                                    // Show content after scroll is complete
                                    hasRestoredScroll = true
                                    spatialPhotoManager.isRestoringScrollPosition = false
                                } else {
                                    // Reset when entering immersive view
                                    hasRestoredScroll = false
                                }
                            }
                            .onAppear {
                                // Show immediately if no scroll to restore
                                if spatialPhotoManager.lastViewedAssetId(forAlbum: "offline") == nil {
                                    hasRestoredScroll = true
                                }
                            }
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
        .navigationTitle("Offline Assets")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Text("\(diskCache.offlineCount) items")
                    .foregroundStyle(.secondary)
            }
        }
        .alert("Remove from Offline?", isPresented: $showRemoveConfirmation) {
            Button("Cancel", role: .cancel) {
                assetToRemove = nil
            }
            Button("Remove", role: .destructive) {
                if let assetId = assetToRemove {
                    diskCache.removeOffline(assetId: assetId)
                }
                assetToRemove = nil
            }
        } message: {
            Text("This asset will no longer be available offline. You can re-download it later.")
        }
    }

    private func openOfflineAsset(assetId: String, index: Int) async {
        isOpeningViewer = true

        // Create minimal Asset objects from the offline IDs
        let offlineAssets = sortedAssetIds.map { id in
            Asset(
                id: id,
                deviceAssetId: nil,
                ownerId: nil,
                deviceId: nil,
                type: .IMAGE,  // Default to image - actual type determined during loading
                originalPath: nil,
                originalFileName: "offline_\(id.prefix(8))",
                fileCreatedAt: nil,
                fileModifiedAt: nil,
                updatedAt: nil,
                isFavorite: nil,
                isArchived: nil,
                duration: nil,
                exifInfo: nil,
                ratio: nil,
                projectionType: spatialCache.isSpatial(id) ? "SPATIAL" : nil
            )
        }

        // Create a virtual "Offline" album
        let offlineAlbum = Album(
            id: "offline",
            albumName: "Offline Assets",
            description: "Assets saved for offline viewing",
            albumThumbnailAssetId: sortedAssetIds.first,
            assetCount: offlineAssets.count,
            owner: Album.Owner(id: "local", name: "Local")
        )

        // Configure the manager with offline assets
        spatialPhotoManager.configure(
            api: api,
            assets: offlineAssets,
            startingAt: index,
            album: offlineAlbum,
            spatialCache: spatialCache
        )

        // Wait briefly for the first image to start loading
        try? await Task.sleep(for: .milliseconds(100))

        isOpeningViewer = false
        // Main window stays open but hidden via opacity controlled by spatialPhotoManager.isDisplaying
        await openImmersiveSpace(id: "SpatialPhotoViewer")
    }
}

/// Thumbnail view for offline assets - loads from API if available, shows placeholder otherwise
struct OfflineThumbnailView: View {
    let assetId: String
    @EnvironmentObject var api: ImmichAPI
    @State private var image: UIImage?
    @State private var isLoading = true

    var body: some View {
        GeometryReader { geometry in
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
            } else if isLoading {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .overlay {
                        ProgressView()
                    }
            } else {
                // Fallback - show offline icon when thumbnail can't be loaded
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .overlay {
                        VStack(spacing: 4) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            Text("Offline")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
            }
        }
        .task {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        guard let url = api.getThumbnailURL(assetId: assetId) else {
            isLoading = false
            return
        }

        do {
            image = try await api.loadImage(from: url)
            isLoading = false
        } catch {
            isLoading = false
        }
    }
}

#Preview {
    NavigationStack {
        OfflineAssetsView()
    }
}
