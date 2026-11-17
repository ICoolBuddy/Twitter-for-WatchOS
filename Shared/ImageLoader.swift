import Foundation
import ImageIO
import SwiftUI
import CoreGraphics

/// Memory-conscious image loading: downloads with a plain URLSession (no cookies),
/// decodes with ImageIO downsampling to the display size, caches decoded CGImages in
/// an NSCache with a byte budget. Requests are cancelled when views disappear.
final class ImageLoader: @unchecked Sendable {
    static let shared = ImageLoader()

    private let cache = NSCache<NSString, CGImageBox>()
    private let session: URLSession

    final class CGImageBox {
        let image: CGImage
        init(_ i: CGImage) { image = i }
    }

    private init() {
        #if os(watchOS)
        cache.totalCostLimit = 12 * 1024 * 1024
        cache.countLimit = 60
        #else
        cache.totalCostLimit = 60 * 1024 * 1024
        cache.countLimit = 300
        #endif
        let cfg = URLSessionConfiguration.default
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.urlCache = URLCache(memoryCapacity: 2 * 1024 * 1024, diskCapacity: 40 * 1024 * 1024)
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        cfg.timeoutIntervalForRequest = 20
        session = URLSession(configuration: cfg)
    }

    func cached(_ url: URL, maxPixel: Int) -> CGImage? {
        cache.object(forKey: key(url, maxPixel))?.image
    }

    func load(_ url: URL, maxPixel: Int) async throws -> CGImage {
        let k = key(url, maxPixel)
        if let c = cache.object(forKey: k) { return c.image }
        let (data, _) = try await session.data(from: url)
        try Task.checkCancellation()
        guard let img = Self.downsample(data, maxPixel: maxPixel) else { throw URLError(.cannotDecodeContentData) }
        cache.setObject(CGImageBox(img), forKey: k, cost: img.bytesPerRow * img.height)
        return img
    }

    func purge() { cache.removeAllObjects() }

    private func key(_ url: URL, _ px: Int) -> NSString { "\(px)|\(url.absoluteString)" as NSString }

    static func downsample(_ data: Data, maxPixel: Int) -> CGImage? {
        let srcOpts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, srcOpts) else { return nil }
        let opts = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts)
    }
}

/// `AsyncImage` replacement backed by `ImageLoader`.
struct RemoteImage: View {
    let url: URL?
    var maxPixel: Int = 300
    var contentMode: ContentMode = .fill

    @State private var image: CGImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.25))
                    .overlay {
                        if failed { Image(systemName: "photo").foregroundStyle(.secondary) }
                    }
            }
        }
        .task(id: url) {
            guard let url else { return }
            if let c = ImageLoader.shared.cached(url, maxPixel: maxPixel) { image = c; return }
            do {
                image = try await ImageLoader.shared.load(url, maxPixel: maxPixel)
            } catch {
                if !(error is CancellationError) { failed = true }
            }
        }
    }
}

struct Avatar: View {
    let user: XUser
    var size: CGFloat = 24

    var body: some View {
        RemoteImage(url: size > 40 ? user.avatarLargeURL : user.avatarURL, maxPixel: Int(size * 2.5))
            .frame(width: size, height: size)
            .clipShape(Circle())
            .accessibilityHidden(true)
    }
}
