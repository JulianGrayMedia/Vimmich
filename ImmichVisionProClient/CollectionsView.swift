//
//  CollectionsView.swift
//  ImmichVisionProClient
//
//  Created by Julian Gray on 2/6/26.
//

import SwiftUI

struct CollectionsView: View {
    @EnvironmentObject var api: ImmichAPI
    @EnvironmentObject var spatialPhotoManager: SpatialPhotoManager
    @EnvironmentObject var spatialCache: SpatialAssetCache
    @State private var yearsThumbnailId: String?
    @State private var albumsThumbnailId: String?
    @State private var spatialThumbnailId: String?
    @State private var libraryThumbnailId: String?
    @State private var isLoadingYears = false
    @State private var isLoadingAlbums = false
    @State private var isLoadingSpatial = false
    @State private var isLoadingLibrary = false
    @State private var memories: [Memory] = []
    @State private var isLoadingMemories = false

    @Environment(\.openImmersiveSpace) var openImmersiveSpace

    let columns = Array(repeating: GridItem(.flexible(), spacing: 16), count: 5)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // On This Day section — always shown when loading or loaded
                if !memories.isEmpty {
                    OnThisDaySection(
                        memories: memories,
                        onMemoryTapped: { memory in
                            Task {
                                await openMemoryInViewer(memory)
                            }
                        }
                    )
                } else if isLoadingMemories {
                    OnThisDaySectionPlaceholder()
                }

                // Collections grid
                VStack(alignment: .leading, spacing: 16) {
                    if !memories.isEmpty || isLoadingMemories {
                        Text("Browse")
                            .font(.title2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 16)
                    }

                    LazyVGrid(columns: columns, spacing: 24) {
                        // Years Collection Card
                        NavigationLink(value: CollectionType.years) {
                            CollectionCard(
                                title: "Years",
                                subtitle: yearsSubtitle,
                                thumbnailAssetId: yearsThumbnailId,
                                iconName: "calendar",
                                isLoading: isLoadingYears
                            )
                            .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 16))
                            .hoverEffect(.highlight)
                        }
                        .buttonStyle(.plain)

                        // Albums Collection Card
                        NavigationLink(value: CollectionType.albums) {
                            CollectionCard(
                                title: "Albums",
                                subtitle: albumsSubtitle,
                                thumbnailAssetId: albumsThumbnailId,
                                iconName: "rectangle.stack",
                                isLoading: isLoadingAlbums
                            )
                            .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 16))
                            .hoverEffect(.highlight)
                        }
                        .buttonStyle(.plain)

                        // Spatial Collection Card
                        NavigationLink(value: CollectionType.spatial) {
                            CollectionCard(
                                title: "Spatial",
                                subtitle: spatialSubtitle,
                                thumbnailAssetId: spatialThumbnailId,
                                iconName: "cube",
                                isLoading: isLoadingSpatial
                            )
                            .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 16))
                            .hoverEffect(.highlight)
                        }
                        .buttonStyle(.plain)

                        // Library Collection Card
                        NavigationLink(value: CollectionType.library) {
                            CollectionCard(
                                title: "Library",
                                subtitle: librarySubtitle,
                                thumbnailAssetId: libraryThumbnailId,
                                iconName: "photo.on.rectangle",
                                isLoading: isLoadingLibrary
                            )
                            .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 16))
                            .hoverEffect(.highlight)
                        }
                        .buttonStyle(.plain)

                        // Locked Folder Card
                        NavigationLink(value: CollectionType.locked) {
                            CollectionCard(
                                title: "Locked",
                                subtitle: lockedSubtitle,
                                thumbnailAssetId: nil,
                                iconName: "lock.fill",
                                isLoading: false
                            )
                            .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 16))
                            .hoverEffect(.highlight)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.top, 24)
            .padding(.bottom, 8)
        }
        .navigationBarHidden(true)
        .task {
            await loadMemories()
            await loadThumbnails()
        }
    }

    private var yearsSubtitle: String {
        let yearCount = api.sortedYears.count
        if yearCount == 0 {
            return "Loading..."
        }
        return "\(yearCount) years"
    }

    private var albumsSubtitle: String {
        let albumCount = api.albums.count
        if albumCount == 0 {
            return "Loading..."
        }
        return "\(albumCount) albums"
    }

    private var spatialSubtitle: String {
        let count = spatialCache.spatialAssetIds.count
        if count == 0 {
            return "3D Photos"
        }
        return "\(count) photos"
    }

    private var librarySubtitle: String {
        let totalCount = api.timeBuckets.reduce(0) { $0 + $1.count }
        if totalCount == 0 {
            return "All Photos"
        }
        return "\(totalCount) photos"
    }

    private var lockedSubtitle: String {
        return "Hidden Photos"
    }

    private func loadMemories() async {
        guard memories.isEmpty && !isLoadingMemories else { return }
        isLoadingMemories = true

        do {
            let fetchedMemories = try await api.fetchMemories()
            await MainActor.run {
                // Filter to only show memories with assets, then consolidate to one per year
                let memoriesWithAssets = fetchedMemories.filter { !$0.assets.isEmpty }
                memories = consolidateMemoriesByYear(memoriesWithAssets)
                isLoadingMemories = false
            }
        } catch {
            print("❌ Collections: Error loading memories: \(error)")
            await MainActor.run {
                isLoadingMemories = false
            }
        }
    }

    /// Consolidate memories to show only one per year (randomly selected, changes daily)
    private func consolidateMemoriesByYear(_ memories: [Memory]) -> [Memory] {
        // Group by year
        var byYear: [Int: [Memory]] = [:]
        for memory in memories {
            if let year = memory.data?.year {
                byYear[year, default: []].append(memory)
            }
        }

        // Use today's date as seed so selection changes daily but stays consistent throughout the day
        let today = Calendar.current.startOfDay(for: Date())
        let daySeed = Int(today.timeIntervalSince1970)

        // Pick a random memory for each year (seeded by date + year for consistency)
        var consolidated: [Memory] = []
        for (year, yearMemories) in byYear {
            guard !yearMemories.isEmpty else { continue }
            // Combine day seed with year to get different selections per year
            let index = abs((daySeed + year).hashValue) % yearMemories.count
            consolidated.append(yearMemories[index])
        }

        // Sort by years ago (most recent first)
        return consolidated.sorted { ($0.yearsAgo ?? 0) < ($1.yearsAgo ?? 0) }
    }

    private func openMemoryInViewer(_ memory: Memory) async {
        let assets = memory.assets.filter { !api.hiddenAssetIds.contains($0.id) }
        guard !assets.isEmpty else { return }
        spatialPhotoManager.configure(
            api: api,
            assets: assets,
            startingAt: 0,
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
        await openImmersiveSpace(id: "SpatialPhotoViewer")
    }

    private func loadThumbnails() async {
        // Ensure time buckets are loaded
        if api.timeBuckets.isEmpty {
            await api.fetchTimeBuckets()
        }

        // Load library thumbnail from most recent photo (first year, first bucket)
        if libraryThumbnailId == nil && !isLoadingLibrary {
            isLoadingLibrary = true
            if let firstYear = api.sortedYears.first,
               let firstBucket = api.yearGroups[firstYear]?.first {
                do {
                    let assets = try await api.fetchAssetsForTimeBucket(timeBucket: firstBucket.timeBucket)
                    await MainActor.run {
                        libraryThumbnailId = assets.first?.id
                        isLoadingLibrary = false
                    }
                } catch {
                    await MainActor.run { isLoadingLibrary = false }
                }
            } else {
                await MainActor.run { isLoadingLibrary = false }
            }
        }

        // Load years thumbnail from a DIFFERENT year/bucket than library
        if yearsThumbnailId == nil && !isLoadingYears {
            isLoadingYears = true
            // Try second year first, then last bucket of first year as fallback
            let sortedYears = api.sortedYears
            var yearsBucket: TimeBucket?

            if sortedYears.count > 1,
               let bucket = api.yearGroups[sortedYears[1]]?.first {
                yearsBucket = bucket
            } else if let firstYear = sortedYears.first,
                      let buckets = api.yearGroups[firstYear],
                      buckets.count > 1 {
                // Use the last bucket of the first year (oldest month)
                yearsBucket = buckets.last
            }

            if let bucket = yearsBucket {
                do {
                    let assets = try await api.fetchAssetsForTimeBucket(timeBucket: bucket.timeBucket)
                    await MainActor.run {
                        yearsThumbnailId = assets.first?.id
                        isLoadingYears = false
                    }
                } catch {
                    await MainActor.run { isLoadingYears = false }
                }
            } else {
                // Only one year with one bucket - use same as library
                await MainActor.run {
                    yearsThumbnailId = libraryThumbnailId
                    isLoadingYears = false
                }
            }
        }

        // Load albums thumbnail from first album
        if albumsThumbnailId == nil && !isLoadingAlbums {
            isLoadingAlbums = true
            if api.albums.isEmpty {
                await api.fetchAlbums()
            }
            await MainActor.run {
                albumsThumbnailId = api.albums.first?.albumThumbnailAssetId
                isLoadingAlbums = false
            }
        }

        // Load spatial thumbnail from first spatial asset
        if spatialThumbnailId == nil && !isLoadingSpatial {
            isLoadingSpatial = true
            await MainActor.run {
                spatialThumbnailId = spatialCache.spatialAssetIds.first
                isLoadingSpatial = false
            }
        }
    }
}

// MARK: - On This Day Section

struct OnThisDaySection: View {
    let memories: [Memory]
    let onMemoryTapped: (Memory) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("On This Day")
                .font(.title)
                .fontWeight(.bold)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(memories) { memory in
                        Button {
                            onMemoryTapped(memory)
                        } label: {
                            MemoryCard(memory: memory)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.top, 8)
    }
}

// MARK: - On This Day Placeholder

/// Skeleton loader shown while memories are being fetched, preserving layout
struct OnThisDaySectionPlaceholder: View {
    private let cardWidth: CGFloat = 480
    private let cardHeight: CGFloat = 270
    private let placeholderCount = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("On This Day")
                .font(.title)
                .fontWeight(.bold)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(0..<placeholderCount, id: \.self) { _ in
                        ZStack(alignment: .bottomLeading) {
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.gray.opacity(0.25))
                                .frame(width: cardWidth, height: cardHeight)

                            ProgressView()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .frame(width: cardWidth, height: cardHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.top, 8)
    }
}

struct MemoryCard: View {
    let memory: Memory
    @EnvironmentObject var api: ImmichAPI

    // 16:9 dimensions - wide and tall
    private let cardWidth: CGFloat = 480
    private let cardHeight: CGFloat = 270

    private var visibleAssets: [Asset] {
        memory.assets.filter { !api.hiddenAssetIds.contains($0.id) }
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let firstAsset = visibleAssets.first {
                // Blurred version behind
                AsyncThumbnailView(assetId: firstAsset.id)
                    .aspectRatio(16/9, contentMode: .fill)
                    .frame(width: cardWidth, height: cardHeight)
                    .clipped()
                    .blur(radius: 20)

                // Sharp version on top, fading out at bottom
                AsyncThumbnailView(assetId: firstAsset.id)
                    .aspectRatio(16/9, contentMode: .fill)
                    .frame(width: cardWidth, height: cardHeight)
                    .clipped()
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black, location: 0.6),
                                .init(color: .clear, location: 0.85)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: cardWidth, height: cardHeight)
            }

            // Memory info overlay
            VStack(alignment: .leading, spacing: 4) {
                Text(memory.displayTitle)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.4), radius: 3)

                Text("\(visibleAssets.count) photos")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.4), radius: 3)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .frame(width: cardWidth, height: cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 16))
        .hoverEffect(.highlight)
    }
}

// MARK: - Collection Card

struct CollectionCard: View {
    let title: String
    let subtitle: String
    let thumbnailAssetId: String?
    let iconName: String
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
                        Image(systemName: iconName)
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    }
            }

            // Collection details overlay at bottom
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.3), radius: 2)

                Text(subtitle)
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

#Preview {
    CollectionsView()
        .environmentObject(ImmichAPI())
}
