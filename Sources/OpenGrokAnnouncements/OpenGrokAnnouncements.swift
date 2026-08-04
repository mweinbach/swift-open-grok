import Foundation
import OpenGrokPaths

public struct AnnouncementCta: Hashable, Sendable, Codable, Equatable {
    public var label: String?
    public var url: String?
    public var caption: String?

    public init(label: String? = nil, url: String? = nil, caption: String? = nil) {
        self.label = label
        self.url = url
        self.caption = caption
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(label, forKey: .label)
        try container.encode(url, forKey: .url)
        try container.encode(caption, forKey: .caption)
    }

    private enum CodingKeys: String, CodingKey {
        case label
        case url
        case caption
    }
}

public struct RemoteAnnouncement: Hashable, Sendable, Codable, Equatable {
    public var id: String?
    public var message: String?
    public var severity: String?
    public var title: String?
    public var cta: AnnouncementCta?
    public var updatedAt: String?
    public var expiresAt: String?
    public var dismissible: Bool?
    public var persistent: Bool?

    public init(
        id: String? = nil,
        message: String? = nil,
        severity: String? = nil,
        title: String? = nil,
        cta: AnnouncementCta? = nil,
        updatedAt: String? = nil,
        expiresAt: String? = nil,
        dismissible: Bool? = nil,
        persistent: Bool? = nil
    ) {
        self.id = id
        self.message = message
        self.severity = severity
        self.title = title
        self.cta = cta
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
        self.dismissible = dismissible
        self.persistent = persistent
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case message
        case severity
        case title
        case cta
        case updatedAt = "updated_at"
        case expiresAt = "expires_at"
        case dismissible
        case persistent
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(message, forKey: .message)
        try container.encode(severity, forKey: .severity)
        try container.encode(title, forKey: .title)
        try container.encode(cta, forKey: .cta)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(expiresAt, forKey: .expiresAt)
        try container.encode(dismissible, forKey: .dismissible)
        try container.encode(persistent, forKey: .persistent)
    }
}

public struct AnnouncementsRefreshed: Hashable, Sendable, Codable, Equatable {
    public var gen: UInt64
    public var announcements: [RemoteAnnouncement]

    private enum CodingKeys: String, CodingKey {
        case gen
        case announcements
    }

    public init(gen: UInt64, announcements: [RemoteAnnouncement] = []) {
        self.gen = gen
        self.announcements = announcements
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gen = try container.decode(UInt64.self, forKey: .gen)
        guard container.contains(.announcements) else {
            announcements = []
            return
        }
        guard !(try container.decodeNil(forKey: .announcements)) else {
            throw DecodingError.typeMismatch(
                [RemoteAnnouncement].self,
                DecodingError.Context(
                    codingPath: container.codingPath + [CodingKeys.announcements],
                    debugDescription: "announcements must be an array"
                )
            )
        }
        announcements = try container.decode([RemoteAnnouncement].self, forKey: .announcements)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(gen, forKey: .gen)
        try container.encode(announcements, forKey: .announcements)
    }
}

private struct HiddenAnnouncementState: Codable {
    var hiddenIDs: [String]

    private enum CodingKeys: String, CodingKey {
        case hiddenIDs = "hidden_ids"
    }

    init(hiddenIDs: [String]) {
        self.hiddenIDs = hiddenIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.hiddenIDs) else {
            hiddenIDs = []
            return
        }
        guard try !container.decodeNil(forKey: .hiddenIDs) else {
            throw DecodingError.typeMismatch(
                [String].self,
                DecodingError.Context(
                    codingPath: container.codingPath + [CodingKeys.hiddenIDs],
                    debugDescription: "hidden_ids must be an array"
                )
            )
        }
        hiddenIDs = try container.decode([String].self, forKey: .hiddenIDs)
    }
}

public func announcementHideKey(_ announcement: RemoteAnnouncement) -> String {
    if let id = announcement.id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
        return id
    }
    return "content:\(announcement.title ?? "")\u{1f}\(announcement.message ?? "")"
}

public func parseHiddenAnnouncementIDs(_ value: String) -> Set<String> {
    guard let data = value.data(using: .utf8),
          let state = try? JSONDecoder().decode(HiddenAnnouncementState.self, from: data)
    else {
        return []
    }
    return Set(state.hiddenIDs)
}

public func serializeHiddenAnnouncementIDs(_ ids: Set<String>) -> String? {
    let state = HiddenAnnouncementState(hiddenIDs: ids.sorted())
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(state) else {
        return nil
    }
    return String(data: data, encoding: .utf8)
}

@discardableResult
public func pruneHiddenAnnouncementIDs(
    _ ids: inout Set<String>,
    active: [RemoteAnnouncement]
) -> Bool {
    let live = Set(active.map(announcementHideKey))
    let previousCount = ids.count
    ids = ids.intersection(live)
    return ids.count != previousCount
}

public func announcementStateURL(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> URL {
    OpenGrokStatePaths.stateDirectory(environment: environment)
        .appendingPathComponent("announcements.json")
}

public struct AnnouncementStateStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.fileURL = announcementStateURL(environment: environment)
    }

    public func read() async -> Set<String> {
        let fileURL = fileURL
        return await Task.detached(priority: nil) {
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard let data = try? Data(contentsOf: fileURL),
                  let value = String(data: data, encoding: .utf8)
            else {
                return []
            }
            return parseHiddenAnnouncementIDs(value)
        }.value
    }

    public func write(_ ids: Set<String>) async {
        guard let value = serializeHiddenAnnouncementIDs(ids),
              let data = value.data(using: .utf8)
        else {
            return
        }
        let fileURL = fileURL
        await Task.detached(priority: nil) {
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: fileURL)
        }.value
    }
}

public func readHiddenAnnouncementIDs(
    environment: [String: String] = ProcessInfo.processInfo.environment
) async -> Set<String> {
    await AnnouncementStateStore(environment: environment).read()
}

public func writeHiddenAnnouncementIDs(
    _ ids: Set<String>,
    environment: [String: String] = ProcessInfo.processInfo.environment
) async {
    await AnnouncementStateStore(environment: environment).write(ids)
}

public func visibleAnnouncements(_ announcements: [RemoteAnnouncement]) -> [RemoteAnnouncement] {
    announcements.filter { announcement in
        guard let message = announcement.message else { return false }
        return !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private func parseRFC3339Date(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) {
        return date
    }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
}

public func isExpiredAt(_ announcement: RemoteAnnouncement, now: Date) -> Bool {
    guard let expiresAt = announcement.expiresAt,
          let expiry = parseRFC3339Date(expiresAt)
    else {
        return false
    }
    return expiry <= now
}

public func filterExpired(_ announcements: [RemoteAnnouncement], now: Date = Date()) -> [RemoteAnnouncement] {
    announcements.filter { !isExpiredAt($0, now: now) }
}

public func filterExpiredAt(_ announcements: [RemoteAnnouncement], now: Date) -> [RemoteAnnouncement] {
    filterExpired(announcements, now: now)
}

public func resolveStartup(
    _ remoteAnnouncements: [RemoteAnnouncement]?,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> [RemoteAnnouncement]? {
    if let raw = environment["GROK_ANNOUNCEMENTS_OVERRIDE"],
       let data = raw.data(using: .utf8),
       let override = try? JSONDecoder().decode([RemoteAnnouncement].self, from: data) {
        return override
    }
    return remoteAnnouncements
}

private func isCritical(_ announcement: RemoteAnnouncement) -> Bool {
    announcement.severity == "critical"
}

private func isPromo(_ announcement: RemoteAnnouncement) -> Bool {
    announcement.severity == "promo"
}

public func isDismissible(_ announcement: RemoteAnnouncement) -> Bool {
    announcement.dismissible != false
}

private func isLiveCritical(_ announcement: RemoteAnnouncement, now: Date) -> Bool {
    isCritical(announcement) && !isExpiredAt(announcement, now: now)
}

private func isLivePromo(_ announcement: RemoteAnnouncement, now: Date) -> Bool {
    isPromo(announcement) && !isExpiredAt(announcement, now: now)
}

private func isLiveSessionAnnouncement(_ announcement: RemoteAnnouncement, now: Date) -> Bool {
    isLiveCritical(announcement, now: now) || isLivePromo(announcement, now: now)
}

private func isHidden(_ announcement: RemoteAnnouncement, hiddenIDs: Set<String>) -> Bool {
    isDismissible(announcement) && hiddenIDs.contains(announcementHideKey(announcement))
}

private func firstCriticalSessionAnnouncementAt(
    _ announcements: [RemoteAnnouncement],
    hiddenIDs: Set<String>,
    now: Date
) -> RemoteAnnouncement? {
    visibleAnnouncements(announcements).first { announcement in
        isLiveCritical(announcement, now: now) && !isHidden(announcement, hiddenIDs: hiddenIDs)
    }
}

private func firstPromoSessionAnnouncementAt(
    _ announcements: [RemoteAnnouncement],
    hiddenIDs: Set<String>,
    now: Date
) -> RemoteAnnouncement? {
    visibleAnnouncements(announcements).first { announcement in
        isLivePromo(announcement, now: now) && !isHidden(announcement, hiddenIDs: hiddenIDs)
    }
}

public func firstSessionAnnouncement(
    _ announcements: [RemoteAnnouncement],
    hiddenIDs: Set<String>,
    now: Date = Date()
) -> RemoteAnnouncement? {
    firstCriticalSessionAnnouncementAt(announcements, hiddenIDs: hiddenIDs, now: now)
        ?? firstPromoSessionAnnouncementAt(announcements, hiddenIDs: hiddenIDs, now: now)
}

public func hasCriticalSessionAnnouncement(
    _ announcements: [RemoteAnnouncement],
    hiddenIDs: Set<String>,
    now: Date = Date()
) -> Bool {
    firstCriticalSessionAnnouncementAt(announcements, hiddenIDs: hiddenIDs, now: now) != nil
}

public func usableCTA(_ announcement: RemoteAnnouncement) -> (label: String, url: String)? {
    guard let cta = announcement.cta,
          let label = cta.label?.trimmingCharacters(in: .whitespacesAndNewlines),
          !label.isEmpty,
          let url = cta.url?.trimmingCharacters(in: .whitespacesAndNewlines),
          !url.isEmpty,
          isSafeStandardURL(url)
    else {
        return nil
    }
    return (label, url)
}

public func usableCTACaption(_ announcement: RemoteAnnouncement) -> String? {
    guard let caption = announcement.cta?.caption?.trimmingCharacters(in: .whitespacesAndNewlines),
          !caption.isEmpty
    else {
        return nil
    }
    return caption
}

private func isSafeStandardURL(_ value: String) -> Bool {
    let scheme: String?
    if let parsed = URL(string: value), let parsedScheme = parsed.scheme {
        scheme = parsedScheme
    } else if let separator = value.firstIndex(of: ":") {
        scheme = String(value[..<separator])
    } else {
        scheme = nil
    }
    guard let scheme else { return false }
    return ["http", "https", "mailto"].contains(scheme.lowercased())
}

public func promoCTA(
    _ announcements: [RemoteAnnouncement],
    hiddenIDs: Set<String>,
    now: Date = Date()
) -> (announcement: RemoteAnnouncement, label: String, url: String)? {
    guard let owner = firstSessionAnnouncement(announcements, hiddenIDs: hiddenIDs, now: now),
          isPromo(owner),
          let cta = usableCTA(owner)
    else {
        return nil
    }
    return (owner, cta.label, cta.url)
}

public func promoCTATarget(
    _ announcements: [RemoteAnnouncement],
    hiddenIDs: Set<String>,
    now: Date = Date()
) -> (announcement: RemoteAnnouncement, url: String)? {
    guard let cta = promoCTA(announcements, hiddenIDs: hiddenIDs, now: now) else {
        return nil
    }
    return (cta.announcement, cta.url)
}

public func sessionAnnouncementHideKeys(
    _ announcements: [RemoteAnnouncement],
    now: Date = Date()
) -> [String] {
    visibleAnnouncements(announcements)
        .filter { isLiveSessionAnnouncement($0, now: now) }
        .map(announcementHideKey)
}

public func hasSessionAnnouncements(
    _ announcements: [RemoteAnnouncement],
    now: Date = Date()
) -> Bool {
    visibleAnnouncements(announcements).contains {
        isLiveSessionAnnouncement($0, now: now)
    }
}

public func sessionBannerHeight(
    _ announcements: [RemoteAnnouncement],
    hiddenIDs: Set<String>,
    now: Date = Date()
) -> Int {
    guard let selected = firstSessionAnnouncement(announcements, hiddenIDs: hiddenIDs, now: now) else {
        return 0
    }
    return isCritical(selected) ? 2 : 1
}
