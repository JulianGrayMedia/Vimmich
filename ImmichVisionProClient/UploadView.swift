//
//  UploadView.swift
//  ImmichVisionProClient
//
//  Created by Julian Gray on 2/6/26.
//

import SwiftUI
import PhotosUI
import ImageIO
import UniformTypeIdentifiers
import AVFoundation

/// Transferable for loading videos as file URLs
struct VideoTransferable: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            // Copy to temp location
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: tempURL)
            return VideoTransferable(url: tempURL)
        }
    }
}

/// Custom transferable that preserves original file data with metadata
struct MediaFileTransfer: Transferable {
    let data: Data
    let contentType: UTType

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { data in
            MediaFileTransfer(data: data, contentType: .image)
        }
        DataRepresentation(importedContentType: .movie) { data in
            MediaFileTransfer(data: data, contentType: .movie)
        }
        DataRepresentation(importedContentType: .heic) { data in
            MediaFileTransfer(data: data, contentType: .heic)
        }
        DataRepresentation(importedContentType: .jpeg) { data in
            MediaFileTransfer(data: data, contentType: .jpeg)
        }
        DataRepresentation(importedContentType: .png) { data in
            MediaFileTransfer(data: data, contentType: .png)
        }
        DataRepresentation(importedContentType: .mpeg4Movie) { data in
            MediaFileTransfer(data: data, contentType: .mpeg4Movie)
        }
        DataRepresentation(importedContentType: .quickTimeMovie) { data in
            MediaFileTransfer(data: data, contentType: .quickTimeMovie)
        }
    }
}

struct UploadView: View {
    @EnvironmentObject var api: ImmichAPI
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var selectedImages: [SelectedMedia] = []
    @State private var isUploading = false
    @State private var uploadProgress: Double = 0
    @State private var uploadedCount = 0
    @State private var duplicateCount = 0
    @State private var failedCount = 0
    @State private var showResults = false

    struct SelectedMedia: Identifiable {
        let id = UUID()
        let item: PhotosPickerItem
        var thumbnail: UIImage?
        var isUploading = false
        var isUploaded = false
        var isDuplicate = false
        var isFailed = false
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                // Header
                VStack(spacing: 12) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 50))

                    Text("Upload to Immich")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("Select photos and videos from your library to upload")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 100)

                // Upload Button (above Change Selection when items selected)
                if !selectedImages.isEmpty && !isUploading {
                    Button(action: {
                        Task {
                            await uploadSelectedMedia()
                        }
                    }) {
                        HStack {
                            Image(systemName: "arrow.up.circle")
                            Text("Upload \(selectedImages.count) Items")
                        }
                        .frame(minWidth: 200)
                    }
                    .buttonStyle(.borderedProminent)
                }

                // Upload Progress
                if isUploading {
                    VStack(spacing: 12) {
                        ProgressView(value: uploadProgress)
                            .progressViewStyle(.linear)

                        Text("Uploading \(uploadedCount + duplicateCount + failedCount) of \(selectedImages.count)...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(minWidth: 200)
                }

                // Photo Picker Button
                PhotosPicker(
                    selection: $selectedItems,
                    maxSelectionCount: 50,
                    matching: .any(of: [.images, .videos]),
                    photoLibrary: .shared()
                ) {
                    HStack {
                        Image(systemName: "photo.on.rectangle.angled")
                        Text(selectedImages.isEmpty ? "Select Media" : "Change Selection")
                    }
                    .frame(minWidth: 200)
                }
                .buttonStyle(.bordered)
                .disabled(isUploading)
                .onChange(of: selectedItems) { oldValue, newValue in
                    Task {
                        await loadSelectedMedia()
                    }
                }

                // Selected Media Grid
                if !selectedImages.isEmpty {
                    VStack(spacing: 16) {
                        HStack {
                            Text("\(selectedImages.count) items selected")
                                .font(.headline)
                            Spacer()
                            Button("Clear") {
                                selectedItems = []
                                selectedImages = []
                            }
                            .disabled(isUploading)
                        }

                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                            ForEach(selectedImages) { media in
                                ZStack {
                                    if let thumbnail = media.thumbnail {
                                        Image(uiImage: thumbnail)
                                            .resizable()
                                            .scaledToFill()
                                    } else {
                                        Rectangle()
                                            .fill(Color.gray.opacity(0.3))
                                            .overlay {
                                                ProgressView()
                                                    .scaleEffect(0.7)
                                            }
                                    }

                                    // Status overlay
                                    if media.isUploading {
                                        Color.black.opacity(0.5)
                                            .overlay {
                                                ProgressView()
                                                    .tint(.white)
                                            }
                                    } else if media.isUploaded {
                                        Color.black.opacity(0.5)
                                            .overlay {
                                                Image(systemName: "checkmark")
                                                    .font(.title2)
                                                    .foregroundStyle(.white)
                                            }
                                    } else if media.isDuplicate {
                                        Color.black.opacity(0.5)
                                            .overlay {
                                                Image(systemName: "doc.on.doc")
                                                    .font(.title3)
                                                    .foregroundStyle(.white)
                                            }
                                    } else if media.isFailed {
                                        Color.black.opacity(0.5)
                                            .overlay {
                                                Image(systemName: "xmark")
                                                    .font(.title2)
                                                    .foregroundStyle(.white)
                                            }
                                    }
                                }
                                .aspectRatio(1, contentMode: .fit)
                                .clipped()
                                .cornerRadius(8)
                            }
                        }
                    }
                    .padding(.horizontal)
                }


                // Results
                if showResults {
                    VStack(spacing: 12) {
                        Divider()

                        Text("Upload Complete")
                            .font(.headline)

                        HStack(spacing: 24) {
                            if uploadedCount > 0 {
                                Label("\(uploadedCount) uploaded", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.primary)
                            }
                            if duplicateCount > 0 {
                                Label("\(duplicateCount) duplicates", systemImage: "doc.on.doc.fill")
                                    .foregroundStyle(.secondary)
                            }
                            if failedCount > 0 {
                                Label("\(failedCount) failed", systemImage: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.subheadline)

                        Button("Done") {
                            resetState()
                        }
                        .buttonStyle(.bordered)
                        .padding(.top, 8)
                    }
                    .padding()
                }

                Spacer()
            }
            .padding(24)
        }
        .navigationTitle("Upload")
    }

    private func loadSelectedMedia() async {
        var newMedia: [SelectedMedia] = []

        for item in selectedItems {
            let media = SelectedMedia(item: item)
            newMedia.append(media)
        }

        await MainActor.run {
            selectedImages = newMedia
        }

        // Load thumbnails
        for (index, item) in selectedItems.enumerated() {
            let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) || $0.conforms(to: .video) }

            if isVideo {
                // For videos, generate thumbnail from video file
                if let thumbnail = await generateVideoThumbnail(for: item) {
                    await MainActor.run {
                        if index < selectedImages.count {
                            selectedImages[index].thumbnail = thumbnail
                        }
                    }
                }
            } else {
                // For images, load and create thumbnail
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    let thumbnail = image.preparingThumbnail(of: CGSize(width: 200, height: 200))
                    await MainActor.run {
                        if index < selectedImages.count {
                            selectedImages[index].thumbnail = thumbnail ?? image
                        }
                    }
                }
            }
        }
    }

    private func generateVideoThumbnail(for item: PhotosPickerItem) async -> UIImage? {
        // Load video as a movie file
        guard let movie = try? await item.loadTransferable(type: VideoTransferable.self) else {
            return nil
        }

        let asset = AVURLAsset(url: movie.url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 200, height: 200)

        do {
            let (cgImage, _) = try await generator.image(at: .zero)
            return UIImage(cgImage: cgImage)
        } catch {
            print("❌ Failed to generate video thumbnail: \(error)")
            return nil
        }
    }

    private func uploadSelectedMedia() async {
        isUploading = true
        uploadedCount = 0
        duplicateCount = 0
        failedCount = 0
        showResults = false

        let total = selectedImages.count

        for (index, _) in selectedImages.enumerated() {
            await MainActor.run {
                selectedImages[index].isUploading = true
            }

            let item = selectedItems[index]

            do {
                // Get the file data - try to preserve original format with metadata
                let data: Data
                if let mediaFile = try await item.loadTransferable(type: MediaFileTransfer.self) {
                    data = mediaFile.data
                    print("📦 Loaded media as \(mediaFile.contentType.identifier): \(data.count) bytes")
                } else if let rawData = try await item.loadTransferable(type: Data.self) {
                    data = rawData
                    print("📦 Loaded media as raw Data: \(data.count) bytes")
                } else {
                    throw URLError(.cannotDecodeContentData)
                }

                // Determine filename
                let filename = generateFilename(for: item)

                // Extract creation date from EXIF metadata, fallback to current date
                let dates = extractDatesFromImageData(data)
                let createdAt = dates.created ?? Date()
                let modifiedAt = dates.modified ?? createdAt

                print("📅 EXIF dates - created: \(createdAt), modified: \(modifiedAt)")

                // Upload to Immich
                let response = try await api.uploadAsset(
                    data: data,
                    filename: filename,
                    createdAt: createdAt,
                    modifiedAt: modifiedAt,
                    isFavorite: false
                )

                await MainActor.run {
                    selectedImages[index].isUploading = false
                    if response.status == "duplicate" {
                        selectedImages[index].isDuplicate = true
                        duplicateCount += 1
                    } else {
                        selectedImages[index].isUploaded = true
                        uploadedCount += 1
                    }
                    uploadProgress = Double(uploadedCount + duplicateCount + failedCount) / Double(total)
                }

            } catch {
                print("❌ Upload failed for item \(index): \(error)")
                await MainActor.run {
                    selectedImages[index].isUploading = false
                    selectedImages[index].isFailed = true
                    failedCount += 1
                    uploadProgress = Double(uploadedCount + duplicateCount + failedCount) / Double(total)
                }
            }
        }

        await MainActor.run {
            isUploading = false
            showResults = true
        }
    }

    private func generateFilename(for item: PhotosPickerItem) -> String {
        // Try to get content type
        let supportedTypes = item.supportedContentTypes
        let isVideo = supportedTypes.contains { $0.conforms(to: .movie) || $0.conforms(to: .video) }

        let timestamp = Int(Date().timeIntervalSince1970)
        let uuid = UUID().uuidString.prefix(8)

        if isVideo {
            return "VisionPro_\(timestamp)_\(uuid).mov"
        } else {
            // Check for HEIC
            let isHEIC = supportedTypes.contains { $0.identifier.contains("heic") || $0.identifier.contains("heif") }
            let ext = isHEIC ? "heic" : "jpg"
            return "VisionPro_\(timestamp)_\(uuid).\(ext)"
        }
    }

    private func resetState() {
        selectedItems = []
        selectedImages = []
        uploadProgress = 0
        uploadedCount = 0
        duplicateCount = 0
        failedCount = 0
        showResults = false
    }

    /// Extract creation and modification dates from image EXIF metadata
    private func extractDatesFromImageData(_ data: Data) -> (created: Date?, modified: Date?) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return (nil, nil)
        }

        // EXIF date formatter (format: "2024:01:15 14:30:00")
        let exifFormatter = DateFormatter()
        exifFormatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        exifFormatter.timeZone = TimeZone.current

        var createdDate: Date? = nil
        var modifiedDate: Date? = nil

        // Try EXIF dictionary first (most reliable for photos)
        if let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            // DateTimeOriginal - when the photo was actually taken
            if let dateString = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String {
                createdDate = exifFormatter.date(from: dateString)
            }
            // DateTimeDigitized - when it was digitized (usually same as original)
            if createdDate == nil, let dateString = exif[kCGImagePropertyExifDateTimeDigitized as String] as? String {
                createdDate = exifFormatter.date(from: dateString)
            }
        }

        // Try TIFF dictionary for modification date
        if let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            if let dateString = tiff[kCGImagePropertyTIFFDateTime as String] as? String {
                modifiedDate = exifFormatter.date(from: dateString)
            }
        }

        // For videos or files without EXIF, modifiedDate might be the only one we get
        if createdDate == nil {
            createdDate = modifiedDate
        }

        return (createdDate, modifiedDate)
    }
}

#Preview {
    UploadView()
        .environmentObject(ImmichAPI())
}
