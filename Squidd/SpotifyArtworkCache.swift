import Foundation
import ImageIO
import CoreGraphics

protocol SpotifyArtworkLoading: Sendable {
    func image(for url: URL) async throws -> CGImage
}

/// Shared by the two panels. Network and thumbnail decoding run off MainActor.
actor SpotifyArtworkCache: SpotifyArtworkLoading {
    private var images: [URL: CGImage] = [:]
    private var recency: [URL] = []
    private let capacity: Int
    private let session: URLSession
    init(capacity: Int = 40, session: URLSession = .shared) {
        self.capacity = max(1, capacity)
        self.session = session
    }
    var cachedCount: Int { images.count }
    func image(for url: URL) async throws -> CGImage {
        guard url.scheme == "https" else { throw URLError(.badURL) }
        if let cached = images[url] { touch(url); return cached }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.expectedContentLength <= 8 * 1024 * 1024 else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 8 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 300
              ] as CFDictionary) else { throw URLError(.cannotDecodeContentData) }
        try Task.checkCancellation()
        images[url] = image; touch(url)
        while recency.count > capacity {
            images.removeValue(forKey: recency.removeFirst())
        }
        return image
    }
    private func touch(_ url: URL) { recency.removeAll { $0 == url }; recency.append(url) }
}
