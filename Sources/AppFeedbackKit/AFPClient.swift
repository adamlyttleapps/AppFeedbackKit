import Foundation
import CryptoKit

/// URLSession-backed HTTP client. Handles the per-request signing + auth
/// headers so individual endpoints don't have to.
///
/// Auth scheme (matches www/include/api.php):
///     X-API-Key:    <api_key>
///     X-Device-Id:  <uuid>
///     X-Timestamp:  <unix seconds>
///     X-Signature:  sha256(api_secret + device_id + timestamp + body)
///
/// Adam accepts that decompiling the host app can leak the secret; the
/// signature mainly stops casual abuse from network-trace observers.
@MainActor
final class AFPClient {

    private weak var kit: AppFeedbackKit?
    private let session: URLSession

    init(kit: AppFeedbackKit, session: URLSession = .shared) {
        self.kit = kit
        self.session = session
    }

    enum AFPError: Error {
        case notConfigured
        case server(code: String, message: String, status: Int)
        case decode(Error)
        case transport(Error)
    }

    func post<B: Encodable, R: Decodable>(path: String, body: B) async throws -> R {
        guard let kit = kit, let config = kit.config else { throw AFPError.notConfigured }

        let bodyData = try JSONEncoder.afp.encode(body)
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let deviceId = kit.storage.deviceId

        let bodyString = String(data: bodyData, encoding: .utf8) ?? ""
        let signaturePayload = config.apiSecret + deviceId + timestamp + bodyString
        let signature = SHA256.hash(data: Data(signaturePayload.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        var url = kit.baseURL
        url.appendPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path)

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = bodyData
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(config.apiKey, forHTTPHeaderField: "X-API-Key")
        req.setValue(deviceId,      forHTTPHeaderField: "X-Device-Id")
        req.setValue(timestamp,     forHTTPHeaderField: "X-Timestamp")
        req.setValue(signature,     forHTTPHeaderField: "X-Signature")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw AFPError.transport(error)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status < 200 || status >= 300 {
            if let err = try? JSONDecoder.afp.decode(AFPErrorEnvelope.self, from: data) {
                throw AFPError.server(code: err.error.code, message: err.error.message, status: status)
            }
            throw AFPError.server(code: "http_\(status)", message: "HTTP \(status)", status: status)
        }

        do {
            return try JSONDecoder.afp.decode(R.self, from: data)
        } catch {
            throw AFPError.decode(error)
        }
    }
}

private struct AFPErrorEnvelope: Decodable {
    struct Inner: Decodable { let code: String; let message: String }
    let error: Inner
}

extension JSONEncoder {
    static let afp: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

extension JSONDecoder {
    static let afp: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
