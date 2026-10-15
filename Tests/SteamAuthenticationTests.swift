import Foundation
import Testing
@testable import SteamLibrary

@MainActor struct SteamAuthenticationTests {
    @Test func credentialRequestUsesClientSessionFields() throws {
        var request = CAuthentication_BeginAuthSessionViaCredentials_Request()
        request.accountName = "fixture"
        request.encryptedPassword = "encrypted-fixture"
        request.encryptionTimestamp = 123
        request.deviceFriendlyName = "Test Mac"
        var decoder = ProtobufDecoder(request.serialize())
        var strings: [UInt32: String] = [:]
        var numbers: [UInt32: UInt64] = [:]
        while let tag = try decoder.readTag() {
            if tag.wireType == .varint { numbers[tag.fieldNumber] = try decoder.readVarint() }
            else if tag.fieldNumber == 9 { _ = try decoder.readBytes() }
            else { strings[tag.fieldNumber] = try decoder.readString() }
        }
        #expect(strings[1] == "Test Mac")
        #expect(strings[2] == "fixture")
        #expect(strings[3] == "encrypted-fixture")
        #expect(strings[8] == "Client")
        #expect(numbers[4] == 123)
        #expect(numbers[6] == 1)
        #expect(numbers[7] == 1)
    }

    @Test(arguments: [Data([0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0x7f]), Data([0x00]), Data([0x0a,0xff,0xff,0xff,0x7f])])
    func rejectsMalformedNetworkMessages(_ bytes: Data) {
        #expect(throws: SteamError.self) { try CAuthentication_BeginAuthSessionViaQR_Response.deserialize(from: bytes) }
    }

    @Test func readsGuardOptionsTogether() throws {
        var response = ProtobufEncoder()
        response.writeUInt64(fieldNumber: 1, value: 123)
        response.writeBytes(fieldNumber: 2, value: Data([1,2,3]))
        for type: UInt32 in [4,3] {
            var confirmation = ProtobufEncoder()
            confirmation.writeUInt32(fieldNumber: 1, value: type)
            response.writeSubmessage(fieldNumber: 4, value: confirmation.data)
        }
        let decoded = try CAuthentication_BeginAuthSessionViaCredentials_Response.deserialize(from: response.data)
        #expect(decoded.allowedConfirmations.map(\.confirmationType) == [4,3])
    }

    @Test func expiredAndMalformedTokensCannotBecomeLaunchCredentials() throws {
        func fixture(expiration: Double) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: ["sub":"12345", "exp":expiration])
            let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            return "fixture.\(encoded).fixture"
        }
        let date = Date(timeIntervalSince1970: 1000)
        let valid = SteamCredentials(accountName: "fixture", refreshToken: try fixture(expiration: 2000), accessToken: "fixture")
        let expired = SteamCredentials(accountName: "fixture", refreshToken: try fixture(expiration: 500), accessToken: "fixture")
        #expect(valid.isUsable(at: date))
        #expect(valid.steamID == 12345)
        #expect(!expired.isUsable(at: date))
        #expect(!SteamCredentials(accountName: "fixture", refreshToken: "garbage", accessToken: "").isUsable(at: date))
    }

    @Test func steamErrorsAreInterpretedBeforePolling() {
        #expect(SteamAuthAPI.error(for: 5) == .invalidCredentials)
        #expect(SteamAuthAPI.error(for: 84) == .rateLimited)
        #expect(SteamAuthAPI.error(for: 27) == .authSessionExpired)
    }
}
