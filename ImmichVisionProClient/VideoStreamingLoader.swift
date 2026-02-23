//
//  VideoStreamingLoader.swift
//  ImmichVisionProClient
//
//  Created by Julian Gray on 1/22/26.
//

import Foundation
import AVFoundation
import UniformTypeIdentifiers

/// Handles streaming video playback with custom authentication headers
/// Uses AVAssetResourceLoaderDelegate to intercept requests and add API key
/// Supports byte-range requests for proper streaming and seeking
class VideoStreamingLoader: NSObject, AVAssetResourceLoaderDelegate {
    private let accessToken: String
    private let originalURL: URL
    private var session: URLSession?

    // Track active requests and their associated data tasks
    private var activeRequests: [AVAssetResourceLoadingRequest: RequestHandler] = [:]

    // Cached content info from first request
    private var cachedContentLength: Int64?
    private var cachedContentType: String?

    // Pre-buffered data (first portion of video, loaded in advance)
    private var preBufferedData: Data?

    // Custom URL scheme prefix
    static let customScheme = "immich-streaming"

    init(accessToken: String, originalURL: URL, preBufferedData: Data? = nil, preBufferedContentLength: Int64? = nil, preBufferedContentType: String? = nil) {
        self.accessToken = accessToken
        self.originalURL = originalURL
        self.preBufferedData = preBufferedData
        super.init()

        // If we have pre-buffered content info, cache it immediately
        if let contentLength = preBufferedContentLength, contentLength > 0 {
            self.cachedContentLength = contentLength
            // Convert MIME type to UTI - AVPlayer expects UTI, not MIME type
            if let mimeType = preBufferedContentType,
               let uti = UTType(mimeType: mimeType) {
                self.cachedContentType = uti.identifier
            }
            let dataSize = (preBufferedData?.count ?? 0) / 1024
            print("📦 VideoStreamingLoader initialized with \(dataSize)KB pre-buffered data, content length: \(contentLength)")
        } else if let preBuffered = preBufferedData {
            print("📦 VideoStreamingLoader initialized with \(preBuffered.count / 1024)KB pre-buffered data (no content info)")
        }

        // Create a shared session
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    deinit {
        session?.invalidateAndCancel()
    }

    /// Convert an HTTPS URL to our custom scheme for interception
    static func customURL(from originalURL: URL) -> URL? {
        guard var components = URLComponents(url: originalURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let originalScheme = components.scheme ?? "https"
        components.scheme = customScheme
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "_originalScheme", value: originalScheme))
        components.queryItems = queryItems
        return components.url
    }

    /// Convert our custom scheme URL back to the original HTTPS URL
    private func originalURL(from customURL: URL) -> URL? {
        guard var components = URLComponents(url: customURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let originalScheme = components.queryItems?.first(where: { $0.name == "_originalScheme" })?.value ?? "https"
        components.queryItems = components.queryItems?.filter { $0.name != "_originalScheme" }
        if components.queryItems?.isEmpty == true {
            components.queryItems = nil
        }
        components.scheme = originalScheme
        return components.url
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                       shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {

        guard let requestURL = loadingRequest.request.url,
              requestURL.scheme == VideoStreamingLoader.customScheme else {
            return false
        }

        guard let actualURL = originalURL(from: requestURL) else {
            return false
        }

        // Create request handler for this loading request
        let handler = RequestHandler(
            loadingRequest: loadingRequest,
            actualURL: actualURL,
            accessToken: accessToken,
            session: session!,
            cachedContentLength: cachedContentLength,
            cachedContentType: cachedContentType,
            preBufferedData: preBufferedData
        ) { [weak self] contentLength, contentType in
            // Cache content info for future requests
            self?.cachedContentLength = contentLength
            self?.cachedContentType = contentType
        }

        activeRequests[loadingRequest] = handler
        handler.start()

        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                       didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        if let handler = activeRequests.removeValue(forKey: loadingRequest) {
            handler.cancel()
        }
    }
}

// MARK: - Request Handler

/// Handles a single AVAssetResourceLoadingRequest with its own data task
private class RequestHandler: NSObject, URLSessionDataDelegate {
    private let loadingRequest: AVAssetResourceLoadingRequest
    private let actualURL: URL
    private let accessToken: String
    private let session: URLSession
    private var dataTask: URLSessionDataTask?
    private var receivedData = Data()
    private var response: HTTPURLResponse?
    private var contentLength: Int64 = 0
    private var requestedOffset: Int64 = 0

    // Pre-buffered data from background loading
    private let preBufferedData: Data?

    // Callback to cache content info
    private let onContentInfo: (Int64, String?) -> Void

    init(loadingRequest: AVAssetResourceLoadingRequest,
         actualURL: URL,
         accessToken: String,
         session: URLSession,
         cachedContentLength: Int64?,
         cachedContentType: String?,
         preBufferedData: Data?,
         onContentInfo: @escaping (Int64, String?) -> Void) {
        self.loadingRequest = loadingRequest
        self.actualURL = actualURL
        self.accessToken = accessToken
        self.session = session
        self.preBufferedData = preBufferedData
        self.onContentInfo = onContentInfo
        super.init()

        // Use cached content info if available
        if let cachedLength = cachedContentLength {
            self.contentLength = cachedLength
        }

        // Fill content info immediately if we have cached data
        if let contentInfoRequest = loadingRequest.contentInformationRequest,
           let cachedLength = cachedContentLength {
            contentInfoRequest.isByteRangeAccessSupported = true
            contentInfoRequest.contentLength = cachedLength
            if let cachedType = cachedContentType {
                contentInfoRequest.contentType = cachedType
            }
        }
    }

    func start() {
        // Check if we can serve from pre-buffered data
        // IMPORTANT: Only use pre-buffer if we have cached content info,
        // otherwise AVPlayer can't determine the video format
        if let dataRequest = loadingRequest.dataRequest,
           let preBuffered = preBufferedData,
           contentLength > 0 {  // Only use pre-buffer if we know the content length
            let requestedStart = Int(dataRequest.requestedOffset)
            let requestedLength = dataRequest.requestedLength
            let requestedEnd = requestedStart + requestedLength

            // If entire range is within pre-buffered data, serve immediately
            if requestedStart < preBuffered.count {
                let availableEnd = min(requestedEnd, preBuffered.count)
                let availableRange = requestedStart..<availableEnd
                let dataToServe = preBuffered.subdata(in: availableRange)

                dataRequest.respond(with: dataToServe)
                print("📦 Served \(formatBytes(Int64(dataToServe.count))) from pre-buffer (offset: \(requestedStart))")

                // If we served everything requested, finish
                if availableEnd >= requestedEnd || dataRequest.requestsAllDataToEndOfResource == false {
                    if availableEnd >= requestedEnd {
                        loadingRequest.finishLoading()
                        return
                    }
                }

                // Need more data beyond pre-buffer, continue with network request
                // Adjust offset to start where pre-buffer ends
                requestedOffset = Int64(availableEnd)
            }
        }

        var request = URLRequest(url: actualURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        // Handle byte-range requests
        if let dataRequest = loadingRequest.dataRequest {
            if requestedOffset == 0 {
                requestedOffset = dataRequest.requestedOffset
            }
            let length = dataRequest.requestedLength

            if dataRequest.requestsAllDataToEndOfResource {
                request.setValue("bytes=\(requestedOffset)-", forHTTPHeaderField: "Range")
                print("📼 Range request: bytes=\(requestedOffset)- (to end)")
            } else {
                let endOffset = dataRequest.requestedOffset + Int64(length) - 1
                request.setValue("bytes=\(requestedOffset)-\(endOffset)", forHTTPHeaderField: "Range")
                print("📼 Range request: bytes=\(requestedOffset)-\(endOffset) (\(formatBytes(Int64(length))))")
            }
        } else {
            print("📼 Full content request (content info only)")
        }

        // Create session with delegate for this request
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegateSession = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        dataTask = delegateSession.dataTask(with: request)
        dataTask?.resume()
    }

    func cancel() {
        dataTask?.cancel()
        dataTask = nil
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let httpResponse = response as? HTTPURLResponse else {
            print("❌ Invalid response type")
            loadingRequest.finishLoading(with: NSError(domain: "VideoStreaming", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"]))
            completionHandler(.cancel)
            return
        }

        self.response = httpResponse

        // Check for auth errors
        if httpResponse.statusCode == 401 {
            print("❌ Authentication failed (401)")
            loadingRequest.finishLoading(with: NSError(domain: "VideoStreaming", code: 401, userInfo: [NSLocalizedDescriptionKey: "Authentication failed"]))
            completionHandler(.cancel)
            return
        }

        // Accept 200 (full content) or 206 (partial content)
        guard httpResponse.statusCode == 200 || httpResponse.statusCode == 206 else {
            print("❌ HTTP error: \(httpResponse.statusCode)")
            loadingRequest.finishLoading(with: NSError(domain: "VideoStreaming", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode)"]))
            completionHandler(.cancel)
            return
        }

        // Get content length from Content-Range or Content-Length header
        if let rangeHeader = httpResponse.value(forHTTPHeaderField: "Content-Range"),
           let totalStr = rangeHeader.split(separator: "/").last,
           let total = Int64(totalStr) {
            contentLength = total
        } else if httpResponse.expectedContentLength > 0 {
            contentLength = httpResponse.expectedContentLength
        }

        // Fill content information
        if let contentInfoRequest = loadingRequest.contentInformationRequest {
            contentInfoRequest.isByteRangeAccessSupported = true
            contentInfoRequest.contentLength = contentLength

            if let mimeType = httpResponse.mimeType,
               let uti = UTType(mimeType: mimeType) {
                contentInfoRequest.contentType = uti.identifier
                onContentInfo(contentLength, uti.identifier)
            } else {
                onContentInfo(contentLength, nil)
            }
        }

        print("📊 Response: \(httpResponse.statusCode), total size: \(formatBytes(contentLength))")
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        receivedData.append(data)

        // Feed data to AVPlayer
        if let dataRequest = loadingRequest.dataRequest {
            dataRequest.respond(with: data)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            if (error as NSError).code != NSURLErrorCancelled {
                print("❌ Request error: \(error.localizedDescription)")
                loadingRequest.finishLoading(with: error)
            }
        } else {
            print("✅ Request complete: \(formatBytes(Int64(receivedData.count))) received")
            loadingRequest.finishLoading()
        }

        session.invalidateAndCancel()
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
