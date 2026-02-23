//
//  SpatialPhotoImmersiveView.swift
//  ImmichVisionProClient
//
//  Created by Julian Gray on 1/12/26.
//

import SwiftUI
import RealityKit
import AVFoundation
import Combine
import UIKit
import ARKit

struct SpatialPhotoImmersiveView: View {
    @EnvironmentObject var spatialPhotoManager: SpatialPhotoManager
    @EnvironmentObject var shareManager: ShareManager
    @Environment(\.dismissWindow) var dismissWindow
    @Environment(\.dismissImmersiveSpace) var dismissImmersiveSpace
    @Environment(\.openWindow) var openWindow

    // Wrapper entity for movement (has collision for gesture)
    @State private var wrapperEntity: Entity = Entity()

    // Content entity that holds the displayed asset (child of wrapper)
    @State private var contentEntity: Entity = Entity()

    // Incoming content entity for carousel transitions (child of wrapper)
    @State private var incomingContentEntity: Entity = Entity()

    // Loading attachment entity (added to content root, position synced with wrapper)
    @State private var loadingEntity: Entity? = nil

    // Drag tracking
    @State private var dragOffset: Float = 0
    @State private var isDragging: Bool = false
    @State private var dragDirection: Int = 0  // -1 = left (next), +1 = right (previous), 0 = undetermined
    @State private var incomingPrepared: Bool = false

    // Loading state - starts false, enabled after wrapper is positioned
    @State private var showLoading: Bool = false

    // Animation state
    @State private var isAnimating: Bool = false

    // Prevents concurrent displayCurrentAsset calls (fixes flicker on initial load)
    @State private var isDisplayingAsset: Bool = false

    // Share state
    @State private var isPreparingShare: Bool = false

    // Controls visibility
    @State private var showControls: Bool = false
    @State private var hideControlsTask: Task<Void, Never>? = nil
    @State private var showInfoPanel: Bool = false

    // Video playback state
    @State private var videoPlayer: AVPlayer? = nil
    @State private var isVideoPlaying: Bool = false
    @State private var videoDuration: Double = 0
    @State private var videoCurrentTime: Double = 0
    @State private var timeObserver: Any? = nil
    @State private var isSeeking: Bool = false
    @State private var videoStreamingLoader: VideoStreamingLoader? = nil
    @State private var sceneVideoEntity: Entity? = nil  // Track video entity added to scene root

    // Incoming video for carousel transitions
    @State private var incomingVideoPlayer: AVPlayer? = nil
    @State private var incomingVideoEntity: Entity? = nil
    @State private var incomingVideoStreamingLoader: VideoStreamingLoader? = nil

    // Pre-created video entities cache (keyed by asset ID)
    // These are created ahead of time so they're ready instantly when swiping
    @State private var preCreatedVideoEntities: [String: (player: AVPlayer, entity: Entity, loader: VideoStreamingLoader)] = [:]
    @State private var preCreateVideoTask: Task<Void, Never>? = nil

    // ARKit for head tracking
    private let arkitSession = ARKitSession()
    private let worldTracking = WorldTrackingProvider()

    // Dynamic base position - centered in volumetric window
    @State private var dynamicBasePosition: SIMD3<Float> = [0, 0, 0]

    // For volumetric window, content is at center
    private let contentDistance: Float = 0

    // How far to slide before triggering navigation (in meters)
    private let swipeThreshold: Float = 0.1

    // Check if the current asset is being saved offline
    private var isCurrentAssetBeingSaved: Bool {
        guard let currentId = spatialPhotoManager.currentAssetMetadata?.id else {
            return false
        }
        return spatialPhotoManager.savingOfflineAssetIds.contains(currentId)
    }

    var body: some View {
        RealityView { content, attachments in
            print("🎬 Immersive space loaded")

            // Get initial position from head tracking
            let initialPosition = await getHeadBasedPosition()

            // Setup wrapper entity (this is what we move and what has collision)
            wrapperEntity.name = "wrapperEntity"
            wrapperEntity.position = initialPosition

            // Add collision to wrapper for gesture detection
            let shape = ShapeResource.generateBox(width: 2.0, height: 1.5, depth: 0.1)
            wrapperEntity.components.set(CollisionComponent(shapes: [shape]))
            wrapperEntity.components.set(InputTargetComponent(allowedInputTypes: .indirect))

            // Content entity is a child of wrapper (position relative to wrapper = origin)
            contentEntity.name = "contentEntity"
            contentEntity.position = .zero  // Centered within wrapper
            wrapperEntity.addChild(contentEntity)

            // Incoming content entity for carousel transitions
            incomingContentEntity.name = "incomingContentEntity"
            incomingContentEntity.position = .zero
            wrapperEntity.addChild(incomingContentEntity)

            content.add(wrapperEntity)

            // Add controls - position below content and slightly in front
            if let controlsAttachment = attachments.entity(for: "controls") {
                // Controls at about 0.45m below content, 0.15m in front (keeping within volume bounds)
                controlsAttachment.position = [0, initialPosition.y - 0.45, initialPosition.z + 0.15]
                content.add(controlsAttachment)
            }

            // Add video timeline - position just above the controls
            if let timelineAttachment = attachments.entity(for: "videoTimeline") {
                // Timeline right above controls, pushed back slightly for depth
                timelineAttachment.position = [0, initialPosition.y - 0.38, initialPosition.z + 0.10]
                content.add(timelineAttachment)
            }

            // Add loading placeholder - wrap in parent entity for reliable positioning
            if let loadingAttachment = attachments.entity(for: "loading") {
                let loadingParent = Entity()
                loadingParent.name = "loadingParent"
                loadingParent.position = initialPosition
                loadingAttachment.position = .zero  // Attachment at parent's origin
                loadingParent.addChild(loadingAttachment)
                loadingEntity = loadingParent
                content.add(loadingParent)
            }

            // Store the position for later use
            await MainActor.run {
                dynamicBasePosition = initialPosition
            }

            // Always show loading initially - it will be hidden after photo renders
            showLoading = true

            // Start loading content in background (non-blocking so view appears instantly)
            Task {
                await displayCurrentAsset()
            }

            // Pre-buffer nearby videos immediately so they're ready when user swipes
            spatialPhotoManager.preBufferAdjacentVideos()

            // Pre-create video entities for adjacent videos (runs after pre-buffering has time to complete)
            preCreateAdjacentVideoEntities()

        } update: { content, attachments in
            // Update loading visibility and sync position with wrapper
            // loadingEntity is the parent entity that holds the attachment
            if let loadingParent = loadingEntity {
                loadingParent.isEnabled = showLoading
                // Keep loading indicator at same position as wrapper (follows during drag)
                loadingParent.position = wrapperEntity.position
            }

        } attachments: {
            // Controls
            Attachment(id: "controls") {
                ControlsContentView(
                    spatialPhotoManager: spatialPhotoManager,
                    showInfoPanel: $showInfoPanel,
                    isPreparingShare: isPreparingShare,
                    isCurrentAssetBeingSaved: isCurrentAssetBeingSaved,
                    showControls: showControls,
                    onNavigatePrevious: { navigatePrevious() },
                    onNavigateNext: { navigateNext() },
                    onShowControlsTemporarily: { showControlsTemporarily() },
                    onPrepareAndShare: { Task { await prepareAndShare() } },
                    onHideAsset: { Task { await hideCurrentAsset() } },
                    onSaveOffline: { Task { let _ = await spatialPhotoManager.saveCurrentAssetOffline() } },
                    onDismiss: { Task { await dismissImmersiveSpace(); spatialPhotoManager.clear() } },
                    formatBytes: formatBytes
                )
            }

            // Video timeline (separate from main controls)
            Attachment(id: "videoTimeline") {
                if spatialPhotoManager.currentAsset?.isVideo == true && videoDuration > 0 {
                    VideoTimelineView(
                        currentTime: $videoCurrentTime,
                        duration: videoDuration,
                        isPlaying: isVideoPlaying,
                        isSeeking: $isSeeking,
                        onSeek: { seekVideo(to: $0) },
                        onPlayPause: { toggleVideoPlayback() },
                        onInteraction: { showControlsTemporarily() }
                    )
                    .opacity(showControls ? 1 : 0)
                    .animation(.easeInOut(duration: 0.25), value: showControls)
                    .allowsHitTesting(showControls)
                }
            }

            // Loading placeholder - adapts to asset type
            Attachment(id: "loading") {
                LoadingPlaceholderView(
                    spatialPhotoManager: spatialPhotoManager,
                    isVisible: showLoading
                )
            }

        }
        .gesture(
            DragGesture(minimumDistance: 5)
                .targetedToAnyEntity()
                .onChanged { value in
                    guard !isAnimating else { return }

                    // Track horizontal drag - translation3D is in points, convert to meters
                    let translationPoints = Float(value.gestureValue.translation3D.x)
                    dragOffset = translationPoints * 0.001

                    if !isDragging {
                        isDragging = true
                        dragDirection = 0
                        incomingPrepared = false
                        print("🖐️ Drag started on entity: \(value.entity.name)")
                    }

                    // Detect direction once drag exceeds small threshold
                    let slideDistance: Float = 0.8
                    if dragDirection == 0 && abs(dragOffset) > 0.02 {
                        dragDirection = dragOffset < 0 ? -1 : 1

                        // Prepare incoming content based on direction
                        let canGoNext = spatialPhotoManager.currentIndex < spatialPhotoManager.totalAssets - 1
                        let canGoPrev = spatialPhotoManager.currentIndex > 0

                        if (dragDirection == -1 && canGoNext) || (dragDirection == 1 && canGoPrev) {
                            // Position incoming content off-screen on opposite side
                            let incomingStartX = Float(-dragDirection) * slideDistance
                            incomingContentEntity.position.x = incomingStartX
                            incomingContentEntity.position.z = 0

                            // Peek at next/previous asset and prepare it
                            Task {
                                await prepareIncomingContent(direction: dragDirection)
                            }
                            incomingPrepared = true
                        }
                    }

                    // Move the wrapper entity (which contains the content as a child)
                    let newX = dynamicBasePosition.x + dragOffset
                    wrapperEntity.position.x = newX

                    // Calculate Z offset - push OLD content back as it moves away
                    // Apply to content children directly (not wrapper) so incoming stays at base Z
                    let dragDistance = abs(dragOffset)
                    let zOffset = min(dragDistance / slideDistance, 1.0) * -0.4
                    for child in contentEntity.children {
                        child.position.z = zOffset
                    }

                    // Fade out old content (videos are now in contentEntity, so setContentOpacity handles both)
                    // Opacity goes from 1.0 to 0.0 with exponential curve (fades faster, reaches 0 sooner)
                    let dragProgress = min(1.0, dragDistance / slideDistance)
                    let oldOpacity = max(0.0, pow(1.0 - dragProgress, 2.0))  // Quadratic ease-out
                    setContentOpacity(oldOpacity)

                    // Update incoming content opacity and Z position (videos are now in incomingContentEntity, so this handles both)
                    if incomingPrepared && dragDirection != 0 {
                        let incomingProgress = min(1.0, dragDistance / slideDistance)
                        let incomingOpacity = incomingProgress  // 0.0 to 1.0 as drag progresses
                        setIncomingContentOpacity(incomingOpacity)

                        // Incoming content starts pushed back and comes forward as it slides in
                        let incomingZOffset = (1.0 - incomingProgress) * -0.4
                        for child in incomingContentEntity.children {
                            child.position.z = incomingZOffset
                        }

                        // Position loading indicator with incoming content
                        let incomingWorldX = dynamicBasePosition.x + Float(-dragDirection) * slideDistance * (1 - incomingProgress)
                        loadingEntity?.position.x = incomingWorldX
                        loadingEntity?.position.z = dynamicBasePosition.z
                    } else {
                        // No incoming, loading follows old content
                        loadingEntity?.position.x = newX
                    }
                }
                .onEnded { value in
                    guard !isAnimating else { return }

                    let translationMeters = Float(value.gestureValue.translation3D.x) * 0.001
                    print("🖐️ Drag ended, offset=\(translationMeters)m, direction=\(dragDirection)")

                    let canGoNext = spatialPhotoManager.currentIndex < spatialPhotoManager.totalAssets - 1
                    let canGoPrev = spatialPhotoManager.currentIndex > 0

                    // Determine if we should complete the transition
                    if translationMeters < -swipeThreshold && canGoNext && dragDirection == -1 {
                        // Complete transition to next
                        completeDragTransition(direction: -1)
                    } else if translationMeters > swipeThreshold && canGoPrev && dragDirection == 1 {
                        // Complete transition to previous
                        completeDragTransition(direction: 1)
                    } else {
                        // Snap back to center
                        snapBackFromDrag()
                    }

                    isDragging = false
                    dragDirection = 0
                    incomingPrepared = false
                }
        )
        .gesture(
            TapGesture()
                .targetedToEntity(wrapperEntity)
                .onEnded { _ in
                    toggleControls()
                }
        )
        .onChange(of: spatialPhotoManager.currentIndex) { oldValue, newValue in
            // Handle external navigation (from buttons)
            // Skip if already displaying to avoid race condition with initial load
            if !isDragging && !isAnimating && !isDisplayingAsset {
                Task {
                    await displayCurrentAsset()
                }
            }
        }
        .onChange(of: spatialPhotoManager.assetQualityDidUpgrade) { _, _ in
            // Reload current asset when quality is upgraded (preview -> full resolution)
            guard !isDragging && !isAnimating else { return }
            guard let asset = spatialPhotoManager.currentAsset, !asset.isVideo else { return }

            print("🔄 Quality upgraded, reloading photo...")
            Task {
                // Load new high-quality photo first, then remove old one to avoid flash
                let oldChildren = contentEntity.children.map { $0 }
                await loadAsset(asset, initialOpacity: 1.0, targetPosition: dynamicBasePosition)
                // Remove old content after new is loaded
                for child in oldChildren {
                    child.removeFromParent()
                }
            }
        }
        .onDisappear {
            spatialPhotoManager.isDisplaying = false
            spatialPhotoManager.clear()
            hideControlsTask?.cancel()
            cleanupVideoObserver()
        }
    }

    // MARK: - Navigation

    private func navigateNext() {
        guard !isAnimating else { return }
        guard spatialPhotoManager.currentIndex < spatialPhotoManager.totalAssets - 1 else { return }
        transitionToNext()
    }

    private func navigatePrevious() {
        guard !isAnimating else { return }
        guard spatialPhotoManager.currentIndex > 0 else { return }
        transitionToPrevious()
    }

    private func transitionToNext() {
        isAnimating = true
        showInfoPanel = false  // Close info panel when navigating
        Task {
            await carouselTransition(direction: -1, navigateForward: true)
            isAnimating = false
        }
    }

    private func transitionToPrevious() {
        isAnimating = true
        showInfoPanel = false  // Close info panel when navigating
        Task {
            await carouselTransition(direction: 1, navigateForward: false)
            isAnimating = false
        }
    }

    /// Carousel transition: old content slides out while new content slides in simultaneously
    /// - Parameters:
    ///   - direction: -1 for left (next), +1 for right (previous)
    ///   - navigateForward: true for next, false for previous
    private func carouselTransition(direction: Float, navigateForward: Bool) async {
        let slideDistance: Float = 0.8

        // Step 1: Position incoming content off-screen (opposite side from slide direction)
        // If sliding left (direction=-1), new content starts on the right (+slideDistance)
        // If sliding right (direction=+1), new content starts on the left (-slideDistance)
        let incomingStartX = -direction * slideDistance
        incomingContentEntity.position.x = incomingStartX
        incomingContentEntity.position.z = 0

        // Step 2: Navigate to new asset (starts loading in background)
        if navigateForward {
            spatialPhotoManager.nextAsset()
        } else {
            spatialPhotoManager.previousAsset()
        }

        // Step 3: Check if new asset is already cached and load it into incoming entity
        var loadedIntoIncoming = false
        if let asset = spatialPhotoManager.currentAsset, !asset.isVideo {
            // Load photo into incoming entity for carousel effect
            await loadPhotoIntoEntity(asset, entity: incomingContentEntity, initialOpacity: 0.0)
            loadedIntoIncoming = true
            showLoading = false
        } else {
            // Show loading indicator sliding in
            showLoading = true
        }

        // Step 4: Animate carousel - wrapper moves so old slides out and new slides in
        // Wrapper X moves by slideDistance, Z stays at base (no forward pull to avoid size pop)
        // Videos are children of contentEntity so they move with the wrapper automatically
        let wrapperTargetX = dynamicBasePosition.x + (direction * slideDistance)

        await animateCarousel(
            wrapperToX: wrapperTargetX,
            wrapperToZ: dynamicBasePosition.z,  // Keep Z constant - no forward pull
            incomingHasContent: loadedIntoIncoming,
            duration: 0.48
        )

        // Step 5: Clean up after animation - do this atomically to avoid visual glitches
        // The incoming content is now at world position (0, y, z) which is correct
        // We need to transfer it to contentEntity without visual change

        // First, calculate where incoming content currently is in world space
        // wrapper is at (baseX + direction*slide, y, baseZ)
        // incoming is at wrapper-relative (incomingStartX, 0, 0) = (-direction*slide, 0, 0)
        // So incoming world X = baseX + direction*slide + (-direction*slide) = baseX = 0 ✓

        // Remove old content (both photos and videos are children of contentEntity)
        contentEntity.children.removeAll()
        cleanupVideoObserver()

        // Move children from incoming to content, adjusting positions to maintain world position
        // After we reset wrapper to base, content at (0,0,0) relative will be at world (baseX, y, baseZ)
        // Currently incoming content is at world (baseX, y, baseZ) - exactly where we want it!
        // So we can just move children to contentEntity at relative (0,0,0)
        let incomingChildren = incomingContentEntity.children.map { $0 }
        for child in incomingChildren {
            child.removeFromParent()
            child.position = .zero
            contentEntity.addChild(child)
        }

        // Now reset wrapper and incoming positions
        wrapperEntity.position = dynamicBasePosition
        incomingContentEntity.position = .zero
        loadingEntity?.position = dynamicBasePosition

        // Step 6: Handle post-transition
        if loadedIntoIncoming {
            // Content is already visible at correct opacity from carousel animation
            // No need to fade - just ensure full opacity
            setContentOpacity(1.0)
            showLoading = false
        } else {
            // Wait for asset to load and display it with fade-in
            await waitAndDisplayAsset()
        }
    }

    /// Load a photo into a specific entity (for carousel transitions)
    private func loadPhotoIntoEntity(_ asset: SpatialPhotoManager.SpatialAssetData, entity: Entity, initialOpacity: Float) async {
        do {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("heic")

            try asset.originalData.write(to: tempURL)

            var component = try await ImagePresentationComponent(contentsOf: tempURL)

            // Debug: Log available viewing modes
            print("🖼️ Available viewing modes: \(component.availableViewingModes)")

            // Use spatialStereoImmersive for blurry edge effect (requires ImmersiveSpace)
            if component.availableViewingModes.contains(.spatialStereoImmersive) {
                component.desiredViewingMode = .spatialStereoImmersive
                print("🖼️ Using spatialStereoImmersive viewing mode (blurry edges)")
            } else if component.availableViewingModes.contains(.spatialStereo) {
                component.desiredViewingMode = .spatialStereo
                print("🖼️ Using spatialStereo viewing mode (fallback)")
            }

            let photoEntity = Entity()

            // Set opacity and add to scene BEFORE setting image component
            photoEntity.components.set(OpacityComponent(opacity: initialOpacity))
            photoEntity.components.set(HoverEffectComponent())
            entity.addChild(photoEntity)

            // Now set the image component
            photoEntity.components.set(component)

            // Cleanup temp file
            Task {
                try? await Task.sleep(for: .seconds(3))
                try? FileManager.default.removeItem(at: tempURL)
            }
        } catch {
            print("❌ Photo load error (carousel): \(error)")
        }
    }

    /// Animate carousel movement - wrapper and old video move together
    /// Loading indicator slides in with the incoming content position
    private func animateCarousel(
        wrapperToX: Float,
        wrapperToZ: Float,
        incomingHasContent: Bool,
        duration: Double
    ) async {
        let steps = 30  // More steps for smoother animation
        let startX = wrapperEntity.position.x
        let startZ = wrapperEntity.position.z
        let deltaX = wrapperToX - startX
        let deltaZ = wrapperToZ - startZ
        let stepDuration = duration / Double(steps)

        // Get starting opacities
        let oldStartOpacity = getCurrentContentOpacity()

        // Calculate incoming content's world position (starts off-screen, ends at center)
        let incomingRelativeX = incomingContentEntity.position.x
        let incomingStartWorldX = startX + incomingRelativeX
        let incomingEndWorldX = dynamicBasePosition.x  // Ends at center

        for i in 1...steps {
            let progress = Float(i) / Float(steps)
            // Smooth ease-out curve for fluid deceleration
            // Using cubic ease-out: starts faster, gently slows to a stop
            let eased = 1 - pow(1 - progress, 2.5)

            // Update wrapper position (moves old content - both photos and videos)
            let newX = startX + deltaX * eased
            let newZ = startZ + deltaZ * eased
            wrapperEntity.position.x = newX
            wrapperEntity.position.z = newZ

            // Calculate incoming content's current world position
            let incomingCurrentWorldX = incomingStartWorldX + (incomingEndWorldX - incomingStartWorldX) * eased

            // Sync loading indicator with incoming content (slides in from off-screen)
            loadingEntity?.position.x = incomingCurrentWorldX
            loadingEntity?.position.z = dynamicBasePosition.z

            // Fade out old content smoothly (applies to both photos and videos)
            setContentOpacity(oldStartOpacity * (1 - eased))

            // Fade in incoming content and animate Z position (starts pushed back, comes forward)
            if incomingHasContent {
                let incomingOpacity: Float = eased  // 0.0 to 1.0
                setIncomingContentOpacity(incomingOpacity)

                // Incoming Z: starts at -0.4, animates to 0
                let incomingZ = (1.0 - eased) * -0.4
                for child in incomingContentEntity.children {
                    child.position.z = incomingZ
                }
            }

            try? await Task.sleep(for: .milliseconds(Int(stepDuration * 1000)))
        }

        // Ensure final positions and opacities
        wrapperEntity.position.x = wrapperToX
        wrapperEntity.position.z = wrapperToZ
        loadingEntity?.position.x = dynamicBasePosition.x
        loadingEntity?.position.z = dynamicBasePosition.z
        setContentOpacity(0)
        if incomingHasContent {
            setIncomingContentOpacity(1.0)
            // Ensure incoming Z is at 0
            for child in incomingContentEntity.children {
                child.position.z = 0
            }
        }
    }

    /// Set opacity on incoming content entity children
    private func setIncomingContentOpacity(_ opacity: Float) {
        for child in incomingContentEntity.children {
            var opacityComponent = child.components[OpacityComponent.self] ?? OpacityComponent(opacity: 1.0)
            opacityComponent.opacity = opacity
            child.components.set(opacityComponent)
        }
    }

    private func snapToCenter() {
        Task {
            // Animate back to center while restoring opacity and Z position
            await animateSlide(toX: dynamicBasePosition.x, toZ: dynamicBasePosition.z, fromOpacity: nil, toOpacity: 1.0, duration: 0.05)
            dragOffset = 0
        }
    }

    /// Prepare incoming content during drag by peeking at next/previous asset
    private func prepareIncomingContent(direction: Int) async {
        // Peek at the next/previous asset without changing current index
        let targetIndex = direction == -1
            ? spatialPhotoManager.currentIndex + 1
            : spatialPhotoManager.currentIndex - 1

        guard targetIndex >= 0 && targetIndex < spatialPhotoManager.totalAssets else { return }

        // Try to get cached asset data for the target index
        if let asset = spatialPhotoManager.peekAsset(at: targetIndex) {
            if !asset.isVideo {
                // Load photo into incoming entity
                await loadPhotoIntoEntity(asset, entity: incomingContentEntity, initialOpacity: 0.0)
                showLoading = false
            } else {
                // Video - check for pre-created entity first (instant!)
                if let preCreated = preCreatedVideoEntities[asset.assetId] {
                    // Add to incomingContentEntity (same as photos, so it inherits all animations)
                    preCreated.entity.position = .zero
                    // Set initial opacity to 0 to prevent pop-in
                    preCreated.entity.components.set(OpacityComponent(opacity: 0.0))
                    if preCreated.entity.parent == nil {
                        incomingContentEntity.addChild(preCreated.entity)
                    }

                    // Start playback immediately
                    preCreated.player.play()

                    // Store references for cleanup
                    incomingVideoPlayer = preCreated.player
                    incomingVideoEntity = preCreated.entity
                    incomingVideoStreamingLoader = preCreated.loader

                    print("📼 Using pre-created video entity for \(asset.assetId.prefix(8))...")
                    showLoading = false
                } else {
                    // Fallback: try to create on demand with pre-buffer
                    let hasPreBuffer = spatialPhotoManager.getPreBufferedVideoInfo(assetId: asset.assetId) != nil
                    if hasPreBuffer {
                        await prepareIncomingVideo(assetId: asset.assetId, direction: direction)
                        showLoading = false
                    } else {
                        showLoading = true
                    }
                }
            }
        } else {
            // Asset not cached yet
            showLoading = true
        }
    }

    /// Prepare an incoming video for carousel transition using pre-buffered data
    private func prepareIncomingVideo(assetId: String, direction: Int) async {
        guard let streamingInfo = spatialPhotoManager.getVideoStreamingInfo(assetId: assetId),
              let preBufferInfo = spatialPhotoManager.getPreBufferedVideoInfo(assetId: assetId) else {
            print("❌ Cannot prepare incoming video - missing data")
            return
        }

        let originalURL = streamingInfo.url
        let accessToken = streamingInfo.accessToken

        print("📼 Preparing incoming video with pre-buffer (\(preBufferInfo.data.count / 1024)KB)...")

        // Create streaming loader with pre-buffered data
        let loader = VideoStreamingLoader(
            accessToken: accessToken,
            originalURL: originalURL,
            preBufferedData: preBufferInfo.data,
            preBufferedContentLength: preBufferInfo.contentLength,
            preBufferedContentType: preBufferInfo.contentType
        )
        incomingVideoStreamingLoader = loader

        // Create custom URL for interception
        guard let customURL = VideoStreamingLoader.customURL(from: originalURL) else {
            print("❌ Failed to create custom streaming URL for incoming video")
            return
        }

        // Create AVURLAsset with the custom URL scheme
        let asset = AVURLAsset(url: customURL)
        let loaderQueue = DispatchQueue(label: "com.immich.incomingVideoStreaming", qos: .userInitiated)
        asset.resourceLoader.setDelegate(loader, queue: loaderQueue)

        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = 2.0
        let player = AVPlayer(playerItem: playerItem)
        player.automaticallyWaitsToMinimizeStalling = false  // Don't wait, start immediately

        // Always request .spatial mode — RealityKit ignores it for non-spatial content.
        // Ensures spatial videos in the carousel display correctly without detection delay.
        print("📼 Incoming video (spatial cache: \(spatialPhotoManager.isAssetKnownSpatial(assetId))) for \(assetId.prefix(8))")

        // Create video entity (add to incomingContentEntity like photos, so it inherits all animations)
        var videoComponent = VideoPlayerComponent(avPlayer: player)
        videoComponent.desiredSpatialVideoMode = .spatial  // Always: RealityKit renders mono for non-spatial
        videoComponent.isPassthroughTintingEnabled = false
        let videoEntity = Entity()
        videoEntity.name = "incomingVideoEntity"
        videoEntity.components.set(videoComponent)
        videoEntity.components.set(OpacityComponent(opacity: 0.0))  // Start at 0, will fade in during drag
        videoEntity.components.set(HoverEffectComponent())
        videoEntity.position = .zero  // Relative to incomingContentEntity

        // Add to incomingContentEntity (same as photos)
        incomingContentEntity.addChild(videoEntity)

        // Store references for cleanup
        incomingVideoPlayer = player
        incomingVideoEntity = videoEntity

        // Start playback immediately - video will render first frame when ready
        player.play()

        print("📼 Incoming video entity added to incomingContentEntity")
    }

    /// Wait for incoming video player to be ready (short timeout for carousel)
    private func waitForIncomingPlayerReady(player: AVPlayer) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            var hasResumed = false
            var statusObserver: NSKeyValueObservation?

            statusObserver = player.currentItem?.observe(\.status, options: [.new, .initial]) { item, _ in
                guard !hasResumed else { return }

                switch item.status {
                case .readyToPlay:
                    hasResumed = true
                    statusObserver?.invalidate()
                    continuation.resume(returning: true)
                case .failed:
                    hasResumed = true
                    statusObserver?.invalidate()
                    continuation.resume(returning: false)
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }

            // Short timeout for carousel (1 second)
            Task {
                try? await Task.sleep(for: .seconds(1))
                if !hasResumed {
                    hasResumed = true
                    statusObserver?.invalidate()
                    continuation.resume(returning: false)
                }
            }
        }
    }

    /// Pre-create video entities for adjacent videos so they're ready instantly when swiping
    private func preCreateAdjacentVideoEntities() {
        // Cancel any previous pre-creation task
        preCreateVideoTask?.cancel()

        preCreateVideoTask = Task {
            guard !Task.isCancelled else { return }

            let currentIndex = spatialPhotoManager.currentIndex
            let totalAssets = spatialPhotoManager.totalAssets

            // Pre-create for previous and next videos (just 1 in each direction for now)
            let indicesToCheck = [currentIndex - 1, currentIndex + 1].filter { $0 >= 0 && $0 < totalAssets }

            for index in indicesToCheck {
                guard !Task.isCancelled else { return }

                guard let asset = spatialPhotoManager.assetMetadata(at: index),
                      asset.type == .VIDEO else { continue }

                // Skip if already pre-created
                if preCreatedVideoEntities[asset.id] != nil { continue }

                // Wait for pre-buffer data to be available (check more frequently)
                var attempts = 0
                while spatialPhotoManager.getPreBufferedVideoInfo(assetId: asset.id) == nil && attempts < 30 {
                    try? await Task.sleep(for: .milliseconds(100))
                    attempts += 1
                    if Task.isCancelled { return }
                }

                guard let preBufferInfo = spatialPhotoManager.getPreBufferedVideoInfo(assetId: asset.id),
                      let streamingInfo = spatialPhotoManager.getVideoStreamingInfo(assetId: asset.id) else {
                    continue
                }

                // Create AVPlayer and entity
                let loader = VideoStreamingLoader(
                    accessToken: streamingInfo.accessToken,
                    originalURL: streamingInfo.url,
                    preBufferedData: preBufferInfo.data,
                    preBufferedContentLength: preBufferInfo.contentLength,
                    preBufferedContentType: preBufferInfo.contentType
                )

                guard let customURL = VideoStreamingLoader.customURL(from: streamingInfo.url) else { continue }

                let avAsset = AVURLAsset(url: customURL)
                let loaderQueue = DispatchQueue(label: "com.immich.preCreateVideo.\(asset.id.prefix(8))", qos: .userInitiated)
                avAsset.resourceLoader.setDelegate(loader, queue: loaderQueue)

                let playerItem = AVPlayerItem(asset: avAsset)
                playerItem.preferredForwardBufferDuration = 2.0
                let player = AVPlayer(playerItem: playerItem)
                player.automaticallyWaitsToMinimizeStalling = false

                // Check spatial cache. For uncached assets, always request .spatial mode —
                // RealityKit ignores it for non-spatial content, so it's safe to always set.
                // The entity is not in the scene yet so availableViewingModes can't be polled;
                // when this entity becomes current via waitForPlayerAndPlay, detection runs there.
                let isSpatialVideo = spatialPhotoManager.isAssetKnownSpatial(asset.id)
                print("📼 Pre-create: spatial=\(isSpatialVideo) for \(asset.id.prefix(8))")

                // Create video entity (but don't add to scene yet)
                // Use opacity 0.2 from the start to avoid flicker when enabling
                var videoComponent = VideoPlayerComponent(avPlayer: player)
                // Always request spatial mode: RealityKit applies it only when content supports it.
                // This ensures spatial assets render correctly even when not yet in the cache.
                videoComponent.desiredSpatialVideoMode = .spatial
                videoComponent.isPassthroughTintingEnabled = false
                let videoEntity = Entity()
                videoEntity.name = "preCreatedVideoEntity_\(asset.id.prefix(8))"
                videoEntity.components.set(videoComponent)
                videoEntity.components.set(OpacityComponent(opacity: 0.2))
                videoEntity.components.set(HoverEffectComponent())
                // Don't disable - just keep it out of scene until needed

                // Store in cache
                await MainActor.run {
                    preCreatedVideoEntities[asset.id] = (player: player, entity: videoEntity, loader: loader)
                }

                print("📼 Pre-created video entity for \(asset.id.prefix(8))...")
            }

            // Clean up old cached entities that are no longer adjacent
            await MainActor.run {
                let adjacentIds = Set(indicesToCheck.compactMap { spatialPhotoManager.assetMetadata(at: $0)?.id })
                let currentAssetId = spatialPhotoManager.currentAssetMetadata?.id

                for (assetId, cached) in preCreatedVideoEntities {
                    // Keep current asset's entity and adjacent ones
                    if assetId != currentAssetId && !adjacentIds.contains(assetId) {
                        cached.player.pause()
                        cached.entity.removeFromParent()
                        preCreatedVideoEntities.removeValue(forKey: assetId)
                        print("🗑️ Cleaned up pre-created video entity for \(assetId.prefix(8))...")
                    }
                }
            }
        }
    }

    /// Complete the drag transition after user releases past threshold
    private func completeDragTransition(direction: Int) {
        isAnimating = true
        showInfoPanel = false

        // Capture current wrapper position before any async operations
        let capturedWrapperX = wrapperEntity.position.x

        Task {
            let slideDistance: Float = 0.8

            // Navigate to the new asset
            if direction == -1 {
                spatialPhotoManager.nextAsset()
            } else {
                spatialPhotoManager.previousAsset()
            }

            // Calculate remaining distance to animate using captured position
            let targetWrapperX = dynamicBasePosition.x + (Float(direction) * slideDistance)

            // Animate the rest of the slide
            let remainingProgress = abs(capturedWrapperX - dynamicBasePosition.x) / slideDistance
            let remainingDuration = 0.35 * Double(1.0 - remainingProgress)  // Proportional duration

            if remainingDuration > 0.02 {
                await animateCarouselCompletion(
                    wrapperFromX: capturedWrapperX,
                    wrapperToX: targetWrapperX,
                    duration: max(0.1, remainingDuration)
                )
            }

            // Clean up old content (both photos and videos are children of contentEntity)
            contentEntity.children.removeAll()
            cleanupVideoObserver()

            // Transfer incoming content to contentEntity (works for both photos and videos)
            let incomingChildren = incomingContentEntity.children.map { $0 }
            for child in incomingChildren {
                child.removeFromParent()
                child.position = .zero
                contentEntity.addChild(child)
            }

            // If incoming was a video, update the video player references
            if let incomingPlayer = incomingVideoPlayer {
                sceneVideoEntity = incomingVideoEntity
                videoPlayer = incomingPlayer
                videoStreamingLoader = incomingVideoStreamingLoader

                // Setup time observer for the new video
                setupVideoTimeObserver(for: incomingPlayer)

                // Clear incoming references
                incomingVideoEntity = nil
                incomingVideoPlayer = nil
                incomingVideoStreamingLoader = nil

                showLoading = false
            }

            wrapperEntity.position = dynamicBasePosition
            incomingContentEntity.position = .zero
            loadingEntity?.position = dynamicBasePosition

            // If content was loaded (photo or video), ensure full opacity; otherwise wait for load
            if !contentEntity.children.isEmpty || sceneVideoEntity != nil {
                setContentOpacity(1.0)
                showLoading = false
            } else {
                await waitAndDisplayAsset()
            }

            isAnimating = false
            dragOffset = 0
        }
    }

    /// Animate the completion of a drag-initiated carousel
    private func animateCarouselCompletion(
        wrapperFromX: Float,
        wrapperToX: Float,
        duration: Double
    ) async {
        let steps = 15
        let deltaX = wrapperToX - wrapperFromX
        let stepDuration = duration / Double(steps)

        let oldStartOpacity = getCurrentContentOpacity()
        let incomingStartOpacity = getIncomingContentOpacity()

        // Get current Z offset of old content
        let oldContentStartZ = contentEntity.children.first?.position.z ?? 0
        let oldContentTargetZ: Float = -0.4  // Full push back position

        // Get current Z offset of incoming content
        let incomingContentStartZ = incomingContentEntity.children.first?.position.z ?? -0.4

        for i in 1...steps {
            let progress = Float(i) / Float(steps)
            let eased = progress * progress * (3 - 2 * progress)

            wrapperEntity.position.x = wrapperFromX + deltaX * eased

            // Continue Z animation on old content (pushes back as it slides out)
            // Videos are now in contentEntity, so this handles both photos and videos
            let currentZ = oldContentStartZ + (oldContentTargetZ - oldContentStartZ) * eased
            for child in contentEntity.children {
                child.position.z = currentZ
            }

            // Animate incoming Z (comes forward from pushed back to 0)
            let incomingZ = incomingContentStartZ * (1 - eased)
            for child in incomingContentEntity.children {
                child.position.z = incomingZ
            }

            // Fade out old, fade in new (setContentOpacity handles both photos and videos now)
            setContentOpacity(oldStartOpacity * (1 - eased))
            setIncomingContentOpacity(min(1.0, incomingStartOpacity + (1.0 - incomingStartOpacity) * eased))

            // Update loading position toward center
            let incomingWorldX = dynamicBasePosition.x + incomingContentEntity.position.x + (wrapperFromX - dynamicBasePosition.x + deltaX * eased)
            loadingEntity?.position.x = dynamicBasePosition.x * eased + incomingWorldX * (1 - eased)

            try? await Task.sleep(for: .milliseconds(Int(stepDuration * 1000)))
        }

        wrapperEntity.position.x = wrapperToX
        setContentOpacity(0)
        setIncomingContentOpacity(1.0)
        // Ensure incoming Z is at 0
        for child in incomingContentEntity.children {
            child.position.z = 0
        }
    }

    /// Get current opacity of incoming content
    private func getIncomingContentOpacity() -> Float {
        guard let firstChild = incomingContentEntity.children.first,
              let opacityComponent = firstChild.components[OpacityComponent.self] else {
            return 0.2
        }
        return opacityComponent.opacity
    }

    /// Snap back from drag, clearing incoming content
    private func snapBackFromDrag() {
        Task {
            // Clear incoming content (both photos and videos are in incomingContentEntity)
            incomingContentEntity.children.removeAll()
            incomingContentEntity.position = .zero

            // Clean up incoming video player if any
            incomingVideoPlayer?.pause()
            incomingVideoPlayer = nil
            incomingVideoEntity = nil
            incomingVideoStreamingLoader = nil

            showLoading = false

            // Animate back to center with easing
            await animateSnapBack(duration: 0.35)
            dragOffset = 0
        }
    }

    /// Animate snap back to center with ease-out curve
    private func animateSnapBack(duration: Double) async {
        let steps = 20
        let startX = wrapperEntity.position.x
        let targetX = dynamicBasePosition.x
        let deltaX = targetX - startX
        let stepDuration = duration / Double(steps)

        let startOpacity = getCurrentContentOpacity()
        let deltaOpacity = 1.0 - startOpacity

        // Get current Z offset of content (to animate back to 0)
        let contentStartZ = contentEntity.children.first?.position.z ?? 0

        for i in 1...steps {
            let progress = Float(i) / Float(steps)
            // Ease-out curve - starts fast, slows at end
            let eased = 1 - pow(1 - progress, 3)

            let newX = startX + deltaX * eased
            wrapperEntity.position.x = newX

            // Animate content Z back to 0 (applies to both photos and videos)
            let contentZ = contentStartZ * (1 - eased)
            for child in contentEntity.children {
                child.position.z = contentZ
            }

            // Sync loading entity
            loadingEntity?.position.x = newX

            // Restore opacity (applies to both photos and videos via setContentOpacity)
            let newOpacity = startOpacity + deltaOpacity * eased
            setContentOpacity(newOpacity)

            try? await Task.sleep(for: .milliseconds(Int(stepDuration * 1000)))
        }

        // Ensure final positions and opacities
        wrapperEntity.position.x = targetX
        for child in contentEntity.children {
            child.position.z = 0
        }
        loadingEntity?.position.x = targetX
        setContentOpacity(1.0)
    }

    // MARK: - Animations

    /// Wait for current asset to load and display it - can be interrupted by navigation
    private func waitAndDisplayAsset() async {
        let targetIndex = spatialPhotoManager.currentIndex
        print("🔄 waitAndDisplayAsset started for index \(targetIndex)")

        // Check if non-video content is already displayed
        // Videos always need to go through loadAsset even if marker exists
        let hasPhotoContent = !contentEntity.children.isEmpty
        let currentAsset = spatialPhotoManager.currentAsset
        let isVideo = currentAsset?.isVideo ?? false

        // Skip only for photos that are already displayed (not videos)
        if hasPhotoContent && !isVideo && !showLoading {
            print("✅ Photo already displayed, skipping waitAndDisplayAsset")
            return
        }

        print("🔄 Waiting for asset to load...")
        print("🔄 currentAsset is \(spatialPhotoManager.currentAsset != nil ? "available" : "nil"), isLoadingCurrentAsset: \(spatialPhotoManager.isLoadingCurrentAsset)")

        // Wait for asset to be ready (with periodic checks for index change)
        var waitTime: Double = 0
        while spatialPhotoManager.currentAsset == nil && waitTime < 60 {
            // Check if user navigated away - if so, stop waiting
            if spatialPhotoManager.currentIndex != targetIndex {
                print("📍 Index changed during wait (\(targetIndex) -> \(spatialPhotoManager.currentIndex)), stopping")
                return
            }

            if spatialPhotoManager.isLoadingCurrentAsset || waitTime < 5 {
                try? await Task.sleep(for: .milliseconds(100))
                waitTime += 0.1
            } else {
                print("⚠️ Asset not loading and wait time exceeded, breaking wait loop")
                break
            }
        }

        // Check again if index changed
        if spatialPhotoManager.currentIndex != targetIndex {
            print("📍 Index changed after wait, not displaying asset")
            return
        }

        // Load and display the asset
        if let asset = spatialPhotoManager.currentAsset {
            print("✅ Asset ready, displaying for index \(targetIndex)")

            if asset.isVideo {
                // Videos: load at full opacity immediately (loading indicator handles the wait)
                await loadAsset(asset, initialOpacity: 1.0, targetPosition: dynamicBasePosition)
                // showLoading is handled inside waitForPlayerAndPlay
            } else {
                // Photos: load at full opacity immediately (no fade)
                await loadAsset(asset, initialOpacity: 1.0, targetPosition: dynamicBasePosition)
                showLoading = false
            }
        } else {
            print("⚠️ Asset still nil after waiting for index \(targetIndex), keeping placeholder")
        }
    }

    /// Set content opacity to 1.0 (instant)
    private func fadeInContent() async {
        setContentOpacity(1.0)
    }

    /// Animate position (X and Z) and opacity together
    /// - Parameters:
    ///   - toX: Target X position
    ///   - toZ: Target Z position
    ///   - fromOpacity: Starting opacity (nil = use current opacity from content)
    ///   - toOpacity: Target opacity
    ///   - duration: Animation duration in seconds
    private func animateSlide(toX: Float, toZ: Float, fromOpacity: Float?, toOpacity: Float, duration: Double) async {
        let steps = 20
        let startX = wrapperEntity.position.x
        let startZ = wrapperEntity.position.z
        let deltaX = toX - startX
        let deltaZ = toZ - startZ
        let stepDuration = duration / Double(steps)

        // If fromOpacity is nil, estimate from current drag offset
        let startOpacity = fromOpacity ?? getCurrentContentOpacity()
        let deltaOpacity = toOpacity - startOpacity

        for i in 1...steps {
            let progress = Float(i) / Float(steps)
            // Ease out curve
            let eased = 1 - pow(1 - progress, 3)

            // Update X position (video inherits from contentEntity which is child of wrapper)
            let newX = startX + deltaX * eased
            wrapperEntity.position.x = newX
            loadingEntity?.position.x = newX

            // Update Z position
            let newZ = startZ + deltaZ * eased
            wrapperEntity.position.z = newZ
            loadingEntity?.position.z = newZ

            // Update opacity on content children (includes both photos and videos)
            let currentOpacity = startOpacity + deltaOpacity * eased
            setContentOpacity(currentOpacity)

            try? await Task.sleep(for: .milliseconds(Int(stepDuration * 1000)))
        }

        wrapperEntity.position.x = toX
        wrapperEntity.position.z = toZ
        loadingEntity?.position.x = toX
        loadingEntity?.position.z = toZ
        setContentOpacity(toOpacity)
    }

    /// Get current opacity from content (estimates based on first child)
    private func getCurrentContentOpacity() -> Float {
        guard let firstChild = contentEntity.children.first,
              let opacityComponent = firstChild.components[OpacityComponent.self] else {
            return 1.0
        }
        return opacityComponent.opacity
    }

    /// Set opacity on all content children, video entity, and loading indicator
    private func setContentOpacity(_ opacity: Float) {
        // Apply opacity to all children of contentEntity (photos)
        for child in contentEntity.children {
            // Use OpacityComponent for fade effect
            var opacityComponent = child.components[OpacityComponent.self] ?? OpacityComponent(opacity: 1.0)
            opacityComponent.opacity = opacity
            child.components.set(opacityComponent)
        }

        // Apply opacity to scene-level video entity (videos are added to scene root)
        if let videoEntity = sceneVideoEntity {
            var opacityComponent = videoEntity.components[OpacityComponent.self] ?? OpacityComponent(opacity: 1.0)
            opacityComponent.opacity = opacity
            videoEntity.components.set(opacityComponent)
        }

        // Also apply opacity to the loading attachment so it fades during swipes
        if let loading = loadingEntity {
            var opacityComponent = loading.components[OpacityComponent.self] ?? OpacityComponent(opacity: 1.0)
            opacityComponent.opacity = opacity
            loading.components.set(opacityComponent)
        }
    }

    // MARK: - Asset Display

    private func displayCurrentAsset() async {
        // Prevent concurrent calls which can cause flicker
        guard !isDisplayingAsset else {
            print("⚠️ displayCurrentAsset already in progress, skipping")
            return
        }
        isDisplayingAsset = true
        defer { isDisplayingAsset = false }

        guard spatialPhotoManager.totalAssets > 0 else {
            print("⚠️ No assets to display")
            showLoading = false
            return
        }

        contentEntity.children.removeAll()
        wrapperEntity.position = dynamicBasePosition  // Reset wrapper position
        loadingEntity?.position = dynamicBasePosition  // Sync loading with wrapper
        dragOffset = 0

        // Only show loading if asset isn't already cached
        let assetReady = spatialPhotoManager.currentAsset != nil
        showLoading = !assetReady

        // Wait briefly for asset if not ready (cached assets load quickly)
        if !assetReady {
            print("⏳ Asset not ready, waiting for initial load... isLoading=\(spatialPhotoManager.isLoadingCurrentAsset)")
            for i in 0..<30 {  // Wait up to 1.5 seconds
                try? await Task.sleep(for: .milliseconds(50))
                if spatialPhotoManager.currentAsset != nil {
                    print("✅ Asset loaded after \(i * 50)ms")
                    break
                }
                if i == 29 {
                    print("⚠️ Timeout waiting for asset, isLoading=\(spatialPhotoManager.isLoadingCurrentAsset)")
                }
            }
        }

        // Check if asset is ready
        if let asset = spatialPhotoManager.currentAsset {
            print("✅ Asset ready, displaying (isVideo: \(asset.isVideo))")

            if asset.isVideo {
                // Videos: load at full opacity immediately (loading indicator handles the wait)
                await loadAsset(asset, initialOpacity: 1.0, targetPosition: dynamicBasePosition)
                // showLoading is handled inside waitForPlayerAndPlay
            } else {
                // Photos: load at full opacity immediately (no fade)
                await loadAsset(asset, initialOpacity: 1.0, targetPosition: dynamicBasePosition)
                showLoading = false
            }
            return
        }

        // Asset not ready, wait for it
        await waitAndDisplayAsset()
    }

    /// Load and display an asset
    /// - Parameters:
    ///   - asset: The asset data to display
    ///   - initialOpacity: Starting opacity for the entity
    ///   - targetPosition: Position for videos (videos use absolute positioning). If nil, uses wrapperEntity.position.
    private func loadAsset(_ asset: SpatialPhotoManager.SpatialAssetData, initialOpacity: Float = 1.0, targetPosition: SIMD3<Float>? = nil) async {
        print("🎬 loadAsset called - isVideo: \(asset.isVideo), dataSize: \(asset.originalData.count), fileName: \(asset.fileName)")

        // Capture the position to use for videos - use provided position or current wrapper position
        let videoPosition = targetPosition ?? wrapperEntity.position
        print("🎬 Video target position: \(videoPosition)")

        // Clean up previous video observer when switching assets
        cleanupVideoObserver()

        if asset.isVideo {
            print("🎬 Calling loadVideo...")
            await loadVideo(asset, initialOpacity: initialOpacity, targetPosition: videoPosition)
            print("🎬 loadVideo completed")
        } else {
            print("🎬 Calling loadPhoto...")
            await loadPhoto(asset, initialOpacity: initialOpacity)
            print("🎬 loadPhoto completed")
        }

        print("🎬 loadAsset completed, contentEntity children count: \(contentEntity.children.count)")

        // Pre-buffer adjacent videos for faster playback
        spatialPhotoManager.preBufferAdjacentVideos()

        // Pre-create video entities for adjacent videos
        preCreateAdjacentVideoEntities()
    }

    private func loadPhoto(_ asset: SpatialPhotoManager.SpatialAssetData, initialOpacity: Float = 1.0) async {
        do {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("heic")

            try asset.originalData.write(to: tempURL)

            var component = try await ImagePresentationComponent(contentsOf: tempURL)

            // Debug: Log available viewing modes
            print("🖼️ Available viewing modes: \(component.availableViewingModes)")

            // Use spatialStereoImmersive for blurry edge effect (requires ImmersiveSpace)
            if component.availableViewingModes.contains(.spatialStereoImmersive) {
                component.desiredViewingMode = .spatialStereoImmersive
                print("🖼️ Using spatialStereoImmersive viewing mode (blurry edges)")
            } else if component.availableViewingModes.contains(.spatialStereo) {
                component.desiredViewingMode = .spatialStereo
                print("🖼️ Using spatialStereo viewing mode (fallback)")
            }

            let photoEntity = Entity()

            // Set opacity BEFORE adding the ImagePresentationComponent
            // to ensure the entity is at full opacity when the image renders
            photoEntity.components.set(OpacityComponent(opacity: initialOpacity))

            // Add visionOS-style hover highlight effect (rim lighting)
            photoEntity.components.set(HoverEffectComponent())

            // Add to scene BEFORE setting the image component
            // This ensures the entity is ready when the image starts rendering
            contentEntity.addChild(photoEntity)

            // Now set the image component - it should render at the entity's current opacity
            photoEntity.components.set(component)

            // Cleanup temp file
            Task {
                try? await Task.sleep(for: .seconds(3))
                try? FileManager.default.removeItem(at: tempURL)
            }
        } catch {
            print("❌ Photo load error: \(error)")
        }
    }

    private func loadVideo(_ asset: SpatialPhotoManager.SpatialAssetData, initialOpacity: Float = 1.0, targetPosition: SIMD3<Float>) async {
        print("📼 loadVideo called - dataSize: \(asset.originalData.count), isSpatial: \(asset.isSpatial), targetPosition: \(targetPosition)")

        // Check if we have cached data or need to stream
        if asset.originalData.isEmpty {
            // Stream the video with buffering
            print("📼 No cached data, streaming video...")
            await streamVideo(isSpatialVideo: asset.isSpatial, initialOpacity: initialOpacity, targetPosition: targetPosition)
        } else {
            // Use cached data
            await loadVideoFromData(asset, initialOpacity: initialOpacity, targetPosition: targetPosition)
        }
    }

    /// Stream video - shows loading indicator until video is ready
    private func streamVideo(isSpatialVideo: Bool, initialOpacity: Float = 1.0, targetPosition: SIMD3<Float>) async {
        // Always use /original for videos to preserve MV-HEVC format
        // We'll detect spatial capability from the actual video tracks
        guard let originalURL = spatialPhotoManager.getVideoOriginalURL(),
              let accessToken = spatialPhotoManager.accessTokenForStreaming else {
            print("❌ Cannot get video URL or access token")
            return
        }

        let assetId = spatialPhotoManager.currentAssetMetadata?.id
        print("📼 streamVideo — assetId: \(assetId?.prefix(8) ?? "nil"), url: \(originalURL)")

        // Show loading indicator until video is ready to play
        showLoading = true

        // Check for pre-buffered data
        let preBufferInfo = assetId.flatMap { spatialPhotoManager.getPreBufferedVideoInfo(assetId: $0) }
        if let info = preBufferInfo {
            print("📦 Pre-buffer found: \(info.data.count / 1024)KB, contentLength: \(info.contentLength), type: \(info.contentType ?? "nil")")
        } else {
            print("⚠️ No pre-buffer — readyToPlay will depend entirely on network speed")
        }
        let streamStartTime = Date()

        // Create the streaming loader for authenticated access (with pre-buffered data if available)
        let loader = VideoStreamingLoader(
            accessToken: accessToken,
            originalURL: originalURL,
            preBufferedData: preBufferInfo?.data,
            preBufferedContentLength: preBufferInfo?.contentLength,
            preBufferedContentType: preBufferInfo?.contentType
        )
        videoStreamingLoader = loader  // Retain the loader

        // Clear pre-buffered data now that we're using it
        if let id = assetId {
            spatialPhotoManager.clearPreBufferedVideoInfo(assetId: id)
        }

        // Create custom URL for interception
        guard let customURL = VideoStreamingLoader.customURL(from: originalURL) else {
            print("❌ Failed to create custom streaming URL")
            return
        }

        print("📼 Custom streaming URL: \(customURL)")

        // Create AVURLAsset with the custom URL scheme
        let asset = AVURLAsset(url: customURL)

        // Set up the resource loader delegate on a dedicated queue
        let loaderQueue = DispatchQueue(label: "com.immich.videoStreaming", qos: .userInitiated)
        asset.resourceLoader.setDelegate(loader, queue: loaderQueue)

        // Create player item and player
        let playerItem = AVPlayerItem(asset: asset)

        // Set minimum forward buffer - 2 seconds for smoother playback
        playerItem.preferredForwardBufferDuration = 2.0

        let player = AVPlayer(playerItem: playerItem)

        // Let AVPlayer handle buffering automatically - it will pause when buffer runs out
        // and automatically resume when enough data is available
        player.automaticallyWaitsToMinimizeStalling = true

        print("📼 AVPlayer created with resource loader delegate")

        // Store player reference
        videoPlayer = player

        // Wait for player to be ready to play
        await waitForPlayerAndPlay(player: player, asset: asset,
                                   originalURL: originalURL, accessToken: accessToken,
                                   startTime: streamStartTime,
                                   initialOpacity: initialOpacity, targetPosition: targetPosition)
    }

    /// Detect if video asset contains spatial video (MV-HEVC) tracks
    private func detectSpatialVideo(asset: AVAsset) async -> Bool {
        do {
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            for track in videoTracks {
                // Check for MV-HEVC format descriptions
                let formatDescriptions = try await track.load(.formatDescriptions)
                for formatDesc in formatDescriptions {
                    let mediaSubType = CMFormatDescriptionGetMediaSubType(formatDesc)
                    let fourCC = String(format: "%c%c%c%c",
                                       (mediaSubType >> 24) & 0xFF,
                                       (mediaSubType >> 16) & 0xFF,
                                       (mediaSubType >> 8) & 0xFF,
                                       mediaSubType & 0xFF)
                    print("📼 Video track format: \(fourCC) (\(mediaSubType))")

                    // Check for HEVC with stereo/MV extensions
                    // hvc1, hev1 are HEVC; check for extensions
                    if let extensions = CMFormatDescriptionGetExtensions(formatDesc) as? [String: Any] {
                        // Check for stereo view configuration
                        if extensions["StereoMVHEVC"] != nil ||
                           extensions["HasLeftStereoEyeView"] != nil ||
                           extensions["HasRightStereoEyeView"] != nil {
                            print("✅ Detected MV-HEVC spatial video via format extensions")
                            return true
                        }
                    }
                }

                // Also check track's media characteristics for spatial
                let characteristics = try await track.load(.mediaCharacteristics)
                if characteristics.contains(.containsStereoMultiviewVideo) {
                    print("✅ Detected spatial video via track characteristics")
                    return true
                }
            }
        } catch {
            print("⚠️ Error detecting spatial video: \(error.localizedDescription)")
        }
        return false
    }

    /// Wait for player to be ready, then show video.
    /// - Parameters:
    ///   - originalURL: The original HTTPS URL (not the custom scheme URL). Used for background
    ///     spatial detection on uncached assets. Nil for offline/cached videos.
    ///   - accessToken: Bearer token for background detection request. Nil for offline videos.
    ///   - startTime: Optional timestamp from before AVPlayer creation, for elapsed-time logging.
    private func waitForPlayerAndPlay(player: AVPlayer, asset: AVAsset,
                                      originalURL: URL? = nil, accessToken: String? = nil,
                                      startTime: Date? = nil,
                                      initialOpacity: Float, targetPosition: SIMD3<Float>) async {
        // Observe player status
        var statusObserver: NSKeyValueObservation?

        let isReady = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            var hasResumed = false

            statusObserver = player.currentItem?.observe(\.status, options: [.new, .initial]) { item, _ in
                guard !hasResumed else { return }

                switch item.status {
                case .readyToPlay:
                    let elapsed = startTime.map { String(format: "%.2f", Date().timeIntervalSince($0)) + "s" } ?? "?"
                    print("📼 Player readyToPlay after \(elapsed)")
                    hasResumed = true
                    continuation.resume(returning: true)
                case .failed:
                    print("❌ Player failed: \(item.error?.localizedDescription ?? "unknown")")
                    hasResumed = true
                    continuation.resume(returning: false)
                case .unknown:
                    break // Still loading
                @unknown default:
                    break
                }
            }

            // Timeout after 30 seconds
            Task {
                try? await Task.sleep(for: .seconds(30))
                if !hasResumed {
                    print("⚠️ Player timeout after 30s")
                    hasResumed = true
                    continuation.resume(returning: false)
                }
            }
        }

        statusObserver?.invalidate()

        guard isReady else {
            print("❌ Player not ready")
            showLoading = false
            return
        }

        // Spatial mode: always request .spatial — RealityKit renders it only if the content is
        // actually MV-HEVC (ignores the request for regular mono video, rendering it as mono).
        // This ensures spatial videos always display correctly on the very first open, even for
        // assets not yet in the spatial cache, with zero risk to non-spatial videos.
        let isKnownSpatial = spatialPhotoManager.isCurrentAssetKnownSpatial
        if isKnownSpatial {
            print("📼 Spatial video confirmed from spatial cache")
            spatialPhotoManager.markCurrentAssetAsSpatial()
        }

        // Setup video entity — isSpatialVideo: true always requests spatial mode
        await setupVideoPlayer(player, initialOpacity: initialOpacity, isSpatialVideo: true, targetPosition: targetPosition)

        // For uncached assets: detect in a fully detached background task (no main actor,
        // separate HTTPS AVURLAsset with no VideoStreamingLoader involvement) purely for
        // cache population so the asset shows up in Spatial Photos. Never blocks playback.
        if !isKnownSpatial, let url = originalURL, let token = accessToken {
            let manager = spatialPhotoManager
            Task.detached(priority: .background) {
                let detectionAsset = AVURLAsset(
                    url: url,
                    options: ["AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "Bearer \(token)"]])
                var isSpatial = false
                do {
                    let videoTracks = try await detectionAsset.loadTracks(withMediaType: .video)
                    outer: for track in videoTracks {
                        let formatDescs = try await track.load(.formatDescriptions)
                        for desc in formatDescs {
                            if let exts = CMFormatDescriptionGetExtensions(desc) as? [String: Any],
                               (exts["StereoMVHEVC"] != nil ||
                                exts["HasLeftStereoEyeView"] != nil ||
                                exts["HasRightStereoEyeView"] != nil) {
                                isSpatial = true
                                break outer
                            }
                        }
                    }
                } catch {
                    print("⚠️ Background spatial detection error: \(error.localizedDescription)")
                }
                if isSpatial {
                    await MainActor.run {
                        manager.markCurrentAssetAsSpatial()
                        print("📼 Background detection: spatial confirmed and cached")
                    }
                }
            }
        }

        // Wait for video to actually start rendering (currentTime > 0)
        // Keep loading indicator visible until video pixels are on screen
        for _ in 0..<100 {  // Check up to 100 times (5 seconds max)
            try? await Task.sleep(for: .milliseconds(50))
            if player.currentTime().seconds > 0.02 {
                let elapsed = startTime.map { String(format: "%.2f", Date().timeIntervalSince($0)) + "s" } ?? "?"
                print("✅ Video first frame visible after \(elapsed) (currentTime=\(String(format: "%.3f", player.currentTime().seconds))s)")
                break
            }
        }

        // NOW hide the loading indicator (video should be visible)
        showLoading = false

        print("✅ Video streaming complete")
    }

    /// Load video from cached data (offline/preloaded)
    private func loadVideoFromData(_ asset: SpatialPhotoManager.SpatialAssetData, initialOpacity: Float = 1.0, targetPosition: SIMD3<Float>) async {
        print("📼 loadVideoFromData - dataSize: \(asset.originalData.count), fileName: \(asset.fileName), isSpatial: \(asset.isSpatial), targetPosition: \(targetPosition)")

        guard asset.originalData.count > 0 else {
            print("❌ Video data is empty!")
            showLoading = false
            return
        }

        // Show loading indicator while setting up
        showLoading = true

        do {
            let ext = (asset.fileName as NSString).pathExtension.lowercased()
            let finalExt = ext.isEmpty ? "mov" : ext
            print("📼 File extension: '\(ext)' -> '\(finalExt)'")

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(finalExt)

            print("📼 Writing to temp file: \(tempURL.path)")
            try asset.originalData.write(to: tempURL)
            print("📼 File written successfully")

            // Verify file exists
            let fileExists = FileManager.default.fileExists(atPath: tempURL.path)
            print("📼 File exists: \(fileExists)")

            let avAsset = AVURLAsset(url: tempURL)
            let playerItem = AVPlayerItem(asset: avAsset)
            let player = AVPlayer(playerItem: playerItem)
            print("📼 AVPlayer created")

            // Store player reference
            videoPlayer = player

            // Wait for player to be ready
            let isReady = await waitForPlayerReady(player: player)
            guard isReady else {
                print("❌ Player failed to become ready")
                showLoading = false
                return
            }

            // Detect spatial video from actual video tracks
            let isSpatialVideo = await detectSpatialVideo(asset: avAsset)
            print("📼 Spatial video detected from cache: \(isSpatialVideo)")

            // Mark as spatial in cache so it appears in Spatial Photos view
            if isSpatialVideo {
                spatialPhotoManager.markCurrentAssetAsSpatial()
            }

            await setupVideoPlayer(player, initialOpacity: initialOpacity, isSpatialVideo: isSpatialVideo, targetPosition: targetPosition)

            // Wait for video to actually start rendering
            for _ in 0..<100 {
                try? await Task.sleep(for: .milliseconds(50))
                if player.currentTime().seconds > 0.02 {
                    print("✅ Video playback confirmed at \(player.currentTime().seconds)s")
                    break
                }
            }

            // NOW hide the loading indicator
            showLoading = false

            // Clean up temp file when video ends
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem,
                queue: .main
            ) { _ in
                try? FileManager.default.removeItem(at: tempURL)
            }
            print("✅ Video loaded from cache successfully (spatial: \(isSpatialVideo))")
        } catch {
            print("❌ Video load error: \(error)")
            showLoading = false
        }
    }

    /// Wait for player to become ready to play
    private func waitForPlayerReady(player: AVPlayer) async -> Bool {
        var statusObserver: NSKeyValueObservation?

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            var hasResumed = false

            statusObserver = player.currentItem?.observe(\.status, options: [.new, .initial]) { item, _ in
                guard !hasResumed else { return }

                switch item.status {
                case .readyToPlay:
                    print("📼 Player ready to play (from cache)")
                    hasResumed = true
                    statusObserver?.invalidate()
                    continuation.resume(returning: true)
                case .failed:
                    print("❌ Player failed: \(item.error?.localizedDescription ?? "unknown")")
                    hasResumed = true
                    statusObserver?.invalidate()
                    continuation.resume(returning: false)
                case .unknown:
                    break // Still loading
                @unknown default:
                    break
                }
            }

            // Timeout after 30 seconds
            Task {
                try? await Task.sleep(for: .seconds(30))
                if !hasResumed {
                    print("⚠️ Player timeout (from cache)")
                    hasResumed = true
                    statusObserver?.invalidate()
                    continuation.resume(returning: false)
                }
            }
        }
    }


    /// Common setup for video player entity
    private func setupVideoPlayer(_ player: AVPlayer, initialOpacity: Float, isSpatialVideo: Bool = false, targetPosition: SIMD3<Float>) async {
        print("📼 setupVideoPlayer called (spatial: \(isSpatialVideo))")
        print("📼 targetPosition: \(targetPosition)")
        print("📼 dynamicBasePosition: \(dynamicBasePosition)")
        print("📼 wrapperEntity.position: \(wrapperEntity.position)")

        // Use VideoPlayerComponent for both spatial and non-spatial videos
        // This gives us proper visionOS native video presentation with styling
        var videoComponent = VideoPlayerComponent(avPlayer: player)

        if isSpatialVideo {
            // Use spatial mode for immersive presentation with blurry edges
            videoComponent.desiredSpatialVideoMode = .spatial
        }

        // Disable passthrough tinting for cleaner appearance
        videoComponent.isPassthroughTintingEnabled = false

        let videoEntity = Entity()
        videoEntity.name = "videoEntity"
        videoEntity.components.set(videoComponent)
        videoEntity.components.set(OpacityComponent(opacity: initialOpacity))
        videoEntity.components.set(HoverEffectComponent())

        // Remove any previous scene-level video entity
        sceneVideoEntity?.removeFromParent()

        // Add video to contentEntity (same as photos) so it inherits all wrapper animations
        // Position at origin relative to contentEntity (wrapper handles world positioning)
        videoEntity.position = .zero
        contentEntity.addChild(videoEntity)
        sceneVideoEntity = videoEntity  // Track for cleanup and playback control
        print("📼 Video entity added to contentEntity at origin")

        print("📼 Video entity added to contentEntity, children count: \(contentEntity.children.count)")

        // Observe player errors
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { notification in
            if let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
                print("❌ Video playback error: \(error)")
            }
        }

        // Setup time observer for timeline (also starts playback)
        setupVideoTimeObserver(for: player)

        print("📼 Video player setup complete")
    }

    // MARK: - Helpers

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: - Controls Visibility

    private func toggleControls() {
        // Cancel any pending hide task
        hideControlsTask?.cancel()

        if showControls {
            // Hide immediately
            showControls = false
        } else {
            // Show and schedule auto-hide
            showControlsTemporarily()
        }
    }

    private func showControlsTemporarily() {
        // Cancel any pending hide task
        hideControlsTask?.cancel()

        // Show controls
        showControls = true

        // Schedule auto-hide after 4 seconds
        hideControlsTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled {
                await MainActor.run {
                    showControls = false
                }
            }
        }
    }

    // MARK: - Video Playback Controls

    private func setupVideoTimeObserver(for player: AVPlayer) {
        // Remove any existing observer
        if let observer = timeObserver {
            videoPlayer?.removeTimeObserver(observer)
            timeObserver = nil
        }

        // Store player reference
        videoPlayer = player

        // Get duration asynchronously (AVAsset.duration is deprecated; use async load)
        if let asset = player.currentItem?.asset {
            Task {
                if let duration = try? await asset.load(.duration) {
                    let durationSeconds = CMTimeGetSeconds(duration)
                    if durationSeconds.isFinite && durationSeconds > 0 {
                        videoDuration = durationSeconds
                        print("📼 Video duration: \(durationSeconds) seconds")
                    }
                }
            }
        }

        // Add periodic time observer
        let interval = CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [self] time in
            if !isSeeking {
                videoCurrentTime = CMTimeGetSeconds(time)
            }

            // Update playing state based on timeControlStatus, not rate
            // This correctly handles buffering: when buffering, status is .waitingToPlayAtSpecifiedRate
            // which means user's intent is to play, so we should show pause button
            switch player.timeControlStatus {
            case .playing, .waitingToPlayAtSpecifiedRate:
                // Playing or buffering (intent to play) - show pause button
                isVideoPlaying = true
            case .paused:
                // Actually paused - show play button
                isVideoPlaying = false
            @unknown default:
                isVideoPlaying = player.rate > 0
            }

            // Update duration if not yet set (async loading)
            if videoDuration == 0, let duration = player.currentItem?.duration {
                let durationSeconds = CMTimeGetSeconds(duration)
                if durationSeconds.isFinite && durationSeconds > 0 {
                    videoDuration = durationSeconds
                    print("📼 Video duration updated: \(durationSeconds) seconds")
                }
            }

            // Check for errors
            if let error = player.currentItem?.error {
                print("❌ Player item error: \(error.localizedDescription)")
            }
        }

        // Observe when video ends to reset
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [self] _ in
            isVideoPlaying = false
            videoCurrentTime = 0
            player.seek(to: .zero)
        }

        // Start playing
        print("▶️ Starting video playback...")
        player.play()
        isVideoPlaying = true
        print("▶️ player.play() called, rate: \(player.rate)")
    }

    private func cleanupVideoObserver() {
        print("🧹 Cleaning up video observer and streaming")

        // Stop playback
        videoPlayer?.pause()

        // Remove time observer
        if let observer = timeObserver {
            videoPlayer?.removeTimeObserver(observer)
            timeObserver = nil
        }

        // Clear player reference
        videoPlayer = nil

        // Release streaming loader (cancels any pending downloads)
        videoStreamingLoader = nil

        // Hide the video entity before removing (prevents flicker)
        // Move far away and set opacity to 0, then delay removal to next frame
        if let videoEntity = sceneVideoEntity {
            videoEntity.position = SIMD3<Float>(0, -100, 0)  // Move far below
            var opacityComp = videoEntity.components[OpacityComponent.self] ?? OpacityComponent(opacity: 1.0)
            opacityComp.opacity = 0
            videoEntity.components.set(opacityComp)

            // Delay removal to ensure opacity/position changes render first
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                videoEntity.removeFromParent()
            }
        }
        sceneVideoEntity = nil

        // Reset state
        videoDuration = 0
        videoCurrentTime = 0
        isVideoPlaying = false
    }

    private func toggleVideoPlayback() {
        guard let player = videoPlayer else { return }
        showControlsTemporarily()

        if player.rate > 0 {
            player.pause()
            isVideoPlaying = false
        } else {
            player.play()
            isVideoPlaying = true
        }
    }

    private func seekVideo(to time: Double) {
        guard let player = videoPlayer else { return }
        let cmTime = CMTime(seconds: time, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        videoCurrentTime = time
    }

    // MARK: - Hide

    private func hideCurrentAsset() async {
        let shouldStayOpen = await spatialPhotoManager.hideCurrentAsset()
        if shouldStayOpen {
            // Reload the new current asset
            await displayCurrentAsset()
        } else {
            // No assets left, dismiss viewer
            await dismissImmersiveSpace()
            spatialPhotoManager.clear()
        }
    }

    // MARK: - Share

    private func prepareAndShare() async {
        guard let asset = spatialPhotoManager.currentAsset else {
            print("❌ No asset to share")
            return
        }

        isPreparingShare = true

        do {
            // Determine proper file extension based on content
            let originalExt = (asset.fileName as NSString).pathExtension.lowercased()
            let fileExtension: String

            if asset.isVideo {
                // Use original extension or default to mov for videos
                fileExtension = originalExt.isEmpty ? "mov" : originalExt
            } else {
                // For images, use original extension or default to heic
                // Common image extensions: heic, jpg, jpeg, png, heif
                let validImageExts = ["heic", "heif", "jpg", "jpeg", "png", "gif", "webp"]
                if validImageExts.contains(originalExt) {
                    fileExtension = originalExt
                } else {
                    fileExtension = "heic"
                }
            }

            // Create filename with proper extension
            let baseName = (asset.fileName as NSString).deletingPathExtension
            let fileName = baseName.isEmpty ? UUID().uuidString : baseName
            let fullFileName = "\(fileName).\(fileExtension)"

            // Create temp file in UUID subdirectory to avoid collisions with spatial viewer cache
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let tempURL = tempDir.appendingPathComponent(fullFileName)

            // Get the data to write - always download original quality for sharing
            var dataToWrite: Data

            if asset.isVideo {
                // For videos: check if we have data or need to download
                if asset.originalData.isEmpty {
                    print("📥 Video was streaming, downloading full file for share...")

                    // Get streaming info (URL and access token)
                    guard let streamingInfo = spatialPhotoManager.getVideoStreamingInfo(assetId: asset.assetId) else {
                        throw NSError(domain: "ShareError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not get video URL"])
                    }

                    // Download the full video
                    var request = URLRequest(url: streamingInfo.url)
                    request.setValue("Bearer \(streamingInfo.accessToken)", forHTTPHeaderField: "Authorization")
                    request.timeoutInterval = 300  // 5 minute timeout for large videos

                    let (data, response) = try await URLSession.shared.data(for: request)

                    guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                        throw NSError(domain: "ShareError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to download video"])
                    }

                    print("✅ Downloaded \(data.count) bytes for sharing")
                    dataToWrite = data
                } else {
                    dataToWrite = asset.originalData
                }
            } else {
                // For images: always download original to ensure full quality with EXIF
                // (cached data might be preview quality)
                guard let originalData = await spatialPhotoManager.downloadOriginalForSharing() else {
                    throw NSError(domain: "ShareError", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to download original image"])
                }
                dataToWrite = originalData
            }

            // Write data to temp file
            try dataToWrite.write(to: tempURL)

            print("✅ Prepared file for sharing: \(fullFileName)")

            // Get thumbnail data if available (convert CGImage to UIImage first)
            var thumbnailData: Data? = nil
            if let cgImage = spatialPhotoManager.currentThumbnail {
                let uiImage = UIImage(cgImage: cgImage)
                thumbnailData = uiImage.pngData()
            }

            // For images, also create UIImage for direct Photos app sharing
            var imageForSharing: UIImage? = nil
            if !asset.isVideo {
                imageForSharing = UIImage(data: dataToWrite)
            }

            // Update share manager
            shareManager.singleFileTempDir = tempDir
            shareManager.fileURL = tempURL
            shareManager.fileName = fullFileName
            shareManager.thumbnailData = thumbnailData
            shareManager.isVideo = asset.isVideo
            shareManager.imageForSharing = imageForSharing
            shareManager.showShareSheet = true

            isPreparingShare = false

            // Switch back to album view to show share sheet
            // Main window is already open but hidden, just dismiss immersive space
            spatialPhotoManager.clear()
            await dismissImmersiveSpace()

        } catch {
            isPreparingShare = false
            print("❌ Share preparation error: \(error)")
        }
    }

    // MARK: - Head Tracking

    private func getHeadBasedPosition() async -> SIMD3<Float> {
        // For immersive space, position content at eye level in world coordinates
        // Y = 0 is floor level, Y = 1.1 is comfortable eye level
        // Z = -1.5 places content about 1.5 meters in front of the user
        let immersivePosition: SIMD3<Float> = [0, 1.1, -1.5]
        print("📦 Using immersive space position: \(immersivePosition)")
        return immersivePosition
    }
}

// MARK: - Loading Placeholder View

struct LoadingPlaceholderView: View {
    @ObservedObject var spatialPhotoManager: SpatialPhotoManager
    let isVisible: Bool

    // Base width in points for SwiftUI attachments (~0.8m in world space)
    private let baseWidth: CGFloat = 800

    private var baseHeight: CGFloat {
        baseWidth * 0.75
    }

    var body: some View {
        // Use simple spinner for all content types to avoid size mismatch
        // between loading placeholder and actual rendered content
        spatialLoadingIndicator
            .opacity(isVisible ? 1.0 : 0.0)
            .animation(.easeInOut(duration: 0.05), value: isVisible)
    }

    /// Check if the content is spatial (from spatial cache, metadata, or loaded asset)
    private func isSpatialContent(metadata: Asset) -> Bool {
        // Check spatial cache first (most reliable - pre-scanned)
        if spatialPhotoManager.isCurrentAssetKnownSpatial { return true }

        // Check metadata flag
        if metadata.isSpatial { return true }

        // Check loaded asset
        if spatialPhotoManager.currentAsset?.isSpatial == true { return true }

        // For videos, check projection type for spatial indicators
        if metadata.type == .VIDEO {
            if let projection = metadata.projectionType, !projection.isEmpty {
                return true
            }
        }

        return false
    }

    /// Simple loading indicator for spatial photos/videos
    private var spatialLoadingIndicator: some View {
        ProgressView()
            .scaleEffect(1.5)
            .tint(.white)
            .frame(width: 100, height: 100)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    /// Sized placeholder for regular photos/videos
    private func regularLoadingPlaceholder(metadata: Asset) -> some View {
        // Use thumbnail's actual aspect ratio if available, otherwise fall back to metadata
        let aspectRatio = spatialPhotoManager.currentThumbnailAspectRatio ?? metadata.ratio ?? (4.0/3.0)
        let size = calculateSizeFromRatio(aspectRatio)

        return ZStack {
            // Background with thumbnail if available
            if let thumbnail = spatialPhotoManager.currentThumbnail {
                // Show thumbnail scaled to match final asset dimensions
                // Use interpolation to scale up the small thumbnail smoothly
                Image(decorative: thumbnail, scale: 1.0)
                    .resizable(resizingMode: .stretch)
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .blur(radius: 12)  // Heavy blur for loading state
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20)
                            .fill(.black.opacity(0.3))
                    }
            } else {
                // Glass placeholder when no thumbnail
                RoundedRectangle(cornerRadius: 20)
                    .fill(.ultraThinMaterial)
                    .frame(width: size.width, height: size.height)
            }

            // Simple spinner overlay
            ProgressView()
                .scaleEffect(1.5)
                .tint(.white)
        }
    }

    /// Default loading window when no metadata available
    private var defaultLoadingPlaceholder: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(.white)

            Text("Loading")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(32)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .glassBackgroundEffect()
    }

    /// Calculate placeholder size from aspect ratio
    /// Uses the base width and calculates height from the ratio
    private func calculateSizeFromRatio(_ ratio: Double) -> CGSize {
        guard ratio > 0 else {
            print("📐 Invalid ratio, using default size: \(baseWidth)x\(baseHeight)")
            return CGSize(width: baseWidth, height: baseHeight)
        }

        // ratio is width/height, so height = width / ratio
        let width = baseWidth
        let height = baseWidth / CGFloat(ratio)

        print("📐 Placeholder size: \(Int(width))x\(Int(height)) (ratio: \(String(format: "%.2f", ratio)))")
        return CGSize(width: width, height: height)
    }
}

// MARK: - Asset Info Panel View

struct AssetInfoPanelView: View {
    let metadata: Asset

    // Pre-compute expensive values once
    private var parsedDate: Date? {
        guard let dateString = metadata.fileCreatedAt else { return nil }
        return Self.iso8601FormatterWithFractional.date(from: dateString)
            ?? Self.iso8601Formatter.date(from: dateString)
    }

    private var formattedDate: String? {
        guard let date = parsedDate else { return nil }
        return Self.displayDateFormatter.string(from: date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // File name header
            HStack(spacing: 8) {
                Image(systemName: metadata.type == .VIDEO ? "video.fill" : "photo.fill")
                    .foregroundStyle(.secondary)
                Text(metadata.originalFileName)
                    .font(.headline)
                    .lineLimit(2)

                // Spatial indicator
                if metadata.isSpatial {
                    Text("3D")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.blue.opacity(0.3))
                        .cornerRadius(4)
                }
            }

            Divider()

            // Type
            InfoRow(icon: "doc", label: "Type", value: assetTypeString)

            // Date taken
            if let dateStr = formattedDate {
                InfoRow(icon: "calendar", label: "Date", value: dateStr)
            }

            // Duration (for videos)
            if let duration = metadata.duration, !duration.isEmpty, duration != "0:00:00.00000" {
                InfoRow(icon: "clock", label: "Duration", value: formatDuration(duration))
            }

            // Aspect ratio
            if let ratio = metadata.ratio {
                InfoRow(icon: "aspectratio", label: "Aspect Ratio", value: formatAspectRatio(ratio))
            }

            // Camera info
            if let exif = metadata.exifInfo {
                if let cameraStr = cameraString(from: exif) {
                    InfoRow(icon: "camera", label: "Camera", value: cameraStr)
                }

                // Lens
                if let lens = exif.lensModel {
                    InfoRow(icon: "camera.aperture", label: "Lens", value: lens)
                }

                // Camera settings
                if let settingsStr = cameraSettingsString(from: exif) {
                    InfoRow(icon: "dial.low", label: "Settings", value: settingsStr)
                }

                // Location (city/state/country or GPS coordinates)
                if let locationStr = locationString(from: exif) {
                    InfoRow(icon: "location", label: "Location", value: locationStr)
                } else if let gpsStr = gpsString(from: exif) {
                    InfoRow(icon: "location", label: "GPS", value: gpsStr)
                }
            }

            // File path (truncated)
            if let path = metadata.originalPath {
                InfoRow(icon: "folder", label: "Path", value: truncatePath(path))
            }
        }
        .frame(minWidth: 320, maxWidth: 480, alignment: .leading)
    }

    // Unused - kept for reference
    private var _unused: some View {
        VStack(alignment: .leading, spacing: 10) {
            // File name header
            HStack(spacing: 8) {
                Image(systemName: metadata.type == .VIDEO ? "video.fill" : "photo.fill")
                    .foregroundStyle(.secondary)
                Text(metadata.originalFileName)
                    .font(.headline)
                    .lineLimit(2)

                // Spatial indicator
                if metadata.isSpatial {
                    Text("3D")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.blue.opacity(0.3))
                        .cornerRadius(4)
                }
            }

            Divider()

            // Type
            InfoRow(icon: "doc", label: "Type", value: assetTypeString)

            // Date taken
            if let dateString = metadata.fileCreatedAt, let date = parseDate(dateString) {
                InfoRow(icon: "calendar", label: "Date", value: formatDate(date))
            }

            // Duration (for videos)
            if let duration = metadata.duration, !duration.isEmpty, duration != "0:00:00.00000" {
                InfoRow(icon: "clock", label: "Duration", value: formatDuration(duration))
            }

            // Aspect ratio
            if let ratio = metadata.ratio {
                InfoRow(icon: "aspectratio", label: "Aspect Ratio", value: formatAspectRatio(ratio))
            }

            // Camera info
            if let exif = metadata.exifInfo {
                if let cameraString = cameraString(from: exif) {
                    InfoRow(icon: "camera", label: "Camera", value: cameraString)
                }

                // Lens
                if let lens = exif.lensModel {
                    InfoRow(icon: "camera.aperture", label: "Lens", value: lens)
                }

                // Camera settings
                if let settingsString = cameraSettingsString(from: exif) {
                    InfoRow(icon: "dial.low", label: "Settings", value: settingsString)
                }

                // Location (city/state/country or GPS coordinates)
                if let locationString = locationString(from: exif) {
                    InfoRow(icon: "location", label: "Location", value: locationString)
                } else if let gpsString = gpsString(from: exif) {
                    InfoRow(icon: "location", label: "GPS", value: gpsString)
                }
            }

            // File path (truncated)
            if let path = metadata.originalPath {
                InfoRow(icon: "folder", label: "Path", value: truncatePath(path))
            }
        }
        .frame(minWidth: 320, maxWidth: 480, alignment: .leading)
    }

    // MARK: - Computed Properties

    private var assetTypeString: String {
        var typeStr = metadata.type == .VIDEO ? "Video" : "Photo"
        if metadata.isSpatial {
            typeStr = "Spatial " + typeStr
        }
        return typeStr
    }

    // MARK: - Helper Functions

    /// Build camera string from EXIF data
    private func cameraString(from exif: Asset.ExifInfo) -> String? {
        if let make = exif.make, let model = exif.model {
            // Avoid redundant make in model name (e.g., "Apple iPhone 15 Pro" -> just use model)
            if model.lowercased().contains(make.lowercased()) {
                return model
            }
            return "\(make) \(model)"
        } else if let model = exif.model {
            return model
        } else if let make = exif.make {
            return make
        }
        return nil
    }

    /// Build location string from EXIF data
    private func locationString(from exif: Asset.ExifInfo) -> String? {
        guard let city = exif.city else { return nil }
        var location = city
        if let state = exif.state {
            location += ", \(state)"
        }
        if let country = exif.country {
            location += ", \(country)"
        }
        return location
    }

    /// Build GPS coordinates string from EXIF data
    private func gpsString(from exif: Asset.ExifInfo) -> String? {
        guard let lat = exif.latitude, let lon = exif.longitude else { return nil }
        let latDir = lat >= 0 ? "N" : "S"
        let lonDir = lon >= 0 ? "E" : "W"
        return String(format: "%.4f° %@, %.4f° %@", abs(lat), latDir, abs(lon), lonDir)
    }

    /// Build camera settings string from EXIF data
    private func cameraSettingsString(from exif: Asset.ExifInfo) -> String? {
        var settings: [String] = []
        if let f = exif.fNumber {
            settings.append("ƒ/\(String(format: "%.1f", f))")
        }
        if let focal = exif.focalLength {
            settings.append("\(Int(focal))mm")
        }
        if let iso = exif.iso {
            settings.append("ISO \(iso)")
        }
        return settings.isEmpty ? nil : settings.joined(separator: "  ")
    }

    /// Format aspect ratio nicely
    private func formatAspectRatio(_ ratio: Double) -> String {
        // Common aspect ratios
        let tolerance = 0.02
        if abs(ratio - 16.0/9.0) < tolerance { return "16:9" }
        if abs(ratio - 4.0/3.0) < tolerance { return "4:3" }
        if abs(ratio - 3.0/2.0) < tolerance { return "3:2" }
        if abs(ratio - 1.0) < tolerance { return "1:1" }
        if abs(ratio - 9.0/16.0) < tolerance { return "9:16" }
        if abs(ratio - 3.0/4.0) < tolerance { return "3:4" }
        if abs(ratio - 2.0/3.0) < tolerance { return "2:3" }

        // Fall back to decimal
        return String(format: "%.2f:1", ratio)
    }

    /// Truncate path to show last 2-3 components
    private func truncatePath(_ path: String) -> String {
        let components = path.split(separator: "/")
        if components.count <= 3 {
            return path
        }
        let lastComponents = components.suffix(3)
        return ".../" + lastComponents.joined(separator: "/")
    }

    // Static formatters to avoid expensive recreation on every render
    private static let iso8601FormatterWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let displayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter
    }()

    private func parseDate(_ dateString: String) -> Date? {
        if let date = Self.iso8601FormatterWithFractional.date(from: dateString) {
            return date
        }
        // Try without fractional seconds
        return Self.iso8601Formatter.date(from: dateString)
    }

    private func formatDate(_ date: Date) -> String {
        return Self.displayDateFormatter.string(from: date)
    }

    private func formatDuration(_ duration: String) -> String {
        // Parse duration format like "0:00:05.12345" or "0:01:30.00000"
        let parts = duration.split(separator: ":")
        guard parts.count >= 3 else { return duration }

        let hours = Int(parts[0]) ?? 0
        let minutes = Int(parts[1]) ?? 0
        let secondsPart = parts[2].split(separator: ".").first ?? parts[2]
        let seconds = Int(secondsPart) ?? 0

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
}

struct InfoRow: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline)
            }
        }
    }
}

// MARK: - Controls Content View (extracted to help compiler type-checking)

struct ControlsContentView: View {
    @ObservedObject var spatialPhotoManager: SpatialPhotoManager
    @Binding var showInfoPanel: Bool
    let isPreparingShare: Bool
    let isCurrentAssetBeingSaved: Bool
    let showControls: Bool

    // Callbacks
    let onNavigatePrevious: () -> Void
    let onNavigateNext: () -> Void
    let onShowControlsTemporarily: () -> Void
    let onPrepareAndShare: () -> Void
    let onHideAsset: () -> Void
    let onSaveOffline: () -> Void
    let onDismiss: () -> Void
    let formatBytes: (Int64) -> String

    var body: some View {
        VStack(spacing: 12) {
            // Info panel (only rendered when visible)
            if showInfoPanel {
                InfoPanelWrapper(spatialPhotoManager: spatialPhotoManager)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .glassBackgroundEffect()
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            // Main controls bar
            mainControlsBar
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .glassBackgroundEffect(in: Capsule())
        }
        .animation(.easeOut(duration: 0.2), value: showInfoPanel)
        .opacity(showControls ? 1 : 0)
        .animation(.easeInOut(duration: 0.25), value: showControls)
        .allowsHitTesting(showControls)
        .onChange(of: showInfoPanel) { oldValue, newValue in
            print("ℹ️ showInfoPanel changed: \(oldValue) -> \(newValue)")
            if newValue {
                Task {
                    await spatialPhotoManager.fetchCurrentAssetDetails()
                }
            }
        }
    }

    private var mainControlsBar: some View {
        HStack(spacing: 24) {
            navigationButtons
            Spacer().frame(width: 20)
            actionButtons
        }
    }

    private var navigationButtons: some View {
        HStack(spacing: 24) {
            Button(action: onNavigatePrevious) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 24, weight: .semibold))
                    .frame(width: 60, height: 60)
            }
            .buttonStyle(.plain)
            .background(.ultraThinMaterial)
            .clipShape(Circle())
            .opacity(spatialPhotoManager.currentIndex == 0 ? 0.4 : 1.0)
            .disabled(spatialPhotoManager.currentIndex == 0)

            Text("\(spatialPhotoManager.currentIndex + 1) of \(spatialPhotoManager.totalAssets)")
                .font(.headline)
                .frame(minWidth: 80)

            Button(action: onNavigateNext) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 24, weight: .semibold))
                    .frame(width: 60, height: 60)
            }
            .buttonStyle(.plain)
            .background(.ultraThinMaterial)
            .clipShape(Circle())
            .opacity(spatialPhotoManager.currentIndex >= spatialPhotoManager.totalAssets - 1 ? 0.4 : 1.0)
            .disabled(spatialPhotoManager.currentIndex >= spatialPhotoManager.totalAssets - 1)
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 24) {
            infoButton
            shareButton
            hideButton
            offlineButton
            closeButton
        }
    }

    private var infoButton: some View {
        Button(action: {
            print("ℹ️ Info button tapped, showInfoPanel was: \(showInfoPanel)")
            showInfoPanel.toggle()
            print("ℹ️ Info button tapped, showInfoPanel now: \(showInfoPanel)")
            onShowControlsTemporarily()
        }) {
            Image(systemName: showInfoPanel ? "info.circle.fill" : "info.circle")
                .font(.system(size: 24, weight: .semibold))
                .frame(width: 60, height: 60)
        }
        .buttonStyle(.plain)
        .background(.ultraThinMaterial)
        .clipShape(Circle())
    }

    private var shareButton: some View {
        Button(action: onPrepareAndShare) {
            Group {
                if isPreparingShare {
                    ProgressView()
                        .scaleEffect(0.8)
                        .tint(.white)
                } else {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 24, weight: .semibold))
                }
            }
            .frame(width: 60, height: 60)
        }
        .buttonStyle(.plain)
        .background(.ultraThinMaterial)
        .clipShape(Circle())
        .disabled(isPreparingShare || spatialPhotoManager.currentAsset == nil)
    }

    private var hideButton: some View {
        Button(action: onHideAsset) {
            Image(systemName: "eye.slash")
                .font(.system(size: 24, weight: .semibold))
                .frame(width: 60, height: 60)
        }
        .buttonStyle(.plain)
        .background(.ultraThinMaterial)
        .clipShape(Circle())
        .disabled(spatialPhotoManager.currentAsset == nil)
    }

    private var offlineButton: some View {
        Button(action: {
            onShowControlsTemporarily()
            onSaveOffline()
        }) {
            HStack(spacing: 12) {
                offlineButtonIcon
                    .frame(width: 30, height: 30)

                if isCurrentAssetBeingSaved && spatialPhotoManager.totalBytes > 0 {
                    Text("\(formatBytes(spatialPhotoManager.downloadedBytes)) / \(formatBytes(spatialPhotoManager.totalBytes))")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, isCurrentAssetBeingSaved && spatialPhotoManager.totalBytes > 0 ? 16 : 15)
            .frame(height: 60)
        }
        .buttonStyle(.plain)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .animation(.easeInOut(duration: 0.05), value: isCurrentAssetBeingSaved)
        .animation(.easeInOut(duration: 0.05), value: spatialPhotoManager.totalBytes)
        .disabled(isCurrentAssetBeingSaved || spatialPhotoManager.currentAsset == nil || spatialPhotoManager.isCurrentAssetOffline)
    }

    @ViewBuilder
    private var offlineButtonIcon: some View {
        if isCurrentAssetBeingSaved {
            ProgressView()
                .scaleEffect(0.8)
                .tint(.white)
        } else if spatialPhotoManager.isCurrentAssetOffline {
            Image(systemName: "checkmark.icloud.fill")
                .font(.system(size: 22, weight: .semibold))
        } else {
            Image(systemName: "icloud.and.arrow.down")
                .font(.system(size: 22, weight: .semibold))
        }
    }

    private var closeButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 24, weight: .semibold))
                .frame(width: 60, height: 60)
        }
        .buttonStyle(.plain)
        .background(.ultraThinMaterial)
        .clipShape(Circle())
    }
}

// MARK: - Info Panel Wrapper (handles fetching full asset details)

struct InfoPanelWrapper: View {
    @ObservedObject var spatialPhotoManager: SpatialPhotoManager

    var body: some View {
        Group {
            if let fullDetails = spatialPhotoManager.currentFullAssetDetails {
                // Full details loaded - show the info panel
                AssetInfoPanelView(metadata: fullDetails)
            } else {
                // Still loading - show spinner
                HStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(0.9)
                    Text("Loading info...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 200)
            }
        }
    }
}

// MARK: - Video Timeline View

struct VideoTimelineView: View {
    @Binding var currentTime: Double
    let duration: Double
    let isPlaying: Bool
    @Binding var isSeeking: Bool
    let onSeek: (Double) -> Void
    let onPlayPause: () -> Void
    let onInteraction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Play/Pause button
            Button(action: {
                onInteraction()
                onPlayPause()
            }) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .background(.ultraThinMaterial)
            .clipShape(Circle())

            // Current time
            Text(formatTime(currentTime))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 45, alignment: .trailing)

            // Timeline slider - fixed width slightly wider than control ornaments
            Slider(
                value: Binding(
                    get: { currentTime },
                    set: { newValue in
                        onInteraction()
                        currentTime = newValue
                        onSeek(newValue)
                    }
                ),
                in: 0...max(duration, 0.01),
                onEditingChanged: { editing in
                    isSeeking = editing
                    if editing {
                        onInteraction()
                    }
                }
            )
            .tint(.white)
            .frame(width: 560)

            // Duration
            Text(formatTime(duration))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 45, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassBackgroundEffect()
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let totalSeconds = Int(seconds)
        let minutes = totalSeconds / 60
        let secs = totalSeconds % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}
