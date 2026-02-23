//
//  SpatialPhotoManager.swift
//  ImmichVisionProClient
//
//  Created by Julian Gray on 1/12/26.
//

import Foundation
import SwiftUI
import Combine
import ImageIO

/// Tracks progress for an individual download
struct DownloadProgress: Identifiable {
    let id: String  // Asset ID
    var downloadedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var progress: Double { totalBytes > 0 ? Double(downloadedBytes) / Double(totalBytes) : 0 }
}

@MainActor
class SpatialPhotoManager: ObservableObject {
    @Published var currentIndex: Int = 0
    @Published var isDisplaying = false
    @Published var isRestoringScrollPosition = false  // True while views are restoring scroll position after closing viewer
    @Published var currentAlbum: Album?
    @Published var isLoadingCurrentAsset = false
    @Published var downloadProgress: Double = 0  // 0.0 to 1.0 (legacy, for current asset display)
    @Published var downloadedBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var isShowingPreviewQuality = false  // True if current non-spatial image is preview quality
    @Published var isLoadingFullResolution = false  // True when upgrading to full resolution
    @Published var assetQualityDidUpgrade = false  // Toggles when an asset is upgraded to full res (for view refresh)
    @Published var savingOfflineAssetIds: Set<String> = []  // Asset IDs currently being saved offline
    @Published var activeDownloads: [String: DownloadProgress] = [:]  // Per-asset download progress

    // Tracks last viewed asset ID per album (persists across clear() for scroll restoration)
    private var lastViewedAssetPerAlbum: [String: String] = [:]

    // Asset metadata (not downloaded yet)
    private var assetMetadata: [Asset] = []

    // Cache of downloaded assets (keyed by asset ID)
    private var cache: [String: SpatialAssetData] = [:]

    // Track assets currently being downloaded by preload to prevent duplicates
    private var downloadingAssetIds: Set<String> = []

    // Track which asset ID should be updating progress (prevents oscillation from cancelled downloads)
    private var progressTrackingAssetId: String? = nil

    // Current preload task - cancelled when navigating
    private var preloadTask: Task<Void, Never>?

    // Current asset load task - cancelled when navigating to ensure fresh load
    private var currentLoadTask: Task<Void, Never>?

    // Track which index we're loading for to handle rapid navigation
    private var loadingForIndex: Int = -1

    // Reference to API for downloading (strong reference to keep it alive during viewing)
    private var api: ImmichAPI?

    // Reference to spatial cache for checking if assets are spatial
    private var spatialCache: SpatialAssetCache?

    // How many assets to keep cached on each side of current
    private let cacheRadius = 3  // Reduced to limit concurrent downloads

    // How many thumbnails to preload in each direction (thumbnails are small, can preload more)
    private let thumbnailPreloadRadius = 5

    struct SpatialAssetData {
        let leftImage: CGImage?
        let rightImage: CGImage?
        let originalData: Data
        let assetId: String
        let fileName: String
        let isVideo: Bool
        let isSpatial: Bool  // True if this is a spatial photo/video (stereo pair)
        let isPreviewQuality: Bool  // True if this is preview quality (not full resolution)
    }

    // Thumbnail cache (keyed by asset ID) - stores thumbnail and its aspect ratio
    private var thumbnailCache: [String: (image: CGImage, aspectRatio: Double)] = [:]

    // Video pre-buffer info - stores first ~1MB of videos plus content info for faster start
    struct VideoPreBufferInfo {
        let data: Data
        let contentLength: Int64
        let contentType: String?
    }

    // Video pre-buffer cache - stores first ~1MB of videos for faster start
    private var videoPreBufferCache: [String: VideoPreBufferInfo] = [:]
    private var videoPreBufferTasks: [String: Task<Void, Never>] = [:]
    private let videoPreBufferSize: Int = 1024 * 1024  // 1MB pre-buffer

    // Offline download tasks - persists even when view is closed (keyed by asset ID)
    private var offlineDownloadTasks: [String: Task<Bool, Never>] = [:]

    // Store access token for offline downloads (persists through clear())
    private var offlineDownloadAccessToken: String?

    // Cache for full asset details (with EXIF data) - keyed by asset ID
    private var fullAssetDetailsCache: [String: Asset] = [:]

    // Published property for current full asset details (fetched on demand)
    @Published var currentFullAssetDetails: Asset?
    @Published var isLoadingAssetDetails = false

    // Album preload cache - persists across clear() for instant loading from album grids
    // This cache is populated by album views and checked before downloading
    private var albumPreloadCache: [String: SpatialAssetData] = [:]
    private var albumPreloadTasks: [String: Task<Void, Never>] = [:]
    private let maxAlbumPreloadCount = 20  // Limit memory usage

    var totalAssets: Int {
        assetMetadata.count
    }

    var currentAsset: SpatialAssetData? {
        guard currentIndex < assetMetadata.count else { return nil }
        let assetId = assetMetadata[currentIndex].id
        return cache[assetId]
    }

    var currentAssetMetadata: Asset? {
        guard currentIndex < assetMetadata.count else { return nil }
        return assetMetadata[currentIndex]
    }

    /// Get the last viewed asset ID for a specific album
    func lastViewedAssetId(forAlbum albumId: String) -> String? {
        return lastViewedAssetPerAlbum[albumId]
    }

    /// Update the last viewed asset for the current album
    private func updateLastViewedAsset() {
        guard let albumId = currentAlbum?.id,
              currentIndex < assetMetadata.count else { return }
        lastViewedAssetPerAlbum[albumId] = assetMetadata[currentIndex].id
    }

    /// Get thumbnail for the current asset (if cached)
    var currentThumbnail: CGImage? {
        guard currentIndex < assetMetadata.count else { return nil }
        return thumbnailCache[assetMetadata[currentIndex].id]?.image
    }

    /// Get thumbnail aspect ratio for the current asset (width/height)
    var currentThumbnailAspectRatio: Double? {
        guard currentIndex < assetMetadata.count else { return nil }
        return thumbnailCache[assetMetadata[currentIndex].id]?.aspectRatio
    }

    /// Check if the current asset is known to be spatial (from the spatial cache)
    var isCurrentAssetKnownSpatial: Bool {
        guard currentIndex < assetMetadata.count else { return false }
        return spatialCache?.isSpatial(assetMetadata[currentIndex].id) ?? false
    }

    /// Check if any asset ID is known to be spatial (from the spatial cache)
    func isAssetKnownSpatial(_ assetId: String) -> Bool {
        return spatialCache?.isSpatial(assetId) ?? false
    }

    /// Mark the current asset as spatial (called when detected during playback)
    func markCurrentAssetAsSpatial() {
        guard currentIndex < assetMetadata.count else { return }
        let asset = assetMetadata[currentIndex]
        Task { @MainActor in
            spatialCache?.markAsSpatial(asset.id, asset: asset)
        }
    }

    /// Mark any asset as spatial by ID (called when detected during carousel/incoming video playback)
    func markAssetAsSpatial(_ assetId: String) {
        Task { @MainActor in
            spatialCache?.markAsSpatial(assetId)
        }
    }

    /// Get thumbnail for asset at offset from current
    func getThumbnailAt(offset: Int) -> CGImage? {
        let targetIndex = currentIndex + offset
        guard targetIndex >= 0 && targetIndex < assetMetadata.count else { return nil }
        return thumbnailCache[assetMetadata[targetIndex].id]?.image
    }

    /// Get thumbnail aspect ratio for asset at offset from current
    func getThumbnailAspectRatioAt(offset: Int) -> Double? {
        let targetIndex = currentIndex + offset
        guard targetIndex >= 0 && targetIndex < assetMetadata.count else { return nil }
        return thumbnailCache[assetMetadata[targetIndex].id]?.aspectRatio
    }

    /// Get metadata for asset at offset from current
    func getMetadataAt(offset: Int) -> Asset? {
        let targetIndex = currentIndex + offset
        guard targetIndex >= 0 && targetIndex < assetMetadata.count else { return nil }
        return assetMetadata[targetIndex]
    }

    /// Get a cached asset at an offset from current index (for carousel preview)
    func getAssetAt(offset: Int) -> SpatialAssetData? {
        let targetIndex = currentIndex + offset
        guard targetIndex >= 0 && targetIndex < assetMetadata.count else { return nil }
        let assetId = assetMetadata[targetIndex].id
        return cache[assetId]
    }

    /// Peek at a cached asset at an absolute index (for drag preview)
    func peekAsset(at index: Int) -> SpatialAssetData? {
        guard index >= 0 && index < assetMetadata.count else { return nil }
        let assetId = assetMetadata[index].id
        // Check main cache first, then album preload cache
        return cache[assetId] ?? albumPreloadCache[assetId]
    }

    /// Get asset metadata at a specific index (without loading)
    func assetMetadata(at index: Int) -> Asset? {
        guard index >= 0 && index < assetMetadata.count else { return nil }
        return assetMetadata[index]
    }

    func configure(api: ImmichAPI, assets: [Asset], startingAt index: Int, album: Album, spatialCache: SpatialAssetCache? = nil) {
        // Cancel any existing tasks
        currentLoadTask?.cancel()
        preloadTask?.cancel()
        currentLoadTask = nil
        preloadTask = nil

        self.api = api
        self.spatialCache = spatialCache
        self.assetMetadata = assets
        self.currentIndex = index
        self.currentAlbum = album
        self.isDisplaying = true
        updateLastViewedAsset()
        self.cache = [:]
        self.downloadingAssetIds = []
        self.progressTrackingAssetId = nil
        self.loadingForIndex = index
        self.isLoadingCurrentAsset = true  // Set loading immediately

        // Preload thumbnails immediately (fast, parallel downloads)
        preloadNearbyThumbnails()

        // Start loading the current asset
        currentLoadTask = Task {
            await loadCurrentAsset()
            startPreloading()
        }
    }

    func nextAsset() {
        guard currentIndex < assetMetadata.count - 1 else { return }

        // Cancel previous tasks
        currentLoadTask?.cancel()
        preloadTask?.cancel()

        currentIndex += 1
        loadingForIndex = currentIndex
        updateLastViewedAsset()

        // Clear downloading set and progress tracking for fresh start
        let asset = assetMetadata[currentIndex]
        downloadingAssetIds.removeAll()
        progressTrackingAssetId = nil  // Stop old downloads from updating progress

        // Clear full details (will be refetched if info panel is opened)
        currentFullAssetDetails = nil

        // Set loading immediately if not cached
        if cache[asset.id] == nil {
            isLoadingCurrentAsset = true
        } else {
            isLoadingCurrentAsset = false
        }

        // Preload thumbnails for new position
        preloadNearbyThumbnails()

        currentLoadTask = Task {
            await loadCurrentAsset()
            cleanupDistantCache()
            startPreloading()
        }
    }

    func previousAsset() {
        guard currentIndex > 0 else { return }

        // Cancel previous tasks
        currentLoadTask?.cancel()
        preloadTask?.cancel()

        currentIndex -= 1
        loadingForIndex = currentIndex
        updateLastViewedAsset()

        // Clear downloading set and progress tracking for fresh start
        let asset = assetMetadata[currentIndex]
        downloadingAssetIds.removeAll()
        progressTrackingAssetId = nil  // Stop old downloads from updating progress

        // Clear full details (will be refetched if info panel is opened)
        currentFullAssetDetails = nil

        // Set loading immediately if not cached
        if cache[asset.id] == nil {
            isLoadingCurrentAsset = true
        } else {
            isLoadingCurrentAsset = false
        }

        // Preload thumbnails for new position
        preloadNearbyThumbnails()

        currentLoadTask = Task {
            await loadCurrentAsset()
            cleanupDistantCache()
            startPreloading()
        }
    }

    private func startPreloading() {
        preloadTask = Task {
            await preloadNearbyAssets()
        }
    }

    func loadCurrentAsset() async {
        let indexToLoad = currentIndex

        // Guard against empty array or out of bounds
        guard assetMetadata.count > 0 else {
            print("⚠️ loadCurrentAsset: no assets available")
            isLoadingCurrentAsset = false
            return
        }

        guard indexToLoad >= 0 && indexToLoad < assetMetadata.count else {
            print("❌ loadCurrentAsset: index \(indexToLoad) out of bounds (count: \(assetMetadata.count))")
            isLoadingCurrentAsset = false
            return
        }

        let asset = assetMetadata[indexToLoad]

        // Already in memory cache
        if cache[asset.id] != nil {
            print("📦 Asset already in memory cache")
            if currentIndex == indexToLoad {
                isLoadingCurrentAsset = false
            }
            return
        }

        // Check album preload cache (populated by album grid views)
        if let preloaded = albumPreloadCache[asset.id] {
            print("📦 Asset found in album preload cache - instant load!")
            cache[asset.id] = preloaded
            if currentIndex == indexToLoad {
                isLoadingCurrentAsset = false
            }
            return
        }

        if Task.isCancelled {
            if currentIndex == indexToLoad { isLoadingCurrentAsset = false }
            return
        }

        downloadingAssetIds.insert(asset.id)
        isLoadingCurrentAsset = true
        print("⏳ Loading asset[\(indexToLoad)]: \(asset.id.prefix(8))...")

        // ===== STEP 1: Check if asset is available OFFLINE =====
        let diskCache = DiskCache.shared
        if diskCache.isAvailableOffline(assetId: asset.id),
           let offlineData = diskCache.getOffline(assetId: asset.id),
           !offlineData.isEmpty {
            print("💾 Loading from OFFLINE storage: \(asset.id.prefix(8))... (\(offlineData.count) bytes)")

            // Detect if it's a video from the file data
            let isVideo = isVideoData(offlineData)

            if isVideo {
                // For offline videos, store the data so the view can play it directly
                let videoAsset = SpatialAssetData(
                    leftImage: nil,
                    rightImage: nil,
                    originalData: offlineData,  // Full video data from disk
                    assetId: asset.id,
                    fileName: asset.originalFileName,
                    isVideo: true,
                    isSpatial: spatialCache?.isSpatial(asset.id) ?? false,
                    isPreviewQuality: false
                )
                cache[asset.id] = videoAsset
                print("✅ Offline VIDEO ready: \(asset.id.prefix(8))...")
            } else {
                // For offline images, process into displayable format
                if let imageAsset = await processImageData(offlineData, asset: asset) {
                    cache[asset.id] = imageAsset
                    print("✅ Offline IMAGE ready: \(asset.id.prefix(8))...")
                } else {
                    print("❌ Failed to process offline image")
                }
            }

            downloadingAssetIds.remove(asset.id)
            if currentIndex == indexToLoad { isLoadingCurrentAsset = false }
            return
        }

        // ===== STEP 2: Not offline - need API to fetch from server =====
        guard let api = api else {
            print("❌ No API available and asset not offline")
            downloadingAssetIds.remove(asset.id)
            if currentIndex == indexToLoad { isLoadingCurrentAsset = false }
            return
        }

        // Download thumbnail in background
        Task { await downloadThumbnail(for: asset) }

        // For videos: create streaming marker (view will stream from server)
        if asset.type == .VIDEO {
            print("▶️ Video will STREAM from server: \(asset.originalFileName)")
            let streamingMarker = SpatialAssetData(
                leftImage: nil,
                rightImage: nil,
                originalData: Data(),  // Empty = streaming mode
                assetId: asset.id,
                fileName: asset.originalFileName,
                isVideo: true,
                isSpatial: asset.isSpatial,
                isPreviewQuality: false
            )
            cache[asset.id] = streamingMarker
            downloadingAssetIds.remove(asset.id)
            if currentIndex == indexToLoad { isLoadingCurrentAsset = false }
            return
        }

        // ===== STREAMING APPROACH FOR IMAGES =====
        // 1. Load preview quality first (fast) and display immediately
        // 2. Then upgrade to full resolution in background
        // Exception: spatial images need original (preview strips stereo pair)
        // Fallback: if preview fails, try original

        let isSpatialImage = spatialCache?.isSpatial(asset.id) ?? false

        if isSpatialImage {
            // Spatial images: must use original quality
            print("📥 Downloading SPATIAL image (original quality)...")
            let loaded = await loadImageFromServer(asset: asset, usePreview: false, indexToLoad: indexToLoad, api: api, diskCache: diskCache)
            if !loaded {
                print("⚠️ Spatial image failed to load")
            }
        } else {
            // Regular images: "stream" with preview first, then upgrade
            print("📥 Streaming IMAGE: preview first, then upgrade...")

            // STEP 1: Load preview quality (fast)
            var previewLoaded = await loadImageFromServer(asset: asset, usePreview: true, indexToLoad: indexToLoad, api: api, diskCache: diskCache)

            // Fallback: if preview failed, try original directly
            if !previewLoaded && currentIndex == indexToLoad {
                print("⚠️ Preview failed, trying original...")
                previewLoaded = await loadImageFromServer(asset: asset, usePreview: false, indexToLoad: indexToLoad, api: api, diskCache: diskCache)
            }

            // STEP 2: If preview loaded and still on same asset, upgrade to full resolution in background
            if previewLoaded && isShowingPreviewQuality && currentIndex == indexToLoad {
                Task {
                    // Small delay to let preview display first
                    try? await Task.sleep(for: .milliseconds(200))

                    // Check still on same asset and still showing preview
                    guard self.currentIndex == indexToLoad && self.isShowingPreviewQuality else { return }

                    print("🔄 Auto-upgrading to full resolution...")
                    await self.loadImageFromServer(asset: asset, usePreview: false, indexToLoad: indexToLoad, api: api, diskCache: diskCache, isBackgroundUpgrade: true)
                }
            }
        }

        downloadingAssetIds.remove(asset.id)
        if currentIndex == indexToLoad {
            isLoadingCurrentAsset = false
        }
    }

    /// Simple helper to decide preview vs original quality
    private func shouldUsePreviewQuality(for asset: Asset) -> Bool {
        guard asset.type != .VIDEO else { return false }
        guard let cache = spatialCache else { return false }
        return cache.hasBeenScanned(asset.id) && !cache.isSpatial(asset.id)
    }

    /// Load image from server with specified quality
    /// Returns true if successful
    @discardableResult
    private func loadImageFromServer(asset: Asset, usePreview: Bool, indexToLoad: Int, api: ImmichAPI, diskCache: DiskCache, isBackgroundUpgrade: Bool = false) async -> Bool {
        let url = usePreview ? api.getPreviewURL(assetId: asset.id) : api.getOriginalImageURL(assetId: asset.id)

        guard let url = url else {
            print("❌ Could not create URL for \(usePreview ? "preview" : "original")")
            return false
        }

        // Track progress only for initial load (not background upgrade)
        let shouldTrackProgress = !isBackgroundUpgrade && currentIndex == indexToLoad
        if shouldTrackProgress {
            progressTrackingAssetId = asset.id
            downloadProgress = 0
            downloadedBytes = 0
            totalBytes = 0
        }

        do {
            let data = try await downloadData(from: url, accessToken: api.getAccessToken(), trackProgress: shouldTrackProgress, assetId: asset.id)

            // Check we're still on the same asset
            guard currentIndex == indexToLoad else {
                print("⚠️ Asset changed during download, discarding")
                return false
            }

            // Save to disk cache
            if usePreview {
                diskCache.savePreview(assetId: asset.id, data: data)
            } else {
                diskCache.saveOriginal(assetId: asset.id, data: data)
            }

            // Process and cache
            if let imageAsset = await processImageData(data, asset: asset, isPreviewQuality: usePreview) {
                // For background upgrade, only update if still showing preview
                if isBackgroundUpgrade {
                    if isShowingPreviewQuality && currentIndex == indexToLoad {
                        cache[asset.id] = imageAsset
                        isShowingPreviewQuality = false
                        assetQualityDidUpgrade.toggle()  // Signal view to refresh
                        print("✅ Upgraded to FULL resolution: \(asset.id.prefix(8))...")
                    }
                } else {
                    cache[asset.id] = imageAsset
                    if currentIndex == indexToLoad {
                        isShowingPreviewQuality = usePreview
                    }
                    print("✅ \(usePreview ? "Preview" : "Full") IMAGE ready: \(asset.id.prefix(8))...")
                }
                return true
            } else {
                print("❌ Failed to process image data")
                return false
            }
        } catch {
            print("❌ Download failed (\(usePreview ? "preview" : "original")): \(error.localizedDescription)")
            return false
        }
    }

    /// Download data from URL (fast bulk download for images)
    private func downloadData(from url: URL, accessToken: String, trackProgress: Bool, assetId: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120

        // Use bulk download - much faster than byte-by-byte streaming
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        return data
    }

    /// Detect if data is a video based on file magic bytes
    private func isVideoData(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }

        // MP4/MOV/HEIC all have "ftyp" at offset 4 (ISO Base Media File Format)
        // We need to check the brand at offset 8 to distinguish video from HEIC images
        let ftypCheck = data.subdata(in: 4..<8)
        guard let ftypStr = String(data: ftypCheck, encoding: .ascii), ftypStr == "ftyp" else {
            return false
        }

        // Check the brand at offset 8-12
        let brandData = data.subdata(in: 8..<12)
        guard let brand = String(data: brandData, encoding: .ascii) else {
            return false
        }

        // HEIC/HEIF image brands - NOT videos
        let imageFormats = ["heic", "heix", "hevc", "hevx", "mif1", "msf1", "avif"]
        if imageFormats.contains(brand.lowercased()) {
            print("📷 Detected HEIC/HEIF image format: \(brand)")
            return false
        }

        // Video brands
        let videoFormats = ["isom", "iso2", "iso3", "iso4", "iso5", "iso6",
                           "mp41", "mp42", "mp71", "avc1", "qt  ",
                           "M4V ", "M4A ", "f4v ", "kddi", "3gp", "3g2"]
        if videoFormats.contains(brand) {
            print("🎬 Detected video format: \(brand)")
            return true
        }

        // Unknown brand - log for debugging, assume video if not HEIC
        print("⚠️ Unknown ftyp brand: '\(brand)' - assuming video")
        return true
    }

    /// Process image data into displayable SpatialAssetData
    private func processImageData(_ data: Data, asset: Asset, isPreviewQuality: Bool = false) async -> SpatialAssetData? {
        // Validate data
        guard !data.isEmpty else {
            print("❌ processImageData: data is empty")
            return nil
        }

        print("📷 Processing image: \(data.count) bytes, asset: \(asset.id.prefix(8))...")

        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else {
            // Log first few bytes for debugging
            let prefix = data.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
            print("❌ Failed to create image source. Data prefix: \(prefix)")
            return nil
        }

        let imageCount = CGImageSourceGetCount(imageSource)
        print("📷 Image has \(imageCount) frame(s)")

        // Spatial photos have 2+ frames (stereo pair)
        if imageCount >= 2,
           let left = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
           let right = CGImageSourceCreateImageAtIndex(imageSource, 1, nil) {
            return SpatialAssetData(
                leftImage: left,
                rightImage: right,
                originalData: data,
                assetId: asset.id,
                fileName: asset.originalFileName,
                isVideo: false,
                isSpatial: true,
                isPreviewQuality: false
            )
        }

        // Regular single-frame image
        if imageCount >= 1,
           let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
            print("✅ Image processed successfully")
            return SpatialAssetData(
                leftImage: image,
                rightImage: nil,
                originalData: data,
                assetId: asset.id,
                fileName: asset.originalFileName,
                isVideo: false,
                isSpatial: false,
                isPreviewQuality: isPreviewQuality
            )
        }

        // Failed to create image from source
        print("❌ Failed to create CGImage from source with \(imageCount) frames")
        return nil
    }

    /// Load full resolution version of current asset (called when user clicks "Load Full Resolution")
    func loadFullResolution() async {
        guard currentIndex >= 0 && currentIndex < assetMetadata.count else { return }
        guard isShowingPreviewQuality else {
            print("ℹ️ Already showing full resolution")
            return
        }
        guard let api = api else {
            print("❌ No API for full resolution download")
            return
        }

        let asset = assetMetadata[currentIndex]
        let indexToLoad = currentIndex

        print("🔄 Upgrading to full resolution: \(asset.originalFileName)")
        isLoadingFullResolution = true

        guard let url = api.getOriginalImageURL(assetId: asset.id) else {
            isLoadingFullResolution = false
            return
        }

        do {
            let data = try await downloadData(from: url, accessToken: api.getAccessToken(), trackProgress: true, assetId: asset.id)
            DiskCache.shared.saveOriginal(assetId: asset.id, data: data)

            if let imageAsset = await processImageData(data, asset: asset, isPreviewQuality: false) {
                if currentIndex == indexToLoad {
                    cache[asset.id] = imageAsset
                    isShowingPreviewQuality = false
                    print("✅ Full resolution loaded")
                }
            }
        } catch {
            print("❌ Full resolution download failed: \(error.localizedDescription)")
        }

        if currentIndex == indexToLoad {
            isLoadingFullResolution = false
        }
    }

    func preloadNearbyAssets() async {
        guard assetMetadata.count > 0 else { return }
        guard let api = api else { return }

        let start = max(0, currentIndex - cacheRadius)
        let end = min(assetMetadata.count - 1, currentIndex + cacheRadius)
        guard start <= end else { return }

        // Prioritize forward, then backward
        var indicesToLoad: [Int] = []
        for offset in 1...cacheRadius {
            if currentIndex + offset <= end {
                indicesToLoad.append(currentIndex + offset)
            }
            if currentIndex - offset >= start {
                indicesToLoad.append(currentIndex - offset)
            }
        }

        for i in indicesToLoad {
            if Task.isCancelled { return }
            guard i >= 0 && i < assetMetadata.count else { continue }
            let asset = assetMetadata[i]

            // Skip if already cached or downloading
            if cache[asset.id] != nil { continue }
            if downloadingAssetIds.contains(asset.id) { continue }

            // Skip videos for preloading (they stream)
            if asset.type == .VIDEO { continue }

            // Check if offline first
            let diskCache = DiskCache.shared
            if diskCache.isAvailableOffline(assetId: asset.id),
               let offlineData = diskCache.getOffline(assetId: asset.id),
               !offlineData.isEmpty {
                if let imageAsset = await processImageData(offlineData, asset: asset) {
                    cache[asset.id] = imageAsset
                }
                continue
            }

            // Download from server
            downloadingAssetIds.insert(asset.id)
            let usePreview = shouldUsePreviewQuality(for: asset)
            let url = usePreview ? api.getPreviewURL(assetId: asset.id) : api.getOriginalImageURL(assetId: asset.id)

            if let url = url {
                do {
                    let data = try await downloadData(from: url, accessToken: api.getAccessToken(), trackProgress: false, assetId: asset.id)
                    if usePreview {
                        diskCache.savePreview(assetId: asset.id, data: data)
                    } else {
                        diskCache.saveOriginal(assetId: asset.id, data: data)
                    }
                    if let imageAsset = await processImageData(data, asset: asset, isPreviewQuality: usePreview) {
                        cache[asset.id] = imageAsset
                    }
                } catch {
                    // Ignore preload errors
                }
            }
            downloadingAssetIds.remove(asset.id)
        }
    }

    private func cleanupDistantCache() {
        guard assetMetadata.count > 0 else { return }

        let start = max(0, currentIndex - cacheRadius)
        let end = min(assetMetadata.count - 1, currentIndex + cacheRadius)

        // Safety check to prevent invalid range
        guard start <= end else { return }

        let validRange = start...end
        let validIds = Set(assetMetadata[validRange].map { $0.id })

        // Remove assets outside the valid range
        for assetId in cache.keys {
            if !validIds.contains(assetId) {
                cache.removeValue(forKey: assetId)
                print("🗑️ Evicted from cache: \(assetId)")
            }
        }

        // Also clean up video pre-buffer cache
        for assetId in videoPreBufferCache.keys {
            if !validIds.contains(assetId) {
                videoPreBufferCache.removeValue(forKey: assetId)
                videoPreBufferTasks[assetId]?.cancel()
                videoPreBufferTasks.removeValue(forKey: assetId)
            }
        }
    }

    /// Pre-buffer adjacent videos for faster playback start
    func preBufferAdjacentVideos() {
        guard assetMetadata.count > 0 else { return }

        // Pre-buffer videos within a radius of 5 in each direction
        // This ensures videos are ready before user swipes to them
        let preBufferRadius = 5
        let startIndex = max(0, currentIndex - preBufferRadius)
        let endIndex = min(assetMetadata.count - 1, currentIndex + preBufferRadius)

        for index in startIndex...endIndex {
            // Skip current asset
            if index == currentIndex { continue }

            let asset = assetMetadata[index]

            // Only pre-buffer videos
            guard asset.type == .VIDEO else { continue }

            // Skip if already pre-buffered or in progress
            if videoPreBufferCache[asset.id] != nil { continue }
            if videoPreBufferTasks[asset.id] != nil { continue }

            // Start pre-buffering in background
            let task = Task {
                await preBufferVideo(asset: asset)
            }
            videoPreBufferTasks[asset.id] = task
        }
    }

    /// Pre-buffer first portion of a video
    private func preBufferVideo(asset: Asset) async {
        guard let api = api else { return }
        // Must use /original (not /video/playback) to match the streaming URL and preserve
        // MV-HEVC spatial format. The pre-buffer data must be from the exact same file as
        // the streaming request, otherwise AVFoundation receives corrupted/mismatched data.
        guard let url = api.getOriginalImageURL(assetId: asset.id) else { return }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(api.getAccessToken())", forHTTPHeaderField: "Authorization")
        // Request only first 1MB
        request.setValue("bytes=0-\(videoPreBufferSize - 1)", forHTTPHeaderField: "Range")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 || httpResponse.statusCode == 206 else {
                print("⚠️ Video pre-buffer failed for \(asset.id.prefix(8)): bad status")
                return
            }

            // Extract content length from Content-Range header (e.g., "bytes 0-1048575/12345678")
            var contentLength: Int64 = 0
            if let rangeHeader = httpResponse.value(forHTTPHeaderField: "Content-Range"),
               let totalStr = rangeHeader.split(separator: "/").last,
               let total = Int64(totalStr) {
                contentLength = total
            }

            // Get content type
            let contentType = httpResponse.mimeType

            // Store pre-buffered data with content info
            let preBufferInfo = VideoPreBufferInfo(
                data: data,
                contentLength: contentLength,
                contentType: contentType
            )
            videoPreBufferCache[asset.id] = preBufferInfo
            print("📦 Pre-buffered \(formatBytes(Int64(data.count))) for video \(asset.id.prefix(8))... (total: \(formatBytes(contentLength)))")
        } catch {
            if !Task.isCancelled {
                print("⚠️ Video pre-buffer error: \(error.localizedDescription)")
            }
        }

        // Clean up task reference
        videoPreBufferTasks.removeValue(forKey: asset.id)
    }

    /// Get pre-buffered info for a video (if available)
    func getPreBufferedVideoInfo(assetId: String) -> VideoPreBufferInfo? {
        return videoPreBufferCache[assetId]
    }

    /// Get video streaming info for a given asset ID
    func getVideoStreamingInfo(assetId: String) -> (url: URL, accessToken: String)? {
        guard let api = api,
              // Must use /original (not /video/playback) to preserve MV-HEVC spatial format
              // and to match the pre-buffer URL so data is consistent.
              let url = api.getOriginalImageURL(assetId: assetId),
              !api.getAccessToken().isEmpty else {
            return nil
        }
        return (url, api.getAccessToken())
    }

    /// Clear pre-buffered info for a video (after it starts playing)
    func clearPreBufferedVideoInfo(assetId: String) {
        videoPreBufferCache.removeValue(forKey: assetId)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// Fetch full asset details including EXIF data for the current asset
    func fetchCurrentAssetDetails() async {
        guard let api = api else {
            print("⚠️ No API available for fetching asset details")
            return
        }
        guard currentIndex < assetMetadata.count else { return }

        let assetId = assetMetadata[currentIndex].id

        // Check if already cached
        if let cached = fullAssetDetailsCache[assetId] {
            currentFullAssetDetails = cached
            print("📷 Using cached asset details for: \(assetId.prefix(8))...")
            return
        }

        isLoadingAssetDetails = true
        print("📷 Fetching full asset details for: \(assetId.prefix(8))...")

        do {
            let fullDetails = try await api.fetchAssetDetails(assetId: assetId)
            fullAssetDetailsCache[assetId] = fullDetails
            currentFullAssetDetails = fullDetails
            print("✅ Asset details loaded - fileName: \(fullDetails.originalFileName), hasExif: \(fullDetails.exifInfo != nil)")
        } catch let decodingError as DecodingError {
            print("❌ Failed to decode asset details: \(decodingError)")
            // Log specific decoding error details
            switch decodingError {
            case .typeMismatch(let type, let context):
                print("   Type mismatch: expected \(type), path: \(context.codingPath.map { $0.stringValue }.joined(separator: "."))")
            case .keyNotFound(let key, let context):
                print("   Key not found: \(key.stringValue), path: \(context.codingPath.map { $0.stringValue }.joined(separator: "."))")
            case .valueNotFound(let type, let context):
                print("   Value not found: \(type), path: \(context.codingPath.map { $0.stringValue }.joined(separator: "."))")
            case .dataCorrupted(let context):
                print("   Data corrupted: \(context.debugDescription)")
            @unknown default:
                print("   Unknown decoding error")
            }
            // Fall back to basic metadata
            currentFullAssetDetails = assetMetadata[currentIndex]
        } catch {
            print("❌ Failed to fetch asset details: \(error.localizedDescription)")
            // Fall back to basic metadata
            currentFullAssetDetails = assetMetadata[currentIndex]
        }

        isLoadingAssetDetails = false
    }

    /// Download thumbnail for an asset
    func downloadThumbnail(for asset: Asset) async {
        guard let api = api else { return }
        guard thumbnailCache[asset.id] == nil else { return }  // Already cached

        guard let url = api.getThumbnailURL(assetId: asset.id) else { return }

        do {
            var request = URLRequest(url: url)
            request.setValue("Bearer \(api.getAccessToken())", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  data.count > 0 else { return }

            guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
                  let thumbnail = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { return }

            // Calculate aspect ratio from actual thumbnail dimensions
            let width = Double(thumbnail.width)
            let height = Double(thumbnail.height)
            let aspectRatio = width / height

            thumbnailCache[asset.id] = (image: thumbnail, aspectRatio: aspectRatio)
            print("🖼️ Thumbnail cached for: \(asset.id.prefix(8))... (\(Int(width))x\(Int(height)), ratio: \(String(format: "%.2f", aspectRatio)))")
        } catch {
            print("⚠️ Thumbnail download failed: \(error.localizedDescription)")
        }
    }

    /// Preload thumbnails for nearby assets (fire and forget, runs in background)
    func preloadNearbyThumbnails() {
        Task {
            await preloadThumbnailsAsync()
        }
    }

    /// Async implementation of thumbnail preloading
    private func preloadThumbnailsAsync() async {
        guard assetMetadata.count > 0 else { return }

        let start = max(0, currentIndex - thumbnailPreloadRadius)
        let end = min(assetMetadata.count - 1, currentIndex + thumbnailPreloadRadius)

        guard start <= end else { return }

        // Prioritize: current first, then forward (more likely swipe direction), then backward
        var indicesToLoad: [Int] = []
        indicesToLoad.append(currentIndex)
        for offset in 1...thumbnailPreloadRadius {
            if currentIndex + offset <= end {
                indicesToLoad.append(currentIndex + offset)
            }
            if currentIndex - offset >= start {
                indicesToLoad.append(currentIndex - offset)
            }
        }

        // Download thumbnails concurrently (they're small, so parallel is fine)
        await withTaskGroup(of: Void.self) { group in
            for i in indicesToLoad {
                guard i >= 0 && i < assetMetadata.count else { continue }
                let asset = assetMetadata[i]

                // Skip if already cached
                if thumbnailCache[asset.id] != nil { continue }

                group.addTask {
                    await self.downloadThumbnail(for: asset)
                }
            }
        }
    }

    /// Save current asset for offline access
    /// Check if a specific asset is currently being downloaded
    func isAssetBeingDownloaded(_ assetId: String) -> Bool {
        return savingOfflineAssetIds.contains(assetId)
    }

    func saveCurrentAssetOffline() async -> Bool {
        guard currentIndex >= 0 && currentIndex < assetMetadata.count else { return false }

        let asset = assetMetadata[currentIndex]
        let diskCache = DiskCache.shared

        // Check if already offline
        if diskCache.isAvailableOffline(assetId: asset.id) {
            print("ℹ️ Asset already available offline")
            return true
        }

        // Check if this specific asset is already being downloaded
        if savingOfflineAssetIds.contains(asset.id) {
            print("⚠️ This asset is already being downloaded")
            return false
        }

        // Track which asset we're saving
        savingOfflineAssetIds.insert(asset.id)

        // For videos, we need to download the full file (cache only has streaming marker with empty data)
        // For images, check if we have valid cached data
        if asset.type != .VIDEO,
           let cachedAsset = cache[asset.id],
           !cachedAsset.isPreviewQuality,
           !cachedAsset.originalData.isEmpty {
            // Use cached original data (only for non-videos with actual data)
            print("💾 Saving cached data for offline: \(asset.id.prefix(8))... (\(cachedAsset.originalData.count) bytes)")
            diskCache.saveOffline(assetId: asset.id, data: cachedAsset.originalData)
            savingOfflineAssetIds.remove(asset.id)
            return true
        }

        // Need to download original quality (always for videos, or when cache is empty/preview)
        print("📥 Downloading original for offline storage... (isVideo: \(asset.type == .VIDEO))")

        guard let api = api else {
            print("❌ Cannot download for offline: API is nil")
            savingOfflineAssetIds.remove(asset.id)
            return false
        }

        // Download the full original file
        guard let url = api.getOriginalImageURL(assetId: asset.id) else {
            print("❌ Cannot create URL for offline download")
            savingOfflineAssetIds.remove(asset.id)
            return false
        }

        // Capture values for the download task (so it can continue after clear())
        let assetId = asset.id
        let accessToken = api.getAccessToken()
        let isVideo = asset.type == .VIDEO

        // Store for persistence through clear()
        offlineDownloadAccessToken = accessToken

        // Start the download in a task that we track - don't wait for completion
        let task = Task { [weak self] in
            guard let self = self else { return false }
            return await self.performOfflineDownload(assetId: assetId, url: url, accessToken: accessToken, isVideo: isVideo)
        }
        offlineDownloadTasks[assetId] = task

        // Return immediately - download continues in background
        return true
    }

    /// Perform the actual offline download - runs independently of view lifecycle
    private func performOfflineDownload(assetId: String, url: URL, accessToken: String, isVideo: Bool) async -> Bool {
        let diskCache = DiskCache.shared

        // Initialize progress tracking
        await MainActor.run {
            activeDownloads[assetId] = DownloadProgress(id: assetId)
        }

        defer {
            // Clean up when done (success or failure)
            Task { @MainActor in
                savingOfflineAssetIds.remove(assetId)
                offlineDownloadTasks.removeValue(forKey: assetId)
                activeDownloads.removeValue(forKey: assetId)
            }
        }

        do {
            var request = URLRequest(url: url)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 300  // 5 minute timeout for large videos

            // Use bytes stream but read in chunks for much better performance
            let (bytes, response) = try await URLSession.shared.bytes(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                print("❌ Download failed with bad response for \(assetId.prefix(8))...")
                return false
            }

            let expectedLength = httpResponse.expectedContentLength

            // Set total bytes for progress
            if expectedLength > 0 {
                await MainActor.run {
                    activeDownloads[assetId]?.totalBytes = expectedLength
                }
            }

            var data = Data()
            if expectedLength > 0 {
                data.reserveCapacity(Int(expectedLength))
            }

            // Read in chunks of 64KB for much better performance
            let chunkSize = 65536
            var buffer = [UInt8]()
            buffer.reserveCapacity(chunkSize)
            var lastProgressUpdate = Date()

            for try await byte in bytes {
                // Check for cancellation
                if Task.isCancelled {
                    print("⚠️ Download cancelled for \(assetId.prefix(8))...")
                    return false
                }

                buffer.append(byte)

                // When buffer is full, append to data
                if buffer.count >= chunkSize {
                    data.append(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)

                    // Update progress at most every 100ms to avoid UI thrashing
                    let now = Date()
                    if now.timeIntervalSince(lastProgressUpdate) >= 0.1 {
                        let currentBytes = Int64(data.count)
                        await MainActor.run {
                            activeDownloads[assetId]?.downloadedBytes = currentBytes
                        }
                        lastProgressUpdate = now
                    }
                }
            }

            // Append remaining bytes
            if !buffer.isEmpty {
                data.append(contentsOf: buffer)
            }

            // Final progress update
            let finalBytes = Int64(data.count)
            await MainActor.run {
                activeDownloads[assetId]?.downloadedBytes = finalBytes
            }

            print("📥 Download complete for \(assetId.prefix(8))...: \(data.count) bytes")

            if data.isEmpty {
                print("❌ Downloaded empty data for \(assetId.prefix(8))...")
                return false
            }

            // Save to offline storage
            diskCache.saveOffline(assetId: assetId, data: data)
            print("💾 Saved to offline: \(assetId.prefix(8))... (\(data.count) bytes)")

            return true
        } catch {
            print("❌ Error downloading for offline (\(assetId.prefix(8))...): \(error.localizedDescription)")
            return false
        }
    }

    /// Check if current asset is available offline
    var isCurrentAssetOffline: Bool {
        guard currentIndex >= 0 && currentIndex < assetMetadata.count else { return false }
        return DiskCache.shared.isAvailableOffline(assetId: assetMetadata[currentIndex].id)
    }

    /// Get streaming URL for current video asset (for progressive playback)
    func getVideoStreamingURL() -> URL? {
        guard currentIndex >= 0 && currentIndex < assetMetadata.count else {
            print("❌ getVideoStreamingURL: index out of bounds")
            return nil
        }
        let asset = assetMetadata[currentIndex]
        guard asset.type == .VIDEO else {
            print("❌ getVideoStreamingURL: asset is not a video (type: \(asset.type))")
            return nil
        }
        let url = api?.getOriginalImageURL(assetId: asset.id)
        print("📼 getVideoStreamingURL: \(url?.absoluteString ?? "nil")")
        return url
    }

    /// Get streamable video URL with embedded API key (for direct AVPlayer use)
    func getStreamableVideoURL() -> URL? {
        guard currentIndex >= 0 && currentIndex < assetMetadata.count else { return nil }
        let asset = assetMetadata[currentIndex]
        guard asset.type == .VIDEO else { return nil }
        return api?.getStreamableVideoURL(assetId: asset.id)
    }

    /// Get video playback URL (Immich's dedicated video endpoint - transcoded)
    func getVideoPlaybackURL() -> URL? {
        guard currentIndex >= 0 && currentIndex < assetMetadata.count else { return nil }
        let asset = assetMetadata[currentIndex]
        guard asset.type == .VIDEO else { return nil }
        return api?.getVideoPlaybackURL(assetId: asset.id)
    }

    /// Get original video URL (untranscoded - preserves spatial video format)
    func getVideoOriginalURL() -> URL? {
        guard currentIndex >= 0 && currentIndex < assetMetadata.count else { return nil }
        let asset = assetMetadata[currentIndex]
        guard asset.type == .VIDEO else { return nil }
        return api?.getOriginalImageURL(assetId: asset.id)  // /original works for videos too
    }

    /// Get access token for video streaming authentication
    var accessTokenForStreaming: String? {
        return api?.getAccessToken()
    }

    /// Download original quality data for the current asset (for sharing)
    /// Returns the original data even if we only have preview quality cached
    func downloadOriginalForSharing() async -> Data? {
        guard let api = api else {
            print("❌ No API available for downloading original")
            return nil
        }
        guard currentIndex >= 0 && currentIndex < assetMetadata.count else {
            print("❌ Invalid current index for downloading original")
            return nil
        }

        let asset = assetMetadata[currentIndex]

        // Check cache state for debugging
        if let cachedAsset = cache[asset.id] {
            print("🔍 Cache state for \(asset.id.prefix(8)): isPreviewQuality=\(cachedAsset.isPreviewQuality), dataSize=\(cachedAsset.originalData.count)")
        } else {
            print("🔍 No cache entry for \(asset.id.prefix(8))")
        }

        // Check if we already have full quality in cache
        if let cachedAsset = cache[asset.id],
           !cachedAsset.isPreviewQuality,
           !cachedAsset.originalData.isEmpty {
            print("📦 Using cached original data for sharing: \(cachedAsset.originalData.count) bytes")
            return cachedAsset.originalData
        }

        // Need to download the original
        guard let url = api.getOriginalImageURL(assetId: asset.id) else {
            print("❌ Could not create original URL for sharing")
            return nil
        }

        print("📥 Downloading original quality for sharing: \(asset.originalFileName) from \(url.absoluteString)")

        do {
            var request = URLRequest(url: url)
            request.setValue("Bearer \(api.getAccessToken())", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 300  // 5 minute timeout

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                print("❌ Failed to download original: bad response")
                return nil
            }

            print("✅ Downloaded original: \(data.count) bytes")
            return data
        } catch {
            print("❌ Failed to download original: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Album Grid Preloading

    /// Preload assets that are visible in an album grid view
    /// Call this from album views when visible items change
    func preloadVisibleAssets(_ assets: [Asset], visibleIndices: [Int], api: ImmichAPI, spatialCache: SpatialAssetCache?) {
        // Cancel preloads for assets no longer visible
        let visibleIds = Set(visibleIndices.compactMap { i in
            i >= 0 && i < assets.count ? assets[i].id : nil
        })

        for (assetId, task) in albumPreloadTasks {
            if !visibleIds.contains(assetId) {
                task.cancel()
                albumPreloadTasks.removeValue(forKey: assetId)
            }
        }

        // Remove cached assets that are no longer visible (keep memory bounded)
        let currentCacheCount = albumPreloadCache.count
        if currentCacheCount > maxAlbumPreloadCount {
            // Remove assets not in visible set, oldest first
            for assetId in albumPreloadCache.keys {
                if !visibleIds.contains(assetId) {
                    albumPreloadCache.removeValue(forKey: assetId)
                    if albumPreloadCache.count <= maxAlbumPreloadCount / 2 {
                        break  // Keep some buffer
                    }
                }
            }
        }

        // Start preloading visible assets
        for index in visibleIndices {
            guard index >= 0 && index < assets.count else { continue }
            let asset = assets[index]

            // Skip if already cached or being preloaded
            if albumPreloadCache[asset.id] != nil { continue }
            if albumPreloadTasks[asset.id] != nil { continue }

            // Skip videos (they stream)
            if asset.type == .VIDEO { continue }

            // Start preload task
            let task = Task {
                await preloadAssetForAlbum(asset: asset, api: api, spatialCache: spatialCache)
            }
            albumPreloadTasks[asset.id] = task
        }
    }

    /// Preload a single asset for album view
    private func preloadAssetForAlbum(asset: Asset, api: ImmichAPI, spatialCache: SpatialAssetCache?) async {
        // Check disk cache first
        let diskCache = DiskCache.shared
        if diskCache.isAvailableOffline(assetId: asset.id),
           let offlineData = diskCache.getOffline(assetId: asset.id),
           !offlineData.isEmpty {
            if let imageAsset = await processImageData(offlineData, asset: asset) {
                albumPreloadCache[asset.id] = imageAsset
                print("📦 Album preload from disk: \(asset.id.prefix(8))...")
            }
            albumPreloadTasks.removeValue(forKey: asset.id)
            return
        }

        // Determine quality (spatial needs original, regular can use preview)
        let isSpatial = spatialCache?.isSpatial(asset.id) ?? false
        let usePreview = !isSpatial

        let url = usePreview ? api.getPreviewURL(assetId: asset.id) : api.getOriginalImageURL(assetId: asset.id)

        guard let url = url else {
            albumPreloadTasks.removeValue(forKey: asset.id)
            return
        }

        do {
            var request = URLRequest(url: url)
            request.setValue("Bearer \(api.getAccessToken())", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 60

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                albumPreloadTasks.removeValue(forKey: asset.id)
                return
            }

            // Save to disk cache
            if usePreview {
                diskCache.savePreview(assetId: asset.id, data: data)
            } else {
                diskCache.saveOriginal(assetId: asset.id, data: data)
            }

            if let imageAsset = await processImageData(data, asset: asset, isPreviewQuality: usePreview) {
                albumPreloadCache[asset.id] = imageAsset
                print("📦 Album preload complete: \(asset.id.prefix(8))... (\(usePreview ? "preview" : "original"))")
            }
        } catch {
            if !Task.isCancelled {
                print("⚠️ Album preload failed for \(asset.id.prefix(8))...: \(error.localizedDescription)")
            }
        }

        albumPreloadTasks.removeValue(forKey: asset.id)
    }

    /// Clear all album preloaded assets (call when leaving album view entirely)
    /// Hide the current asset (move to locked folder) and advance to next/previous
    /// Returns true if viewer should remain open, false if it should dismiss (no assets left)
    @MainActor
    func hideCurrentAsset() async -> Bool {
        guard currentIndex < assetMetadata.count,
              let api = api else { return true }

        let asset = assetMetadata[currentIndex]
        let assetId = asset.id

        do {
            try await api.updateAssetVisibility(assetIds: [assetId], visibility: "locked")

            // Remove from spatial cache
            spatialCache?.removeSpatialAsset(assetId)

            // Remove from local asset list
            cache.removeValue(forKey: assetId)
            assetMetadata.removeAll { $0.id == assetId }

            if assetMetadata.isEmpty {
                return false
            }

            // Adjust index if needed
            if currentIndex >= assetMetadata.count {
                currentIndex = assetMetadata.count - 1
            }

            // Reload current asset
            loadingForIndex = currentIndex
            updateLastViewedAsset()
            return true
        } catch {
            print("❌ Failed to hide asset: \(error)")
            return true
        }
    }

    func clearAlbumPreloadCache() {
        for task in albumPreloadTasks.values {
            task.cancel()
        }
        albumPreloadTasks.removeAll()
        albumPreloadCache.removeAll()
        print("🗑️ Album preload cache cleared")
    }

    /// Check if an asset is preloaded
    func isAssetPreloaded(_ assetId: String) -> Bool {
        return albumPreloadCache[assetId] != nil
    }

    func clear() {
        currentLoadTask?.cancel()
        preloadTask?.cancel()
        currentLoadTask = nil
        preloadTask = nil
        self.assetMetadata = []
        self.cache = [:]
        self.thumbnailCache = [:]
        self.fullAssetDetailsCache = [:]
        self.currentFullAssetDetails = nil
        self.isLoadingAssetDetails = false
        self.downloadingAssetIds = []
        self.progressTrackingAssetId = nil
        self.currentIndex = 0
        self.loadingForIndex = -1
        self.isDisplaying = false
        self.isRestoringScrollPosition = false
        self.isShowingPreviewQuality = false
        self.isLoadingFullResolution = false
        // Don't clear API if there are active offline downloads
        if offlineDownloadTasks.isEmpty {
            self.api = nil
        }
        self.spatialCache = nil
        // Note: Don't clear savingOfflineAssetIds or offlineDownloadTasks
        // to allow downloads to complete even after closing the viewer
    }
}
