//! Mouthy for AI agents: the same loopback MCP endpoint as the Mac app (127.0.0.1:51089, tool
//! `ask_user_dictation`). `mouthy --mcp-bridge` is the stdio transport for Claude Code.

use serde_json::{json, Value};
use std::io::{BufRead, Read, Write};

pub const PORT: u16 = 51089;

/// Answers JSON-RPC messages. `ask` records the spoken answer (blocking until finished).
pub fn handle(body: &[u8], ask: &dyn Fn(Vec<String>) -> String) -> Option<Value> {
    let Ok(message) = serde_json::from_slice::<Value>(body) else {
        return Some(json!({"jsonrpc": "2.0", "id": null, "error": {"code": -32700, "message": "Parse error"}}));
    };
    let id = message.get("id")?.clone();
    let params = message.get("params").cloned().unwrap_or(json!({}));
    let result = match message["method"].as_str().unwrap_or_default() {
        "initialize" => json!({
            "protocolVersion": params["protocolVersion"].as_str().unwrap_or("2025-06-18"),
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "mouthy", "version": env!("CARGO_PKG_VERSION")}
        }),
        "ping" => json!({}),
        "tools/list" => json!({"tools": [{
            "name": "ask_user_dictation",
            "description": "Ask the user one or more questions and get their spoken answer, transcribed on their computer. Use when you need the user's input or a decision.",
            "inputSchema": {"type": "object", "required": ["questions"], "properties": {
                "questions": {"type": "array", "items": {"type": "string"}, "description": "Questions to ask the user."}}}
        }]}),
        "tools/call" => {
            if params["name"] != "ask_user_dictation" {
                return Some(json!({"jsonrpc": "2.0", "id": id, "error": {"code": -32602, "message": "Unknown tool"}}));
            }
            let arguments = &params["arguments"];
            let questions: Vec<String> = arguments["questions"].as_array()
                .map(|a| a.iter().filter_map(|q| q.as_str().map(String::from)).collect())
                .unwrap_or_else(|| vec![arguments["question"].as_str().unwrap_or("Your answer?").to_string()]);
            json!({"content": [{"type": "text", "text": ask(questions)}], "isError": false})
        }
        _ => return Some(json!({"jsonrpc": "2.0", "id": id, "error": {"code": -32601, "message": "Method not found"}})),
    };
    Some(json!({"jsonrpc": "2.0", "id": id, "result": result}))
}

/// Only local programs may ask questions: a browser always sends Origin on a cross-site POST,
/// a DNS-rebinding page has a foreign Host, and requiring JSON forces a CORS preflight we never answer.
fn is_local_client(origin: Option<&str>, host: Option<&str>, content_type: Option<&str>) -> bool {
    origin.is_none()
        && host.is_some_and(|h| h == format!("127.0.0.1:{PORT}") || h == format!("localhost:{PORT}"))
        && content_type.is_some_and(|t| t.starts_with("application/json"))
}

/// Requests carry `Mouthy-Auth: HMAC-SHA256(token, body)` and replies `Mouthy-Proof:
/// HMAC-SHA256(token, "reply:" + body)`. The token (`store::agent_token`) is readable only by this
/// user and never travels, so another account can neither ask questions nor pose as Mouthy.
pub fn sign(token: &str, data: &[u8]) -> String {
    use hmac::Mac;
    let mut mac = hmac::Hmac::<sha2::Sha256>::new_from_slice(token.as_bytes()).expect("any key length");
    mac.update(data);
    mac.finalize().into_bytes().iter().map(|b| format!("{b:02x}")).collect()
}

fn verify(token: &str, data: &[u8], signature: &str) -> bool {
    use hmac::Mac;
    let Some(bytes) = (0..signature.len()).step_by(2).map(|i| signature.get(i..i + 2).and_then(|h| u8::from_str_radix(h, 16).ok())).collect::<Option<Vec<u8>>>() else { return false };
    let mut mac = hmac::Hmac::<sha2::Sha256>::new_from_slice(token.as_bytes()).expect("any key length");
    mac.update(data);
    mac.verify_slice(&bytes).is_ok()
}

const MAX_BODY: u64 = 1 << 20;
const MAX_REQUESTS: usize = 8;

/// Serves the loopback endpoint on a background thread; each request gets its own thread (at most
/// `MAX_REQUESTS` at once) so a pending question does not block pings. Requests are refused while
/// `enabled` returns false. Fails if the port is taken.
pub fn serve(ask: impl Fn(Vec<String>) -> String + Send + Sync + 'static, enabled: impl Fn() -> bool + Send + Sync + 'static) -> Result<(), String> {
    let token = crate::store::agent_token().map_err(|e| format!("Agent answers are unavailable: {e}"))?;
    let server = tiny_http::Server::http(("127.0.0.1", PORT)).map_err(|e| format!("Agent answers are unavailable: port {PORT} is in use ({e})."))?;
    let ask = std::sync::Arc::new(ask);
    let active = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
    std::thread::spawn(move || {
        use std::sync::atomic::Ordering;
        for mut request in server.incoming_requests() {
            let header = |name: &'static str| request.headers().iter().find(|h| h.field.equiv(name)).map(|h| h.value.as_str().to_string());
            let local = is_local_client(header("Origin").as_deref(), header("Host").map(|h| h.to_ascii_lowercase()).as_deref(), header("Content-Type").map(|h| h.to_ascii_lowercase()).as_deref());
            let too_long = request.body_length().is_some_and(|n| n as u64 > MAX_BODY);
            if !local || too_long || !enabled() || active.load(Ordering::SeqCst) >= MAX_REQUESTS {
                let _ = request.respond(tiny_http::Response::empty(if too_long { 413 } else if !local || !enabled() { 403 } else { 503 }));
                continue;
            }
            let auth = header("Mouthy-Auth").unwrap_or_default();
            let (ask, token, active) = (ask.clone(), token.clone(), active.clone());
            active.fetch_add(1, Ordering::SeqCst);
            std::thread::spawn(move || {
                let mut body = Vec::new();
                let read = request.as_reader().take(MAX_BODY + 1).read_to_end(&mut body);
                let response = if read.is_err() || body.len() as u64 > MAX_BODY {
                    tiny_http::Response::from_string(String::new()).with_status_code(413)
                } else if !verify(&token, &body, &auth) {
                    tiny_http::Response::from_string(String::new()).with_status_code(403)
                } else {
                    let (text, code) = match handle(&body, &|q| ask(q)) {
                        Some(value) => (value.to_string(), 200),
                        None => (String::new(), 202),
                    };
                    let proof = sign(&token, &[b"reply:".as_slice(), text.as_bytes()].concat());
                    tiny_http::Response::from_string(text).with_status_code(code)
                        .with_header("Content-Type: application/json".parse::<tiny_http::Header>().unwrap())
                        .with_header(format!("Mouthy-Proof: {proof}").parse::<tiny_http::Header>().unwrap())
                };
                let _ = request.respond(response);
                active.fetch_sub(1, Ordering::SeqCst);
            });
        }
    });
    Ok(())
}

/// stdio ↔ HTTP bridge: one JSON-RPC message per line, no timeout while the user answers.
pub fn bridge() -> i32 {
    let agent = ureq::AgentBuilder::new().timeout_read(std::time::Duration::from_secs(900)).build();
    let stdin = std::io::stdin();
    let mut stdout = std::io::stdout();
    let fail = |stdout: &mut std::io::Stdout, line: &str, message: String| {
        if let Ok(request) = serde_json::from_str::<Value>(line) {
            if let Some(id) = request.get("id") {
                let reply = json!({"jsonrpc": "2.0", "id": id, "error": {"code": -32000, "message": message}});
                let _ = writeln!(stdout, "{reply}"); let _ = stdout.flush();
            }
        }
    };
    for line in stdin.lock().lines() {
        let Ok(line) = line else { break };
        if line.trim().is_empty() { continue; }
        let token = match crate::store::agent_token() {
            Ok(token) => token,
            Err(error) => { fail(&mut stdout, &line, format!("Mouthy's agent token is unreadable: {error}")); continue; }
        };
        let request = agent.post(&format!("http://127.0.0.1:{PORT}/mcp"))
            .set("Content-Type", "application/json")
            .set("Mouthy-Auth", &sign(&token, line.as_bytes()));
        match request.send_string(&line) {
            Ok(response) => {
                let proof = response.header("Mouthy-Proof").unwrap_or_default().to_string();
                let text = response.into_string().unwrap_or_default();
                if !verify(&token, &[b"reply:".as_slice(), text.as_bytes()].concat(), &proof) {
                    fail(&mut stdout, &line, format!("The program on port {PORT} is not this user's Mouthy; the answer was discarded."));
                } else if !text.is_empty() {
                    let _ = writeln!(stdout, "{text}"); let _ = stdout.flush();
                }
            }
            Err(error) => fail(&mut stdout, &line, format!("Mouthy is not running: {error}")),
        }
    }
    0
}


#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn web_pages_cannot_ask_questions() {
        let json = Some("application/json");
        assert!(is_local_client(None, Some("127.0.0.1:51089"), json));
        assert!(is_local_client(None, Some("localhost:51089"), json));
        assert!(!is_local_client(Some("https://example.com"), Some("127.0.0.1:51089"), json));
        assert!(!is_local_client(None, Some("attacker.example:51089"), json));
        assert!(!is_local_client(None, Some("127.0.0.1:51089"), Some("text/plain")));
    }
    #[test]
    fn signatures_need_the_token() {
        let signature = sign("secret-token", b"{}");
        assert!(verify("secret-token", b"{}", &signature));
        assert!(!verify("other-token", b"{}", &signature));
        assert!(!verify("secret-token", b"{ }", &signature));
        assert!(!verify("secret-token", b"{}", ""));
        assert!(!verify("secret-token", b"{}", "zz"));
        // Same scheme as the Mac app and its `openssl dgst -hmac` bridge.
        assert_eq!(sign("key", b"abc"), "9c196e32dc0175f86f4b1cb89289d6619de6bee699e4c378e68309ed97a1a6ab");
    }
    #[test]
    fn speaks_mcp() {
        let ask = |q: Vec<String>| format!("answer to {}", q[0]);
        let init = handle(br#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#, &ask).unwrap();
        assert_eq!(init["result"]["protocolVersion"], "2025-06-18");
        assert!(handle(br#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, &ask).is_none());
        let list = handle(br#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#, &ask).unwrap();
        assert_eq!(list["result"]["tools"][0]["name"], "ask_user_dictation");
        let call = handle(br#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ask_user_dictation","arguments":{"questions":["Ship?"]}}}"#, &ask).unwrap();
        assert_eq!(call["result"]["content"][0]["text"], "answer to Ship?");
    }
}
