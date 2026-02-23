//
//  PhotoDetailView.swift
//  ImmichVisionProClient
//
//  Created by Julian Gray on 1/12/26.
//

import SwiftUI
import RealityKit
import ImageIO

struct PhotoDetailView: View {
    let asset: Asset
    @EnvironmentObject var api: ImmichAPI
    @State private var imageData: Data?
    @State private var isLoading = true
    @State private var isSpatial = false
    @State private var leftImage: CGImage?
    @State private var rightImage: CGImage?
    
    var body: some View {
        ZStack {
            if let data = imageData {
                if isSpatial && leftImage != nil {
                    VStack(spacing: 20) {
                        // Preview of the left eye view
                        if let cgImage = leftImage {
                            Image(decorative: cgImage, scale: 1.0)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 400)
                                .cornerRadius(12)
                        }
                        
                        VStack(spacing: 12) {
                            HStack {
                                Image(systemName: "view.3d")
                                    .font(.title2)
                                Text("Spatial Photo Detected")
                                    .font(.title2)
                                    .fontWeight(.semibold)
                            }
                            
                            Text("Open from album view to see in immersive 3D")
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                    }
                    .padding()
                } else if let uiImage = UIImage(data: data) {
                    // Regular 2D photo
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                }
            } else if isLoading {
                ProgressView("Loading photo...")
                    .font(.title)
            } else {
                Text("Failed to load photo")
                    .foregroundStyle(.red)
            }
        }
        .navigationTitle(asset.originalFileName)
        .task {
            await loadFullImage()
        }
    }
    
    private func loadFullImage() async {
        guard let url = api.getOriginalImageURL(assetId: asset.id) else {
            isLoading = false
            return
        }
        
        do {
            var request = URLRequest(url: url)
            request.setValue("Bearer \(api.getAccessToken())", forHTTPHeaderField: "Authorization")
            
            let (data, _) = try await URLSession.shared.data(for: request)
            imageData = data
            await analyzeSpatialPhoto(data: data)
            isLoading = false
        } catch {
            print("Error loading image: \(error)")
            isLoading = false
        }
    }
    
    private func analyzeSpatialPhoto(data: Data) async {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else {
            return
        }
        
        let imageCount = CGImageSourceGetCount(imageSource)
        print("Image has \(imageCount) frame(s)")
        
        if imageCount > 1 {
            if let left = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
               let right = CGImageSourceCreateImageAtIndex(imageSource, 1, nil) {
                leftImage = left
                rightImage = right
                isSpatial = true
                print("Successfully loaded spatial photo stereo pair")
            }
        }
    }
}
