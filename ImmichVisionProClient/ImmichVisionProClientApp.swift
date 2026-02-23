//
//  ImmichVisionProClientApp.swift
//  ImmichVisionProClient
//
//  Created by Julian Gray on 1/12/26.
//

import SwiftUI
import Combine
import UIKit

// Observable object to hold share data between views
class ShareManager: ObservableObject {
    @Published var fileURL: URL?
    @Published var fileName: String = ""
    @Published var showShareSheet: Bool = false
    @Published var thumbnailData: Data?
    @Published var isVideo: Bool = false
    @Published var imageForSharing: UIImage?
    @Published var fileURLs: [URL] = []
    @Published var fileNames: [String] = []
    @Published var fileIsVideo: [Bool] = []
    @Published var isSelectionModeActive: Bool = false

    func clear() {
        if let url = fileURL {
            try? FileManager.default.removeItem(at: url)
        }
        // Remove batch share temp directory (files are in a UUID-named subdirectory)
        if let firstURL = fileURLs.first {
            let parentDir = firstURL.deletingLastPathComponent()
            try? FileManager.default.removeItem(at: parentDir)
        }
        fileURL = nil
        fileName = ""
        showShareSheet = false
        thumbnailData = nil
        isVideo = false
        imageForSharing = nil
        fileURLs = []
        fileNames = []
        fileIsVideo = []
    }
}

@main
struct ImmichVisionProClientApp: App {
    @StateObject private var spatialPhotoManager = SpatialPhotoManager()
    @StateObject private var spatialCache = SpatialAssetCache()
    @StateObject private var shareManager = ShareManager()

    var body: some Scene {
        // Main window for album browsing
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(spatialPhotoManager)
                .environmentObject(spatialCache)
                .environmentObject(shareManager)
                .opacity(spatialPhotoManager.isDisplaying || spatialPhotoManager.isRestoringScrollPosition ? 0 : 1)
                .animation(.easeInOut(duration: 0.05), value: spatialPhotoManager.isDisplaying)
                .animation(.easeInOut(duration: 0.05), value: spatialPhotoManager.isRestoringScrollPosition)
                .allowsHitTesting(!spatialPhotoManager.isDisplaying)
                .persistentSystemOverlays(spatialPhotoManager.isDisplaying ? .hidden : .automatic)
        }
        .windowStyle(.plain)

        // Immersive space for spatial photo viewing (borderless, no environments)
        ImmersiveSpace(id: "SpatialPhotoViewer") {
            SpatialPhotoImmersiveView()
                .environmentObject(spatialPhotoManager)
                .environmentObject(spatialCache)
                .environmentObject(shareManager)
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}
