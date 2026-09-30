import Foundation

/// BIP-173 bech32, the encoding side only.
///
/// The core decodes bech32 for us (`AddressFromBech32`, `PubKeyBytesFromBech32`)
/// but exposes no encoder for a **public key**, and `gnokey maketx session
/// create -pubkey` wants exactly that: `gpub…`, the amino bytes of the key under
/// the `gpub` hrp. Without this the app could mint a session key and still not
/// say which key it minted.
///
/// `GnoKeyInfo.pubKey` already carries `pubkey.Bytes()`, so this is only the
/// 8-to-5-bit regroup plus the checksum. `Bech32Tests` proves the output by
/// feeding it back through the core's own decoder.
public enum Bech32 {
    /// gno's public-key hrp (`tm2/pkg/crypto/globals.go`).
    public static let pubKeyPrefix = "gpub"

    private static let charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
    private static let generator: [UInt32] = [0x3b6a_57b2, 0x2650_8e6d, 0x1ea1_19fa, 0x3d42_33dd, 0x2a14_62b3]

    public static func encode(hrp: String, data: Data) -> String {
        let values = convertBits(Array(data), from: 8, to: 5, pad: true)
        let checksum = createChecksum(hrp: hrp, values: values)
        let payload = (values + checksum).map { charset[Int($0)] }
        return hrp + "1" + String(payload)
    }

    /// The bech32 form `gnokey -pubkey` expects.
    public static func pubKey(_ bytes: Data) -> String {
        encode(hrp: pubKeyPrefix, data: bytes)
    }

    private static func convertBits(_ input: [UInt8], from: UInt32, to: UInt32, pad: Bool) -> [UInt8] {
        var accumulator: UInt32 = 0
        var bits: UInt32 = 0
        var output: [UInt8] = []
        let maxValue: UInt32 = (1 << to) - 1

        for byte in input {
            accumulator = (accumulator << from) | UInt32(byte)
            bits += from
            while bits >= to {
                bits -= to
                output.append(UInt8((accumulator >> bits) & maxValue))
            }
        }
        if pad, bits > 0 {
            output.append(UInt8((accumulator << (to - bits)) & maxValue))
        }
        return output
    }

    private static func polymod(_ values: [UInt8]) -> UInt32 {
        var checksum: UInt32 = 1
        for value in values {
            let top = checksum >> 25
            checksum = ((checksum & 0x1ff_ffff) << 5) ^ UInt32(value)
            for (index, constant) in generator.enumerated() where (top >> UInt32(index)) & 1 == 1 {
                checksum ^= constant
            }
        }
        return checksum
    }

    private static func expand(hrp: String) -> [UInt8] {
        let bytes = Array(hrp.utf8)
        return bytes.map { $0 >> 5 } + [0] + bytes.map { $0 & 31 }
    }

    private static func createChecksum(hrp: String, values: [UInt8]) -> [UInt8] {
        let enc = expand(hrp: hrp) + values + [0, 0, 0, 0, 0, 0]
        let mod = polymod(enc) ^ 1
        return (0..<6).map { UInt8((mod >> (5 * (5 - UInt32($0)))) & 31) }
    }
}
