// ---------------------------------------------------------------------------
// ZStrdup.swift — Cross-platform strdup wrapper
//
// MSVC names this _strdup; POSIX (Darwin/Glibc) names it strdup.
// This helper centralizes the platform difference so callers don't need
// conditional compilation at every call site.
// ---------------------------------------------------------------------------

#if os(Windows)
import ucrt

/// Duplicate a C string — Windows `_strdup` underneath.
public func z_strdup(_ s: String) -> UnsafeMutablePointer<CChar>! {
    return s.withCString { _strdup($0) }
}
#else
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Duplicate a C string — POSIX `strdup` underneath.
public func z_strdup(_ s: String) -> UnsafeMutablePointer<CChar>! {
    return s.withCString { strdup($0) }
}
#endif
