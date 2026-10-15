// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Jfishin, 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Derived from the pinned Madeira Steam client; see THIRD-PARTY-NOTICES.md. Reduced to the
// message types the owned library and downloads use. The numbers are Valve's
// (steammessages / enums.proto): interface facts of Steam's public protocol.

import Foundation

// MARK: - Connection state

nonisolated enum SteamConnectionState: String, Sendable {
    case disconnected
    case connecting
    case connected       // WebSocket up, not yet logged on
    case authenticated   // logged on
    case reconnecting    // lost the connection, trying again
}

// MARK: - Message types

/// The message types the library and downloads use.
nonisolated enum EMsg: UInt32 {
    /// Set on the message type of a protobuf-encoded message.
    static let protoMask: UInt32 = 0x80000000

    case multi = 1
    case clientHeartBeat = 703
    case clientHello = 4006
    case clientLogon = 5514
    case clientLogonResponse = 5515
    case clientLogOff = 5516
    case clientLoggedOff = 5517
    case clientLicenseList = 780
    case clientPICSProductInfoRequest = 8903
    case clientPICSProductInfoResponse = 8904
    case clientPICSAccessTokenRequest = 8905
    case clientPICSAccessTokenResponse = 8906
    case clientGetDepotDecryptionKey = 5438
    case clientGetDepotDecryptionKeyResponse = 5439
    case serviceMethod = 146
    case serviceMethodResponse = 147
    case serviceMethodCallFromClient = 151

    /// The raw value with the protobuf flag set.
    var masked: UInt32 { rawValue | EMsg.protoMask }
}

// MARK: - Result codes

nonisolated enum EResult: UInt32 {
    case ok = 1
    case tryAnotherCM = 48   // the server is overloaded; connect to another

    var isSuccess: Bool { self == .ok }
}
