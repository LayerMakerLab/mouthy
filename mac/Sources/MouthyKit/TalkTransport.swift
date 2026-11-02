import Foundation

/// Opens Talk's WebSocket. Production uses `URLSessionTalkTransport`; tests pass a fake, so nothing reaches a network.
public protocol TalkTransport: Sendable {
    /// Connects and returns once the socket is open, or throws (a refused key usually fails here).
    func connect(_ request: URLRequest) async throws -> any TalkSocket
}

/// One open WebSocket carrying text (JSON) messages.
public protocol TalkSocket: AnyObject, Sendable {
    func send(_ message: String) async throws
    /// The next server message; binary frames are read as UTF-8 text. Throws `TalkSocketClosed` once the server closes.
    func receive() async throws -> String
    func close()
}

/// The server closed the socket, with the provider's close code and reason.
public struct TalkSocketClosed: Error, Sendable, Equatable, LocalizedError {
    public var code: Int
    public var reason: String
    public init(code: Int, reason: String) { self.code = code; self.reason = reason }
    public var errorDescription: String? { reason.isEmpty ? "The connection closed (\(code))." : reason }
}

/// URLSessionWebSocketTask in an ephemeral session: no cookies, cache or credentials are stored, and the request
/// (with its key header) is used once and not kept.
public struct URLSessionTalkTransport: TalkTransport {
    public init() {}

    public func connect(_ request: URLRequest) async throws -> any TalkSocket {
        let opened = OpenSignal()
        let session = URLSession(configuration: .ephemeral, delegate: opened, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 16 << 20
        task.resume()
        do {
            try await opened.wait()
        } catch {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
            throw error
        }
        return URLSessionTalkSocket(task: task, session: session)
    }

    /// Resolves once the handshake succeeds or the task fails.
    private final class OpenSignal: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<Void, Error>?
        private var waiter: CheckedContinuation<Void, Error>?

        func wait() async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if let result { lock.unlock(); continuation.resume(with: result) } else { waiter = continuation; lock.unlock() }
            }
        }

        private func finish(_ outcome: Result<Void, Error>) {
            lock.lock()
            guard result == nil else { lock.unlock(); return }
            result = outcome
            let waiter = waiter; self.waiter = nil
            lock.unlock()
            waiter?.resume(with: outcome)
        }

        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
            finish(.success(()))
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let status = (task.response as? HTTPURLResponse)?.statusCode
            let message = status.map { "The provider refused the connection (HTTP \($0))." } ?? error?.localizedDescription ?? "The connection closed."
            finish(.failure(TalkSocketClosed(code: status ?? -1, reason: message)))
        }

        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
            finish(.failure(TalkSocketClosed(code: closeCode.rawValue, reason: reason.flatMap { String(data: $0, encoding: .utf8) } ?? "")))
        }
    }
}

final class URLSessionTalkSocket: TalkSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let session: URLSession

    init(task: URLSessionWebSocketTask, session: URLSession) { self.task = task; self.session = session }

    func send(_ message: String) async throws { try await task.send(.string(message)) }

    func receive() async throws -> String {
        do {
            switch try await task.receive() {
            case .string(let text): return text
            case .data(let data): return String(decoding: data, as: UTF8.self)
            @unknown default: return ""
            }
        } catch {
            if task.closeCode != .invalid {
                throw TalkSocketClosed(code: task.closeCode.rawValue, reason: task.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? "")
            }
            throw error
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
        session.finishTasksAndInvalidate()
    }
}
