//
//  DiskCache.swift
//  ImmichVisionProClient
//
//  Created by Julian Gray on 1/21/26.
//

import Foundation
import SwiftUI
import Combine

/// Manages persistent disk cache for downloaded assets
/// Stores both preview and original quality versions separately
class DiskCache: ObservableObject {
    static let shared = DiskCache()

    @Published var cacheSize: Int64 = 0
    @Published var offlineAssetIds: Set<String> = []  // Assets marked for offline
    @Published var offlineAlbumIds: Set<String> = []  // Albums fully available offline

    private let fileManager = FileManager.default
    private let previewCacheDir: URL
    private let originalCacheDir: URL
    private let offlineDir: URL  // For "make available offline" assets

    private let offlineIdsKey = "offlineAssetIds"
    private let offlineAlbumIdsKey = "offlineAlbumIds"

    init() {
        let cacheBase = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("VimmichCache", isDirectory: true)

        previewCacheDir = cacheBase.appendingPathComponent("previews", isDirectory: true)
        originalCacheDir = cacheBase.appendingPathComponent("originals", isDirectory: true)
        offlineDir = cacheBase.appendingPathComponent("offline", isDirectory: true)

        // Create directories if needed
        try? fileManager.createDirectory(at: previewCacheDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: originalCacheDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: offlineDir, withIntermediateDirectories: true)

        // Load offline asset IDs
        if let data = UserDefaults.standard.data(forKey: offlineIdsKey),
           let ids = try? JSONDecoder().decode(Set<String>.self, from: data) {
            offlineAssetIds = ids
        }

        // Load offline album IDs
        if let data = UserDefaults.standard.data(forKey: offlineAlbumIdsKey),
           let ids = try? JSONDecoder().decode(Set<String>.self, from: data) {
            offlineAlbumIds = ids
        }

        // Calculate cache size in background
        Task {
            await calculateCacheSize()
        }
    }

    // MARK: - Preview Cache

    /// Get cached preview data for an asset
    func getPreview(assetId: String) -> Data? {
        let url = previewCacheDir.appendingPathComponent(assetId)
        return try? Data(contentsOf: url)
    }

    /// Save preview data to cache
    func savePreview(assetId: String, data: Data) {
        let url = previewCacheDir.appendingPathComponent(assetId)
        try? data.write(to: url)
        Task { await calculateCacheSize() }
    }

    /// Check if preview exists in cache
    func hasPreview(assetId: String) -> Bool {
        let url = previewCacheDir.appendingPathComponent(assetId)
        return fileManager.fileExists(atPath: url.path)
    }

    // MARK: - Original Cache (temporary, evicted more aggressively)

    /// Get cached original data for an asset
    func getOriginal(assetId: String) -> Data? {
        let url = originalCacheDir.appendingPathComponent(assetId)
        return try? Data(contentsOf: url)
    }

    /// Save original data to cache
    func saveOriginal(assetId: String, data: Data) {
        let url = originalCacheDir.appendingPathComponent(assetId)
        try? data.write(to: url)
        Task { await calculateCacheSize() }
    }

    /// Check if original exists in cache
    func hasOriginal(assetId: String) -> Bool {
        let url = originalCacheDir.appendingPathComponent(assetId)
        return fileManager.fileExists(atPath: url.path)
    }

    // MARK: - Offline Storage (persistent, user-controlled)

    /// Check if asset is available offline (verifies file exists and has content)
    func isAvailableOffline(assetId: String) -> Bool {
        guard offlineAssetIds.contains(assetId) else { return false }
        // Also verify the file actually exists and has content
        let url = offlineDir.appendingPathComponent(assetId)
        guard fileManager.fileExists(atPath: url.path) else {
            // File missing - remove from tracking
            offlineAssetIds.remove(assetId)
            saveOfflineIds()
            return false
        }
        // Check file size
        if let attrs = try? fileManager.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64,
           size > 0 {
            return true
        }
        // Empty file - remove from tracking
        offlineAssetIds.remove(assetId)
        saveOfflineIds()
        try? fileManager.removeItem(at: url)
        return false
    }

    /// Get offline data for an asset (returns nil if file is missing or empty)
    func getOffline(assetId: String) -> Data? {
        let url = offlineDir.appendingPathComponent(assetId)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return nil
        }
        return data
    }

    /// Save asset for offline access
    func saveOffline(assetId: String, data: Data) {
        let url = offlineDir.appendingPathComponent(assetId)
        do {
            try data.write(to: url)
            offlineAssetIds.insert(assetId)
            saveOfflineIds()
            Task { await calculateCacheSize() }
            print("💾 Saved offline: \(assetId.prefix(8))...")
        } catch {
            print("❌ Failed to save offline: \(error)")
        }
    }

    /// Remove asset from offline storage
    func removeOffline(assetId: String) {
        let url = offlineDir.appendingPathComponent(assetId)
        try? fileManager.removeItem(at: url)
        offlineAssetIds.remove(assetId)
        saveOfflineIds()
        Task { await calculateCacheSize() }
    }

    private func saveOfflineIds() {
        if let data = try? JSONEncoder().encode(offlineAssetIds) {
            UserDefaults.standard.set(data, forKey: offlineIdsKey)
        }
    }

    // MARK: - Offline Album Tracking

    /// Check if an album is fully available offline
    func isAlbumOffline(albumId: String) -> Bool {
        return offlineAlbumIds.contains(albumId)
    }

    /// Mark an album as fully available offline
    func markAlbumOffline(albumId: String) {
        offlineAlbumIds.insert(albumId)
        saveOfflineAlbumIds()
    }

    /// Remove an album's offline status
    func removeAlbumOffline(albumId: String) {
        offlineAlbumIds.remove(albumId)
        saveOfflineAlbumIds()
    }

    private func saveOfflineAlbumIds() {
        if let data = try? JSONEncoder().encode(offlineAlbumIds) {
            UserDefaults.standard.set(data, forKey: offlineAlbumIdsKey)
        }
    }

    // MARK: - Cache Management

    /// Calculate total cache size
    @MainActor
    func calculateCacheSize() async {
        let dirs = [previewCacheDir, originalCacheDir, offlineDir]
        let fm = fileManager

        let size = await Task.detached {
            var total: Int64 = 0

            for dir in dirs {
                if let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) {
                    while let fileURL = enumerator.nextObject() as? URL {
                        if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                            total += Int64(size)
                        }
                    }
                }
            }

            return total
        }.value

        self.cacheSize = size
    }

    /// Clear preview cache (keeps offline assets)
    func clearPreviewCache() {
        try? fileManager.removeItem(at: previewCacheDir)
        try? fileManager.createDirectory(at: previewCacheDir, withIntermediateDirectories: true)
        Task { await calculateCacheSize() }
        print("🗑️ Cleared preview cache")
    }

    /// Clear original cache (keeps offline assets)
    func clearOriginalCache() {
        try? fileManager.removeItem(at: originalCacheDir)
        try? fileManager.createDirectory(at: originalCacheDir, withIntermediateDirectories: true)
        Task { await calculateCacheSize() }
        print("🗑️ Cleared original cache")
    }

    /// Clear all offline assets
    func clearOfflineCache() {
        try? fileManager.removeItem(at: offlineDir)
        try? fileManager.createDirectory(at: offlineDir, withIntermediateDirectories: true)
        offlineAssetIds.removeAll()
        offlineAlbumIds.removeAll()
        saveOfflineIds()
        saveOfflineAlbumIds()
        Task { await calculateCacheSize() }
        print("🗑️ Cleared offline cache")
    }

    /// Clear all caches
    func clearAllCaches() {
        clearPreviewCache()
        clearOriginalCache()
        clearOfflineCache()
    }

    /// Format cache size for display
    var formattedCacheSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: cacheSize)
    }

    /// Count of offline assets
    var offlineCount: Int {
        offlineAssetIds.count
    }
}
