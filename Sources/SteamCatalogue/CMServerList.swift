// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Jfishin, 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Derived from the pinned Madeira Steam client; see THIRD-PARTY-NOTICES.md. Adapted for
// the owned library and downloads (docs/STEAM_LIBRARY.md).

import Foundation

/// Discovers and manages Steam CM (Connection Manager) WebSocket endpoints.
actor CMServerList {
    /// A CM server endpoint (WebSocket)
    nonisolated struct CMServer: Codable, Sendable {
        let host: String
        let port: UInt16
        var lastAttempt: Date?
        var failCount: Int = 0

        var isHealthy: Bool { failCount < 3 }
        var isValid: Bool {
            port == 443 && host.utf8.count <= 253 && host.hasSuffix(".steamserver.net")
                && host.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }
                && !host.split(separator: ".", omittingEmptySubsequences: false).contains(where: \.isEmpty)
        }

        var endpoint: String { "\(host):\(port)" }

        var url: URL { URL(string: "wss://\(host):\(port)/cmsocket/")! }
    }

    private var servers: [CMServer] = []
    private var lastFetched: Date?
    private let cacheKey = "swiftsteam_cm_servers_websocket"
    private let staleInterval: TimeInterval = 3600
    /// A cached list stands in only until the directory answers again.
    private let cachedStaleInterval: TimeInterval = 60
    private var listFromCache = false

    // MARK: - Public API

    /// Get the best available CM server to connect to
    func getServer() async throws -> CMServer {
        if servers.isEmpty || isListStale {
            try await refreshServerList()
        }

        guard let server = servers
            .filter({ $0.isHealthy })
            .sorted(by: { ($0.lastAttempt ?? .distantPast) < ($1.lastAttempt ?? .distantPast) })
            .first
        else {
            for i in servers.indices {
                servers[i].failCount = 0
            }
            guard let server = servers.first else {
                throw SteamError.noServersAvailable
            }
            return server
        }

        return server
    }

    func markFailed(endpoint: String) {
        if let index = servers.firstIndex(where: { $0.endpoint == endpoint }) {
            servers[index].failCount += 1
            servers[index].lastAttempt = Date()
        }
    }

    func markSuccess(endpoint: String) {
        if let index = servers.firstIndex(where: { $0.endpoint == endpoint }) {
            servers[index].failCount = 0
            servers[index].lastAttempt = Date()
        }
    }

    func refreshServerList() async throws {
        try Task.checkCancellation()
        let availableServers: [CMServer]
        let fromCache: Bool
        do {
            let freshServers = try await fetchServerList()
            guard !freshServers.isEmpty else {
                throw SteamError.noServersAvailable
            }
            availableServers = freshServers
            fromCache = false
        } catch {
            // Cancellation must never turn into a successful cached connection.
            try Task.checkCancellation()
            guard !(error is CancellationError), (error as? URLError)?.code != .cancelled else {
                throw error
            }
            guard let cached = loadCachedServers(), !cached.isEmpty else {
                throw error
            }
            availableServers = cached
            fromCache = true
        }
        try Task.checkCancellation()
        // Reloading the same cache would forget which servers just failed.
        if !(fromCache && listFromCache && !servers.isEmpty) { servers = availableServers }
        lastFetched = Date()
        listFromCache = fromCache
        if !fromCache { cacheServerList() }
    }

    // MARK: - Private

    private var isListStale: Bool {
        guard let lastFetched else { return true }
        return Date().timeIntervalSince(lastFetched) > (listFromCache ? cachedStaleInterval : staleInterval)
    }

    /// Fetch WebSocket CM server list from Steam Web API
    private func fetchServerList() async throws -> [CMServer] {
        let urlString = "https://api.steampowered.com/ISteamDirectory/GetCMListForConnect/v1/?cellid=0&cmtype=websockets"
        guard let url = URL(string: urlString) else {
            throw SteamError.connectionFailed("Invalid CM directory URL")
        }

        // A cached list is retried every minute, so a hung directory must not stall each connect.
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 15))

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw SteamError.connectionFailed("CM directory returned non-200 status")
        }

        // Response format: { "response": { "serverlist": [ { "endpoint": "host:port", ... }, ... ] } }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let serverResponse = json["response"] as? [String: Any],
              let serverList = serverResponse["serverlist"] as? [[String: Any]] else {
            throw SteamError.connectionFailed("Invalid CM directory response format")
        }

        // Each entry has an "endpoint" field: "hostname:port"
        let servers = serverList.compactMap { entry -> CMServer? in
            guard let endpoint = entry["endpoint"] as? String else { return nil }
            let parts = endpoint.split(separator: ":")
            guard parts.count == 2, let port = UInt16(parts[1]) else { return nil }
            let server = CMServer(host: String(parts[0]), port: port)
            return server.isValid ? server : nil
        }

        return servers
    }

    // MARK: - Caching

    private func cacheServerList() {
        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }

    private func loadCachedServers() -> [CMServer]? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              data.count <= 1024 * 1024,
              let cached = try? JSONDecoder().decode([CMServer].self, from: data), cached.count <= 1000 else {
            return nil
        }
        return cached.filter(\.isValid)
    }
}
