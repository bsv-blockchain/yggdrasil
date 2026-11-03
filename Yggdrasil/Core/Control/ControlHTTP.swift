import Foundation

/// The little of HTTP/1.1 the control API needs: one request per connection,
/// bodies by Content-Length, JSON in and out.
struct HTTPRequest: Equatable {
    let method: String
    let path: String
    /// Names lowercased.
    let headers: [String: String]
    let body: Data
}

struct HTTPResponse: Equatable {
    var status: Int
    var body = Data()
    var contentType = "application/json"

    static func json(_ value: JSONValue, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, body: value.encoded())
    }

    static func empty(_ status: Int) -> HTTPResponse {
        HTTPResponse(status: status)
    }

    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        if !body.isEmpty { head += "Content-Type: \(contentType)\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        return Data(head.utf8) + body
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 413: "Content Too Large"
        default: "Error"
        }
    }
}

enum HTTPParser {
    enum Failure: Error, Equatable {
        case malformed
        case tooLarge
    }

    static let maxHeaderBytes = 16 * 1024

    /// The request in `data`, nil while more bytes are needed.
    static func parse(_ data: Data, maxBody: Int) throws -> HTTPRequest? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > maxHeaderBytes { throw Failure.tooLarge }
            return nil
        }
        guard end.lowerBound <= maxHeaderBytes,
              let head = String(bytes: data[data.startIndex ..< end.lowerBound], encoding: .utf8)
        else { throw Failure.malformed }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { throw Failure.malformed }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw Failure.malformed }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        // Chunked uploads aren't needed by any client of this API.
        guard headers["transfer-encoding"] == nil else { throw Failure.malformed }
        let length = try headers["content-length"].map { raw -> Int in
            guard let value = Int(raw), value >= 0 else { throw Failure.malformed }
            return value
        } ?? 0
        guard length <= maxBody else { throw Failure.tooLarge }
        let bodyStart = end.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return nil }
        let target = String(requestLine[1])
        return HTTPRequest(
            method: String(requestLine[0]),
            path: target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target,
            headers: headers,
            body: Data(data[bodyStart ..< bodyStart + length])
        )
    }
}
