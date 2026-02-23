//
//  SpatialAssetCache.swift
//  ImmichVisionProClient
//
//  Created by Julian Gray on 1/20/26.
//

import Foundation
import SwiftUI
import Combine
import ImageIO
import AVFoundation
import RealityKit

/// Manages a persistent cache of spatial (stereoscopic) asset IDs
/// Since Immich API doesn't provide spatial metadata, we scan images once and cache locally
class SpatialAssetCache: ObservableObject {
    @Published var spatialAssetIds: Set<String> = []
    @Published var spatialAssets: [Asset] = []  // Cached spatial asset metadata for quick display
    @Published var isScanning = false
    @Published var scanProgress: Double = 0  // 0.0 to 1.0
    @Published var scannedCount: Int = 0
    @Published var totalToScan: Int = 0
    @Published var totalLibrarySize: Int = 0  // Total assets in library
    @Published var lastScanDate: Date?

    private let cacheKey = "spatialAssetIds"
    private let lastScanKey = "lastSpatialScanDate"
    private let scannedIdsKey = "scannedAssetIds"  // Track which assets we've already checked
    private let spatialAssetsKey = "spatialAssetsData"  // Cache the actual asset metadata
    private let hiddenSpatialKey = "hiddenSpatialAssets"  // Spatial assets moved to locked folder

    private var scannedAssetIds: Set<String> = []  // Assets we've already checked (spatial or not)
    private var hiddenSpatialAssets: [String: Asset] = [:]  // Spatial assets that were hidden (for restore on unhide)
    private var scanTask: Task<Void, Never>?

    init() {
        loadCache()
    }

    /// Load cached spatial asset IDs from UserDefaults
    private func loadCache() {
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let ids = try? JSONDecoder().decode(Set<String>.self, from: data) {
            spatialAssetIds = ids
            print("📦 Loaded \(ids.count) spatial asset IDs from cache")
        }

        if let data = UserDefaults.standard.data(forKey: scannedIdsKey),
           let ids = try? JSONDecoder().decode(Set<String>.self, from: data) {
            scannedAssetIds = ids
            print("📦 Loaded \(ids.count) previously scanned asset IDs")
        }

        if let data = UserDefaults.standard.data(forKey: spatialAssetsKey),
           let assets = try? JSONDecoder().decode([Asset].self, from: data) {
            spatialAssets = assets
            print("📦 Loaded \(assets.count) spatial asset metadata from cache")
        }

        if let data = UserDefaults.standard.data(forKey: hiddenSpatialKey),
           let hidden = try? JSONDecoder().decode([String: Asset].self, from: data) {
            hiddenSpatialAssets = hidden
            print("📦 Loaded \(hidden.count) hidden spatial asset(s) for potential restore")
        }

        lastScanDate = UserDefaults.standard.object(forKey: lastScanKey) as? Date
    }

    /// Save spatial asset IDs to UserDefaults
    private func saveCache() {
        if let data = try? JSONEncoder().encode(spatialAssetIds) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }

        if let data = try? JSONEncoder().encode(scannedAssetIds) {
            UserDefaults.standard.set(data, forKey: scannedIdsKey)
        }

        if let data = try? JSONEncoder().encode(spatialAssets) {
            UserDefaults.standard.set(data, forKey: spatialAssetsKey)
        }

        if let data = try? JSONEncoder().encode(hiddenSpatialAssets) {
            UserDefaults.standard.set(data, forKey: hiddenSpatialKey)
        }

        UserDefaults.standard.set(Date(), forKey: lastScanKey)
        lastScanDate = Date()
        print("💾 Saved \(spatialAssetIds.count) spatial IDs, \(spatialAssets.count) assets, \(scannedAssetIds.count) total scanned")
    }

    /// Check if an asset is known to be spatial
    func isSpatial(_ assetId: String) -> Bool {
        return spatialAssetIds.contains(assetId)
    }

    /// Remove a spatial asset from the cache (e.g., when hidden or deleted)
    /// If it was spatial, remembers it for potential restore on unhide
    func removeSpatialAsset(_ assetId: String) {
        // Remember spatial assets so they can be restored if unhidden
        if spatialAssetIds.contains(assetId),
           let asset = spatialAssets.first(where: { $0.id == assetId }) {
            hiddenSpatialAssets[assetId] = asset
        }
        spatialAssetIds.remove(assetId)
        spatialAssets.removeAll { $0.id == assetId }
        scannedAssetIds.remove(assetId)
        saveCache()
    }

    /// Restore a previously-spatial asset after unhiding from the locked folder
    func restoreSpatialAsset(_ assetId: String, asset: Asset) {
        if let cachedAsset = hiddenSpatialAssets.removeValue(forKey: assetId) {
            // Was previously known as spatial — restore it
            spatialAssetIds.insert(assetId)
            if !spatialAssets.contains(where: { $0.id == assetId }) {
                spatialAssets.append(cachedAsset)
            }
            scannedAssetIds.insert(assetId)
            saveCache()
            print("♻️ Restored spatial asset from hidden: \(assetId.prefix(8))...")
        } else {
            // Not previously known as spatial — mark as unscanned so next scan picks it up
            scannedAssetIds.remove(assetId)
        }
    }

    /// Remove cached spatial assets that are no longer in the visible library
    /// (e.g., hidden/locked/deleted from web UI or another view)
    @MainActor
    func pruneHiddenAssets(visibleAssetIds: Set<String>) {
        let removedIds = spatialAssetIds.subtracting(visibleAssetIds)
        guard !removedIds.isEmpty else { return }

        // Remember pruned spatial assets for potential restore on unhide
        for id in removedIds {
            if let asset = spatialAssets.first(where: { $0.id == id }) {
                hiddenSpatialAssets[id] = asset
            }
        }

        spatialAssetIds.subtract(removedIds)
        spatialAssets.removeAll { removedIds.contains($0.id) }
        scannedAssetIds.subtract(removedIds)
        saveCache()
        print("🧹 Pruned \(removedIds.count) hidden/deleted asset(s) from spatial cache")
    }

    /// Total number of assets scanned across all sessions (for progress display)
    var overallScannedCount: Int {
        // scannedAssetIds already includes current session's progress as items are scanned
        scannedAssetIds.count
    }

    /// Overall progress through the entire library (0.0 to 1.0)
    var overallProgress: Double {
        guard totalLibrarySize > 0 else { return 0 }
        return Double(overallScannedCount) / Double(totalLibrarySize)
    }

    /// Check if an asset has already been scanned
    func hasBeenScanned(_ assetId: String) -> Bool {
        return scannedAssetIds.contains(assetId)
    }

    /// Get all spatial assets from a list of assets
    func filterSpatialAssets(_ assets: [Asset]) -> [Asset] {
        return assets.filter { spatialAssetIds.contains($0.id) }
    }

    /// Cancel any ongoing scan
    @MainActor
    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    /// Clear the cache completely
    @MainActor
    func clearCache() {
        spatialAssetIds.removeAll()
        spatialAssets.removeAll()
        scannedAssetIds.removeAll()
        hiddenSpatialAssets.removeAll()
        UserDefaults.standard.removeObject(forKey: cacheKey)
        UserDefaults.standard.removeObject(forKey: scannedIdsKey)
        UserDefaults.standard.removeObject(forKey: spatialAssetsKey)
        UserDefaults.standard.removeObject(forKey: hiddenSpatialKey)
        UserDefaults.standard.removeObject(forKey: lastScanKey)
        lastScanDate = nil
        print("🗑️ Spatial cache cleared")
    }

    /// Scan library for spatial assets
    /// Only scans assets that haven't been scanned before (incremental)
    @MainActor
    func scanLibrary(api: ImmichAPI, assets: [Asset]) {
        // Cancel any existing scan
        cancelScan()

        // Prune any cached spatial assets no longer in the visible library (hidden/deleted)
        let visibleIds = Set(assets.map { $0.id })
        pruneHiddenAssets(visibleAssetIds: visibleIds)

        // Filter to assets we haven't scanned yet (both images and videos)
        let assetsToScan = assets.filter {
            !scannedAssetIds.contains($0.id)
        }

        totalLibrarySize = assets.count  // Track total library size

        if assetsToScan.isEmpty {
            print("✅ All assets already scanned")
            return
        }

        isScanning = true
        scanProgress = 0
        scannedCount = 0
        totalToScan = assetsToScan.count

        print("🔍 Starting spatial scan: \(assetsToScan.count) new assets to check")

        scanTask = Task { @MainActor in
            var foundCount = 0

            for (index, asset) in assetsToScan.enumerated() {
                // Check for cancellation - save progress before exiting
                if Task.isCancelled {
                    print("⏸️ Scan cancelled at \(scannedCount)/\(totalToScan) - saving progress...")
                    saveCache()
                    isScanning = false
                    return
                }

                let isSpatial: Bool
                if asset.type == .IMAGE {
                    isSpatial = await checkIfSpatialImage(asset: asset, api: api)
                } else if asset.type == .VIDEO {
                    isSpatial = await checkIfSpatialVideo(asset: asset, api: api)
                } else {
                    isSpatial = false
                }

                // Mark as scanned regardless of result
                scannedAssetIds.insert(asset.id)

                if isSpatial {
                    spatialAssetIds.insert(asset.id)
                    spatialAssets.append(asset)  // Store asset metadata for quick display
                    foundCount += 1
                    print("✅ Found spatial [\(foundCount)]: \(asset.id.prefix(8))...")
                }

                // Update progress
                scannedCount = index + 1
                scanProgress = Double(scannedCount) / Double(totalToScan)

                // Save periodically (every 25 assets for more frequent checkpoints)
                if scannedCount % 25 == 0 {
                    saveCache()
                }
            }

            // Final save
            saveCache()

            isScanning = false
            print("🔍 Scan complete: found \(foundCount) spatial photos out of \(assetsToScan.count) scanned")
        }
    }

    /// Check a single image asset to see if it's spatial using ImagePresentationComponent
    private func checkIfSpatialImage(asset: Asset, api: ImmichAPI) async -> Bool {
        guard let url = api.getOriginalImageURL(assetId: asset.id) else {
            return false
        }

        do {
            var request = URLRequest(url: url)
            request.setValue("Bearer \(api.getAccessToken())", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 30

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  data.count > 0 else {
                return false
            }

            // Write to temp file and use ImagePresentationComponent (same as playback)
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(asset.id)_scan.heic")
            try data.write(to: tempURL)
            defer { try? FileManager.default.removeItem(at: tempURL) }

            let component = try await ImagePresentationComponent(contentsOf: tempURL)
            let modes = component.availableViewingModes
            print("🔍 IMAGE \(asset.originalFileName): modes = \(modes)")

            // Only check for actual stereo modes
            let hasSpatialStereoImmersive = modes.contains(.spatialStereoImmersive)
            let hasSpatialStereo = modes.contains(.spatialStereo)

            print("🔍 IMAGE \(asset.originalFileName): spatialStereoImmersive=\(hasSpatialStereoImmersive), spatialStereo=\(hasSpatialStereo)")

            let isSpatial = hasSpatialStereoImmersive || hasSpatialStereo

            if isSpatial {
                print("✅ Spatial photo: \(asset.originalFileName)")
            }
            return isSpatial

        } catch {
            print("⚠️ Error checking image \(asset.id.prefix(8))...: \(error.localizedDescription)")
            return false
        }
    }

    /// Check a single video asset to see if it's spatial (MV-HEVC format)
    /// Downloads full video and uses AVFoundation for accurate detection
    private func checkIfSpatialVideo(asset: Asset, api: ImmichAPI) async -> Bool {
        // First check if Immich API already indicates spatial via projectionType
        if asset.isSpatial {
            print("✅ Video marked spatial by API metadata: \(asset.originalFileName)")
            return true
        }

        guard let url = api.getOriginalImageURL(assetId: asset.id) else {
            return false
        }

        // Download full video for accurate AVFoundation analysis
        var request = URLRequest(url: url)
        request.setValue("Bearer \(api.getAccessToken())", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  data.count > 0 else {
                return false
            }

            // Write to temp file for AVFoundation
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(asset.id)_scan.mov")
            try data.write(to: tempURL)
            defer { try? FileManager.default.removeItem(at: tempURL) }

            // Use AVFoundation to check for spatial tracks
            let avAsset = AVURLAsset(url: tempURL)
            let isSpatial = await checkVideoTracksForSpatial(asset: avAsset, fileName: asset.originalFileName)
            return isSpatial

        } catch {
            print("⚠️ Error checking video \(asset.id.prefix(8))...: \(error.localizedDescription)")
            return false
        }
    }

    /// Use AVFoundation to check video tracks for MV-HEVC/spatial indicators
    private func checkVideoTracksForSpatial(asset: AVAsset, fileName: String = "") async -> Bool {
        do {
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            print("🔍 VIDEO \(fileName): \(videoTracks.count) video track(s)")

            for (idx, track) in videoTracks.enumerated() {
                // Check track's media characteristics for stereo multiview (most reliable)
                let characteristics = try await track.load(.mediaCharacteristics)
                let hasStereMultiview = characteristics.contains(.containsStereoMultiviewVideo)
                print("🔍 VIDEO \(fileName): track[\(idx)] containsStereoMultiviewVideo = \(hasStereMultiview)")

                if hasStereMultiview {
                    print("✅ VIDEO \(fileName): SPATIAL via .containsStereoMultiviewVideo")
                    return true
                }

                // Check format descriptions for MV-HEVC indicators
                let formatDescriptions = try await track.load(.formatDescriptions)
                for formatDesc in formatDescriptions {
                    if let extensions = CMFormatDescriptionGetExtensions(formatDesc) as? [String: Any] {
                        // Log all extension keys for debugging
                        print("🔍 VIDEO \(fileName): track[\(idx)] extension keys: \(extensions.keys.sorted())")

                        // Only check for specific MV-HEVC spatial video keys
                        let hasStereoMVHEVC = extensions["StereoMVHEVC"] != nil
                        let hasLeftEye = extensions["HasLeftStereoEyeView"] != nil
                        let hasRightEye = extensions["HasRightStereoEyeView"] != nil
                        let hasHFOV = extensions["HorizontalFieldOfView"] != nil
                        let hasBaseline = extensions["StereoCameraBaseline"] != nil

                        if hasStereoMVHEVC || hasLeftEye || hasRightEye || hasHFOV || hasBaseline {
                            print("✅ VIDEO \(fileName): SPATIAL via extensions (StereoMVHEVC=\(hasStereoMVHEVC), LeftEye=\(hasLeftEye), RightEye=\(hasRightEye), HFOV=\(hasHFOV), Baseline=\(hasBaseline))")
                            return true
                        }
                    }
                }
            }
        } catch {
            print("⚠️ VIDEO \(fileName): Error checking tracks: \(error.localizedDescription)")
        }

        print("🔍 VIDEO \(fileName): NOT spatial")
        return false
    }

    /// Incrementally scan a batch of assets without canceling existing scans or pruning the cache.
    /// Used by LibraryView to background-scan newly loaded buckets.
    func scanAssetsInBackground(api: ImmichAPI, assets: [Asset]) async {
        for asset in assets {
            guard !Task.isCancelled else { return }

            let isSpatial: Bool
            if asset.type == .IMAGE {
                isSpatial = await checkIfSpatialImage(asset: asset, api: api)
            } else if asset.type == .VIDEO {
                isSpatial = await checkIfSpatialVideo(asset: asset, api: api)
            } else {
                isSpatial = false
            }

            await MainActor.run {
                scannedAssetIds.insert(asset.id)
                if isSpatial {
                    spatialAssetIds.insert(asset.id)
                    if !spatialAssets.contains(where: { $0.id == asset.id }) {
                        spatialAssets.append(asset)
                    }
                    print("✅ Background scan found spatial: \(asset.id.prefix(8))...")
                }
            }
        }

        // Save once at the end
        await MainActor.run {
            saveCache()
        }
    }

    /// Manually add a spatial asset (e.g., when detected during viewing)
    @MainActor
    func markAsSpatial(_ assetId: String, asset: Asset? = nil) {
        if !spatialAssetIds.contains(assetId) {
            spatialAssetIds.insert(assetId)
            scannedAssetIds.insert(assetId)
            // Also add to spatialAssets array if asset metadata provided
            if let asset = asset, !spatialAssets.contains(where: { $0.id == assetId }) {
                spatialAssets.append(asset)
            }
            saveCache()
        }
    }

    /// Mark an asset as scanned (not spatial)
    @MainActor
    func markAsScanned(_ assetId: String) {
        if !scannedAssetIds.contains(assetId) {
            scannedAssetIds.insert(assetId)
            // Don't save immediately for non-spatial, batch save later
        }
    }
}

