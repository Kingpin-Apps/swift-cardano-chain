import Foundation
import SwiftBlockfrostAPI
import SwiftKoios
import SwiftYaciAPI

/// Free-form JSON that carries ledger values, with every number held as the
/// exact `Decimal` its JSON text spells.
///
/// Blockfrost, Koios and Yaci each hand over their free-form ledger JSON as
/// their own `LedgerJSON`; ``ChainJSON/init(_:)`` turns any of them into this
/// one type, so the readers (``LedgerGovActionJSON``, ``LedgerValues``) are
/// written once. JSON this library reads itself (cardano-cli output, Yaci
/// DevKit genesis files) is decoded straight into it with `JSONDecoder`.
///
/// A `Decimal` holds 38 significant digits — enough for every ledger amount,
/// count and fraction, which fit a `UInt64` — but not for a Plutus datum's
/// unbounded integers, so datums are never read through this type: they come
/// from their CBOR.
indirect enum ChainJSON: Codable, Sendable, Hashable {
    case object([String: ChainJSON])
    case array([ChainJSON])
    case string(String)
    case number(Decimal)
    case bool(Bool)
    case null

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Decimal.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ChainJSON].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: ChainJSON].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a JSON value")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    /// `data` decoded as JSON, or an error naming `what`.
    static func decode(_ data: Data, _ what: @autoclosure () -> String) throws -> ChainJSON {
        do {
            return try JSONDecoder().decode(ChainJSON.self, from: data)
        } catch {
            throw CardanoChainError.valueError("\(what()) is not JSON: \(error)")
        }
    }

    /// The member named `key` of an object, else `nil`.
    subscript(key: String) -> ChainJSON? {
        if case .object(let members) = self { return members[key] }
        return nil
    }

    /// The members of an object, else `nil`.
    var object: [String: ChainJSON]? {
        if case .object(let members) = self { return members }
        return nil
    }

    /// The elements of an array, else `nil`.
    var array: [ChainJSON]? {
        if case .array(let elements) = self { return elements }
        return nil
    }

    /// The text of a string, else `nil`.
    var string: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    /// Whether this is JSON null.
    var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

extension Optional where Wrapped == ChainJSON {
    /// The value, or `nil` when it is absent or JSON null.
    var nonNull: ChainJSON? {
        guard let self, !self.isNull else { return nil }
        return self
    }
}

/// A client's free-form ledger JSON, convertible to ``ChainJSON``.
protocol ChainJSONConvertible {
    var chainJSON: ChainJSON { get }
}

extension ChainJSON {
    /// A client's ledger JSON as a `ChainJSON`.
    init(_ value: some ChainJSONConvertible) {
        self = value.chainJSON
    }
}

extension SwiftBlockfrostAPI.LedgerJSON: ChainJSONConvertible {
    var chainJSON: ChainJSON {
        switch self {
        case .object(let members): .object(members.mapValues(\.chainJSON))
        case .array(let elements): .array(elements.map(\.chainJSON))
        case .string(let text): .string(text)
        case .number(let value): .number(value)
        case .bool(let value): .bool(value)
        case .null: .null
        }
    }
}

extension SwiftKoios.LedgerJSON: ChainJSONConvertible {
    var chainJSON: ChainJSON {
        switch self {
        case .object(let members): .object(members.mapValues(\.chainJSON))
        case .array(let elements): .array(elements.map(\.chainJSON))
        case .string(let text): .string(text)
        case .number(let value): .number(value)
        case .bool(let value): .bool(value)
        case .null: .null
        }
    }
}

extension SwiftYaciAPI.LedgerJSON: ChainJSONConvertible {
    var chainJSON: ChainJSON {
        switch self {
        case .object(let members): .object(members.mapValues(\.chainJSON))
        case .array(let elements): .array(elements.map(\.chainJSON))
        case .string(let text): .string(text)
        case .number(let value): .number(value)
        case .bool(let value): .bool(value)
        case .null: .null
        }
    }
}
