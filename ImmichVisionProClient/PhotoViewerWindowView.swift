//
//  PhotoViewerWindowView.swift
//  ImmichVisionProClient
//
//  Created by Julian Gray on 5/24/26.
//

import SwiftUI
import UIKit
import AVKit
import AVFoundation

struct PhotoViewerWindowView: View {
    @EnvironmentObject var spatialPhotoManager: SpatialPhotoManager
    @EnvironmentObject var spatialCache: SpatialAssetCache
    @EnvironmentObject var shareManager: ShareManager
    @EnvironmentObject var api: ImmichAPI

    @Environment(\.dismiss) var dismiss
    @Environment(\.openImmersiveSpace) var openImmersiveSpace

    @State private var videoPlayer: AVPlayer? = nil
    @State private var videoStreamingLoader: VideoStreamingLoader? = nil

    private var currentAssetId: String? {
        spatialPhotoManager.currentAsset?.assetId
    }

    var body: some View {
        ZStack {
            Color.black
            photoContent
            navigationOverlay
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    teardownVideoPlayer()
                    spatialPhotoManager.clear()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
            }
            ToolbarItem(placement: .principal) {
                if spatialPhotoManager.totalAssets > 1 {
                    Text("\(spatialPhotoManager.currentIndex + 1) of \(spatialPhotoManager.totalAssets)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    videoPlayer?.pause()
                    Task { await openImmersiveSpace(id: "SpatialPhotoViewer") }
                } label: {
                    Label(
                        spatialPhotoManager.currentAsset?.isSpatial == true ? "View Spatially" : "View in Space",
                        systemImage: spatialPhotoManager.currentAsset?.isSpatial == true ? "view.3d" : "arrow.up.left.and.arrow.down.right"
                    )
                }
            }
        }
        .onChange(of: currentAssetId) { _, newId in
            guard let newId else { teardownVideoPlayer(); return }
            if spatialPhotoManager.currentAsset?.isVideo == true {
                Task { await setupVideoPlayer(assetId: newId) }
            } else {
                teardownVideoPlayer()
            }
        }
        .onDisappear {
            teardownVideoPlayer()
            if spatialPhotoManager.isDisplaying {
                spatialPhotoManager.clear()
            }
        }
    }

    // MARK: - Photo/Video Content

    @ViewBuilder
    private var photoContent: some View {
        if spatialPhotoManager.isLoadingCurrentAsset {
            loadingView
        } else if let asset = spatialPhotoManager.currentAsset {
            if asset.isVideo {
                videoContentView
            } else if let image = asset.leftImage {
                Image(uiImage: UIImage(cgImage: image))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView()
            }
        } else {
            ProgressView()
        }
    }

    private var loadingView: some View {
        ZStack {
            if let thumbnail = spatialPhotoManager.currentThumbnail {
                Image(uiImage: UIImage(cgImage: thumbnail))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .blur(radius: 8)
                    .opacity(0.6)
            }
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.5)
                if spatialPhotoManager.downloadProgress > 0 && spatialPhotoManager.downloadProgress < 1 {
                    ProgressView(value: spatialPhotoManager.downloadProgress)
                        .frame(width: 200)
                }
            }
        }
    }

    @ViewBuilder
    private var videoContentView: some View {
        if let player = videoPlayer {
            VideoPlayer(player: player)
        } else {
            ZStack {
                if let thumbnail = spatialPhotoManager.currentThumbnail {
                    Image(uiImage: UIImage(cgImage: thumbnail))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Color.black
                }
                ProgressView()
                    .scaleEffect(1.5)
            }
        }
    }

    // MARK: - Navigation Overlay

    private var navigationOverlay: some View {
        HStack(spacing: 0) {
            Button {
                teardownVideoPlayer()
                spatialPhotoManager.previousAsset()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 28, weight: .medium))
                    .padding(20)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .opacity(spatialPhotoManager.currentIndex > 0 ? 1 : 0)
            .allowsHitTesting(spatialPhotoManager.currentIndex > 0)

            Spacer()

            Button {
                teardownVideoPlayer()
                spatialPhotoManager.nextAsset()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 28, weight: .medium))
                    .padding(20)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .opacity(spatialPhotoManager.currentIndex < spatialPhotoManager.totalAssets - 1 ? 1 : 0)
            .allowsHitTesting(spatialPhotoManager.currentIndex < spatialPhotoManager.totalAssets - 1)
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Video Player Setup

    private func setupVideoPlayer(assetId: String) async {
        teardownVideoPlayer()

        guard let streamingInfo = spatialPhotoManager.getVideoStreamingInfo(assetId: assetId) else {
            print("⚠️ PhotoViewerWindow: no streaming info for \(assetId.prefix(8))")
            return
        }

        guard spatialPhotoManager.currentAsset?.assetId == assetId else { return }

        let preBufferInfo = spatialPhotoManager.getPreBufferedVideoInfo(assetId: assetId)

        let loader = VideoStreamingLoader(
            accessToken: streamingInfo.accessToken,
            originalURL: streamingInfo.url,
            preBufferedData: preBufferInfo?.data,
            preBufferedContentLength: preBufferInfo?.contentLength,
            preBufferedContentType: preBufferInfo?.contentType
        )

        guard let customURL = VideoStreamingLoader.customURL(from: streamingInfo.url) else {
            print("⚠️ PhotoViewerWindow: failed to create custom URL")
            return
        }

        let avAsset = AVURLAsset(url: customURL)
        let loaderQueue = DispatchQueue(label: "com.vimmich.windowVideoLoader", qos: .userInitiated)
        avAsset.resourceLoader.setDelegate(loader, queue: loaderQueue)

        let playerItem = AVPlayerItem(asset: avAsset)
        let player = AVPlayer(playerItem: playerItem)

        guard spatialPhotoManager.currentAsset?.assetId == assetId else { return }

        videoStreamingLoader = loader
        videoPlayer = player

        print("▶️ PhotoViewerWindow: video player ready for \(assetId.prefix(8))")
    }

    private func teardownVideoPlayer() {
        videoPlayer?.pause()
        videoPlayer = nil
        videoStreamingLoader = nil
    }
}
