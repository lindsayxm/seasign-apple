import Foundation
import Network

/// A tiny HTTP/1.1 server on the loopback interface, for tests that need the
/// real URLSession stack (redirects are handled inside it, below any
/// `ClientTransport` stub). It answers every request with one fixed response
/// and records what arrived. Each connection carries one request and is closed.
///
/// It reflects as nothing: what it records (key headers included) is not
/// app state.
final class LocalHTTPServer: CustomReflectable, @unchecked Sendable {
    struct Request: Sendable {
        var method: String
        var path: String
        /// Header names lowercased, values as sent.
        var headers: [(name: String, value: String)]
        var body: Data

        func header(_ name: String) -> String? {
            headers.first { $0.name == name.lowercased() }?.value
        }
    }

    struct Response: Sendable {
        var status: Int
        var reason: String
        var headers: [(String, String)] = []
        var body = Data()
    }

    var customMirror: Mirror { Mirror(self, children: [:]) }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "LocalHTTPServer")
    private let lock = NSLock()
    private var recorded: [Request] = []
    /// Open connections, kept alive until they are answered.
    private var open: [ObjectIdentifier: NWConnection] = [:]
    private var response: Response
    private(set) var port: UInt16 = 0

    /// Starts listening on a free loopback port; returns once it is ready.
    init(answering response: Response) async throws {
        self.response = response
        let parameters = NWParameters.tcp
        // Loopback only. Not `acceptLocalOnly`: in the Simulator it resets
        // every connection before the handler sees it.
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        let ready: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    once.resume(with: .success(listener.port?.rawValue ?? 0))
                case .failed(let error):
                    once.resume(with: .failure(error))
                case .cancelled:
                    once.resume(with: .failure(CancellationError()))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        port = ready
    }

    /// Resumes a continuation the first time only: the listener reports
    /// more states after `.ready`.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<UInt16, any Error>?

        init(_ continuation: CheckedContinuation<UInt16, any Error>) {
            self.continuation = continuation
        }

        func resume(with result: Result<UInt16, any Error>) {
            let pending = lock.withLock {
                let pending = continuation
                continuation = nil
                return pending
            }
            pending?.resume(with: result)
        }
    }

    deinit {
        listener.cancel()
    }

    func stop() {
        listener.cancel()
    }

    /// `http://localhost:<port>`.
    var url: URL { URL(string: "http://localhost:\(port)")! }

    var requests: [Request] { lock.withLock { recorded } }

    // MARK: Serving

    private func serve(_ connection: NWConnection) {
        lock.withLock { open[ObjectIdentifier(connection)] = connection }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.lock.withLock { _ = self?.open.removeValue(forKey: ObjectIdentifier(connection)) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                let response = self.lock.withLock {
                    self.recorded.append(request)
                    return self.response
                }
                connection.send(content: Self.encode(response), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    /// A whole request (head and, by Content-Length, body), or nil while more is needed.
    private static func parse(_ buffer: Data) -> Request? {
        guard let end = buffer.firstRange(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count >= 2 else { return nil }
        var headers: [(name: String, value: String)] = []
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
        }
        let length = headers.first { $0.name == "content-length" }.flatMap { Int($0.value) } ?? 0
        let body = buffer[end.upperBound...]
        guard body.count >= length else { return nil }
        return Request(
            method: String(start[0]),
            path: String(start[1]),
            headers: headers,
            body: Data(body.prefix(length))
        )
    }

    private static func encode(_ response: Response) -> Data {
        var head = "HTTP/1.1 \(response.status) \(response.reason)\r\n"
        for (name, value) in response.headers {
            head += "\(name): \(value)\r\n"
        }
        head += "Content-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + response.body
    }
}
