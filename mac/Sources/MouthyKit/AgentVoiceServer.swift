import CryptoKit
import Foundation
import Network

/// Mouthy for AI agents: a loopback-only MCP endpoint exposing `ask_user_dictation`. An agent sends questions; Mouthy records the spoken answer
/// (finish with the dictation shortcut, Escape cancels) and returns the transcript. Claude Code connects
/// through the stdio bridge script because its HTTP MCP timeout is too short for speech.
///
/// Requests carry `Mouthy-Auth: HMAC-SHA256(token, body)` and replies `Mouthy-Proof: HMAC-SHA256(token,
/// "reply:" + body)`. The token lives in an owner-only file and never travels, so other accounts on this
/// Mac can neither ask questions nor pose as Mouthy on the port.
@MainActor
final class AgentVoiceServer {
    nonisolated static let port: UInt16 = 51089
    nonisolated static let maxBody = 1 << 20
    private var listener: NWListener?
    private let answer: ([String]) async -> String
    private let problem: (String) -> Void
    /// The bridge hung up (agent stopped or crashed) while a question was waiting for its answer. Carries the
    /// exchange's id so only that agent's question is cancelled.
    private let abandoned: (UUID) -> Void
    private var token = ""

    /// The exchange a question arrived on, readable from `answer` (task-local): its id, and whether the agent
    /// is still waiting (it may hang up while the question is read aloud).
    struct ExchangeContext: Sendable {
        let id: UUID
        let isWaiting: @MainActor @Sendable () -> Bool
    }
    @TaskLocal static var current: ExchangeContext?

    init(answer: @escaping ([String]) async -> String, problem: @escaping (String) -> Void = { _ in }, abandoned: @escaping (UUID) -> Void = { _ in }) {
        self.answer = answer
        self.problem = problem
        self.abandoned = abandoned
    }

    static var bridgeURL: URL {
        LocalStore.supportDirectory.appendingPathComponent("mcp-bridge.sh")
    }

    static var tokenURL: URL {
        LocalStore.supportDirectory.appendingPathComponent("agent-token")
    }

    func start() {
        guard listener == nil else { return }
        guard let token = Self.loadToken() else { problem("Agent answers are unavailable: the agent token could not be saved."); return }
        self.token = token
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: Self.port)!)
        guard let listener = try? NWListener(using: parameters) else { problem("Agent answers are unavailable: port \(Self.port) could not be opened."); return }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.serve(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard case .failed(let error) = state else { return }
            Task { @MainActor in
                self?.stop()
                self?.problem("Agent answers are unavailable: port \(Self.port) is in use (\(error.localizedDescription)).")
            }
        }
        listener.start(queue: .main)
        self.listener = listener
        installBridge()
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    /// Reads the token, creating it (owner read/write only) on first use.
    static func loadToken() -> String? {
        if let token = try? String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), token.count >= 32 {
            return token
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try? FileManager.default.createDirectory(at: LocalStore.supportDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard FileManager.default.createFile(atPath: tokenURL.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
        else { return nil }
        return token
    }

    nonisolated static func sign(_ data: Data, token: String) -> String {
        HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: Data(token.utf8)))
            .map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func verify(_ data: Data, signature: String, token: String) -> Bool {
        let pairs = Array(signature.utf8)
        guard pairs.count == 64 else { return false }
        var bytes: [UInt8] = []
        for index in stride(from: 0, to: 64, by: 2) {
            guard let byte = UInt8(String(decoding: pairs[index..<index + 2], as: UTF8.self), radix: 16) else { return false }
            bytes.append(byte)
        }
        return HMAC<SHA256>.isValidAuthenticationCode(bytes, authenticating: data, using: SymmetricKey(data: Data(token.utf8)))
    }

    /// Stdio → HTTP bridge: one JSON-RPC message per line, no timeout while the person answers. It signs
    /// each request and passes on only replies proven to come from Mouthy.
    private func installBridge() {
        Self.installBridge(in: LocalStore.supportDirectory)
    }

    /// Writes the bridge into `folder`, owner-only.
    static func installBridge(in folder: URL) {
        let script = Self.bridgeScript
        let url = folder.appendingPathComponent("mcp-bridge.sh")
        // Owner-only folder and script, so no other account can replace what the agent runs. A folder
        // left over from an older version is tightened too.
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        if (try? String(contentsOf: url, encoding: .utf8)) != script {
            try? script.write(to: url, atomically: true, encoding: .utf8)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    nonisolated static var bridgeScript: String {
        """
        #!/bin/sh
        # Mouthy MCP bridge: forwards stdio JSON-RPC lines to the local Mouthy app.
        dir=$(dirname "$0")
        tmp=$(mktemp -d) || exit 1
        trap 'rm -rf "$tmp"' EXIT
        hmac() { /usr/bin/openssl dgst -sha256 -hmac "$token" -r | cut -d' ' -f1; }
        fail() {
          id=$(printf '%s' "$line" | /usr/bin/sed -nE 's/.*"id"[[:space:]]*:[[:space:]]*("[^"]*"|[0-9]+).*/\\1/p')
          [ -n "$id" ] && printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32000,"message":"%s"}}\\n' "$id" "$1"
        }
        while IFS= read -r line; do
          [ -z "$line" ] && continue
          token=$(cat "$dir/agent-token" 2>/dev/null) || { fail "Mouthy's agent token is unreadable."; continue; }
          auth=$(printf '%s' "$line" | hmac)
          if ! printf '%s' "$line" | curl -s --max-time 900 -D "$tmp/head" -o "$tmp/body" -H 'Content-Type: application/json' -H 'Accept: application/json' -H "Mouthy-Auth: $auth" --data-binary @- http://127.0.0.1:\(Self.port)/mcp; then
            fail "Mouthy is not running."; continue
          fi
          proof=$(tr -d '\\r' < "$tmp/head" | /usr/bin/sed -n 's/^[Mm]outhy-[Pp]roof: //p')
          expected=$({ printf 'reply:'; cat "$tmp/body"; } | hmac)
          if [ -z "$proof" ] || [ "$proof" != "$expected" ]; then
            fail "The program on port \(Self.port) is not this user's Mouthy; the answer was discarded."; continue
          fi
          [ -s "$tmp/body" ] && { cat "$tmp/body"; printf '\\n'; }
        done

        """
    }

    /// Per-connection state: whether a question on it is still waiting for the person's answer.
    @MainActor private final class Exchange { let id = UUID(); var waiting = false }

    private func serve(_ connection: NWConnection) {
        let exchange = Exchange()
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed: Task { @MainActor in self?.hungUp(exchange) }
            default: break
            }
        }
        connection.start(queue: .main)
        receive(connection, buffer: Data(), exchange: exchange)
    }

    /// The agent side went away mid-question: stop recording an answer nobody will read.
    private func hungUp(_ exchange: Exchange) {
        guard exchange.waiting else { return }
        exchange.waiting = false
        abandoned(exchange.id)
    }

    /// While a question waits, a read that ends (EOF or error) means the bridge hung up; curl sends nothing more.
    private func watchForHangUp(_ connection: NWConnection, exchange: Exchange) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, exchange.waiting else { return }
                if complete || error != nil { self.hungUp(exchange) }
                else if data != nil { self.watchForHangUp(connection, exchange: exchange) }
            }
        }
    }

    private func receive(_ connection: NWConnection, buffer: Data, exchange: Exchange) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                if let request = HTTPRequest(buffer) {
                    guard request.isLocalClient, request.body.count <= Self.maxBody,
                          Self.verify(request.body, signature: request.headers["mouthy-auth"] ?? "", token: self.token)
                    else { self.refuse(connection); return }
                    exchange.waiting = true
                    self.watchForHangUp(connection, exchange: exchange)
                    let context = ExchangeContext(id: exchange.id, isWaiting: { exchange.waiting })
                    let body = await Self.$current.withValue(context) { await self.handle(request.body) }
                    let stillThere = exchange.waiting
                    exchange.waiting = false
                    if stillThere { self.respond(connection, body: body) } else { connection.cancel() }
                } else if complete || error != nil || buffer.count > Self.maxBody + 16 << 10 || HTTPRequest.isMalformed(buffer) {
                    connection.cancel()
                } else {
                    self.receive(connection, buffer: buffer, exchange: exchange)
                }
            }
        }
    }

    private func respond(_ connection: NWConnection, body: Data?) {
        let payload = body ?? Data()
        let proof = Self.sign(Data("reply:".utf8) + payload, token: token)
        let head = (body == nil ? "HTTP/1.1 202 Accepted\r\n" : "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n")
            + "Mouthy-Proof: \(proof)\r\n"
            + "Content-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Web pages and unsigned requests are refused (see `HTTPRequest.isLocalClient`).
    private func refuse(_ connection: NWConnection) {
        let head = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Returns the JSON-RPC response, or nil for notifications.
    func handle(_ body: Data) async -> Data? {
        guard let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let method = message["method"] as? String else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        guard let id = message["id"] else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        let result: [String: Any]
        switch method {
        case "initialize":
            result = ["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                      "capabilities": ["tools": [:]],
                      "serverInfo": ["name": "mouthy", "version": Bundle.main.object(forInfoDictionaryKey: "MouthySourceRevision") as? String ?? "dev"]]
        case "ping":
            result = [:]
        case "tools/list":
            result = ["tools": [[
                "name": "ask_user_dictation",
                "description": "Ask the user one or more questions and get their spoken answer, transcribed on their Mac. Use when you need the user's input or a decision.",
                "inputSchema": ["type": "object", "required": ["questions"], "properties": [
                    "questions": ["type": "array", "items": ["type": "string"], "description": "Questions to ask the user."]]]
            ]]]
        case "tools/call":
            guard params["name"] as? String == "ask_user_dictation" else {
                return encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32602, "message": "Unknown tool"]])
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let questions = (arguments["questions"] as? [String]) ?? [(arguments["question"] as? String) ?? "Your answer?"]
            let text = await answer(questions)
            result = ["content": [["type": "text", "text": text]], "isError": false]
        default:
            return encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]])
        }
        return encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func encode(_ object: [String: Any]) -> Data? { try? JSONSerialization.data(withJSONObject: object) }
}

/// Minimal HTTP/1.1 request: complete once headers and Content-Length bytes have arrived.
struct HTTPRequest {
    let body: Data
    let headers: [String: String]
    init?(_ data: Data) {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<separator.lowerBound], encoding: .utf8) else { return nil }
        var headers: [String: String] = [:]
        for line in head.split(separator: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        self.headers = headers
        guard let length = Self.contentLength(headers) else { return nil }
        let start = separator.upperBound
        guard data.count - start >= length else { return nil }
        body = data[start..<start + length]
    }

    /// A missing length means an empty body; negative, unparsable or oversized lengths are invalid.
    static func contentLength(_ headers: [String: String]) -> Int? {
        guard let value = headers["content-length"] else { return 0 }
        guard let length = Int(value), (0...AgentVoiceServer.maxBody).contains(length) else { return nil }
        return length
    }

    /// True once the headers have arrived but carry an invalid Content-Length, so the connection can be dropped.
    static func isMalformed(_ data: Data) -> Bool {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<separator.lowerBound], encoding: .utf8) else { return false }
        let headers = Dictionary(head.split(separator: "\r\n").dropFirst().compactMap { line -> (String, String)? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (line[..<colon].lowercased(), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }, uniquingKeysWith: { first, _ in first })
        return contentLength(headers) == nil
    }

    /// Only local programs may ask questions: a browser always sends Origin on a cross-site POST,
    /// a DNS-rebinding page has a foreign Host, and requiring JSON forces a CORS preflight we never answer.
    var isLocalClient: Bool {
        headers["origin"] == nil
            && ["127.0.0.1:\(AgentVoiceServer.port)", "localhost:\(AgentVoiceServer.port)"].contains(headers["host"]?.lowercased() ?? "")
            && (headers["content-type"]?.lowercased().hasPrefix("application/json") ?? false)
    }
}
