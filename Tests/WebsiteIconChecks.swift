import AppKit
import Foundation

private final class IconProtocol: URLProtocol {
    static let lock = NSLock()
    static var requests: [String: Int] = [:]
    static var image = Data()
    static func count(_ url: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return requests[url, default: 0]
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.lock.lock()
        Self.requests[url.absoluteString, default: 0] += 1
        Self.lock.unlock()
        var data = Data()
        var status = 200
        if url.host == "direct.test" && url.path == "/favicon.ico" || url.path == "/images/icon.png" {
            data = Self.image
        } else if url.host == "html.test" && url.path == "/" {
            data = Data("<LINK href='/images/icon.png' REL='shortcut icon'>".utf8)
            data.append(Data(repeating: 32, count: 512 * 1024 - 1 - data.count))
            data.append(Data("中".utf8)) // Download limit splits this UTF-8 character.
        } else { status = 404 }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": "\(data.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct WebsiteIconChecks {
    static func main() async throws {
        if CommandLine.arguments.contains("--live") {
            let store = WebsiteIconStore(directory: URL(fileURLWithPath: CommandLine.arguments.last!))
            await withTaskGroup(of: Void.self) { group in
                for host in ["x.com", "www.mgtv.com", "www.douyin.com", "www.bilibili.com", "space.bilibili.com", "www.youtube.com", "github.com", "example.com", "www.freedidi.com", "www.zhipin.com"] {
                    group.addTask {
                        let data = await store.icon(for: host)
                        print("\(host): \(data.map { "icon \($0.count) bytes" } ?? "fallback")")
                    }
                }
            }
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("timeglow-icons-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        // Use a real production image to exercise decoding and thumbnail generation.
        IconProtocol.image = try Data(contentsOf: URL(fileURLWithPath: "Timeglow/Resources/BookmarkOrbs/safe.webp"))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [IconProtocol.self]
        let store = WebsiteIconStore(directory: root, configuration: config)
        let direct = await store.icon(for: "direct.test")
        precondition(direct != nil && NSImage(data: direct!) != nil, "Direct favicon must decode")
        _ = await store.icon(for: "https://DIRECT.test/path")
        precondition(IconProtocol.count("https://direct.test/favicon.ico") == 1, "Memory cache/normalization")
        let diskStore = WebsiteIconStore(directory: root, configuration: config)
        let disk = await diskStore.icon(for: "direct.test")
        precondition(disk == direct && IconProtocol.count("https://direct.test/favicon.ico") == 1, "Persistent cache")
        let html = await store.icon(for: "html.test")
        precondition(html != nil, "Discover relative icon in a large HTML document")
        precondition(IconProtocol.count("https://html.test/images/icon.png") == 1, "Resolve declared icon")
        await withTaskGroup(of: Data?.self) { group in
            for _ in 0..<8 { group.addTask { await store.icon(for: "missing.test") } }
            for await result in group { precondition(result == nil, "Missing favicon uses fallback") }
        }
        _ = await store.icon(for: "missing.test")
        precondition(IconProtocol.count("https://missing.test/favicon.ico") == 1, "Deduplicate requests and back off failures")
        precondition(IconProtocol.count("https://missing.test/") == 1, "No repeated page fetch on failure")
        let urls = WebsiteIconStore.iconURLs(in: """
        <link rel=icon href=//cdn.test/favicon.png>
        <link href='relative.png?a=1&amp;b=2' rel='apple-touch-icon'>
        <link rel=stylesheet href='/style.css'><link rel=icon href='http://unsafe.test/icon.png'>
        """, relativeTo: URL(string: "https://html.test/path/")!)
        precondition(urls.map(\.absoluteString) == ["https://cdn.test/favicon.png", "https://html.test/path/relative.png?a=1&b=2"], "Parse declared icons; ignore unrelated/insecure links")
        try Data("corrupt".utf8).write(to: root.appendingPathComponent("direct.test.png"))
        let repaired = await WebsiteIconStore(directory: root, configuration: config).icon(for: "direct.test")
        precondition(repaired != nil && IconProtocol.count("https://direct.test/favicon.ico") == 2, "Recover a corrupt disk cache")
        let invalid = await store.icon(for: "bad domain")
        precondition(invalid == nil, "Invalid domain uses fallback")
        print("Website icon checks passed: direct icon, memory/disk cache, HTML discovery, relative/CDN links, oversized HTML prefix, missing icon, request deduplication, failure backoff, corrupt cache, invalid domain.")
    }
}
