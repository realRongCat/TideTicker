import Foundation

public enum GitHubReleaseClientError: LocalizedError, ReleaseUpdateRetryProviding, Sendable {
    case invalidResponse
    case responseTooLarge
    case httpStatus(Int)
    case rateLimited(Date?)
    case invalidRelease

    public var retryAt: Date? {
        if case let .rateLimited(date) = self { return date }
        return nil
    }

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "GitHub 返回了无法识别的响应。"
        case .responseTooLarge: return "GitHub 更新信息超过允许大小。"
        case let .httpStatus(status): return "GitHub 更新检查失败（HTTP \(status)）。"
        case .rateLimited: return "GitHub 暂时限制了更新检查，请稍后再试。"
        case .invalidRelease: return "GitHub 发布信息不符合 TideTicker 的版本规则。"
        }
    }
}

public actor GitHubReleaseClient: ReleaseUpdateFetching {
    private static let endpoint = URL(string: "https://api.github.com/repos/realRongCat/TideTicker/releases/latest")!
    private static let releasePrefix = "/realRongCat/TideTicker/releases/tag/"
    private static let maximumResponseBytes = 256 * 1024
    private let session: URLSession
    private let userAgent: String

    public init(appVersion: String, session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 15
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpCookieAcceptPolicy = .never
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration)
        }
        userAgent = "TideTicker/\(appVersion)"
    }

    public func latestRelease(ifNoneMatch etag: String?) async throws -> ReleaseUpdateFetchResult {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let etag, etag.count <= 512, !etag.contains("\n"), !etag.contains("\r") {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              http.url?.scheme == "https", http.url?.host?.lowercased() == "api.github.com",
              http.url?.path == Self.endpoint.path else { throw GitHubReleaseClientError.invalidResponse }
        let responseETag = Self.validETag(http.value(forHTTPHeaderField: "ETag"))
        if http.statusCode == 304 { return .notModified(etag: responseETag) }
        if http.statusCode == 404 { return .noRelease(etag: responseETag) }
        if http.statusCode == 403 || http.statusCode == 429 {
            throw GitHubReleaseClientError.rateLimited(Self.retryDate(from: http))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GitHubReleaseClientError.httpStatus(http.statusCode)
        }
        if let length = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init),
           length > Self.maximumResponseBytes {
            throw GitHubReleaseClientError.responseTooLarge
        }
        guard data.count <= Self.maximumResponseBytes else {
            throw GitHubReleaseClientError.responseTooLarge
        }
        guard let release = try Self.parseRelease(data) else {
            return .noRelease(etag: responseETag)
        }
        return .release(release, etag: responseETag)
    }

    static func parseRelease(_ data: Data) throws -> AppRelease? {
        struct Payload: Decodable {
            let tagName: String
            let name: String?
            let draft: Bool
            let prerelease: Bool
            let htmlURL: String
            let publishedAt: String

            enum CodingKeys: String, CodingKey {
                case tagName = "tag_name"
                case name, draft, prerelease
                case htmlURL = "html_url"
                case publishedAt = "published_at"
            }
        }

        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: data) }
        catch { throw GitHubReleaseClientError.invalidRelease }
        guard !payload.draft, !payload.prerelease else { return nil }
        guard payload.tagName.count <= 64, let version = AppVersion(payload.tagName),
              let url = URL(string: payload.htmlURL), url.scheme == "https",
              url.host?.lowercased() == "github.com",
              url.path == Self.releasePrefix + payload.tagName,
              let publishedAt = ISO8601DateFormatter().date(from: payload.publishedAt) else {
            throw GitHubReleaseClientError.invalidRelease
        }
        let rawTitle = (payload.name ?? "").replacingOccurrences(
            of: "[\\p{C}\\r\\n]+", with: " ", options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let title = rawTitle.isEmpty ? "TideTicker \(version)" : String(rawTitle.prefix(120))
        return AppRelease(version: version, tagName: payload.tagName, title: title,
                          publishedAt: publishedAt, releaseURL: url)
    }

    private static func validETag(_ value: String?) -> String? {
        guard let value, value.count <= 512, !value.contains("\n"), !value.contains("\r") else { return nil }
        return value
    }

    private static func retryDate(from response: HTTPURLResponse) -> Date? {
        if let seconds = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) {
            return Date().addingTimeInterval(max(0, seconds))
        }
        if let timestamp = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init) {
            return Date(timeIntervalSince1970: timestamp)
        }
        return nil
    }
}
