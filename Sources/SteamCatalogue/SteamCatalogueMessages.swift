// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Jfishin, 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Derived from the pinned Madeira Steam client; see THIRD-PARTY-NOTICES.md. The protobuf
// helpers and the IAuthenticationService messages are what sign-in uses; the
// CM logon, license, product-info (PICS), depot-key and service-call messages
// were added for the owned library and downloads (docs/STEAM_LIBRARY.md).
// Field numbers are Valve's, from its public protocol definitions.

import Foundation

// MARK: - CMsgProtoBufHeader

/// Header included with every protobuf-encoded Steam message
nonisolated struct CMsgProtoBufHeader {
    var steamid: UInt64 = 0
    var clientSessionid: Int32 = 0
    var jobidSource: UInt64 = UInt64.max
    var jobidTarget: UInt64 = UInt64.max
    var targetJobName: String = ""
    var eresult: Int32 = 0

    func serialize() -> Data {
        var encoder = ProtobufEncoder()
        // Always write steamid and client_sessionid — CM servers silently drop
        // messages with an empty protobuf header (all fields at default = nothing on wire).
        encoder.writeFixed64Always(fieldNumber: 1, value: steamid)
        encoder.writeInt32Always(fieldNumber: 2, value: clientSessionid)
        // Field numbers from Valve's steammessages_base.proto:
        // jobid_source=10, jobid_target=11, target_job_name=12, eresult=13
        if jobidSource != UInt64.max {
            encoder.writeFixed64(fieldNumber: 10, value: jobidSource)
        }
        if jobidTarget != UInt64.max {
            encoder.writeFixed64(fieldNumber: 11, value: jobidTarget)
        }
        encoder.writeString(fieldNumber: 12, value: targetJobName)
        encoder.writeInt32(fieldNumber: 13, value: eresult)
        return encoder.data
    }

    static func deserialize(from data: Data) throws -> CMsgProtoBufHeader {
        var decoder = ProtobufDecoder(data)
        var header = CMsgProtoBufHeader()

        while let tag = try decoder.readTag() {
            switch tag.fieldNumber {
            case 1: header.steamid = try decoder.readFixed64()
            case 2: header.clientSessionid = Int32(truncatingIfNeeded: try decoder.readVarint())
            case 10: header.jobidSource = try decoder.readFixed64()
            case 11: header.jobidTarget = try decoder.readFixed64()
            case 12: header.targetJobName = try decoder.readString()
            case 13: header.eresult = Int32(truncatingIfNeeded: try decoder.readVarint())
            default: try decoder.skip(wireType: tag.wireType)
            }
        }

        return header
    }
}

// MARK: - Client Hello

/// Sent immediately after WebSocket connection to initiate the Steam3 handshake.
/// Without this, the CM server will reject messages and close the connection.
nonisolated struct CMsgClientHello {
    var protocolVersion: UInt32 = 65580

    func serialize() -> Data {
        var encoder = ProtobufEncoder()
        encoder.writeUInt32(fieldNumber: 1, value: protocolVersion)
        return encoder.data
    }
}

// MARK: - Client Login Messages

/// Client logon request
nonisolated struct CMsgClientLogon {
    var accountName: String = ""
    var accessToken: String = ""
    var protocolVersion: UInt32 = 65580
    var cellID: UInt32 = 0
    var clientOSType: Int32 = -102  // MacOS
    var clientLanguage: String = "english"
    var shouldRememberPassword: Bool = true
    var machineName: String = ""
    var machineID: Data = Data()
    var supportsRateLimitResponse: Bool = true
    var clientPackageVersion: UInt32 = 1771

    /// Get the machine's primary IPv4 address in host byte order (for obfuscation).
    /// getifaddrs works on both macOS and iOS — Host.current() doesn't exist on iOS.
    private static func getLocalIPv4() -> UInt32 {
        var addrList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrList) == 0, let first = addrList else { return 0 }
        defer { freeifaddrs(addrList) }
        for ifa in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            if name.hasPrefix("lo") { continue }
            let raw = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            return UInt32(bigEndian: raw)  // same byte order as a<<24|b<<16|c<<8|d
        }
        return 0
    }

    func serialize() -> Data {
        var encoder = ProtobufEncoder()
        // Field numbers from Valve's steammessages_clientserver_login.proto
        encoder.writeUInt32(fieldNumber: 1, value: protocolVersion)             // protocol_version = 1
        // obfuscated_private_ip (field 11) — CMsgIPAddress sub-message with local IPv4 XOR'd with mask.
        // Valve's own client always sends this; without it some CM servers silently ignore the logon.
        // NOTE: field 2 is deprecated_obfustucated_private_ip (uint32), field 11 is the correct CMsgIPAddress.
        let localIP = CMsgClientLogon.getLocalIPv4()
        let obfuscatedIP = localIP ^ 0xBAADF00D
        var ipEncoder = ProtobufEncoder()
        ipEncoder.writeFixed32(fieldNumber: 1, value: obfuscatedIP)
        encoder.writeSubmessage(fieldNumber: 11, value: ipEncoder.data)         // obfuscated_private_ip = 11
        if cellID != 0 {
            encoder.writeUInt32(fieldNumber: 3, value: cellID)                  // cell_id = 3
        }
        encoder.writeUInt32(fieldNumber: 5, value: clientPackageVersion)        // client_package_version = 5
        encoder.writeString(fieldNumber: 6, value: clientLanguage)              // client_language = 6
        // client_os_type = 7 (uint32 in proto; Steam uses negative values for macOS e.g. -102)
        encoder.writeUInt32(fieldNumber: 7, value: UInt32(bitPattern: clientOSType)) // client_os_type = 7
        encoder.writeBool(fieldNumber: 8, value: shouldRememberPassword)        // should_remember_password = 8
        encoder.writeBytes(fieldNumber: 30, value: machineID)                   // machine_id = 30
        encoder.writeString(fieldNumber: 50, value: accountName)                // account_name = 50
        encoder.writeString(fieldNumber: 96, value: machineName)                // machine_name = 96
        encoder.writeBool(fieldNumber: 102, value: supportsRateLimitResponse)   // supports_rate_limit_response = 102
        encoder.writeString(fieldNumber: 108, value: accessToken)               // access_token = 108
        return encoder.data
    }
}

/// Client logon response
nonisolated struct CMsgClientLogonResponse {
    var eresult: Int32 = 0
    var heartbeatSeconds: Int32 = 0
    var clientSuppliedSteamID: UInt64 = 0
    var vanityURL: String = ""
    var cellID: UInt32 = 0

    static func deserialize(from data: Data) throws -> Self {
        var decoder = ProtobufDecoder(data)
        var msg = Self()

        while let tag = try decoder.readTag() {
            switch tag.fieldNumber {
            case 1: msg.eresult = Int32(truncatingIfNeeded: try decoder.readVarint())       // eresult = 1
            case 3: msg.heartbeatSeconds = Int32(truncatingIfNeeded: try decoder.readVarint()) // heartbeat_seconds = 3
            case 7: msg.cellID = UInt32(truncatingIfNeeded: try decoder.readVarint())                           // cell_id = 7
            case 14: msg.vanityURL = try decoder.readString()                               // vanity_url = 14
            case 20: msg.clientSuppliedSteamID = try decoder.readFixed64()                  // client_supplied_steamid = 20
            default: try decoder.skip(wireType: tag.wireType)
            }
        }
        return msg
    }
}

// MARK: - License / Ownership Messages

nonisolated struct CMsgClientLicenseList {
    struct License {
        var packageID: UInt32 = 0
        var timeCreated: UInt32 = 0
        var timeNextProcess: UInt32 = 0
        var minuteLimit: Int32 = 0
        var minutesUsed: Int32 = 0
        var paymentMethod: UInt32 = 0
        var flags: UInt32 = 0
        var purchaseCountryCode: String = ""
        var licenseType: UInt32 = 0
        var territoryCode: Int32 = 0
        var ownerID: UInt32 = 0
    }

    var eresult: Int32 = 0
    var licenses: [License] = []

    static func deserialize(from data: Data) throws -> Self {
        var decoder = ProtobufDecoder(data)
        var msg = Self()

        while let tag = try decoder.readTag() {
            switch tag.fieldNumber {
            case 1: msg.eresult = Int32(truncatingIfNeeded: try decoder.readVarint())
            case 2:
                let subData = try decoder.readBytes()
                var subDecoder = ProtobufDecoder(subData)
                var license = License()
                while let subTag = try subDecoder.readTag() {
                    switch subTag.fieldNumber {
                    case 1: license.packageID = UInt32(truncatingIfNeeded: try subDecoder.readVarint())
                    case 2: license.timeCreated = try subDecoder.readFixed32()      // fixed32 on the wire, not varint
                    case 3: license.timeNextProcess = try subDecoder.readFixed32()  // fixed32 on the wire, not varint
                    case 4: license.minuteLimit = Int32(truncatingIfNeeded: try subDecoder.readVarint())
                    case 5: license.minutesUsed = Int32(truncatingIfNeeded: try subDecoder.readVarint())
                    case 6: license.paymentMethod = UInt32(truncatingIfNeeded: try subDecoder.readVarint())
                    case 7: license.flags = UInt32(truncatingIfNeeded: try subDecoder.readVarint())
                    case 8: license.purchaseCountryCode = try subDecoder.readString()
                    case 9: license.licenseType = UInt32(truncatingIfNeeded: try subDecoder.readVarint())
                    case 10: license.territoryCode = Int32(truncatingIfNeeded: try subDecoder.readVarint())
                    case 14: license.ownerID = UInt32(truncatingIfNeeded: try subDecoder.readVarint())
                    default: try subDecoder.skip(wireType: subTag.wireType)
                    }
                }
                msg.licenses.append(license)
            default: try decoder.skip(wireType: tag.wireType)
            }
        }
        return msg
    }
}

// MARK: - PICS Messages

nonisolated struct CMsgClientPICSProductInfoRequest {
    struct AppInfo {
        var appid: UInt32 = 0
        var accessToken: UInt64 = 0
    }
    struct PackageInfo {
        var packageid: UInt32 = 0
        var accessToken: UInt64 = 0
    }

    var apps: [AppInfo] = []
    var packages: [PackageInfo] = []
    var metaDataOnly: Bool = false

    func serialize() -> Data {
        // Field numbers per steammessages_clientserver_appinfo.proto:
        // packages = 1, apps = 2; access_token is uint64 (varint).
        var encoder = ProtobufEncoder()
        for pkg in packages {
            var subEncoder = ProtobufEncoder()
            subEncoder.writeUInt32(fieldNumber: 1, value: pkg.packageid)
            subEncoder.writeUInt64(fieldNumber: 2, value: pkg.accessToken)
            encoder.writeSubmessage(fieldNumber: 1, value: subEncoder.data)
        }
        for app in apps {
            var subEncoder = ProtobufEncoder()
            subEncoder.writeUInt32(fieldNumber: 1, value: app.appid)
            subEncoder.writeUInt64(fieldNumber: 2, value: app.accessToken)
            encoder.writeSubmessage(fieldNumber: 2, value: subEncoder.data)
        }
        encoder.writeBool(fieldNumber: 3, value: metaDataOnly)
        return encoder.data
    }
}

nonisolated struct CMsgClientPICSProductInfoResponse {
    struct AppInfo {
        var appid: UInt32 = 0
        var changeNumber: UInt32 = 0
        /// Field 3, set when the request lacked a valid access token.
        var missingToken = false
        var buffer: Data = Data()  // VDF binary format app info
    }
    struct PackageInfo {
        var packageid: UInt32 = 0
        var changeNumber: UInt32 = 0
        var buffer: Data = Data()
    }

    var apps: [AppInfo] = []
    var packages: [PackageInfo] = []
    var unknownApps: [UInt32] = []
    var unknownPackages: [UInt32] = []
    // Field 6: how many more PICSProductInfoResponse messages are coming for this job.
    // When 0, all parts have been received.
    var pendingResponseCount: Int32 = 0

    static func deserialize(from data: Data) throws -> Self {
        var decoder = ProtobufDecoder(data)
        var msg = Self()

        while let tag = try decoder.readTag() {
            switch tag.fieldNumber {
            case 1:
                let subData = try decoder.readBytes()
                var subDecoder = ProtobufDecoder(subData)
                var app = AppInfo()
                while let subTag = try subDecoder.readTag() {
                    switch subTag.fieldNumber {
                    case 1: app.appid = UInt32(truncatingIfNeeded: try subDecoder.readVarint())
                    case 2: app.changeNumber = UInt32(truncatingIfNeeded: try subDecoder.readVarint())
                    case 3 where subTag.wireType == .varint: app.missingToken = try subDecoder.readVarint() != 0
                    case 5: app.buffer = try subDecoder.readBytes()
                    default: try subDecoder.skip(wireType: subTag.wireType)
                    }
                }
                msg.apps.append(app)
            case 2: msg.unknownApps.append(UInt32(truncatingIfNeeded: try decoder.readVarint()))
            case 3:
                let subData = try decoder.readBytes()
                var subDecoder = ProtobufDecoder(subData)
                var pkg = PackageInfo()
                while let subTag = try subDecoder.readTag() {
                    switch subTag.fieldNumber {
                    case 1: pkg.packageid = UInt32(truncatingIfNeeded: try subDecoder.readVarint())
                    case 2: pkg.changeNumber = UInt32(truncatingIfNeeded: try subDecoder.readVarint())
                    case 5: pkg.buffer = try subDecoder.readBytes()
                    default: try subDecoder.skip(wireType: subTag.wireType)
                    }
                }
                msg.packages.append(pkg)
            case 4: msg.unknownPackages.append(UInt32(truncatingIfNeeded: try decoder.readVarint()))
            case 6: msg.pendingResponseCount = Int32(truncatingIfNeeded: try decoder.readVarint())
            default: try decoder.skip(wireType: tag.wireType)
            }
        }
        return msg
    }
}

// MARK: - Multi Message (for bundled responses)

nonisolated struct CMsgMulti {
    var sizeUnzipped: UInt32 = 0
    var messageBody: Data = Data()

    static func deserialize(from data: Data) throws -> Self {
        var decoder = ProtobufDecoder(data)
        var msg = Self()

        while let tag = try decoder.readTag() {
            switch tag.fieldNumber {
            case 1: msg.sizeUnzipped = UInt32(truncatingIfNeeded: try decoder.readVarint())
            case 2: msg.messageBody = try decoder.readBytes()
            default: try decoder.skip(wireType: tag.wireType)
            }
        }
        return msg
    }
}

// MARK: - PICS Access Token Messages

nonisolated struct CMsgClientPICSAccessTokenRequest {
    var appids: [UInt32] = []
    var packageids: [UInt32] = []

    func serialize() -> Data {
        // Field numbers per steammessages_clientserver_appinfo.proto:
        // packageids = 1, appids = 2.
        var encoder = ProtobufEncoder()
        for pkgid in packageids {
            encoder.writeUInt32(fieldNumber: 1, value: pkgid)
        }
        for appid in appids {
            encoder.writeUInt32(fieldNumber: 2, value: appid)
        }
        return encoder.data
    }
}

nonisolated struct CMsgClientPICSAccessTokenResponse {
    struct AppToken {
        var appid: UInt32 = 0
        var accessToken: UInt64 = 0
    }
    struct PackageToken {
        var packageid: UInt32 = 0
        var accessToken: UInt64 = 0
    }

    var appAccessTokens: [AppToken] = []
    var packageAccessTokens: [PackageToken] = []
    var appAccessTokensDenied: [UInt32] = []
    var packageAccessTokensDenied: [UInt32] = []

    static func deserialize(from data: Data) throws -> Self {
        var decoder = ProtobufDecoder(data)
        var msg = Self()

        // Field numbers per steammessages_clientserver_appinfo.proto:
        // package_access_tokens = 1, package_denied_tokens = 2,
        // app_access_tokens = 3, app_denied_tokens = 4.
        // access_token is uint64 (varint), not fixed64.
        while let tag = try decoder.readTag() {
            switch tag.fieldNumber {
            case 1:
                let subData = try decoder.readBytes()
                var sub = ProtobufDecoder(subData)
                var token = PackageToken()
                while let st = try sub.readTag() {
                    switch st.fieldNumber {
                    case 1: token.packageid = UInt32(truncatingIfNeeded: try sub.readVarint())
                    case 2: token.accessToken = try sub.readVarint()
                    default: try sub.skip(wireType: st.wireType)
                    }
                }
                msg.packageAccessTokens.append(token)
            case 2: msg.packageAccessTokensDenied.append(UInt32(truncatingIfNeeded: try decoder.readVarint()))
            case 3:
                let subData = try decoder.readBytes()
                var sub = ProtobufDecoder(subData)
                var token = AppToken()
                while let st = try sub.readTag() {
                    switch st.fieldNumber {
                    case 1: token.appid = UInt32(truncatingIfNeeded: try sub.readVarint())
                    case 2: token.accessToken = try sub.readVarint()
                    default: try sub.skip(wireType: st.wireType)
                    }
                }
                msg.appAccessTokens.append(token)
            case 4: msg.appAccessTokensDenied.append(UInt32(truncatingIfNeeded: try decoder.readVarint()))
            default: try decoder.skip(wireType: tag.wireType)
            }
        }
        return msg
    }
}
