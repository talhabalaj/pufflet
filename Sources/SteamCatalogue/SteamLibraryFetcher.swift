// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Jfishin, 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Derived from the pinned Madeira Steam client; see THIRD-PARTY-NOTICES.md. Adapted for
// the owned library and downloads (docs/STEAM_LIBRARY.md).

import Foundation

/// Resolves the signed-in account's licenses through Steam PICS. Content is installed by Valve.
@MainActor final class SteamLibraryFetcher {
    private let session: any SteamCMSession
    init(session: any SteamCMSession) { self.session = session }
    func fetchOwnedApps() async throws -> [OwnedSteamGame] {
        try await session.ensureConnected()
        let packages = try await fetchLicenseList()
        guard packages.count <= 100_000 else { throw SteamError.invalidMessage }
        let tokens = try await fetchPICSAccessTokens(packageIDs: packages)
        let apps = try await fetchAppIDsFromPackages(packageIDs: packages, tokens: tokens)
        guard apps.count <= 100_000 else { throw SteamError.invalidMessage }
        let appTokens = try await fetchPICSAccessTokens(appIDs: Array(apps))
        let fetched = try await fetchAppInfo(appIDs: Array(apps), tokens: appTokens)
        return Array(Dictionary(fetched.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }).values)
    }
    private func fetchLicenseList() async throws -> [UInt32] {
        try await session.awaitLicenseList(timeout: 15)
    }

    // MARK: - PICS Access Tokens

    private func fetchPICSAccessTokens(appIDs: [UInt32] = [], packageIDs: [UInt32] = []) async throws -> [UInt32: UInt64] {
        var request = CMsgClientPICSAccessTokenRequest()
        request.appids = appIDs
        request.packageids = packageIDs

        let response = try await session.sendAndWait(
            eMsg: .clientPICSAccessTokenRequest,
            body: request.serialize(),
            responseEMsg: .clientPICSAccessTokenResponse,
            timeout: 30
        )

        let tokenResponse = try CMsgClientPICSAccessTokenResponse.deserialize(from: response.body)

        var tokens: [UInt32: UInt64] = [:]
        for appToken in tokenResponse.appAccessTokens {
            tokens[appToken.appid] = appToken.accessToken
        }
        for pkgToken in tokenResponse.packageAccessTokens {
            tokens[pkgToken.packageid] = pkgToken.accessToken
        }

        return tokens
    }

    // MARK: - Package Info → App IDs

    private func fetchAppIDsFromPackages(packageIDs: [UInt32], tokens: [UInt32: UInt64]) async throws -> Set<UInt32> {
        var allAppIDs = Set<UInt32>()

        // Package info requests in batches of 50.
        let batches = stride(from: 0, to: packageIDs.count, by: 50).map {
            Array(packageIDs[$0..<min($0 + 50, packageIDs.count)])
        }

        for batch in batches {
            try Task.checkCancellation()
            var request = CMsgClientPICSProductInfoRequest()
            request.packages = batch.map { pkgID in
                CMsgClientPICSProductInfoRequest.PackageInfo(
                    packageid: pkgID,
                    accessToken: tokens[pkgID] ?? 0
                )
            }

            let responses = try await session.sendAndWaitPICS(
                eMsg: .clientPICSProductInfoRequest,
                body: request.serialize(),
                timeout: 30
            )

            for response in responses {
                let picsResponse = try CMsgClientPICSProductInfoResponse.deserialize(from: response.body)
                for pkg in picsResponse.packages {
                    allAppIDs.formUnion(PackageAppIDs.parse(from: pkg.buffer))
                }
            }
        }

        return allAppIDs
    }

    // MARK: - App Info

    private func fetchAppInfo(appIDs: [UInt32], tokens: [UInt32: UInt64]) async throws -> [OwnedSteamGame] {
        var allApps: [OwnedSteamGame] = []

        // App info requests in batches of 50.
        let batches = stride(from: 0, to: appIDs.count, by: 50).map {
            Array(appIDs[$0..<min($0 + 50, appIDs.count)])
        }

        for batch in batches {
            try Task.checkCancellation()
            var request = CMsgClientPICSProductInfoRequest()
            request.apps = batch.map { appID in
                CMsgClientPICSProductInfoRequest.AppInfo(
                    appid: appID,
                    accessToken: tokens[appID] ?? 0
                )
            }

            let responses = try await session.sendAndWaitPICS(
                eMsg: .clientPICSProductInfoRequest,
                body: request.serialize(),
                timeout: 30
            )

            for response in responses {
                let picsResponse = try CMsgClientPICSProductInfoResponse.deserialize(from: response.body)
                for app in picsResponse.apps where batch.contains(app.appid) {
                    guard !app.missingToken else { throw SteamError.authSessionExpired }
                    if let info = OwnedSteamGame.parse(appID: app.appid, from: app.buffer) {
                        allApps.append(info)
                    }
                }
            }
        }

        return allApps
    }
}