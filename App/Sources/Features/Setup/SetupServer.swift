import Foundation
import Network
import Core

/// Serves the setup page on http://<tv-ip>:8765. `GET /` shows the form, `POST /cookies`
/// validates the pasted cookies with YouTube (through `onCookies`) and answers with the result.
final class SetupServer: @unchecked Sendable {
    static let port: UInt16 = 8765

    enum Status: Equatable {
        case starting
        case listening
        case failed(String)
    }

    var onStatus: ((Status) -> Void)?
    var onRequest: ((String) -> Void)?
    /// Receives the raw textarea content; returns the page to show on the phone/computer.
    var onCookies: ((String) async -> SetupPage.State)?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "tube.setup.server")

    func start() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            guard let port = NWEndpoint.Port(rawValue: Self.port) else { return }
            let listener = try NWListener(using: parameters, on: port)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.emit(.listening)
                case .failed(let error):
                    self?.emit(.failed("The setup page couldn't start: \(error.localizedDescription)"))
                case .waiting(let error):
                    self?.emit(.failed("Waiting for the network: \(error.localizedDescription). If the Apple TV asked about devices on your local network, allow it in Settings → Privacy."))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            self.listener = listener
            emit(.starting)
            listener.start(queue: queue)
        } catch {
            emit(.failed("The setup page couldn't start: \(error.localizedDescription)"))
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func emit(_ status: Status) {
        DispatchQueue.main.async { [weak self] in self?.onStatus?(status) }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPRequestParser.parse(buffer) {
            case .incomplete:
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
            case .invalid(let message):
                self.send(.html(SetupPage.html(.failure(message: message)), status: 400, reason: "Bad Request"), on: connection)
            case .complete(let request, _):
                self.route(request, on: connection)
            }
        }
    }

    private func route(_ request: HTTPRequest, on connection: NWConnection) {
        DispatchQueue.main.async { [weak self] in self?.onRequest?("\(request.method) \(request.path)") }
        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/index.html"), ("GET", "/cookies"):
            send(.html(SetupPage.html(.form(message: nil))), on: connection)
        case ("POST", "/cookies"), ("POST", "/"):
            let raw = request.formFields["cookies"] ?? ""
            Task { [weak self] in
                guard let self else { return }
                let page = await self.onCookies?(raw) ?? .failure(message: "The TV isn't ready yet. Try again in a moment.")
                self.send(.html(SetupPage.html(page)), on: connection)
            }
        case ("GET", "/favicon.ico"):
            send(HTTPResponse(status: 404, reason: "Not Found", contentType: "text/plain", body: Data()), on: connection)
        default:
            send(.html(SetupPage.html(.form(message: nil)), status: 404, reason: "Not Found"), on: connection)
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

enum NetworkInfo {
    /// The TV's IPv4 address on the local network (Ethernet first, then Wi-Fi).
    static func localIPv4() -> String? {
        var addresses: [(name: String, address: String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let interface = current.pointee
            pointer = interface.ifa_next
            guard let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(bitPattern: interface.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: interface.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let address = String(cString: host)
                if !address.hasPrefix("169.254.") { addresses.append((name, address)) }
            }
        }
        let preferred = addresses.first { $0.name == "en0" } ?? addresses.first { $0.name.hasPrefix("en") } ?? addresses.first
        return preferred?.address
    }

    static var setupURL: String? {
        localIPv4().map { "http://\($0):\(SetupServer.port)" }
    }
}
