//
//  ImmichAPI.swift
//  ImmichVisionProClient
//
//  Created by Julian Gray on 1/12/26.
//

import Foundation
import Combine
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Thumbnail Cache

/// In-memory cache for thumbnails with prefetching support
@MainActor
class ThumbnailCache: ObservableObject {
    static let shared = ThumbnailCache()

    private var cache: [String: UIImage] = [:]
    private var pendingPrefetches: Set<String> = []
    private let maxCacheSize = 500  // Maximum number of thumbnails to keep in memory

    private init() {}

    /// Get a cached thumbnail if available
    func get(_ assetId: String) -> UIImage? {
        return cache[assetId]
    }

    /// Store a thumbnail in the cache
    func set(_ assetId: String, image: UIImage) {
        // Evict oldest entries if cache is too large
        if cache.count >= maxCacheSize {
            // Remove roughly 20% of entries
            let keysToRemove = Array(cache.keys.prefix(maxCacheSize / 5))
            for key in keysToRemove {
                cache.removeValue(forKey: key)
            }
        }
        cache[assetId] = image
    }

    /// Check if an asset is already cached or being fetched
    func isCachedOrPending(_ assetId: String) -> Bool {
        return cache[assetId] != nil || pendingPrefetches.contains(assetId)
    }

    /// Prefetch thumbnails for the given asset IDs
    func prefetch(assetIds: [String], api: ImmichAPI) {
        for assetId in assetIds {
            // Skip if already cached or pending
            guard !isCachedOrPending(assetId) else { continue }

            pendingPrefetches.insert(assetId)

            Task {
                guard let url = api.getThumbnailURL(assetId: assetId) else {
                    pendingPrefetches.remove(assetId)
                    return
                }

                do {
                    let image = try await api.loadImage(from: url)
                    self.set(assetId, image: image)
                    pendingPrefetches.remove(assetId)
                } catch {
                    pendingPrefetches.remove(assetId)
                }
            }
        }
    }

    /// Clear the cache
    func clear() {
        cache.removeAll()
        pendingPrefetches.removeAll()
    }
}

// Columnar response format from timeline bucket endpoint (Immich API)
struct ColumnarBucketResponse: Codable {
    let id: [String]
    let ownerId: [String?]?
    let isImage: [Bool]?  // true = image, false = video
    let fileCreatedAt: [String?]?
    let isFavorite: [Bool?]?
    let duration: [String?]?
    let ratio: [Double?]?  // Aspect ratio (width/height)
    let projectionType: [String?]?  // For spatial/360 content

    func toAssets() -> [Asset] {
        print("📊 Columnar parsing - id count: \(id.count), isImage count: \(isImage?.count ?? 0)")

        var assets: [Asset] = []
        for i in 0..<id.count {
            // isImage: true = IMAGE, false = VIDEO
            let isImg = isImage?[safe: i] ?? true
            let assetType: Asset.AssetType = isImg ? .IMAGE : .VIDEO

            // Debug first few assets
            if i < 3 {
                let ratioValue = ratio?[safe: i].flatMap { $0 } ?? 0
                print("   Asset[\(i)]: id=\(id[i].prefix(8))..., isImage=\(isImg), type=\(assetType), ratio=\(ratioValue)")
            }

            let asset = Asset(
                id: id[i],
                deviceAssetId: nil,
                ownerId: ownerId?[safe: i] ?? nil,
                deviceId: nil,
                type: assetType,
                originalPath: nil,
                originalFileName: "asset_\(i)",  // Generate a placeholder name
                fileCreatedAt: fileCreatedAt?[safe: i] ?? nil,
                fileModifiedAt: nil,
                updatedAt: nil,
                isFavorite: isFavorite?[safe: i] ?? nil,
                isArchived: nil,
                duration: duration?[safe: i] ?? nil,
                exifInfo: nil,
                ratio: ratio?[safe: i] ?? nil,
                projectionType: projectionType?[safe: i] ?? nil
            )
            assets.append(asset)
        }
        return assets
    }
}

// Safe array subscript extension
extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

// Memory response from Immich API (On This Day feature)
struct Memory: Codable, Identifiable, Hashable {
    let id: String
    let createdAt: String?
    let updatedAt: String?
    let memoryAt: String?
    let seenAt: String?
    let ownerId: String?
    let type: String  // "on_this_day"
    let data: MemoryData?
    let isSaved: Bool?
    let assets: [Asset]

    struct MemoryData: Codable, Hashable {
        let year: Int?
    }

    var yearsAgo: Int? {
        guard let year = data?.year else { return nil }
        let currentYear = Calendar.current.component(.year, from: Date())
        return currentYear - year
    }

    var displayTitle: String {
        if let years = yearsAgo {
            if years == 1 {
                return "1 year ago"
            } else {
                return "\(years) years ago"
            }
        }
        return "Memory"
    }

    // Hashable conformance using just the id
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: Memory, rhs: Memory) -> Bool {
        lhs.id == rhs.id
    }
}

struct TimeBucket: Codable, Identifiable {
    let timeBucket: String
    let count: Int

    var id: String { timeBucket }

    var year: Int? {
        let components = timeBucket.split(separator: "-")
        guard let yearStr = components.first else { return nil }
        return Int(yearStr)
    }

    var displayName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        if let date = formatter.date(from: timeBucket + "-01") {
            formatter.dateFormat = "MMMM yyyy"
            return formatter.string(from: date)
        }
        return timeBucket
    }
}

// Login response from Immich API
struct LoginResponse: Codable {
    let accessToken: String
    let userId: String
    let userEmail: String
    let name: String
    let isAdmin: Bool
    let profileImagePath: String?
}

// Login error response
struct LoginErrorResponse: Codable {
    let message: String
    let statusCode: Int?
    let error: String?
}

enum LoginError: LocalizedError {
    case invalidURL
    case invalidResponse
    case invalidCredentials
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid server URL"
        case .invalidResponse:
            return "Invalid response from server"
        case .invalidCredentials:
            return "Incorrect email or password"
        case .serverError(let message):
            return message
        }
    }
}

@MainActor
class ImmichAPI: ObservableObject {
    @Published var albums: [Album] = []
    @Published var timeBuckets: [TimeBucket] = []
    @Published var hiddenAssetIds: Set<String> = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var isLoggedIn = false
    @Published var currentUserEmail: String?
    @Published var currentUserName: String?

    private var baseURL: String = ""
    private var accessToken: String = ""

    private let keychain = KeychainHelper.shared

    init() {
        // Try to restore session from keychain
        restoreSession()
    }

    // MARK: - Authentication

    /// Restore session from keychain if available
    private func restoreSession() {
        if let serverURL = keychain.getServerURL(),
           let token = keychain.getAccessToken() {
            self.baseURL = serverURL
            self.accessToken = token
            self.currentUserEmail = keychain.getUserEmail()
            self.isLoggedIn = true
        }
    }

    /// Login with email and password
    @MainActor
    func login(serverURL: String, email: String, password: String) async throws {
        let trimmedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard let url = URL(string: "\(trimmedURL)/api/auth/login") else {
            throw LoginError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let body = ["email": email, "password": password]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LoginError.invalidResponse
        }

        if httpResponse.statusCode == 201 || httpResponse.statusCode == 200 {
            // Success
            let loginResponse = try JSONDecoder().decode(LoginResponse.self, from: data)

            // Save to keychain
            _ = keychain.saveAccessToken(loginResponse.accessToken)
            keychain.saveServerURL(trimmedURL)
            keychain.saveUserEmail(loginResponse.userEmail)

            // Update state
            self.baseURL = trimmedURL
            self.accessToken = loginResponse.accessToken
            self.currentUserEmail = loginResponse.userEmail
            self.currentUserName = loginResponse.name
            self.isLoggedIn = true

            // Login successful
        } else if httpResponse.statusCode == 401 {
            throw LoginError.invalidCredentials
        } else {
            // Try to parse error message
            if let errorResponse = try? JSONDecoder().decode(LoginErrorResponse.self, from: data) {
                throw LoginError.serverError(errorResponse.message)
            }
            throw LoginError.serverError("Server returned status \(httpResponse.statusCode)")
        }
    }

    /// Logout and clear stored credentials
    @MainActor
    func logout() {
        // Clear keychain
        keychain.clearAll()

        // Clear state
        self.baseURL = ""
        self.accessToken = ""
        self.currentUserEmail = nil
        self.currentUserName = nil
        self.isLoggedIn = false
        self.albums = []
        self.timeBuckets = []
        self.errorMessage = nil
    }

    /// Check if the current session is still valid
    @MainActor
    func validateSession() async -> Bool {
        guard isLoggedIn, !accessToken.isEmpty else { return false }

        // Try to fetch user info to validate the token
        guard let url = URL(string: "\(baseURL)/api/users/me") else { return false }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    return true
                } else if httpResponse.statusCode == 401 {
                    // Token expired or invalid, logout
                    logout()
                    return false
                }
            }
        } catch {
            print("❌ Session validation failed: \(error)")
        }

        return false
    }

    // MARK: - Legacy API Key Support (for backwards compatibility)

    func configure(baseURL: String, apiKey: String) {
        self.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.accessToken = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isLoggedIn = true
    }
    
    @MainActor
    func fetchAlbums() async {
        isLoading = true
        errorMessage = nil
        
        guard let url = URL(string: "\(baseURL)/api/albums") else {
            errorMessage = "Invalid server URL"
            isLoading = false
            return
        }
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                errorMessage = "Invalid response from server"
                isLoading = false
                return
            }

            if httpResponse.statusCode == 401 {
                errorMessage = "Session expired. Please log in again."
                logout()
                isLoading = false
                return
            }
            
            if httpResponse.statusCode != 200 {
                errorMessage = "Server error: \(httpResponse.statusCode)"
                isLoading = false
                return
            }
            
            let decoder = JSONDecoder()
            let fetchedAlbums = try decoder.decode([Album].self, from: data)
            self.albums = fetchedAlbums
            
        } catch {
            errorMessage = "Failed to fetch albums: \(error.localizedDescription)"
        }
        
        isLoading = false
    }
    
    func fetchAlbumDetails(albumId: String) async throws -> AlbumDetails {
        guard let url = URL(string: "\(baseURL)/api/albums/\(albumId)") else {
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        let (data, _) = try await URLSession.shared.data(for: request)
        let decoder = JSONDecoder()
        return try decoder.decode(AlbumDetails.self, from: data)
    }
    
    func getThumbnailURL(assetId: String) -> URL? {
        return URL(string: "\(baseURL)/api/assets/\(assetId)/thumbnail")
    }

    /// Get preview quality image URL (1440px - good for viewing, faster to load)
    func getPreviewURL(assetId: String) -> URL? {
        return URL(string: "\(baseURL)/api/assets/\(assetId)/thumbnail?size=preview")
    }

    func getOriginalImageURL(assetId: String) -> URL? {
        return URL(string: "\(baseURL)/api/assets/\(assetId)/original")
    }

    /// Get video playback URL with API key as query parameter (for AVPlayer streaming)
    func getVideoPlaybackURL(assetId: String) -> URL? {
        return URL(string: "\(baseURL)/api/assets/\(assetId)/video/playback")
    }

    /// Get video URL for direct streaming
    func getStreamableVideoURL(assetId: String) -> URL? {
        return URL(string: "\(baseURL)/api/assets/\(assetId)/video/playback")
    }

    /// Get the current access token for authenticated requests (e.g., video streaming)
    func getAccessToken() -> String {
        return accessToken
    }
    
    func loadImage(from url: URL) async throws -> UIImage {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await URLSession.shared.data(for: request)

        guard let image = UIImage(data: data) else {
            throw URLError(.cannotDecodeContentData)
        }

        return image
    }

    /// Load raw data from a URL (for offline storage)
    func loadImageData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }

    @MainActor
    func fetchTimeBuckets() async {
        // Don't refetch if we already have data
        guard timeBuckets.isEmpty else {
            print("📦 Time buckets already loaded: \(timeBuckets.count) buckets")
            return
        }

        print("🔄 Fetching time buckets from: \(baseURL)/api/timeline/buckets")

        // Immich API requires these params for timeline buckets
        guard let url = URL(string: "\(baseURL)/api/timeline/buckets?size=MONTH&isArchived=false") else {
            print("❌ Invalid URL for time buckets")
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                print("📦 Time buckets response status: \(httpResponse.statusCode)")
                if httpResponse.statusCode != 200 {
                    print("❌ Error response: \(String(data: data, encoding: .utf8) ?? "unknown")")
                    return
                }
            }

            // Debug: print raw response
            if let rawString = String(data: data, encoding: .utf8) {
                print("📄 Raw response (first 500 chars): \(String(rawString.prefix(500)))")
            }

            let decoder = JSONDecoder()
            self.timeBuckets = try decoder.decode([TimeBucket].self, from: data)
            print("✅ Loaded \(timeBuckets.count) time buckets")

            // Debug: print first few buckets
            for bucket in timeBuckets.prefix(3) {
                print("   - \(bucket.timeBucket): \(bucket.count) items, year: \(bucket.year ?? 0)")
            }
            print("   Years available: \(sortedYears)")
        } catch {
            print("❌ Error fetching time buckets: \(error)")
        }
    }

    func fetchAssetsForTimeBucket(timeBucket: String) async throws -> [Asset] {
        guard let url = URL(string: "\(baseURL)/api/timeline/bucket?size=MONTH&timeBucket=\(timeBucket)&isArchived=false") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse {
            print("📦 Bucket \(timeBucket) response: \(httpResponse.statusCode)")
        }

        // Debug: print response structure (keys only)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            print("📄 Bucket response keys: \(json.keys.sorted())")
            // Print a sample value for each key
            for key in json.keys.prefix(5) {
                if let arr = json[key] as? [Any], let first = arr.first {
                    print("   \(key)[0] = \(first)")
                }
            }
        }

        let decoder = JSONDecoder()

        // Try to decode as columnar format (Immich API returns columns of arrays)
        do {
            let columnar = try decoder.decode(ColumnarBucketResponse.self, from: data)
            let assets = columnar.toAssets()
            print("✅ Parsed \(assets.count) assets from columnar format")
            return assets
        } catch {
            print("⚠️ Columnar decode failed: \(error)")
        }

        // Fall back to array format (older Immich API format)
        print("⚠️ Trying fallback array format...")
        return try decoder.decode([Asset].self, from: data)
    }

    var yearGroups: [Int: [TimeBucket]] {
        Dictionary(grouping: timeBuckets) { $0.year ?? 0 }
    }

    var sortedYears: [Int] {
        yearGroups.keys.sorted(by: >)
    }

    /// Fetch full asset details including EXIF data
    func fetchAssetDetails(assetId: String) async throws -> Asset {
        guard let url = URL(string: "\(baseURL)/api/assets/\(assetId)") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse {
            print("📷 Asset details response: \(httpResponse.statusCode)")
        }

        let decoder = JSONDecoder()
        return try decoder.decode(Asset.self, from: data)
    }

    /// Fetch "On This Day" memories
    func fetchMemories() async throws -> [Memory] {
        guard let url = URL(string: "\(baseURL)/api/memories") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse {
            print("📸 Memories response: \(httpResponse.statusCode)")
            if httpResponse.statusCode != 200 {
                print("❌ Memories error: \(String(data: data, encoding: .utf8) ?? "unknown")")
                return []
            }
        }

        let decoder = JSONDecoder()
        let memories = try decoder.decode([Memory].self, from: data)
        print("✅ Loaded \(memories.count) memories")
        return memories
    }

    // MARK: - Upload

    struct UploadResponse: Codable {
        let id: String
        let status: String  // "created" or "duplicate"
    }

    /// Upload an asset to Immich
    func uploadAsset(
        data: Data,
        filename: String,
        createdAt: Date,
        modifiedAt: Date,
        isFavorite: Bool = false
    ) async throws -> UploadResponse {
        guard let url = URL(string: "\(baseURL)/api/assets") else {
            throw URLError(.badURL)
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        // Build multipart form data
        var body = Data()

        // Device Asset ID (unique identifier)
        let deviceAssetId = "\(filename)-\(Int(modifiedAt.timeIntervalSince1970))"
        body.appendMultipartField(named: "deviceAssetId", value: deviceAssetId, boundary: boundary)

        // Device ID
        body.appendMultipartField(named: "deviceId", value: "VisionPro", boundary: boundary)

        // Timestamps (ISO8601 format)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        body.appendMultipartField(named: "fileCreatedAt", value: formatter.string(from: createdAt), boundary: boundary)
        body.appendMultipartField(named: "fileModifiedAt", value: formatter.string(from: modifiedAt), boundary: boundary)

        // Is Favorite
        body.appendMultipartField(named: "isFavorite", value: isFavorite ? "true" : "false", boundary: boundary)

        // File data
        let mimeType = mimeTypeForFilename(filename)
        body.appendMultipartFile(named: "assetData", filename: filename, mimeType: mimeType, data: data, boundary: boundary)

        // End boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (responseData, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        print("📤 Upload response: \(httpResponse.statusCode)")

        if httpResponse.statusCode == 200 || httpResponse.statusCode == 201 {
            let decoder = JSONDecoder()
            return try decoder.decode(UploadResponse.self, from: responseData)
        } else {
            let errorMessage = String(data: responseData, encoding: .utf8) ?? "Unknown error"
            print("❌ Upload error: \(errorMessage)")
            throw URLError(.badServerResponse)
        }
    }

    // MARK: - Asset Management

    /// Delete multiple assets at once
    func deleteAssets(assetIds: [String]) async throws {
        guard !assetIds.isEmpty else { return }

        guard let url = URL(string: "\(baseURL)/api/assets") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let body = ["ids": assetIds]
        request.httpBody = try JSONEncoder().encode(body)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        if httpResponse.statusCode != 204 && httpResponse.statusCode != 200 {
            print("❌ Delete failed with status: \(httpResponse.statusCode)")
            throw URLError(.badServerResponse)
        }

        print("🗑️ Deleted \(assetIds.count) asset(s)")
    }

    /// Delete a single asset (convenience wrapper)
    func deleteAsset(assetId: String) async throws {
        try await deleteAssets(assetIds: [assetId])
    }

    /// Add assets to an album
    func addAssetsToAlbum(albumId: String, assetIds: [String]) async throws {
        guard let url = URL(string: "\(baseURL)/api/albums/\(albumId)/assets") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let body = ["ids": assetIds]
        request.httpBody = try JSONEncoder().encode(body)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        if httpResponse.statusCode != 200 && httpResponse.statusCode != 201 {
            print("❌ Add to album failed with status: \(httpResponse.statusCode)")
            throw URLError(.badServerResponse)
        }

        print("📁 Added \(assetIds.count) asset(s) to album: \(albumId.prefix(8))...")
    }

    /// Remove asset from an album (doesn't delete the asset)
    func removeAssetFromAlbum(albumId: String, assetIds: [String]) async throws {
        guard let url = URL(string: "\(baseURL)/api/albums/\(albumId)/assets") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let body = ["ids": assetIds]
        request.httpBody = try JSONEncoder().encode(body)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        if httpResponse.statusCode != 200 && httpResponse.statusCode != 201 {
            print("❌ Remove from album failed with status: \(httpResponse.statusCode)")
            throw URLError(.badServerResponse)
        }

        print("📁 Removed \(assetIds.count) asset(s) from album: \(albumId.prefix(8))...")
    }

    /// Rename an album
    func renameAlbum(albumId: String, newName: String) async throws {
        guard let url = URL(string: "\(baseURL)/api/albums/\(albumId)") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["albumName": newName]
        request.httpBody = try JSONEncoder().encode(body)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        if httpResponse.statusCode != 200 {
            print("❌ Rename album failed with status: \(httpResponse.statusCode)")
            throw URLError(.badServerResponse)
        }

        // Update local list
        if let index = albums.firstIndex(where: { $0.id == albumId }) {
            let old = albums[index]
            albums[index] = Album(
                id: old.id,
                albumName: newName,
                description: old.description,
                albumThumbnailAssetId: old.albumThumbnailAssetId,
                assetCount: old.assetCount,
                owner: old.owner
            )
        }

        print("✏️ Renamed album \(albumId.prefix(8))... to \"\(newName)\"")
    }

    /// Delete an album (does not delete the assets inside it)
    func deleteAlbum(albumId: String) async throws {
        guard let url = URL(string: "\(baseURL)/api/albums/\(albumId)") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        if httpResponse.statusCode != 200 && httpResponse.statusCode != 204 {
            print("❌ Delete album failed with status: \(httpResponse.statusCode)")
            throw URLError(.badServerResponse)
        }

        // Remove from local list
        albums.removeAll { $0.id == albumId }

        print("🗑️ Deleted album: \(albumId.prefix(8))...")
    }

    /// Create a new album, optionally seeding it with asset IDs
    @discardableResult
    func createAlbum(name: String, assetIds: [String] = []) async throws -> Album {
        guard let url = URL(string: "\(baseURL)/api/albums") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var body: [String: Any] = ["albumName": name]
        if !assetIds.isEmpty {
            body["assetIds"] = assetIds
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 201 else {
            print("❌ Create album failed with status: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            throw URLError(.badServerResponse)
        }

        let decoder = JSONDecoder()
        let newAlbum = try decoder.decode(Album.self, from: data)

        // Prepend to local list so it shows up at the top
        albums.insert(newAlbum, at: 0)

        print("➕ Created album \"\(name)\" with id: \(newAlbum.id.prefix(8))...")
        return newAlbum
    }

    /// Update asset visibility (e.g., move to locked folder)
    func updateAssetVisibility(assetIds: [String], visibility: String) async throws {
        guard let url = URL(string: "\(baseURL)/api/assets") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let body: [String: Any] = ["ids": assetIds, "visibility": visibility]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        if httpResponse.statusCode != 200 && httpResponse.statusCode != 204 {
            print("❌ Update visibility failed with status: \(httpResponse.statusCode)")
            throw URLError(.badServerResponse)
        }

        print("🔒 Updated visibility to '\(visibility)' for \(assetIds.count) asset(s)")

        if visibility == "locked" {
            assetIds.forEach { hiddenAssetIds.insert($0) }
        } else if visibility == "timeline" {
            assetIds.forEach { hiddenAssetIds.remove($0) }
        }
    }

    /// Fetch assets with locked visibility (hidden folder)
    func fetchLockedAssets() async throws -> [Asset] {
        guard let url = URL(string: "\(baseURL)/api/search/metadata") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let body: [String: String] = ["visibility": "locked"]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse {
            print("🔒 Locked assets response: \(httpResponse.statusCode)")
        }

        // Debug: log raw response for troubleshooting decode failures
        if let rawString = String(data: data, encoding: .utf8) {
            print("🔒 Raw locked response (first 500 chars): \(String(rawString.prefix(500)))")
        }

        // The search endpoint returns { assets: { items: [Asset], ... }, ... }
        struct SearchResponse: Decodable {
            struct AssetResult: Decodable {
                let items: [Asset]
            }
            let assets: AssetResult
        }

        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        print("🔒 Found \(decoded.assets.items.count) locked asset(s)")
        return decoded.assets.items
    }

    // MARK: - Locked Folder Auth

    struct AuthStatusResponse: Decodable {
        let pinCode: Bool       // whether user has a PIN set up
        let password: Bool
        let isElevated: Bool    // whether current session can see locked assets
        let pinExpiresAt: String?
    }

    /// Check the current auth/PIN status for the session
    func getAuthStatus() async throws -> AuthStatusResponse {
        guard let url = URL(string: "\(baseURL)/api/auth/status") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        print("🔐 Auth status response: \(httpResponse.statusCode)")

        guard httpResponse.statusCode == 200 else {
            throw URLError(.userAuthenticationRequired)
        }

        return try JSONDecoder().decode(AuthStatusResponse.self, from: data)
    }

    /// Unlock the session with a PIN code to access locked assets
    func unlockSession(pinCode: String) async throws {
        guard let url = URL(string: "\(baseURL)/api/auth/session/unlock") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let body = ["pinCode": pinCode]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        if httpResponse.statusCode == 200 || httpResponse.statusCode == 204 {
            print("🔓 Session unlocked successfully")
        } else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            print("❌ Unlock failed (\(httpResponse.statusCode)): \(errorMessage)")
            throw URLError(.userAuthenticationRequired)
        }
    }

    /// Lock the session to revoke access to locked assets
    func lockSession() async throws {
        guard let url = URL(string: "\(baseURL)/api/auth/session/lock") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        if httpResponse.statusCode == 200 || httpResponse.statusCode == 204 {
            print("🔒 Session locked successfully")
        } else {
            print("❌ Lock session failed with status: \(httpResponse.statusCode)")
            throw URLError(.badServerResponse)
        }
    }

    private func mimeTypeForFilename(_ filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg":
            return "image/jpeg"
        case "png":
            return "image/png"
        case "heic":
            return "image/heic"
        case "heif":
            return "image/heif"
        case "gif":
            return "image/gif"
        case "webp":
            return "image/webp"
        case "mov":
            return "video/quicktime"
        case "mp4":
            return "video/mp4"
        case "m4v":
            return "video/x-m4v"
        default:
            return "application/octet-stream"
        }
    }
}

// MARK: - Data Multipart Helpers

extension Data {
    mutating func appendMultipartField(named name: String, value: String, boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }

    mutating func appendMultipartFile(named name: String, filename: String, mimeType: String, data: Data, boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        append(data)
        append("\r\n".data(using: .utf8)!)
    }
}
