import Foundation
import Security

public struct SignatureInfo: Sendable, Equatable {
    public enum Status: Sendable, Equatable { case valid, invalid, unsigned }
    public var status: Status
    public var teamID: String?
    public var isApple: Bool
    public var isNotarized: Bool
}

/// Static code-signature checks through the Security framework (no shell).
public enum CodeSignature {
    /// `validateResources: false` checks the executable and Info.plist only: apps that rewrite files inside
    /// their own bundle (common, harmless) would otherwise all show up as invalid, and full checks are slow.
    public static func check(_ url: URL, validateResources: Bool = true) -> SignatureInfo {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            return SignatureInfo(status: .unsigned, teamID: nil, isApple: false, isNotarized: false)
        }
        var info: CFDictionary?
        SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        let dict = info as? [String: Any] ?? [:]
        if dict[kSecCodeInfoIdentifier as String] == nil {
            return SignatureInfo(status: .unsigned, teamID: nil, isApple: false, isNotarized: false)
        }
        let valid = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: validateResources ? kSecCSCheckAllArchitectures : kSecCSDoNotValidateResources), nil) == errSecSuccess
        return SignatureInfo(status: valid ? .valid : .invalid,
                             teamID: dict[kSecCodeInfoTeamIdentifier as String] as? String,
                             isApple: satisfies(code, "anchor apple"),
                             isNotarized: satisfies(code, "notarized"))
    }

    static func satisfies(_ code: SecStaticCode, _ requirement: String) -> Bool {
        var req: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess, let req else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSDoNotValidateResources), req) == errSecSuccess
    }
}
