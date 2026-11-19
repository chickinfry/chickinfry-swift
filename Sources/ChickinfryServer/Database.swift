#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public struct DatabaseError: Error, Sendable {
    public let code: String
    public var message: String {
        code == "commit_unknown" ? "Transaction commit outcome is unknown." : "Database operation failed."
    }

    init(_ code: String) { self.code = code }
}

public enum FieldValue<Value: Sendable>: Sendable {
    case absent
    case present(Value)
}

public struct Filter: Sendable {
    indirect enum Expression: Sendable {
        case comparison(String, String, String, [HostValue])
        case group(String, [Expression])
        case not(Expression)
        case invalid
    }
    let expression: Expression
}

public func and(_ filters: Filter...) -> Filter { Filter(expression: .group("AND", filters.map(\.expression))) }
public func or(_ filters: Filter...) -> Filter { Filter(expression: .group("OR", filters.map(\.expression))) }
public func not(_ filter: Filter) -> Filter { Filter(expression: .not(filter.expression)) }

public struct Order: Sendable {
    let table: String
    let name: String
    let descending: Bool
}

public struct FindMany: Sendable {
    public let `where`: Filter?
    public let orderBy: [Order]
    public let limit: Int?
    public let offset: Int?

    public init(where predicate: Filter? = nil, orderBy: [Order] = [], limit: Int? = nil, offset: Int? = nil) {
        self.where = predicate
        self.orderBy = orderBy
        self.limit = limit
        self.offset = offset
    }
}

public struct Field<Value: Codable & Sendable>: Sendable {
    private let table: String
    private let name: String
    @_spi(Generated) public init(_ table: String, _ name: String) { self.table = table; self.name = name }

    private func compare(_ operation: String, _ values: [Value]) -> Filter {
        do {
            return Filter(expression: .comparison(table, name, operation, try values.map { try _encodeDatabaseValue($0) }))
        } catch { return Filter(expression: .invalid) }
    }

    public func eq(_ value: Value) -> Filter { compare("=", [value]) }
    public func ne(_ value: Value) -> Filter { compare("<>", [value]) }
    public func gt(_ value: Value) -> Filter { compare(">", [value]) }
    public func gte(_ value: Value) -> Filter { compare(">=", [value]) }
    public func lt(_ value: Value) -> Filter { compare("<", [value]) }
    public func lte(_ value: Value) -> Filter { compare("<=", [value]) }
    public func isIn(_ values: [Value]) -> Filter { compare("IN", values) }
    public func isNull() -> Filter { Filter(expression: .comparison(table, name, "IS NULL", [])) }
    public func isNotNull() -> Filter { Filter(expression: .comparison(table, name, "IS NOT NULL", [])) }
    public func asc() -> Order { Order(table: table, name: name, descending: false) }
    public func desc() -> Order { Order(table: table, name: name, descending: true) }
}

@_spi(Generated) public func _encodeDatabaseValue<Value: Encodable>(_ value: Value) throws -> HostValue {
    try JSONDecoder().decode(HostValue.self, from: JSONEncoder().encode(value))
}

@_spi(Generated) public struct _DatabaseColumn: Sendable {
    let name: String
    let kind: String
    let nullable: Bool
    let optional: Bool

    public init(_ name: String, kind: String, nullable: Bool, optional: Bool) {
        self.name = name
        self.kind = kind
        self.nullable = nullable
        self.optional = optional
    }

    func validate(_ value: HostValue) throws { _ = try normalized(value) }

    func normalized(_ value: HostValue) throws -> HostValue {
        if value == .null {
            guard nullable else { throw DatabaseError("invalid_input") }
            return value
        }
        if kind == "integer" {
            guard case .integer(let integer) = value, Int32(exactly: integer) != nil else { throw DatabaseError("22003") }
            return value
        }
        guard case .string(let text) = value else { throw DatabaseError("invalid_input") }
        switch kind {
        case "string":
            guard !text.utf8.contains(0) else { throw DatabaseError("invalid_input") }
        case "id":
            let bytes = Array(text.utf8)
            guard bytes.count == 36, bytes.enumerated().allSatisfy({ index, byte in
                [8, 13, 18, 23].contains(index) ? byte == 45 : (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
            }) else { throw DatabaseError("invalid_input") }
            return .string(text.lowercased())
        case "date": _ = try databaseDate(Array(text.utf8))
        case "timestamp": return .string(try databaseTimestamp(text))
        default: throw DatabaseError("invalid_input")
        }
        return value
    }
}

private func databaseDays(_ year: Int, _ month: Int) -> Int {
    if month == 2 { return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28 }
    return [4, 6, 9, 11].contains(month) ? 30 : 31
}

private func databaseDigits(_ bytes: ArraySlice<UInt8>) throws -> Int {
    guard !bytes.isEmpty, bytes.allSatisfy({ (48...57).contains($0) }) else { throw DatabaseError("invalid_input") }
    return bytes.reduce(0) { $0 * 10 + Int($1 - 48) }
}

private func databaseDate(_ bytes: [UInt8]) throws -> (Int, Int, Int) {
    guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45 else { throw DatabaseError("invalid_input") }
    let year = try databaseDigits(bytes[0..<4]), month = try databaseDigits(bytes[5..<7]), day = try databaseDigits(bytes[8..<10])
    guard (1...9999).contains(year), (1...12).contains(month), (1...databaseDays(year, month)).contains(day) else { throw DatabaseError("invalid_input") }
    return (year, month, day)
}

private func databaseTimestamp(_ text: String) throws -> String {
    let bytes = Array(text.utf8)
    guard bytes.count >= 20, [32, 84].contains(bytes[10]), bytes[13] == 58, bytes[16] == 58 else { throw DatabaseError("invalid_input") }
    var (year, month, day) = try databaseDate(Array(bytes.prefix(10)))
    let hour = try databaseDigits(bytes[11..<13]), minute = try databaseDigits(bytes[14..<16]), second = try databaseDigits(bytes[17..<19])
    guard hour < 24, minute < 60, second < 60 else { throw DatabaseError("invalid_input") }
    var index = 19, fraction = ""
    if bytes[index] == 46 {
        index += 1
        let start = index
        while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
        guard (1...6).contains(index - start) else { throw DatabaseError("invalid_input") }
        fraction = String(decoding: bytes[start..<index], as: UTF8.self)
    }
    let zone = Array(bytes[index...])
    var offset = 0
    if zone != [90] {
        guard [3, 6].contains(zone.count), [43, 45].contains(zone[0]), zone.count == 3 || zone[3] == 58 else { throw DatabaseError("invalid_input") }
        let hours = try databaseDigits(zone[1..<3]), minutes = try zone.count == 6 ? databaseDigits(zone[4..<6]) : 0
        guard hours < 24, minutes < 60 else { throw DatabaseError("invalid_input") }
        offset = (hours * 60 + minutes) * 60 * (zone[0] == 43 ? 1 : -1)
    }
    var seconds = hour * 3600 + minute * 60 + second - offset
    if seconds < 0 {
        seconds += 86400; day -= 1
        if day == 0 { month -= 1; if month == 0 { year -= 1; month = 12 }; day = databaseDays(year, month) }
    } else if seconds >= 86400 {
        seconds -= 86400; day += 1
        if day > databaseDays(year, month) { day = 1; month += 1; if month == 13 { year += 1; month = 1 } }
    }
    guard (1...9999).contains(year) else { throw DatabaseError("invalid_input") }
    func pad(_ value: Int, _ width: Int = 2) -> String { let result = String(value); return String(repeating: "0", count: max(0, width - result.count)) + result }
    fraction += String(repeating: "0", count: max(0, 3 - fraction.count))
    return "\(pad(year, 4))-\(pad(month))-\(pad(day))T\(pad(seconds / 3600)):\(pad(seconds / 60 % 60)):\(pad(seconds % 60)).\(fraction)Z"

}

@_spi(Generated) public actor _DatabaseConnection {
    private let host: HostRequest?
    private let lease: UInt64?
    private var open = true

    public init(_ context: Context) {
        self.host = context.databaseHost
        self.lease = nil
    }

    private init(host: HostRequest, lease: UInt64) {
        self.host = host
        self.lease = lease
    }

    private func perform(_ frame: [String: HostValue]) async throws -> [String: HostValue] {
        guard let host else { throw DatabaseError("database_failed") }
        do { return try HostFrame.decode(await host.database(HostFrame.encode(frame))) }
        catch let error as HostFailure { throw DatabaseError(error.code) }
    }

    func query(_ sql: String, _ parameters: [HostValue]) async throws -> [[String: HostValue]] {
        guard open else { throw DatabaseError("invalid_host_call") }
        var frame: [String: HostValue] = ["op": .string(lease == nil ? "query" : "exec"), "sql": .string(sql), "params": .array(parameters)]
        if let lease { frame["lease"] = .integer(Int64(lease)) }
        let result = try await perform(frame)
        guard case .array(let rows) = result["rows"] else { throw DatabaseError("database_failed") }
        return try rows.map {
            guard case .object(let row) = $0 else { throw DatabaseError("database_failed") }
            return row
        }
    }

    private func close() { open = false }

    public func transaction<Value: Sendable>(_ work: @Sendable (_DatabaseConnection) async throws -> Value) async throws -> Value {
        guard open, lease == nil else { throw DatabaseError("invalid_host_call") }
        guard let host else { throw DatabaseError("database_failed") }
        let begun = try await perform(["op": .string("begin")])
        guard let handle = begun["lease"]?.handle else { throw DatabaseError("database_failed") }
        let connection = _DatabaseConnection(host: host, lease: handle)
        let result: Value
        do {
            result = try await work(connection)
            try Task.checkCancellation()
        } catch {
            await connection.close()
            // Request cancellation owns physical cleanup; no new I/O is allowed after cancellation.
            if !Task.isCancelled { _ = try await perform(["op": .string("rollback"), "lease": .integer(Int64(handle))]) }
            throw error
        }
        await connection.close()
        // A commit failure is final: never compensate or retry an unknown outcome.
        _ = try await perform(["op": .string("commit"), "lease": .integer(Int64(handle))])
        return result
    }
}

@_spi(Generated) public struct _Repository<Row: Decodable & Sendable>: Sendable {
    private let connection: _DatabaseConnection
    private let name: String
    private let columns: [_DatabaseColumn]
    private let primaryKey: [String]

    public init(_ connection: _DatabaseConnection, table: String, primaryKey: [String], columns: [_DatabaseColumn]) {
        self.connection = connection
        self.name = table
        self.primaryKey = primaryKey
        self.columns = columns
    }

    private func quote(_ name: String) throws -> String {
        guard !name.isEmpty, name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }) else {
            throw DatabaseError("invalid_input")
        }
        return "\"" + name + "\""
    }

    private func column(_ name: String) throws -> _DatabaseColumn {
        guard let column = columns.first(where: { $0.name == name }) else { throw DatabaseError("invalid_input") }
        return column
    }

    private var projection: String {
        get throws { try columns.map { try quote($0.name) }.joined(separator: ", ") }
    }

    private func validate(_ values: [String: HostValue], insert: Bool = false, key: Bool = false) throws {
        if key, Set(values.keys) != Set(primaryKey) { throw DatabaseError("invalid_input") }
        for (name, value) in values {
            let definition = try column(name)
            if !insert && !key && primaryKey.contains(name) { throw DatabaseError("invalid_input") }
            try definition.validate(value)
        }
        if insert && columns.contains(where: { !$0.optional && values[$0.name] == nil }) { throw DatabaseError("invalid_input") }
    }

    private func parameter(_ value: HostValue, _ parameters: inout [HostValue]) -> String {
        parameters.append(value)
        return "$\(parameters.count)"
    }

    private func predicate(_ expression: Filter.Expression, _ parameters: inout [HostValue]) throws -> String {
        switch expression {
        case .invalid: throw DatabaseError("invalid_input")
        case .not(let child): return "NOT (" + (try predicate(child, &parameters)) + ")"
        case .group(let operation, let children):
            if children.isEmpty { return operation == "AND" ? "TRUE" : "FALSE" }
            return "(" + (try children.map { try predicate($0, &parameters) }.joined(separator: " \(operation) ")) + ")"
        case .comparison(let table, let name, let operation, let values):
            guard table == self.name else { throw DatabaseError("invalid_input") }
            let definition = try column(name)
            let identifier = try quote(name)
            if operation == "IS NULL" || operation == "IS NOT NULL" { return identifier + " " + operation }
            if operation == "IN" {
                if values.isEmpty { return "FALSE" }
                for value in values { try definition.validate(value) }
                return identifier + " IN (" + values.map { parameter($0, &parameters) }.joined(separator: ", ") + ")"
            }
            guard let value = values.first else { throw DatabaseError("invalid_input") }
            try definition.validate(value)
            if value == .null && ["=", "<>"].contains(operation) { return identifier + (operation == "=" ? " IS NULL" : " IS NOT NULL") }
            return identifier + " " + operation + " " + parameter(value, &parameters)
        }
    }

    private func keyPredicate(_ key: [String: HostValue], _ parameters: inout [HostValue]) throws -> String {
        try validate(key, key: true)
        return try primaryKey.map { try quote($0) + " = " + parameter(key[$0]!, &parameters) }.joined(separator: " AND ")
    }

    private func query(_ sql: String, _ parameters: [HostValue]) async throws -> [Row] {
        let rows = try await connection.query(sql, parameters)
        return try rows.map { raw in
            var row = raw
            for definition in columns {
                guard let value = row[definition.name] else { throw DatabaseError("database_failed") }
                row[definition.name] = try definition.normalized(value)
            }
            return try JSONDecoder().decode(Row.self, from: JSONEncoder().encode(row))
        }
    }

    public func insert(_ values: [String: HostValue]) async throws -> Row { try await insert(values, upsert: false) }
    public func upsert(_ values: [String: HostValue]) async throws -> Row { try await insert(values, upsert: true) }

    private func insert(_ values: [String: HostValue], upsert: Bool) async throws -> Row {
        try validate(values, insert: true)
        var parameters: [HostValue] = []
        let names = columns.map(\.name).filter { values[$0] != nil }
        var sql = "INSERT INTO " + (try quote(name))
        if names.isEmpty { sql += " DEFAULT VALUES" }
        else {
            sql += " (" + (try names.map(quote).joined(separator: ", ")) + ") VALUES (" + names.map { parameter(values[$0]!, &parameters) }.joined(separator: ", ") + ")"
        }
        if upsert {
            let mutable = names.filter { !primaryKey.contains($0) }
            guard !mutable.isEmpty, primaryKey.allSatisfy({ values[$0] != nil }) else { throw DatabaseError("invalid_input") }
            sql += " ON CONFLICT (" + (try primaryKey.map(quote).joined(separator: ", ")) + ") DO UPDATE SET "
            sql += try mutable.map { try quote($0) + " = EXCLUDED." + quote($0) }.joined(separator: ", ")
        }
        let rows = try await query(sql + " RETURNING " + projection, parameters)
        guard let row = rows.first else { throw DatabaseError("database_failed") }
        return row
    }

    public func findById(_ key: [String: HostValue]) async throws -> Row? {
        var parameters: [HostValue] = []
        let condition = try keyPredicate(key, &parameters)
        return try await query("SELECT " + projection + " FROM " + quote(name) + " WHERE " + condition + " LIMIT 1", parameters).first
    }

    public func findMany(_ options: FindMany = FindMany()) async throws -> [Row] {
        var parameters: [HostValue] = []
        var sql = try "SELECT " + projection + " FROM " + quote(name)
        if let filter = options.where { sql += " WHERE " + (try predicate(filter.expression, &parameters)) }
        if !options.orderBy.isEmpty {
            sql += " ORDER BY " + (try options.orderBy.map {
                guard $0.table == name else { throw DatabaseError("invalid_input") }
                _ = try column($0.name)
                return try quote($0.name) + ($0.descending ? " DESC" : " ASC")
            }.joined(separator: ", "))
        }
        for (name, value) in [(" LIMIT ", options.limit), (" OFFSET ", options.offset)] {
            if let value {
                guard value >= 0, Int64(value) <= 9_007_199_254_740_991 else { throw DatabaseError("invalid_input") }
                sql += name + parameter(.integer(Int64(value)), &parameters)
            }
        }
        return try await query(sql, parameters)
    }

    public func update(_ key: [String: HostValue], _ patch: [String: HostValue]) async throws -> Row {
        guard let row = try await change(key, condition: nil, patch: patch, increments: [:]) else { throw DatabaseError("not_found") }
        return row
    }

    public func updateIf(_ key: [String: HostValue], _ condition: Filter, _ patch: [String: HostValue]) async throws -> Row? {
        try await change(key, condition: condition, patch: patch, increments: [:])
    }

    public func increment(_ key: [String: HostValue], _ increments: [String: HostValue]) async throws -> Row {
        guard !increments.isEmpty else { throw DatabaseError("invalid_input") }
        guard let row = try await change(key, condition: nil, patch: [:], increments: increments) else { throw DatabaseError("not_found") }
        return row
    }

    public func incrementIf(_ key: [String: HostValue], _ condition: Filter, _ increments: [String: HostValue], _ patch: [String: HostValue]) async throws -> Row? {
        guard !increments.isEmpty, !patch.isEmpty else { throw DatabaseError("invalid_input") }
        return try await change(key, condition: condition, patch: patch, increments: increments)
    }

    private func change(_ key: [String: HostValue], condition: Filter?, patch: [String: HostValue], increments: [String: HostValue]) async throws -> Row? {
        try validate(patch)
        var parameters: [HostValue] = []
        guard Set(patch.keys).isDisjoint(with: increments.keys) else { throw DatabaseError("invalid_input") }
        let assignments = try columns.compactMap { definition -> String? in
            if let value = patch[definition.name] { return try quote(definition.name) + " = " + parameter(value, &parameters) }
            guard let value = increments[definition.name] else { return nil }
            guard definition.kind == "integer", !primaryKey.contains(definition.name), case .integer(let amount) = value, amount != 0 else { throw DatabaseError("invalid_input") }
            return try quote(definition.name) + " = " + quote(definition.name) + " + " + parameter(value, &parameters) + "::bigint"
        }
        for name in increments.keys { _ = try column(name) }
        var predicate = try keyPredicate(key, &parameters)
        if let condition { predicate += " AND (" + (try self.predicate(condition.expression, &parameters)) + ")" }
        guard !assignments.isEmpty else { throw DatabaseError("invalid_input") }
        return try await query("UPDATE " + quote(name) + " SET " + assignments.joined(separator: ", ") + " WHERE " + predicate + " RETURNING " + projection, parameters).first
    }

    public func delete(_ key: [String: HostValue]) async throws -> Row? {
        var parameters: [HostValue] = []
        let predicate = try keyPredicate(key, &parameters)
        return try await query("DELETE FROM " + quote(name) + " WHERE " + predicate + " RETURNING " + projection, parameters).first
    }
}
