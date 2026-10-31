#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

enum JSONValue: Sendable {
    case null, bool(Bool), number(String), string(String), array([JSONValue])
    case object([(key: String, value: JSONValue)], [[UInt8]: Int])
}

@_spi(Generated)
public func _decodeJSON<T: Decodable>(_ type: T.Type, from literal: String) throws -> T {
    let parsed = try JSONBody.parse(Data(literal.utf8), requireObject: false)
    return try T(from: JSONValueDecoder(parsed))
}

struct JSONValueDecoder: Decoder {
    let value: JSONValue
    let codingPath: [any CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    init(_ value: JSONValue) {
        self.value = value
        codingPath = []
    }

    private init(_ value: JSONValue, path: [any CodingKey]) {
        self.value = value
        codingPath = path
    }

    func child(_ value: JSONValue, key: any CodingKey) -> JSONValueDecoder {
        JSONValueDecoder(value, path: codingPath + [key])
    }

    func mismatch(_ type: Any.Type) -> DecodingError {
        let context = DecodingError.Context(codingPath: codingPath, debugDescription: "Unexpected JSON value.")
        if case .null = value { return .valueNotFound(type, context) }
        return .typeMismatch(type, context)
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard case .object(let members, let indices) = value else { throw mismatch([String: JSONValue].self) }
        return KeyedDecodingContainer(ObjectContainer<Key>(decoder: self, members: members, indices: indices))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        guard case .array(let elements) = value else { throw mismatch([JSONValue].self) }
        return ArrayContainer(decoder: self, elements: elements)
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer { ScalarContainer(decoder: self) }
}

private struct ObjectContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let decoder: JSONValueDecoder
    let members: [(key: String, value: JSONValue)]
    let indices: [[UInt8]: Int]
    var codingPath: [any CodingKey] { decoder.codingPath }
    var allKeys: [Key] { members.compactMap { Key(stringValue: $0.key) } }

    private func value(for key: Key) -> JSONValue? {
        indices[Array(key.stringValue.utf8)].map { members[$0].value }
    }

    func contains(_ key: Key) -> Bool { value(for: key) != nil }

    private func child(for key: Key) throws -> JSONValueDecoder {
        guard let value = value(for: key) else {
            throw DecodingError.keyNotFound(key, .init(codingPath: codingPath, debugDescription: "Missing JSON key."))
        }
        return decoder.child(value, key: key)
    }

    func decodeNil(forKey key: Key) throws -> Bool {
        if case .null = try child(for: key).value { return true }
        return false
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        try T(from: child(for: key))
    }

    func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
        try child(for: key).container(keyedBy: type)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        try child(for: key).unkeyedContainer()
    }

    func superDecoder() throws -> any Decoder {
        let key = JSONKey(stringValue: "super")
        let value = indices[Array(key.stringValue.utf8)].map { members[$0].value } ?? .null
        return decoder.child(value, key: key)
    }

    func superDecoder(forKey key: Key) throws -> any Decoder {
        decoder.child(value(for: key) ?? .null, key: key)
    }
}

private struct JSONKey: CodingKey {
    let stringValue: String
    let intValue: Int?
    init(stringValue: String) { self.stringValue = stringValue; intValue = nil }
    init(intValue: Int) { self.intValue = intValue; stringValue = "Index \(intValue)" }
}

private struct ArrayContainer: UnkeyedDecodingContainer {
    let decoder: JSONValueDecoder
    let elements: [JSONValue]
    var codingPath: [any CodingKey] { decoder.codingPath }
    var count: Int? { elements.count }
    var currentIndex = 0
    var isAtEnd: Bool { currentIndex == elements.count }

    private func child() throws -> JSONValueDecoder {
        let key = JSONKey(intValue: currentIndex)
        guard !isAtEnd else {
            throw DecodingError.valueNotFound(Any.self, .init(codingPath: codingPath + [key], debugDescription: "JSON array is at end."))
        }
        return decoder.child(elements[currentIndex], key: key)
    }

    mutating func decodeNil() throws -> Bool {
        if case .null = try child().value { currentIndex += 1; return true }
        return false
    }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let value = try T(from: child())
        currentIndex += 1
        return value
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
        let container = try child().container(keyedBy: type)
        currentIndex += 1
        return container
    }

    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        let container = try child().unkeyedContainer()
        currentIndex += 1
        return container
    }

    mutating func superDecoder() throws -> any Decoder {
        let value = try child()
        currentIndex += 1
        return value
    }
}

private struct ScalarContainer: SingleValueDecodingContainer {
    let decoder: JSONValueDecoder
    var codingPath: [any CodingKey] { decoder.codingPath }
    func decodeNil() -> Bool { if case .null = decoder.value { return true }; return false }

    func decode(_ type: Bool.Type) throws -> Bool {
        guard case .bool(let value) = decoder.value else { throw decoder.mismatch(type) }
        return value
    }

    func decode(_ type: String.Type) throws -> String {
        guard case .string(let value) = decoder.value else { throw decoder.mismatch(type) }
        return value
    }

    private func number<T: Decodable>(_ type: T.Type) throws -> T {
        guard case .number(let token) = decoder.value else { throw decoder.mismatch(type) }
        do { return try JSONDecoder().decode(type, from: Data(token.utf8)) }
        catch DecodingError.dataCorrupted(let context) {
            throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: context.debugDescription))
        }
        catch { throw decoder.mismatch(type) }
    }

    func decode(_ type: Double.Type) throws -> Double { try number(type) }
    func decode(_ type: Float.Type) throws -> Float { try number(type) }
    func decode(_ type: Int.Type) throws -> Int { try number(type) }
    func decode(_ type: Int8.Type) throws -> Int8 { try number(type) }
    func decode(_ type: Int16.Type) throws -> Int16 { try number(type) }
    func decode(_ type: Int32.Type) throws -> Int32 { try number(type) }
    func decode(_ type: Int64.Type) throws -> Int64 { try number(type) }
    func decode(_ type: UInt.Type) throws -> UInt { try number(type) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try number(type) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try number(type) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try number(type) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try number(type) }
    func decode<T: Decodable>(_ type: T.Type) throws -> T { try T(from: decoder) }
}
