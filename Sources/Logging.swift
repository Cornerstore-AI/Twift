import Foundation

/// Removes sensitive values from request headers before logging.
/// Authorization headers are redacted to avoid leaking credentials.
internal func sanitizeRequestHeaders(_ headers: [String: String]?) -> [String: String] {
  guard let headers = headers else { return [:] }
  var sanitized: [String: String] = [:]

  for (key, value) in headers {
    if key.caseInsensitiveCompare("Authorization") == .orderedSame {
      sanitized[key] = "<redacted>"
    } else {
      sanitized[key] = value
    }
  }

  return sanitized
}

/// Removes sensitive values from response headers before logging.
/// Authorization and Set-Cookie headers are redacted to avoid leaking credentials.
internal func sanitizeResponseHeaders(_ headers: [AnyHashable: Any]) -> [String: String] {
  var sanitized: [String: String] = [:]

  for (key, value) in headers {
    let keyString = String(describing: key)
    if keyString.caseInsensitiveCompare("Authorization") == .orderedSame ||
        keyString.caseInsensitiveCompare("Set-Cookie") == .orderedSame {
      sanitized[keyString] = "<redacted>"
    } else {
      sanitized[keyString] = String(describing: value)
    }
  }

  return sanitized
}

/// Logs a standard API request, including headers and body if available.
func logStandardAPIRequest(tag: String, request: URLRequest) {
  let method = request.httpMethod ?? "UNKNOWN"
  let urlString = request.url?.absoluteString ?? "unknown URL"
  let headers = sanitizeRequestHeaders(request.allHTTPHeaderFields)

  print("📤 [\(tag)] Request: \(method) \(urlString)")
  if !headers.isEmpty {
    print("📤 [\(tag)] Headers: \(headers)")
  }

  guard let body = request.httpBody, !body.isEmpty else {
    return
  }

  if let bodyString = String(data: body, encoding: .utf8) {
    print("📤 [\(tag)] Body: \(bodyString)")
  } else {
    print("📤 [\(tag)] Body bytes: \(body.count)")
  }
}

/// Logs a standard API response, including headers and body where possible.
func logStandardAPIResponse(tag: String, response: HTTPURLResponse, responseData: Data) {
  let urlString = response.url?.absoluteString ?? "unknown URL"
  let headers = sanitizeResponseHeaders(response.allHeaderFields)

  print("📥 [\(tag)] Response: \(response.statusCode) \(urlString)")
  if !headers.isEmpty {
    print("📥 [\(tag)] Response Headers: \(headers)")
  }

  guard !responseData.isEmpty else {
    print("📥 [\(tag)] Response Body: <empty>")
    return
  }

  if let responseString = String(data: responseData, encoding: .utf8) {
    print("📥 [\(tag)] Response Body: \(responseString)")
  } else {
    print("📥 [\(tag)] Response Body bytes: \(responseData.count)")
  }
}
