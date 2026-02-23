//
//  MemoryDetailView.swift
//  ImmichVisionProClient
//
//  Created by Julian Gray on 2/6/26.
//

import SwiftUI

struct MemoryDetailView: View {
    let memory: Memory
    @EnvironmentObject var api: ImmichAPI
    @EnvironmentObject var spatialPhotoManager: SpatialPhotoManager
    @EnvironmentObject var spatialCache: SpatialAssetCache
    @State private var hasRestoredScroll = false
    @State private var wasDisplayingImmersive = false

    @Environment(\.openImmersiveSpace) var openImmersiveSpace

    let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 5)

    private var visibleAssets: [Asset] {
        memory.assets.filter { !api.hiddenAssetIds.contains($0.id) }
    }

    var body: some View {
        Group {
            if !spatialPhotoManager.isDisplaying {
                ScrollViewReader { proxy in
                    ScrollView {
                        if visibleAssets.isEmpty {
                            VStack(spacing: 20) {
                                Text("No photos in this memory")
                                    .font(.title2)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 100)
                        } else {
                            LazyVGrid(columns: columns, spacing: 0) {
                                ForEach(Array(visibleAssets.enumerated()), id: \.element.id) { index, asset in
                                    Button(action: {
                                        Task {
                                            await openInViewer(startingAt: index)
                                        }
                                    }) {
                                        AsyncThumbnailView(assetId: asset.id)
                                            .aspectRatio(1, contentMode: .fill)
                                            .clipped()
                                            .contentShape(.hoverEffect, .rect)
                                            .hoverEffect(.highlight)
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
                                    }
                                    .buttonStyle(.plain)
                                    .id(asset.id)
                                    .onAppear {
                                        // Prefetch thumbnails ahead of visible area
                                        prefetchThumbnails(aroundIndex: index)
                                    }
                                }
                            }
                        }
                    }
                    .opacity(hasRestoredScroll ? 1 : 0)
                    .task(id: spatialPhotoManager.isDisplaying) {
                        // Scroll to last viewed position when returning from immersive view
                        if !spatialPhotoManager.isDisplaying && wasDisplayingImmersive {
                            if let lastViewedId = spatialPhotoManager.lastViewedAssetId(forAlbum: "memory-\(memory.id)") {
                                // Signal that we're restoring scroll position
                                spatialPhotoManager.isRestoringScrollPosition = true
                                // Additional delay for grid to render
                                try? await Task.sleep(for: .milliseconds(100))
                                proxy.scrollTo(lastViewedId, anchor: .center)
                            }
                            spatialPhotoManager.isRestoringScrollPosition = false
                            wasDisplayingImmersive = false
                        }
                        // Show content after scroll is complete
                        hasRestoredScroll = true
                    }
                }
            }
        }
        // Track immersive state changes at this level (outside the conditional view)
        .onChange(of: spatialPhotoManager.isDisplaying) { oldValue, newValue in
            if newValue {
                wasDisplayingImmersive = true
                hasRestoredScroll = false
            }
        }
        .navigationTitle(memory.displayTitle)
        .onAppear {
            // If not coming back from immersive view, show immediately
            if !spatialPhotoManager.isDisplaying && spatialPhotoManager.lastViewedAssetId(forAlbum: "memory-\(memory.id)") == nil {
                hasRestoredScroll = true
            }
        }
    }

    /// Prefetch thumbnails ahead of the visible area for smooth scrolling
    private func prefetchThumbnails(aroundIndex index: Int) {
        let assets = visibleAssets
        guard !assets.isEmpty else { return }

        // Prefetch 25 items ahead (5 rows with 5 columns)
        let prefetchAhead = 25
        let prefetchBehind = 10

        let start = max(0, index - prefetchBehind)
        let end = min(assets.count - 1, index + prefetchAhead)

        guard start <= end else { return }

        let assetIds = (start...end).map { assets[$0].id }
        ThumbnailCache.shared.prefetch(assetIds: assetIds, api: api)
    }

    private func openInViewer(startingAt index: Int) async {
        let assets = visibleAssets
        spatialPhotoManager.configure(
            api: api,
            assets: assets,
            startingAt: index,
            album: Album(
                id: "memory-\(memory.id)",
                albumName: memory.displayTitle,
                description: nil,
                albumThumbnailAssetId: assets.first?.id,
                assetCount: assets.count,
                owner: Album.Owner(id: "", name: "")
            ),
            spatialCache: spatialCache
        )
        // Main window stays open but hidden via opacity controlled by spatialPhotoManager.isDisplaying
        await openImmersiveSpace(id: "SpatialPhotoViewer")
    }
}

#Preview {
    MemoryDetailView(memory: Memory(
        id: "preview",
        createdAt: nil,
        updatedAt: nil,
        memoryAt: nil,
        seenAt: nil,
        ownerId: nil,
        type: "on_this_day",
        data: Memory.MemoryData(year: 2023),
        isSaved: nil,
        assets: []
    ))
    .environmentObject(ImmichAPI())
    .environmentObject(SpatialPhotoManager())
    .environmentObject(SpatialAssetCache())
}
