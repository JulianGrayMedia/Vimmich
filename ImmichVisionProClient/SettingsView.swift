//
//  SettingsView.swift
//  ImmichVisionProClient
//
//  Created by Julian Gray on 1/20/26.
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var api: ImmichAPI
    @EnvironmentObject var spatialCache: SpatialAssetCache
    @EnvironmentObject var spatialPhotoManager: SpatialPhotoManager
    @StateObject private var diskCache = DiskCache.shared

    @State private var isClearing = false
    @State private var isRescanning = false
    @State private var allAssets: [Asset] = []
    @State private var showClearConfirmation = false
    @State private var showClearCacheConfirmation = false
    @State private var showRemoveConfirmation = false
    @State private var assetToRemove: String?
    @State private var showLogoutConfirmation = false

    var body: some View {
        ScrollView {
            VStack(spacing: 48) {
                // Account Section (at top)
                VStack(spacing: 16) {
                    Image("AppLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 72, height: 72)
                        .opacity(0.6)
                        .padding(.bottom, 8)

                    Text("Account")
                        .font(.title2)
                        .fontWeight(.semibold)

                    VStack(spacing: 6) {
                        if let email = api.currentUserEmail {
                            Text(email)
                                .foregroundStyle(.secondary)
                        }

                        if let name = api.currentUserName {
                            Text(name)
                                .foregroundStyle(.tertiary)
                                .font(.caption)
                        }
                    }

                    Button(action: {
                        showLogoutConfirmation = true
                    }) {
                        HStack {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                            Text("Sign Out")
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .alert("Sign Out?", isPresented: $showLogoutConfirmation) {
                    Button("Cancel", role: .cancel) { }
                    Button("Sign Out", role: .destructive) {
                        spatialCache.clearCache()
                        api.logout()
                    }
                } message: {
                    Text("You will need to sign in again to access your photos.")
                }

                Divider()

                // Spatial Photos Indexing Section
                VStack(spacing: 16) {
                    Text("Spatial Photos Indexing")
                        .font(.title2)
                        .fontWeight(.semibold)

                    VStack(spacing: 6) {
                        Text("Spatial photos found: \(spatialCache.spatialAssetIds.count)")
                            .foregroundStyle(.secondary)

                        Text("Total assets scanned: \(spatialCache.overallScannedCount)")
                            .foregroundStyle(.secondary)

                        if let lastScan = spatialCache.lastScanDate {
                            Text("Last scan: \(lastScan.formatted(date: .abbreviated, time: .shortened))")
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(spacing: 12) {
                        Button(action: {
                            Task {
                                await scanLibrary()
                            }
                        }) {
                            HStack {
                                if isRescanning {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                } else {
                                    Image(systemName: "cube.transparent")
                                }
                                Text("Scan Library")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isRescanning || spatialCache.isScanning)

                        Button(action: {
                            showClearConfirmation = true
                        }) {
                            HStack {
                                Image(systemName: "trash")
                                Text("Clear Spatial Index")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(spatialCache.isScanning)
                    }
                    .alert("Clear Spatial Index?", isPresented: $showClearConfirmation) {
                        Button("Cancel", role: .cancel) { }
                        Button("Clear", role: .destructive) {
                            spatialCache.clearCache()
                        }
                    } message: {
                        Text("This will erase all previous spatial indexing. You will have to rescan your entire library to find spatial photos and videos again.")
                    }

                    if spatialCache.isScanning {
                        VStack(spacing: 8) {
                            ProgressView(value: spatialCache.overallProgress)
                                .progressViewStyle(.linear)
                                .tint(.white)
                                .frame(maxWidth: 260)

                            Text("Scanning \(spatialCache.overallScannedCount.formatted()) of \(spatialCache.totalLibrarySize.formatted())")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Button("Cancel Scan") {
                                spatialCache.cancelScan()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                Divider()

                // Media Available Offline Section
                VStack(spacing: 16) {
                    Text("Media Available Offline")
                        .font(.title2)
                        .fontWeight(.semibold)

                    VStack(spacing: 6) {
                        Text("Storage used: \(diskCache.formattedCacheSize)")
                            .foregroundStyle(.secondary)

                        Text("Saved media: \(diskCache.offlineCount)")
                            .foregroundStyle(.secondary)

                        // Active downloads list
                        if !spatialPhotoManager.activeDownloads.isEmpty {
                            VStack(spacing: 8) {
                                Text("Active Downloads")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.secondary)

                                ForEach(Array(spatialPhotoManager.activeDownloads.values)) { download in
                                    VStack(spacing: 8) {
                                        // Thumbnail centered
                                        DownloadThumbnailView(assetId: download.id)
                                            .frame(width: 60, height: 60)
                                            .cornerRadius(8)

                                        // Progress bar centered
                                        ProgressView(value: download.progress)
                                            .progressViewStyle(.linear)
                                            .tint(.blue)
                                            .frame(width: 220)

                                        // Bytes and percentage centered
                                        if download.totalBytes > 0 {
                                            Text("\(Int(download.progress * 100))%  ·  \(formatBytes(download.downloadedBytes)) / \(formatBytes(download.totalBytes))")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        } else {
                                            Text("Starting...")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    Button(action: {
                        showClearCacheConfirmation = true
                    }) {
                        HStack {
                            Image(systemName: "trash")
                            Text("Clear Cache")
                        }
                    }
                    .buttonStyle(.bordered)
                    .alert("Clear Cache?", isPresented: $showClearCacheConfirmation) {
                        Button("Cancel", role: .cancel) { }
                        Button("Clear", role: .destructive) {
                            diskCache.clearPreviewCache()
                            diskCache.clearOriginalCache()
                            diskCache.clearOfflineCache()
                        }
                    } message: {
                        Text("This will clear all cached data and remove all \(diskCache.offlineCount) items saved for offline viewing.")
                    }

                }

                // Offline assets grid
                if !diskCache.offlineAssetIds.isEmpty {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 5), spacing: 0) {
                        ForEach(Array(diskCache.offlineAssetIds).sorted(), id: \.self) { assetId in
                            OfflineThumbnailView(assetId: assetId)
                                .aspectRatio(1, contentMode: .fill)
                                .clipped()
                                .overlay(alignment: .topTrailing) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.white)
                                        .shadow(radius: 2)
                                        .padding(6)
                                }
                                .overlay(alignment: .bottomLeading) {
                                    if spatialCache.isSpatial(assetId) {
                                        Text("3D")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 2)
                                            .background(Color.black.opacity(0.5))
                                            .cornerRadius(4)
                                            .shadow(radius: 2)
                                            .padding(6)
                                    }
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
                    }
                    .padding(.horizontal, -24)
                }

                Spacer()
                    .frame(height: 60)

                // Legal
                VStack(spacing: 8) {
                    Link("Privacy Policy", destination: URL(string: "https://juliangray.space/Vimmich/PrivacyPolicy")!)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    // Signature
                    Text("Designed by Julian Gray")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
                .padding(.bottom, 20)
            }
            .padding(.horizontal, 24)
            .padding(.top, 32)
            .padding(.bottom, 24)
        }
        .navigationTitle("Settings")
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

    private func loadAllAssets() async {
        guard allAssets.isEmpty else { return }

        // Load assets from all time buckets
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

        allAssets = assets
    }

    private func scanLibrary() async {
        isRescanning = true

        await loadAllAssets()
        spatialCache.scanLibrary(api: api, assets: allAssets)

        isRescanning = false
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

/// Small thumbnail view for downloads - loads from API
struct DownloadThumbnailView: View {
    let assetId: String
    @EnvironmentObject var api: ImmichAPI
    @State private var image: UIImage?
    @State private var isLoading = true

    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if isLoading {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .overlay {
                        ProgressView()
                            .scaleEffect(0.6)
                    }
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .overlay {
                        Image(systemName: "photo")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .clipped()
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
