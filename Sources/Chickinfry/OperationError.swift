import Foundation

/// A safe failure code and the HTTP status, when a response was observed.
public struct OperationError: Error, Sendable, LocalizedError, CustomStringConvertible {
    public let code: String
    public let status: Int?

    public var errorDescription: String? { description }

    public var description: String {
        switch code {
        case "invalid_origin":
            "The server origin is invalid. Use HTTPS or an explicit loopback HTTP origin without credentials, a path, query, or fragment."
        case "invalid_input":
            "The request is invalid. Check the operation, JSON object, and timeout settings."
        case "invalid_token":
            "The access token is invalid. Sign in again before calling this operation."
        case "request_too_large":
            "The request exceeds 4 MiB. Reduce the input size before trying again."
        case "response_too_large":
            "The response exceeds 1 MiB. Request a smaller result from the server."
        case "timeout":
            "The operation timed out and its result may be unknown. Check the operation's result before trying again."
        case "cancelled":
            "The operation was cancelled and its result may be unknown. Check the operation's result before trying again."
        case "transport_error":
            "The operation could not complete and its result may be unknown. Check your connection and the operation's result before trying again."
        case "invalid_response":
            "The server returned an invalid response. Check that the client and server contracts match before trying again."
        default:
            "The server rejected the operation. Check the error code and HTTP status, then correct the request or contact the application owner."
        }
    }
}
