import Foundation

/// Fixed bundled delivery authority. URLs are strings in serialized values, never caller input.
struct ModelDeliveryLocation: Codable, Sendable, Equatable {
    let path: String
    let httpsURL: String
    init(path: String, httpsURL: String) throws {
        try ModelPackageRules.path(path)
        guard httpsURL.utf8.count <= 4096, let c = URLComponents(string: httpsURL),
              c.scheme == "https", let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil, c.fragment == nil, c.url != nil,
              !httpsURL.contains("\n"), !httpsURL.contains("\r") else { throw ModelRepositoryCode.invalidDescriptor }
        self.path = path; self.httpsURL = httpsURL
    }
    init(from decoder: Decoder) throws {
        try rejectUnknownDeliveryFields(decoder, allowed: ["path", "httpsURL"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(path: c.decode(String.self, forKey: .path), httpsURL: c.decode(String.self, forKey: .httpsURL))
    }
}
struct ModelDelivery: Codable, Sendable, Equatable {
    let key: InstalledModelKey
    let locations: [ModelDeliveryLocation]
    init(key: InstalledModelKey, locations: [ModelDeliveryLocation]) throws {
        guard !locations.isEmpty, locations.count <= 4096,
              Set(locations.map(\.path)).count == locations.count else { throw ModelRepositoryCode.invalidDescriptor }
        self.key = key; self.locations = locations.sorted { $0.path < $1.path }
    }
    init(from decoder: Decoder) throws {
        try rejectUnknownDeliveryFields(decoder, allowed: ["key", "locations"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(key: c.decode(InstalledModelKey.self, forKey: .key), locations: c.decode([ModelDeliveryLocation].self, forKey: .locations))
    }
}
private struct DeliveryField: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
private func rejectUnknownDeliveryFields(_ decoder: Decoder, allowed: Set<String>) throws {
    let c = try decoder.container(keyedBy: DeliveryField.self)
    guard c.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else { throw ModelRepositoryCode.invalidDescriptor }
}
