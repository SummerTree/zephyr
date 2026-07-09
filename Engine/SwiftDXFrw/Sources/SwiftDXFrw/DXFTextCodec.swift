import Foundation
#if canImport(CIconv)
import CIconv
#endif

/// Cross-platform DXF text codec.
///
/// Uses iconv for ALL code page conversions (SBCS + DBCS) — same engine
/// that libdxfrw's DRW_ExtConverter uses via its iconv path.
///
/// Platforms:
///   - macOS:  system libiconv (linked via CIconv module)
///   - Linux:  glibc iconv (linked via CIconv module)
///   - Windows: requires libiconv.dll (install via vcpkg/brew/apt)
///
/// Fallback: built-in CP1252 table for environments without iconv.
/// Handles \U+XXXX escape sequences per the DXF spec.
///
/// Mirrors libdxfrw DRW_TextCodec (drw_textcodec.h/cpp).
public class DXFTextCodec {

    public var version: DXFVersion = .r2007
    public var codePage: String = "ANSI_1252"

    public init() {
        setCodePage("ANSI_1252")
    }

    /// Set code page from DXF $DWGCODEPAGE value
    public func setCodePage(_ cp: String) {
        codePage = normalizeCodePage(cp)
    }

    /// Set DXF version
    public func setVersion(_ v: DXFVersion) {
        version = v
    }

    /// Normalize DXF code page name to canonical form
    public func normalizeCodePage(_ cp: String) -> String {
        let s = cp.uppercased().trimmingCharacters(in: .whitespaces)

        if s == "ANSI_874" || s == "CP874" || s == "ISO8859-11" || s == "TIS-620" { return "ANSI_874" }
        if s == "ANSI_1250" || s == "CP1250" || s == "ISO8859-2" { return "ANSI_1250" }
        if s == "ANSI_1251" || s == "CP1251" || s == "ISO8859-5" || s == "KOI8-R" || s == "KOI8-U" || s == "IBM 866" { return "ANSI_1251" }
        if s == "ANSI_1252" || s == "CP1252" || s == "LATIN1" || s == "ISO-8859-1" || s == "ISO8859-1" || s == "ISO8859-15" || s == "APPLE ROMAN" || s == "IBM 850" { return "ANSI_1252" }
        if s == "ANSI_1253" || s == "CP1253" || s == "ISO8859-7" { return "ANSI_1253" }
        if s == "ANSI_1254" || s == "CP1254" || s == "ISO8859-9" || s == "ISO8859-3" { return "ANSI_1254" }
        if s == "ANSI_1255" || s == "CP1255" || s == "ISO8859-8" { return "ANSI_1255" }
        if s == "ANSI_1256" || s == "CP1256" || s == "ISO8859-6" { return "ANSI_1256" }
        if s == "ANSI_1257" || s == "CP1257" || s == "ISO8859-4" || s == "ISO8859-10" || s == "ISO8859-13" { return "ANSI_1257" }
        if s == "ANSI_1258" || s == "CP1258" { return "ANSI_1258" }
        if s == "ANSI_932" || s == "SHIFT-JIS" || s == "SHIFT_JIS" || s == "CSSHIFTJIS" || s == "MS_KANJI" || s == "EUCJP" || s == "EUC-JP" || s == "JIS7" { return "ANSI_932" }
        if s == "ANSI_936" || s == "GBK" || s == "GB2312" || s == "GB18030" { return "ANSI_936" }
        if s == "ANSI_949" || s == "EUCKR" || s == "EUC-KR" { return "ANSI_949" }
        if s == "ANSI_950" || s == "BIG5" || s == "BIG5-HKSCS" { return "ANSI_950" }
        if s == "UTF-8" || s == "UTF8" { return "UTF-8" }
        if s == "UTF-16" || s == "UTF16" { return "UTF-16" }
        return "ANSI_1252"
    }

    /// Map canonical code page to iconv encoding name
    private func iconvNameFor(_ cp: String) -> String {
        switch cp {
        case "ANSI_874":  return "CP874"
        case "ANSI_1250": return "CP1250"
        case "ANSI_1251": return "CP1251"
        case "ANSI_1252": return "CP1252"
        case "ANSI_1253": return "CP1253"
        case "ANSI_1254": return "CP1254"
        case "ANSI_1255": return "CP1255"
        case "ANSI_1256": return "CP1256"
        case "ANSI_1257": return "CP1257"
        case "ANSI_1258": return "CP1258"
        case "ANSI_932":  return "SHIFT_JIS"
        case "ANSI_936":  return "GBK"
        case "ANSI_949":  return "EUC-KR"
        case "ANSI_950":  return "BIG5"
        default:          return "CP1252"
        }
    }

    // MARK: - Public API

    /// Convert string from DXF code page to UTF-8.
    /// Decodes \U+XXXX escape sequences embedded in the encoded text.
    public func toUtf8(_ s: String) -> String {
        if codePage == "UTF-8"  { return decodeUnicodeEscapes(s) }
        if codePage == "UTF-16" { return decodeUnicodeEscapes(s) }

        let decoded: String
        if #available(macOS 10.10, *) {
            decoded = iconvConvert(s, from: codePage, to: "UTF-8")
        } else {
            decoded = fallbackDecode(s)
        }
        return decodeUnicodeEscapes(decoded)
    }

    /// Convert string from UTF-8 to DXF code page.
    /// Characters not representable in target encoding become \U+XXXX.
    public func fromUtf8(_ s: String) -> String {
        if codePage == "UTF-8"  { return s }
        if codePage == "UTF-16" { return s }

        let encoded: String
        if #available(macOS 10.10, *) {
            encoded = iconvConvert(s, from: "UTF-8", to: codePage)
        } else {
            encoded = fallbackEncode(s)
        }
        // If iconv result is empty (conversion failed), escape non-representable chars
        if encoded.isEmpty && !s.isEmpty {
            return escapeNonRepresentable(s)
        }
        return encoded
    }

    // MARK: - iconv Conversion

    /// Convert string between encodings using iconv.
    /// Returns empty string on failure.
    private func iconvConvert(_ s: String, from fromCP: String, to toCP: String) -> String {
        #if canImport(CIconv)
        let fromName = iconvNameFor(fromCP)
        let toName = iconvNameFor(toCP)

        let cd = CIconv.ci_iconv_open(toName, fromName)
        // iconv_open returns (iconv_t)-1 on failure → opaque pointer with value ~0
        let cdRaw = unsafeBitCast(cd, to: Int.self)
        if cdRaw == -1 {
            return fallbackConvert(s, from: fromCP, to: toCP)
        }
        defer { CIconv.ci_iconv_close(cd) }

        // Raw bytes of the string (Swift String uses UTF-8 internally)
        let inData = Data(s.utf8)
        let bufSize = max(inData.count * 4 + 64, 4096)
        var outBuf = [CChar](repeating: 0, count: bufSize)

        var inBytes = size_t(inData.count)
        var outBytes = size_t(bufSize - 2)

        inData.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            var inPtr: UnsafeMutablePointer<CChar>? = UnsafeMutablePointer(mutating: base.assumingMemoryBound(to: CChar.self))
            var outPtr: UnsafeMutablePointer<CChar>? = outBuf.withUnsafeMutableBufferPointer { $0.baseAddress! }
            let _ = CIconv.ci_iconv(cd, &inPtr, &inBytes, &outPtr, &outBytes)
        }

        let written = bufSize - 2 - Int(outBytes)
        let outSlice = outBuf[0..<written].map(UInt8.init)
        return String(decoding: outSlice, as: UTF8.self)
        #else
        return fallbackConvert(s, from: fromCP, to: toCP)
        #endif
    }

    // MARK: - Fallback (no iconv)

    /// Fallback: use Foundation encoding or CP1252 table
    private func fallbackConvert(_ s: String, from: String, to: String) -> String {
        if to == "UTF-8" {
            return fallbackDecode(s)
        } else {
            return fallbackEncode(s)
        }
    }

    private func fallbackDecode(_ s: String) -> String {
        // Try Foundation String.Encoding first
        let enc = foundationEncodingFor(codePage)
        if let data = s.data(using: enc, allowLossyConversion: true),
           let decoded = String(data: data, encoding: .utf8) {
            return decoded
        }
        // Fallback to CP1252 table
        return decode1252Table(s)
    }

    private func fallbackEncode(_ s: String) -> String {
        let enc = foundationEncodingFor(codePage)
        if let data = s.data(using: .utf8),
           let encoded = String(data: data, encoding: enc) {
            return encoded
        }
        return encode1252Table(s)
    }

    /// Best-effort Foundation encoding for fallback path
    private func foundationEncodingFor(_ cp: String) -> String.Encoding {
        switch cp {
        case "ANSI_1252": return .windowsCP1252
        case "ANSI_932":  return .shiftJIS
        default:          return .windowsCP1252
        }
    }

    // MARK: - \U+XXXX Escape Handling

    private func decodeUnicodeEscapes(_ s: String) -> String {
        var result = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "\\", s[i...].hasPrefix("\\U+") {
                var hex = ""
                var j = s.index(i, offsetBy: 3)
                while j < s.endIndex, hex.count < 4, s[j].isHexDigit {
                    hex.append(s[j]); j = s.index(after: j)
                }
                if let code = Int(hex, radix: 16), let scalar = UnicodeScalar(code) {
                    result.append(Character(scalar)); i = j
                } else { result.append(s[i]); i = s.index(after: i) }
            } else { result.append(s[i]); i = s.index(after: i) }
        }
        return result
    }

    private func escapeNonRepresentable(_ s: String) -> String {
        let enc = foundationEncodingFor(codePage)
        var result = ""
        for ch in s {
            if String(ch).data(using: enc, allowLossyConversion: true) != nil {
                result.append(ch)
            } else {
                result += String(format: "\\U+%04X", ch.unicodeScalars.first!.value)
            }
        }
        return result
    }

    // MARK: - CP1252 Fallback Table

    /// CP1252-specific chars (0x80-0x9F) → Unicode
    private static let cp1252ToUnicode: [UInt16] = [
        0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
        0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
        0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
        0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
    ]

    private func decode1252Table(_ s: String) -> String {
        var result = ""
        for byte in s.utf8 {
            if byte < 0x80 || byte >= 0xA0 {
                result.append(Character(UnicodeScalar(UInt32(byte))!))
            } else {
                let unicode = Self.cp1252ToUnicode[Int(byte) - 0x80]
                result.append(Character(UnicodeScalar(unicode)!))
            }
        }
        return decodeUnicodeEscapes(result)
    }

    private func encode1252Table(_ s: String) -> String {
        var result = ""
        for ch in s {
            let val = ch.unicodeScalars.first!.value
            if val < 0x80 || (val >= 0xA0 && val <= 0xFF && !isCP1252Special(val)) {
                result.append(Character(UnicodeScalar(val & 0xFF)!))
            } else if let idx = Self.cp1252ToUnicode.firstIndex(of: UInt16(val)) {
                result.append(Character(UnicodeScalar(UInt32(0x80 + idx))!))
            } else {
                result += String(format: "\\U+%04X", val)
            }
        }
        return result
    }

    private func isCP1252Special(_ val: UInt32) -> Bool {
        Self.cp1252ToUnicode.contains(UInt16(val))
    }
}
