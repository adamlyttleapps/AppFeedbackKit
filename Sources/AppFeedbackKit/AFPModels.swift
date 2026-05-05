import Foundation
#if canImport(UIKit)
import UIKit
#endif

// ----------------------------------------------------------------
// Wire format — matches www/api/*.php
// ----------------------------------------------------------------

/// Sent on every request so the server has the latest snapshot of who's
/// answering. `meta` is an open dict — see AFPDeviceProbe.snapshot() for keys.
/// `subscriptions` is added asynchronously when StoreKit returns; nil/empty if
/// the host app has no IAP configured or StoreKit times out.
struct AFPDeviceContext: Encodable, Sendable {
    let app_version: String
    let os_version: String
    let locale: String
    let sessions: Int
    let meta: [String: AFPJSONOut]
    let subscriptions: [AFPJSONOut]

    @MainActor
    static func current(launches: Int, firstLaunch: Date? = nil, subscriptions: [AFPJSONOut] = []) -> AFPDeviceContext {
        let snap = AFPDeviceProbe.snapshot(launches: launches, firstLaunch: firstLaunch)
        let app = snap["app_version"]?.stringValue ?? "0"
        let os  = snap["os_version"]?.stringValue ?? ""
        let loc = snap["locale"]?.stringValue ?? Locale.current.identifier
        return .init(
            app_version: app,
            os_version: os,
            locale: loc,
            sessions: launches,
            meta: snap,
            subscriptions: subscriptions
        )
    }
}

private extension AFPJSONOut {
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

struct AFPEligibilityResponse: Decodable, Sendable {
    let eligible: Bool
    let reason: String?
    let cooldown_days: Int?
    /// Server-controlled presentation mode: "sheet" / "banner" / "both".
    /// Defaults to "both" if the field is missing for back-compat.
    let presentation_mode: String?
    /// When true, the SDK ignores its local cooldown / launch-count gates.
    /// Set server-side via the project's debug_mode toggle. Used during dev.
    let bypass_cooldown: Bool?
}

struct AFPProject: Decodable, Sendable {
    let id: Int
    let name: String
    let tagline: String?
    let icon_url: String?
    let status: String
}

struct AFPQuestionnaire: Decodable, Sendable {
    let active: Bool
    let questions: [AFPQuestion]
}

struct AFPConfigResponse: Decodable, Sendable {
    let project: AFPProject
    let questionnaire: AFPQuestionnaire
}

struct AFPQuestion: Decodable, Sendable, Identifiable {
    let id: Int
    let type: String
    let prompt: String?
    let hint: String?
    let required: Bool
    let config: AFPJSON
}

// ----------------------------------------------------------------
// Untyped JSON wrapper — questions' `config` shape varies by type, so we
// decode it into a tagged enum and let each step view pull the keys it needs.
// ----------------------------------------------------------------

@dynamicMemberLookup
public enum AFPJSON: Decodable, Sendable, Equatable {
    case object([String: AFPJSON])
    case array([AFPJSON])
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self)    { self = .bool(v); return }
        if let v = try? c.decode(Int.self)     { self = .int(v); return }
        if let v = try? c.decode(Double.self)  { self = .double(v); return }
        if let v = try? c.decode(String.self)  { self = .string(v); return }
        if let v = try? c.decode([AFPJSON].self) { self = .array(v); return }
        if let v = try? c.decode([String: AFPJSON].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unknown JSON value")
    }

    public subscript(dynamicMember key: String) -> AFPJSON {
        if case .object(let obj) = self { return obj[key] ?? .null }
        return .null
    }

    public subscript(key: String) -> AFPJSON {
        if case .object(let obj) = self { return obj[key] ?? .null }
        return .null
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    public var intValue: Int? {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int(v)
        case .string(let s): return Int(s)
        default: return nil
        }
    }
    public var boolValue: Bool {
        switch self {
        case .bool(let v): return v
        case .int(let v): return v != 0
        case .string(let s): return ["1","true","yes"].contains(s.lowercased())
        default: return false
        }
    }
    public var arrayValue: [AFPJSON] {
        if case .array(let a) = self { return a }
        return []
    }
    public var stringArray: [String] {
        arrayValue.compactMap { $0.stringValue }
    }
}

// ----------------------------------------------------------------
// Outbound bodies for /api/answer, /api/dismiss, /api/complete, /api/event
// ----------------------------------------------------------------

struct AFPAnswerBody: Encodable, Sendable {
    let question_id: Int
    let response_id: Int?
    let value: AFPJSONOut
    let skipped: Bool
    let app_version: String
    let os_version: String
    let locale: String
    let sessions: Int
}

struct AFPDismissBody: Encodable, Sendable {
    let response_id: Int?
    let app_version: String
    let os_version: String
    let locale: String
    let sessions: Int
}

struct AFPCompleteBody: Encodable, Sendable {
    let response_id: Int
    let app_version: String
    let os_version: String
    let locale: String
    let sessions: Int
}

struct AFPEventBody: Encodable, Sendable {
    let name: String
    let data: AFPJSONOut?
    let app_version: String
    let os_version: String
    let locale: String
    let sessions: Int
}

struct AFPAnswerResponse: Decodable, Sendable {
    let ok: Bool
    let response_id: Int
}

struct AFPSimpleResponse: Decodable, Sendable {
    let ok: Bool
}

// ----------------------------------------------------------------
// Encoder-side JSON — outbound counterpart to AFPJSON.
// ----------------------------------------------------------------

enum AFPJSONOut: Encodable, Sendable {
    case object([String: AFPJSONOut])
    case array([AFPJSONOut])
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v):  try c.encode(v)
        case .string(let v): try c.encode(v)
        case .int(let v):    try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v):   try c.encode(v)
        case .null:          try c.encodeNil()
        }
    }
}

extension AFPAnswerBody {
    @MainActor
    static func make(questionId: Int, responseId: Int?, value: AFPJSONOut, skipped: Bool, launches: Int) -> AFPAnswerBody {
        let ctx = AFPDeviceContext.current(launches: launches)
        return AFPAnswerBody(
            question_id: questionId,
            response_id: responseId,
            value: value,
            skipped: skipped,
            app_version: ctx.app_version,
            os_version: ctx.os_version,
            locale: ctx.locale,
            sessions: launches
        )
    }
}
