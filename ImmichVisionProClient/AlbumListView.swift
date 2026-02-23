//
//  AlbumListView.swift
//  ImmichVisionProClient
//
//  Created by Julian Gray on 1/12/26.
//

import SwiftUI

struct AlbumCard: View {
    let album: Album
    @EnvironmentObject var api: ImmichAPI

    @State private var showDeleteAlert = false
    @State private var showRenameAlert = false
    @State private var renameText = ""
    @State private var isDownloadingOffline = false

    private var isAlbumOffline: Bool {
        DiskCache.shared.isAlbumOffline(albumId: album.id)
    }

    var body: some View {
        NavigationLink(value: album) {
            ZStack(alignment: .bottom) {
                // Square thumbnail
                if let thumbnailId = album.albumThumbnailAssetId {
                    // Blurred version behind
                    AsyncThumbnailView(assetId: thumbnailId)
                        .aspectRatio(1, contentMode: .fill)
                        .clipped()
                        .blur(radius: 20)

                    // Sharp version on top, fading out at bottom
                    AsyncThumbnailView(assetId: thumbnailId)
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

                // Top trailing status indicator
                if isDownloadingOffline || isAlbumOffline {
                    VStack {
                        HStack {
                            Spacer()
                            if isDownloadingOffline {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(width: 14, height: 14)
                                    .tint(.white)
                                    .shadow(color: .black.opacity(0.5), radius: 2)
                                    .padding(8)
                            } else {
                                Image(systemName: "checkmark.icloud.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.white)
                                    .shadow(color: .black.opacity(0.5), radius: 2)
                                    .padding(8)
                            }
                        }
                        Spacer()
                    }
                }

                // Album details overlay at bottom
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.albumName)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.3), radius: 2)

                    Text("\(album.assetCount) items · \(album.owner.name)")
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
            .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 16))
            .hoverEffect(.highlight)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if isAlbumOffline {
                Button {
                    DiskCache.shared.removeAlbumOffline(albumId: album.id)
                } label: {
                    Label("Remove Offline", systemImage: "icloud.slash")
                }
            } else {
                Button {
                    Task { await makeAlbumAvailableOffline() }
                } label: {
                    Label("Make Available Offline", systemImage: "arrow.down.circle")
                }
                .disabled(isDownloadingOffline)
            }

            Button {
                renameText = album.albumName
                showRenameAlert = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            Divider()

            Button(role: .destructive) {
                showDeleteAlert = true
            } label: {
                Label("Delete Album", systemImage: "trash")
            }
        }
        .alert("Delete Album", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { await deleteAlbum() }
            }
        } message: {
            Text("Are you sure you want to delete \"\(album.albumName)\"? The photos inside will not be deleted.")
        }
        .alert("Rename Album", isPresented: $showRenameAlert) {
            TextField("Album name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                Task { await renameAlbum() }
            }
        } message: {}
    }

    private func makeAlbumAvailableOffline() async {
        isDownloadingOffline = true

        do {
            let details = try await api.fetchAlbumDetails(albumId: album.id)
            let assets = details.assets

            for asset in assets {
                guard !DiskCache.shared.isAvailableOffline(assetId: asset.id) else {
                    continue
                }

                guard let url = api.getOriginalImageURL(assetId: asset.id) else { continue }

                do {
                    let data = try await api.loadImageData(from: url)
                    DiskCache.shared.saveOffline(assetId: asset.id, data: data)
                } catch {
                    print("❌ Failed to download asset \(asset.id.prefix(8))... for offline: \(error)")
                }

            }

            DiskCache.shared.markAlbumOffline(albumId: album.id)
            print("✅ Album \"\(album.albumName)\" now available offline (\(assets.count) assets)")
        } catch {
            print("❌ Failed to make album available offline: \(error)")
        }

        isDownloadingOffline = false
    }

    private func renameAlbum() async {
        let newName = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != album.albumName else { return }
        do {
            try await api.renameAlbum(albumId: album.id, newName: newName)
            // Re-fetch to force UI update (Album Equatable only compares id)
            await api.fetchAlbums()
        } catch {
            print("❌ Failed to rename album: \(error)")
        }
    }

    private func deleteAlbum() async {
        do {
            try await api.deleteAlbum(albumId: album.id)
        } catch {
            print("❌ Failed to delete album: \(error)")
        }
    }
}
