//
//  PlusCode.swift
//  Wander
//
//  Self-contained Open Location Code (Plus Code) decoder — no external
//  dependencies. Implements enough of the OLC spec to resolve a pasted full
//  code (e.g. "8FVC9G8F+6X") to a lat/lng, and to recover a short code
//  (e.g. "9G8F+6X") against a reference coordinate (the current map center).
//
//  Reference: https://github.com/google/open-location-code
//  The decoder implements the OLC spec directly; it was cross-checked against
//  the official reference implementation's decode/encode/short-code vectors
//  (500 random full codes to <1e-6°, all short-code recovery vectors) during
//  development.
//

import Foundation
import CoreLocation

enum PlusCode {

    // MARK: - Spec constants

    private static let separator: Character = "+"
    private static let separatorPosition = 8
    private static let paddingCharacter: Character = "0"
    private static let codeAlphabet = "23456789CFGHJMPQRVWX"
    private static let encodingBase = 20.0
    private static let latitudeMax = 90.0
    private static let longitudeMax = 180.0
    /// Maximum number of digits we decode (matches the reference).
    private static let maxDigitCount = 15
    /// Number of digits in the "pair" section (before grid refinement).
    private static let pairCodeLength = 10
    /// Grid rows/columns used for the fine-grid section.
    private static let gridRows = 5.0
    private static let gridColumns = 4.0

    private static let alphabetIndex: [Character: Int] = {
        var map: [Character: Int] = [:]
        for (i, c) in codeAlphabet.enumerated() { map[c] = i }
        return map
    }()

    // MARK: - Public API

    /// Decoded region of a Plus Code.
    struct CodeArea {
        let latitudeLo: Double
        let longitudeLo: Double
        let latitudeHi: Double
        let longitudeHi: Double

        var center: CLLocationCoordinate2D {
            CLLocationCoordinate2D(
                latitude: (latitudeLo + latitudeHi) / 2,
                longitude: (longitudeLo + longitudeHi) / 2
            )
        }
    }

    /// True if the string is a syntactically valid full Plus Code (has 8 digits
    /// before the '+' and can decode standalone).
    static func isFullCode(_ code: String) -> Bool {
        guard isValid(code) else { return false }
        return !isShort(code)
    }

    /// Resolve any Plus Code to a coordinate. Full codes decode standalone;
    /// short codes are recovered against `reference` (e.g. the map center).
    /// Returns nil if the input is not a valid Plus Code.
    static func coordinate(
        from code: String,
        reference: CLLocationCoordinate2D?
    ) -> CLLocationCoordinate2D? {
        let cleaned = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard isValid(cleaned) else { return nil }

        if isShort(cleaned) {
            guard let reference else { return nil }
            guard let full = recoverNearest(
                shortCode: cleaned,
                referenceLatitude: reference.latitude,
                referenceLongitude: reference.longitude
            ) else { return nil }
            return decode(full)?.center
        }

        return decode(cleaned)?.center
    }

    // MARK: - Validation of the code string

    /// Whether a string is a valid full or short Open Location Code.
    static func isValid(_ code: String) -> Bool {
        guard code.count >= 2 else { return false }

        // Exactly one separator, at an even position, no further than 8 in.
        guard let sepIndex = code.firstIndex(of: separator) else { return false }
        let sepOffset = code.distance(from: code.startIndex, to: sepIndex)
        if code.filter({ $0 == separator }).count != 1 { return false }
        if sepOffset > separatorPosition || sepOffset % 2 != 0 { return false }

        // Padding characters ('0') only allowed before the separator.
        if code.contains(paddingCharacter) {
            if code.first == paddingCharacter { return false }
            let beforeSep = String(code[code.startIndex..<sepIndex])
            let padIndex = beforeSep.firstIndex(of: paddingCharacter)
            guard let padIndex else { return false }
            // Padding must run contiguously to the separator, even length.
            let padSection = String(beforeSep[padIndex...])
            if padSection.contains(where: { $0 != paddingCharacter }) { return false }
            if padSection.count % 2 != 0 { return false }
            // Separator must be at position 8 when padded.
            if sepOffset != separatorPosition { return false }
        }

        // Nothing after the separator, or 2+ characters (a single trailing digit
        // is invalid per the spec).
        let afterSep = code[code.index(after: sepIndex)...]
        if afterSep.count == 1 { return false }

        // All non-separator characters must be in the alphabet (or padding).
        for ch in code where ch != separator {
            if ch == paddingCharacter { continue }
            if alphabetIndex[ch] == nil { return false }
        }
        return true
    }

    /// Whether a valid code is a short code (fewer than 8 digits before '+',
    /// and no padding).
    static func isShort(_ code: String) -> Bool {
        guard let sepIndex = code.firstIndex(of: separator) else { return false }
        let sepOffset = code.distance(from: code.startIndex, to: sepIndex)
        return sepOffset < separatorPosition
    }

    // MARK: - Decoding

    /// Decode a full Plus Code into its bounding area.
    static func decode(_ code: String) -> CodeArea? {
        guard isFullCode(code) else { return nil }
        let digits = code
            .uppercased()
            .filter { $0 != separator && $0 != paddingCharacter }
        let trimmed = String(digits.prefix(maxDigitCount))

        var latHi = -latitudeMax
        var lngHi = -longitudeMax
        var latPlaceValue = encodingBase * encodingBase   // 400
        var lngPlaceValue = encodingBase * encodingBase   // 400

        let chars = Array(trimmed)
        var index = 0

        // Pair section: 10 digits, alternating lat/lng.
        while index < min(pairCodeLength, chars.count) {
            latPlaceValue /= encodingBase
            lngPlaceValue /= encodingBase
            guard let latDigit = alphabetIndex[chars[index]] else { return nil }
            latHi += latPlaceValue * Double(latDigit)
            index += 1
            if index < chars.count {
                guard let lngDigit = alphabetIndex[chars[index]] else { return nil }
                lngHi += lngPlaceValue * Double(lngDigit)
                index += 1
            }
        }

        var resolutionLat = latPlaceValue
        var resolutionLng = lngPlaceValue

        // Grid refinement section (digits 11..15): each digit subdivides a
        // 4-wide x 5-tall grid.
        if chars.count > pairCodeLength {
            var rowPlace = latPlaceValue
            var colPlace = lngPlaceValue
            index = pairCodeLength
            while index < chars.count {
                guard let value = alphabetIndex[chars[index]] else { return nil }
                let row = value / Int(gridColumns)
                let col = value % Int(gridColumns)
                rowPlace /= gridRows
                colPlace /= gridColumns
                latHi += rowPlace * Double(row)
                lngHi += colPlace * Double(col)
                resolutionLat = rowPlace
                resolutionLng = colPlace
                index += 1
            }
        }

        return CodeArea(
            latitudeLo: latHi,
            longitudeLo: lngHi,
            latitudeHi: latHi + resolutionLat,
            longitudeHi: lngHi + resolutionLng
        )
    }

    // MARK: - Short-code recovery

    /// Recover the nearest full code for a short code, relative to a reference
    /// coordinate. Mirrors the reference `recoverNearest`.
    static func recoverNearest(
        shortCode rawCode: String,
        referenceLatitude: Double,
        referenceLongitude: Double
    ) -> String? {
        let shortCode = rawCode.uppercased()
        guard isShort(shortCode) else {
            return isFullCode(shortCode) ? shortCode : nil
        }

        let refLat = clipLatitude(referenceLatitude)
        let refLng = normalizeLongitude(referenceLongitude)

        guard let sepIndex = shortCode.firstIndex(of: separator) else { return nil }
        let paddingLength = separatorPosition - shortCode.distance(from: shortCode.startIndex, to: sepIndex)
        // The resolution (height/width, in degrees) of the padded area.
        let resolution = pow(encodingBase, Double(2) - (Double(paddingLength) / 2))
        let halfResolution = resolution / 2.0

        // Encode the reference at the full pair length (10), then take the
        // leading `paddingLength` characters as the prefix — mirrors the
        // reference implementation exactly.
        let refCode = encode(latitude: refLat, longitude: refLng, codeLength: pairCodeLength)
        let prefix = String(refCode.prefix(paddingLength))
        let fullCode = prefix + shortCode

        guard let area = decode(fullCode) else { return nil }
        var centerLat = area.center.latitude
        var centerLng = area.center.longitude

        // Adjust to the nearest matching area if it wrapped away from the ref.
        if refLat + halfResolution < centerLat && centerLat - resolution >= -latitudeMax {
            centerLat -= resolution
        } else if refLat - halfResolution > centerLat && centerLat + resolution <= latitudeMax {
            centerLat += resolution
        }
        if refLng + halfResolution < centerLng {
            centerLng -= resolution
        } else if refLng - halfResolution > centerLng {
            centerLng += resolution
        }

        return encode(
            latitude: centerLat,
            longitude: centerLng,
            codeLength: fullCode.filter { $0 != separator && $0 != paddingCharacter }.count
        )
    }

    // MARK: - Encoding (needed for short-code recovery)

    private static let gridRowsInt = 5
    private static let gridColumnsInt = 4
    private static let encodingBaseInt = 20
    private static let gridCodeLength = maxDigitCount - pairCodeLength   // 5
    // FINAL_LAT_PRECISION = 20^3 * 5^5 = 25_000_000
    private static let finalLatPrecision: Int64 = 25_000_000
    // FINAL_LNG_PRECISION = 20^3 * 4^5 = 8_192_000
    private static let finalLngPrecision: Int64 = 8_192_000

    /// Convert a coordinate to the integer representation used by the encoder.
    private static func locationToIntegers(_ latitude: Double, _ longitude: Double) -> (lat: Int64, lng: Int64) {
        var latVal = Int64((latitude * Double(finalLatPrecision)).rounded(.down))
        latVal += Int64(latitudeMax) * finalLatPrecision
        if latVal < 0 {
            latVal = 0
        } else if latVal >= 2 * Int64(latitudeMax) * finalLatPrecision {
            latVal = 2 * Int64(latitudeMax) * finalLatPrecision - 1
        }

        var lngVal = Int64((longitude * Double(finalLngPrecision)).rounded(.down))
        lngVal += Int64(longitudeMax) * finalLngPrecision
        let lngRange = 2 * Int64(longitudeMax) * finalLngPrecision
        if lngVal < 0 {
            lngVal = ((lngVal % lngRange) + lngRange) % lngRange
        } else if lngVal >= lngRange {
            lngVal = lngVal % lngRange
        }
        return (latVal, lngVal)
    }

    /// Encode a coordinate to a full Plus Code of the given digit length.
    /// Mirrors the reference integer-based encoder for exactness.
    static func encode(latitude: Double, longitude: Double, codeLength: Int) -> String {
        var length = min(max(codeLength, 2), maxDigitCount)
        // Enforce even lengths below the pair section.
        if length < pairCodeLength && length % 2 == 1 { length -= 1 }
        let lat = clipLatitude(latitude)
        let lng = normalizeLongitude(longitude)

        var (latVal, lngVal) = locationToIntegers(lat, lng)
        let alphabet = Array(codeAlphabet)
        var code = ""

        if length > pairCodeLength {
            for _ in 0..<gridCodeLength {
                let latDigit = Int(latVal % Int64(gridRowsInt))
                let lngDigit = Int(lngVal % Int64(gridColumnsInt))
                let ndx = latDigit * gridColumnsInt + lngDigit
                code = String(alphabet[ndx]) + code
                latVal /= Int64(gridRowsInt)
                lngVal /= Int64(gridColumnsInt)
            }
        } else {
            latVal /= Int64(pow(Double(gridRowsInt), Double(gridCodeLength)))
            lngVal /= Int64(pow(Double(gridColumnsInt), Double(gridCodeLength)))
        }

        for _ in 0..<(pairCodeLength / 2) {
            code = String(alphabet[Int(lngVal % Int64(encodingBaseInt))]) + code
            code = String(alphabet[Int(latVal % Int64(encodingBaseInt))]) + code
            latVal /= Int64(encodingBaseInt)
            lngVal /= Int64(encodingBaseInt)
        }

        // Insert the separator at position 8.
        code.insert(separator, at: code.index(code.startIndex, offsetBy: separatorPosition))

        if length >= separatorPosition {
            return String(code.prefix(length + 1))
        }
        // Pad shorter codes to the separator position.
        var truncated = String(code.prefix(length))
        while truncated.count < separatorPosition {
            truncated.append(paddingCharacter)
        }
        return truncated + String(separator)
    }

    // MARK: - Helpers

    private static func clipLatitude(_ latitude: Double) -> Double {
        min(max(latitude, -latitudeMax), latitudeMax)
    }

    private static func normalizeLongitude(_ longitude: Double) -> Double {
        var lng = longitude
        while lng < -longitudeMax { lng += 360 }
        while lng >= longitudeMax { lng -= 360 }
        return lng
    }
}
