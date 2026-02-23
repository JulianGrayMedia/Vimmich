//
//  Album.swift
//  ImmichVisionProClient
//
//  Created by Julian Gray on 1/12/26.
//

import Foundation
import SwiftUI

struct Album: Identifiable, Codable, Hashable {
    static func == (lhs: Album, rhs: Album) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    let id: String
    let albumName: String
    let description: String?
    let assetCount: Int
    let albumThumbnailAssetId: String?
    let createdAt: String?
    let updatedAt: String?
    let owner: Owner

    struct Owner: Codable {
        let id: String
        let email: String?
        let name: String

        init(id: String, email: String? = nil, name: String) {
            self.id = id
            self.email = email
            self.name = name
        }
    }

    // Convenience initializer for virtual albums (Library, Years)
    init(id: String, albumName: String, description: String?, albumThumbnailAssetId: String?, assetCount: Int, owner: Owner) {
        self.id = id
        self.albumName = albumName
        self.description = description
        self.albumThumbnailAssetId = albumThumbnailAssetId
        self.assetCount = assetCount
        self.createdAt = nil
        self.updatedAt = nil
        self.owner = owner
    }
}

struct Asset: Identifiable, Codable, Hashable {
    static func == (lhs: Asset, rhs: Asset) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    let id: String
    let deviceAssetId: String?
    let ownerId: String?
    let deviceId: String?
    let type: AssetType
    let originalPath: String?
    let originalFileName: String
    let fileCreatedAt: String?
    let fileModifiedAt: String?
    let updatedAt: String?
    let isFavorite: Bool?
    let isArchived: Bool?
    let duration: String?
    let exifInfo: ExifInfo?
    let ratio: Double?  // Aspect ratio (width/height)
    let projectionType: String?  // For spatial content detection (e.g., "EQUIRECTANGULAR")

    // Initializer for creating Asset from columnar data
    init(id: String, deviceAssetId: String?, ownerId: String?, deviceId: String?,
         type: AssetType, originalPath: String?, originalFileName: String,
         fileCreatedAt: String?, fileModifiedAt: String?, updatedAt: String?,
         isFavorite: Bool?, isArchived: Bool?, duration: String?, exifInfo: ExifInfo?,
         ratio: Double? = nil, projectionType: String? = nil) {
        self.id = id
        self.deviceAssetId = deviceAssetId
        self.ownerId = ownerId
        self.deviceId = deviceId
        self.type = type
        self.originalPath = originalPath
        self.originalFileName = originalFileName
        self.fileCreatedAt = fileCreatedAt
        self.fileModifiedAt = fileModifiedAt
        self.updatedAt = updatedAt
        self.isFavorite = isFavorite
        self.isArchived = isArchived
        self.duration = duration
        self.exifInfo = exifInfo
        self.ratio = ratio
        self.projectionType = projectionType
    }

    /// Returns true if this asset is likely a spatial photo/video
    var isSpatial: Bool {
        // Spatial photos typically have specific projection types or aspect ratios
        // For now, we'll detect based on available metadata
        if let projection = projectionType, !projection.isEmpty {
            return true
        }
        return false
    }

    enum AssetType: String, Codable {
        case IMAGE
        case VIDEO
    }
    
    struct ExifInfo: Codable {
        let make: String?
        let model: String?
        let lensModel: String?
        let fNumber: Double?
        let focalLength: Double?
        let iso: Int?
        let latitude: Double?
        let longitude: Double?
        let city: String?
        let state: String?
        let country: String?

        // Custom decoder to handle type mismatches from API
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            make = try container.decodeIfPresent(String.self, forKey: .make)
            model = try container.decodeIfPresent(String.self, forKey: .model)
            lensModel = try container.decodeIfPresent(String.self, forKey: .lensModel)
            fNumber = try container.decodeIfPresent(Double.self, forKey: .fNumber)
            focalLength = try container.decodeIfPresent(Double.self, forKey: .focalLength)
            latitude = try container.decodeIfPresent(Double.self, forKey: .latitude)
            longitude = try container.decodeIfPresent(Double.self, forKey: .longitude)
            city = try container.decodeIfPresent(String.self, forKey: .city)
            state = try container.decodeIfPresent(String.self, forKey: .state)
            country = try container.decodeIfPresent(String.self, forKey: .country)

            // Handle iso which might come as Int, Double, or String
            if let intValue = try? container.decodeIfPresent(Int.self, forKey: .iso) {
                iso = intValue
            } else if let doubleValue = try? container.decodeIfPresent(Double.self, forKey: .iso) {
                iso = Int(doubleValue)
            } else if let stringValue = try? container.decodeIfPresent(String.self, forKey: .iso),
                      let intValue = Int(stringValue) {
                iso = intValue
            } else {
                iso = nil
            }
        }

        private enum CodingKeys: String, CodingKey {
            case make, model, lensModel, fNumber, focalLength, iso
            case latitude, longitude, city, state, country
        }
    }
}

struct AlbumDetails: Codable {
    let id: String
    let albumName: String
    let description: String?
    let assetCount: Int
    var assets: [Asset]
    let owner: Album.Owner
}
