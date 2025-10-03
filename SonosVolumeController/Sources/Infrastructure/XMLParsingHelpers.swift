import Foundation

/// Utilities for parsing XML responses from Sonos SOAP/UPnP services.
/// Provides simple regex-based extraction for common XML patterns.
enum XMLParsingHelpers {

    // MARK: - HTML Entity Decoding

    /// Decodes HTML entities commonly found in XML responses (e.g., &lt; → <)
    static func decodeHTMLEntities(_ xml: String) -> String {
        return xml
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&apos;", with: "'")
    }

    // MARK: - Value Extraction

    /// Extracts the text content of an XML element.
    /// Example: extractValue(from: xml, tag: "CurrentVolume") → "50"
    static func extractValue(from xml: String, tag: String) -> String? {
        // Pattern: <tag>value</tag> or <tag>value with spaces</tag>
        let pattern = "<\(tag)>([^<]+)</\(tag)>"
        guard let range = xml.range(of: pattern, options: .regularExpression) else {
            return nil
        }

        let match = String(xml[range])
        return match
            .replacingOccurrences(of: "<\(tag)>", with: "")
            .replacingOccurrences(of: "</\(tag)>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extracts the text content of an XML element with attributes.
    /// Example: extractValue(from: xml, tagPattern: "Current[^>]*") → "50"
    static func extractValue(from xml: String, tagPattern: String) -> String? {
        let pattern = "<\(tagPattern)>([^<]+)</"
        guard let range = xml.range(of: pattern, options: .regularExpression) else {
            return nil
        }

        let match = String(xml[range])
        // Remove opening tag (with possible attributes) and closing tag marker
        return match
            .replacingOccurrences(of: "<\(tagPattern)>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "</", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extracts an integer value from an XML element.
    static func extractIntValue(from xml: String, tag: String) -> Int? {
        guard let stringValue = extractValue(from: xml, tag: tag) else {
            return nil
        }
        return Int(stringValue)
    }

    // MARK: - Attribute Extraction

    /// Extracts an XML attribute value.
    /// Example: extractAttribute(from: xml, element: "ZoneGroup", attribute: "Coordinator") → "RINCON_..."
    static func extractAttribute(from xml: String, element: String, attribute: String) -> String? {
        let pattern = "<\(element)[^>]*\(attribute)=\"([^\"]+)\""
        guard let range = xml.range(of: pattern, options: .regularExpression) else {
            return nil
        }

        let match = String(xml[range])
        // Extract the attribute value from the pattern
        let attrPattern = "\(attribute)=\"([^\"]+)\""
        guard let attrRange = match.range(of: attrPattern, options: .regularExpression) else {
            return nil
        }

        return String(match[attrRange])
            .replacingOccurrences(of: "\(attribute)=\"", with: "")
            .replacingOccurrences(of: "\"", with: "")
    }

    // MARK: - Section Extraction

    /// Extracts a section of XML between opening and closing tags.
    /// Example: extractSection(from: xml, tag: "ZoneGroupState") → "<ZoneGroupState>...</ZoneGroupState>"
    static func extractSection(from xml: String, tag: String) -> String? {
        let pattern = "<\(tag)>([\\s\\S]*?)</\(tag)>"
        guard let range = xml.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        return String(xml[range])
    }

    /// Extracts all matches of a pattern from XML.
    /// Returns array of matched strings.
    static func extractAll(from xml: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }

        let nsString = xml as NSString
        let matches = regex.matches(in: xml, options: [], range: NSRange(location: 0, length: nsString.length))

        return matches.compactMap { match in
            guard match.range.location != NSNotFound else { return nil }
            return nsString.substring(with: match.range)
        }
    }

    // MARK: - UPnP-Specific Helpers

    /// Extracts UPnP error code from SOAP fault response.
    static func extractUPnPErrorCode(from xml: String) -> String? {
        return extractValue(from: xml, tag: "errorCode")
    }

    /// Extracts UPnP error description from SOAP fault response.
    static func extractUPnPErrorDescription(from: String) -> String? {
        return extractValue(from: from, tag: "errorDescription")
    }
}
