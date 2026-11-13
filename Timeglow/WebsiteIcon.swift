import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

struct WebsiteIcon: View {
    let domain: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
                    .background(.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 3))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Image(systemName: "globe").resizable().scaledToFit().foregroundStyle(Graphite.muted)
            }
        }
        .accessibilityHidden(true)
        .task(id: domain) {
            image = nil
            let data = await WebsiteIconStore.shared.icon(for: domain)
            guard !Task.isCancelled else { return }
            image = data.flatMap(NSImage.init(data:))
        }
    }
}

/// Shared by the statistics and overview lists. Network and disk work stays off
/// the main actor; collapsing/reopening a browser reuses the same request/cache.
actor WebsiteIconStore {
    static let shared = WebsiteIconStore()
    private let memory = NSCache<NSString, NSData>()
    private var pending: [String: Task<Data?, Never>] = [:]
    private var failures: [String: Date] = [:]
    private let directory: URL
    private let session: URLSession
    private let lifetime: TimeInterval = 7 * 24 * 60 * 60

    init(directory: URL? = nil, configuration: URLSessionConfiguration = .ephemeral) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Timeglow/WebsiteIcons", isDirectory: true)
        // Icon requests use no browser cookies, credentials or third-party lookup service.
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 10
        configuration.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: configuration)
        memory.countLimit = 128
        memory.totalCostLimit = 4 * 1024 * 1024
    }

    func icon(for domain: String) async -> Data? {
        guard let host = DomainRules.normalized(domain) else { return nil }
        if let data = memory.object(forKey: host as NSString) { return data as Data }
        if let task = pending[host] { return await task.value }
        if let failedAt = failures[host], Date().timeIntervalSince(failedAt) < 300 { return nil }
        let file = directory.appendingPathComponent(host + ".png")
        if let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           Date().timeIntervalSince(date) < lifetime,
           let data = try? Data(contentsOf: file), thumbnail(data) != nil {
            memory.setObject(data as NSData, forKey: host as NSString, cost: data.count)
            return data
        }
        let task = Task { await fetch(host: host) }
        pending[host] = task
        let data = await task.value
        pending[host] = nil
        if let data {
            memory.setObject(data as NSData, forKey: host as NSString, cost: data.count)
            failures[host] = nil
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        } else {
            failures[host] = Date()
        }
        return data
    }

    private func fetch(host: String) async -> Data? {
        guard let root = URL(string: "https://" + host + "/") else { return nil }
        if let (data, _) = await download(root.appendingPathComponent("favicon.ico")),
           let png = thumbnail(data) { return png }

        // Some sites publish only a CDN/PNG icon in their HTML. Resolve relative
        // links against the final URL so redirects (including subdomains) work.
        guard let (html, pageURL) = await download(root, prefixOnly: true) else { return nil }
        // The bounded prefix may end in the middle of a UTF-8 character.
        let text = String(decoding: html, as: UTF8.self)
        for url in Self.iconURLs(in: text, relativeTo: pageURL).prefix(3) {
            if let (data, _) = await download(url), let png = thumbnail(data) { return png }
        }
        return nil
    }

    private func download(_ url: URL, prefixOnly: Bool = false) async -> (Data, URL)? {
        guard url.scheme?.lowercased() == "https" else { return nil }
        do {
            var request = URLRequest(url: url)
            request.setValue("image/*,text/html;q=0.8", forHTTPHeaderField: "Accept")
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  let finalURL = response.url, finalURL.scheme == "https",
                  prefixOnly || response.expectedContentLength <= 512 * 1024 else { return nil }
            var data = Data()
            for try await byte in bytes {
                if data.count >= 512 * 1024 { return prefixOnly ? (data, finalURL) : nil }
                data.append(byte)
            }
            return (data, finalURL)
        } catch { return nil }
    }

    private func thumbnail(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 64,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return result as Data
    }

    nonisolated static func iconURLs(in html: String, relativeTo base: URL) -> [URL] {
        guard let links = try? NSRegularExpression(pattern: #"<link\b[^>]*>"#, options: .caseInsensitive),
              let attributes = try? NSRegularExpression(pattern: #"([\w-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#) else { return [] }
        let source = html as NSString
        var urls: [URL] = []
        for link in links.matches(in: html, range: NSRange(location: 0, length: source.length)) {
            let tag = source.substring(with: link.range) as NSString
            var values: [String: String] = [:]
            for match in attributes.matches(in: tag as String, range: NSRange(location: 0, length: tag.length)) {
                let valueRange = (2...4).map { match.range(at: $0) }.first { $0.location != NSNotFound }!
                values[tag.substring(with: match.range(at: 1)).lowercased()] = tag.substring(with: valueRange)
            }
            let rel = (values["rel"] ?? "").lowercased().split(whereSeparator: { $0.isWhitespace })
            guard rel.contains("icon") || rel.contains("apple-touch-icon"),
                  let href = values["href"],
                  let url = URL(string: href.replacingOccurrences(of: "&amp;", with: "&"), relativeTo: base)?.absoluteURL,
                  url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
                  !urls.contains(url) else { continue }
            urls.append(url)
        }
        return urls
    }
}
