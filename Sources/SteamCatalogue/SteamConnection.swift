// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Jfishin, 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Derived from the pinned Madeira Steam client; see THIRD-PARTY-NOTICES.md. Adapted for
// the owned library and downloads (docs/STEAM_LIBRARY.md).

import Foundation

// MARK: - SteamConnection

/// WebSocket transport to a Steam CM server (wss://).
/// TLS handles all encryption — no ChannelEncrypt handshake required.
/// Each binary WebSocket frame is exactly one complete Steam protocol message.
actor SteamConnection {
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private let serverList = CMServerList()
    private var currentEndpoint: String?
    private var messageHandler: (@Sendable (Data) -> Void)?
    private var disconnectHandler: (@Sendable (Error?) -> Void)?

    var isConnected: Bool {
        webSocketTask?.state == .running
    }

    // MARK: - Connect

    func connect() async throws {
        let server = try await serverList.getServer()
        currentEndpoint = server.endpoint

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        let session = URLSession(configuration: config)
        urlSession = session

        // IMPORTANT: Sec-WebSocket-Protocol is a CONTROLLED HEADER in URLSessionWebSocketTask.
        // Setting it via request.setValue is silently ignored by URLSession.
        // The only supported way is the `protocols` parameter below.
        // Without "steamdataport", Steam CM servers accept the WebSocket but do not
        // initialize a Steam session handler, so they silently ignore all messages.
        let task = session.webSocketTask(with: server.url, protocols: ["steamdataport"])
        webSocketTask = task
        task.maximumMessageSize = 16 * 1024 * 1024
        task.resume()

        // Verify the connection completed (WebSocket handshake + ping round-trip)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error {
                    cont.resume(throwing: SteamError.connectionFailed(error.localizedDescription))
                } else {
                    cont.resume()
                }
            }
        }

        await serverList.markSuccess(endpoint: server.endpoint)
        scheduleReceive(task)
    }

    // MARK: - Receive

    /// Continuously receive WebSocket binary frames.
    /// Each frame is one complete Steam protocol message — no TCP length/magic framing.
    nonisolated private func scheduleReceive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .data(let data):
                    Task { await self.dispatchMessage(data, task: task) }
                case .string:
                    break
                @unknown default:
                    break
                }
                // Schedule the next receive immediately to keep the loop running
                self.scheduleReceive(task)

            case .failure(let error):
                // NSPOSIXErrorDomain 57 "Socket is not connected" is a normal disconnect
                let nsError = error as NSError
                let isNormalClose = nsError.domain == NSPOSIXErrorDomain && nsError.code == 57
                Task { await self.handleDisconnect(error: isNormalClose ? nil : error, task: task) }
            }
        }
    }

    private func dispatchMessage(_ data: Data, task: URLSessionWebSocketTask) {
        guard webSocketTask === task else { return }
        messageHandler?(data)
    }

    // MARK: - Send

    /// Send raw bytes as a binary WebSocket frame.
    /// Wire format: [4B masked EMsg][4B headerLen][protobuf header][body] — no TCP framing wrapper.
    func send(_ data: Data) async throws {
        guard let task = webSocketTask, task.state == .running else {
            throw SteamError.disconnected
        }
        try await task.send(.data(data))
    }

    /// WebSocket-level ping (transport keepalive).
    /// Steam protocol heartbeat is handled by SteamSession at the message level.
    func sendPing() async {
        webSocketTask?.sendPing { _ in }
    }

    // MARK: - Handlers

    func setMessageHandler(_ handler: @escaping @Sendable (Data) -> Void) {
        self.messageHandler = handler
    }

    func setDisconnectHandler(_ handler: @escaping @Sendable (Error?) -> Void) {
        self.disconnectHandler = handler
    }

    private func handleDisconnect(error: Error?, task: URLSessionWebSocketTask) {
        guard webSocketTask === task else { return }
        // Only fire disconnect once per connection — clear webSocketTask to prevent repeat
        guard webSocketTask != nil else { return }
        webSocketTask = nil
        disconnectHandler?(error)
    }

    // MARK: - Disconnect

    func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        currentEndpoint = nil
    }

    func reconnect() async throws {
        if let endpoint = currentEndpoint {
            await serverList.markFailed(endpoint: endpoint)
        }
        disconnect()
        try await connect()
    }
}
