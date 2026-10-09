import Testing
import Foundation
@testable import MouthyKit

private func json(_ data: Data?) -> [String: Any] { (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:] }
private func request(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

@MainActor @Test func agentServerSpeaksMCP() async {
    var asked: [String] = []
    let server = AgentVoiceServer { questions in asked = questions; return "Ship it on Friday." }
    let initialize = json(await server.handle(request(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]])))
    #expect((initialize["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-06-18")
    #expect(await server.handle(request(["jsonrpc": "2.0", "method": "notifications/initialized"])) == nil)
    let list = json(await server.handle(request(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])))
    let tools = (list["result"] as? [String: Any])?["tools"] as? [[String: Any]]
    #expect(tools?.first?["name"] as? String == "ask_user_dictation")
    let call = json(await server.handle(request(["jsonrpc": "2.0", "id": 3, "method": "tools/call",
        "params": ["name": "ask_user_dictation", "arguments": ["questions": ["When should we ship?"]]]])))
    let content = ((call["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first
    #expect(content?["text"] as? String == "Ship it on Friday.")
    #expect(asked == ["When should we ship?"])
    let unknown = json(await server.handle(request(["jsonrpc": "2.0", "id": 4, "method": "nope"])))
    #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32601)
}

@Test func httpRequestWaitsForTheWholeBody() {
    let head = "POST /mcp HTTP/1.1\r\nContent-Length: 4\r\n\r\n"
    #expect(HTTPRequest(Data((head + "ab").utf8)) == nil)
    #expect(HTTPRequest(Data((head + "abcd").utf8))?.body == Data("abcd".utf8))
}

@Test func invalidLengthsAreRefusedWithoutCrashing() {
    for length in ["-1", "x", "99999999"] {
        let data = Data("POST /mcp HTTP/1.1\r\nContent-Length: \(length)\r\n\r\n{}".utf8)
        #expect(HTTPRequest(data) == nil)
        #expect(HTTPRequest.isMalformed(data))
    }
    #expect(!HTTPRequest.isMalformed(Data("POST /mcp HTTP/1.1\r\nContent-Length: 2\r\n\r\n{".utf8)))
}

@Test func requestsAndRepliesAreSignedWithTheToken() {
    let body = Data("{}".utf8)
    let signature = AgentVoiceServer.sign(body, token: "secret-token")
    #expect(AgentVoiceServer.verify(body, signature: signature, token: "secret-token"))
    #expect(!AgentVoiceServer.verify(body, signature: signature, token: "other-token"))
    #expect(!AgentVoiceServer.verify(Data("{ }".utf8), signature: signature, token: "secret-token"))
    #expect(!AgentVoiceServer.verify(body, signature: "", token: "secret-token"))
    // Same scheme as the Windows/Linux app's `agent::sign` and the bridge's `openssl dgst -hmac`.
    #expect(AgentVoiceServer.sign(Data("abc".utf8), token: "key") == "9c196e32dc0175f86f4b1cb89289d6619de6bee699e4c378e68309ed97a1a6ab")
}

@Test func webPagesCannotAskQuestions() {
    func request(_ headers: String) -> HTTPRequest? { HTTPRequest(Data("POST /mcp HTTP/1.1\r\n\(headers)Content-Length: 2\r\n\r\n{}".utf8)) }
    let json = "Content-Type: application/json\r\n"
    #expect(request("Host: 127.0.0.1:51089\r\n" + json)?.isLocalClient == true)
    #expect(request("Host: localhost:51089\r\n" + json)?.isLocalClient == true)
    #expect(request("Host: 127.0.0.1:51089\r\nOrigin: https://example.com\r\n" + json)?.isLocalClient == false)
    #expect(request("Host: attacker.example:51089\r\n" + json)?.isLocalClient == false)
    #expect(request("Host: 127.0.0.1:51089\r\nContent-Type: text/plain\r\n")?.isLocalClient == false)
}

/// The bridge is written owner-only into the given support folder and nowhere else.
@MainActor @Test func bridgeIsWrittenOnlyIntoTheSupportFolder() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mouthy bridge \(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let support = root.appendingPathComponent("Mouthy")
    let current = support.appendingPathComponent("mcp-bridge.sh")
    AgentVoiceServer.installBridge(in: support)
    #expect(try String(contentsOf: current, encoding: .utf8) == AgentVoiceServer.bridgeScript)
    #expect(try FileManager.default.attributesOfItem(atPath: current.path)[.posixPermissions] as? Int == 0o700)
    #expect(try FileManager.default.attributesOfItem(atPath: support.path)[.posixPermissions] as? Int == 0o700)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["Mouthy"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: support.path) == ["mcp-bridge.sh"])
}
