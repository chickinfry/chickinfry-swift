import Foundation

/// A safe failure code and the HTTP status, when a response was observed.
public struct ClientError: Error, Sendable, LocalizedError, CustomStringConvertible {
    let reason: String
    public let status: Int?

    @_spi(Generated) public static var invalidArgument: ClientError { ClientError(code: "invalid_input", status: nil) }

    init(code: String, status: Int?) {
        self.reason = code == "invalid_token" && status == 401 ? "refresh_blocked" : code
        self.status = code == "invalid_token" && status == 401 ? nil : status
    }

    public var code: String {
        switch reason {
        case "invalid_origin", "invalid_input", "invalid_operation", "invalid_request", "invalid_timeout":
            return "invalid_argument"
        case "invalid_token":
            return status == nil ? "invalid_argument" : "unauthenticated"
        case "session_changed", "missing_session", "refresh_blocked":
            return "unauthenticated"
        case "origin_mismatch", "invalid_session", "session_store_error", "device_storage_unavailable":
            return "failed_precondition"
        case "request_too_large", "response_too_large", "device_storage_full":
            return "resource_exhausted"
        case "timeout": return "deadline_exceeded"
        case "cancelled": return "canceled"
        case "transport_error": return "unavailable"
        case "device_storage_corrupt": return "data_loss"
        case "device_storage_version_unsupported": return "unimplemented"
        case "invalid_response": return "internal"
        default: return "unknown"
        }
    }
    var devicePreparation = false

    public var errorDescription: String? { description }

    public var description: String {
        switch reason {
        case "invalid_origin", "origin_mismatch":
            "The server origin is invalid. Use HTTPS or an explicit loopback HTTP origin without credentials, a path, query, or fragment."
        case "invalid_input":
            "The request is invalid. Check the operation, JSON object, and timeout settings."
        case "invalid_token", "session_changed", "refresh_blocked":
            "The access token is invalid. Sign in again before calling this operation."
        case "session_store_error":
            "The session store could not complete the operation. Check your session storage before trying again."
        case "device_storage_unavailable":
            "Could not use device storage for the session. Check that the storage location is writable, or set persist to another directory or turn it off."
        case "device_storage_corrupt":
            "Stored session data could not be read. Sign out to clear it, then sign in again."
        case "device_storage_full":
            "Device storage for sign-in is full. Finish or cancel pending sign-ups, then try again."
        case "device_storage_version_unsupported":
            "Stored session data was written by a newer SDK. Update the SDK, or sign out and sign in again."
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

/// A failure returned by the server for an operation.
public struct OperationError: Error, Sendable, LocalizedError, CustomStringConvertible {
    public let code: String
    public let status: Int?

    public var errorDescription: String? { description }
    public var description: String {
        "The server rejected the operation. Check the error code and HTTP status, then correct the request or contact the application owner."
    }
}
