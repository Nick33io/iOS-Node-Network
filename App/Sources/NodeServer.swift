import Foundation
import Network
import WriteCore

/// Makes this device addressable as a node over the tailnet.
///
/// The mesh needs every node reachable from one place. Bonjour solves that only
/// on a shared LAN; Tailscale solves it everywhere, including for the Android
/// device that MultipeerConnectivity can never carry. So the primary transport
/// is a plain HTTP listener on a stable tailnet address, and peer-to-peer stays
/// the fallback for when there is no network at all.
///
/// iOS cannot serve in the background: the listener is alive only while the app
/// is foregrounded. That is not a limitation to work around here, because
/// generation stops on suspend anyway — a backgrounded node has nothing to
/// offer whether or not it can be reached.
///
/// Routes:
///   GET  /health    -> device identity, memory, thermal state, model, backend
///   POST /generate  -> {prompt, maxOutputTokens} -> text plus timings
@MainActor
@Observable
final class NodeServer {
  nonisolated static let port: UInt16 = 8833

  private(set) var isListening = false
  private(set) var lastError: String?
  private(set) var served = 0

  private var listener: NWListener?
  private let makeWriter: @MainActor () async throws -> any DeviceWriter
  private let describe: @MainActor () -> [String: Any]

  init(
    makeWriter: @escaping @MainActor () async throws -> any DeviceWriter,
    describe: @escaping @MainActor () -> [String: Any]
  ) {
    self.makeWriter = makeWriter
    self.describe = describe
  }

  func start() {
    guard listener == nil else { return }
    do {
      let parameters = NWParameters.tcp
      parameters.allowLocalEndpointReuse = true
      let listener = try NWListener(
        using: parameters, on: NWEndpoint.Port(rawValue: Self.port)!
      )
      listener.newConnectionHandler = { [weak self] connection in
        Task { @MainActor in self?.accept(connection) }
      }
      listener.stateUpdateHandler = { [weak self] state in
        Task { @MainActor in
          switch state {
          case .ready: self?.isListening = true
          case .failed(let error):
            self?.lastError = String(describing: error)
            self?.isListening = false
          case .cancelled: self?.isListening = false
          default: break
          }
        }
      }
      listener.start(queue: .main)
      self.listener = listener
    } catch {
      lastError = String(describing: error)
    }
  }

  func stop() {
    listener?.cancel()
    listener = nil
    isListening = false
  }

  // MARK: Connection handling

  private func accept(_ connection: NWConnection) {
    connection.start(queue: .main)
    receive(on: connection, buffer: Data())
  }

  /// Accumulates until headers and the declared body have both arrived. HTTP
  /// requests arrive in arbitrarily many TCP reads, and a body split across two
  /// packets is the common case for a full-size prompt.
  private func receive(on connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
      [weak self] chunk, _, isComplete, error in
      guard let self else { return }
      var buffer = buffer
      if let chunk { buffer.append(chunk) }

      Task { @MainActor in
        if error != nil {
          connection.cancel()
          return
        }
        if let request = HTTPRequest(buffer) {
          await self.respond(to: request, on: connection)
          return
        }
        if isComplete {
          connection.cancel()
          return
        }
        self.receive(on: connection, buffer: buffer)
      }
    }
  }

  private func respond(to request: HTTPRequest, on connection: NWConnection) async {
    served += 1
    switch (request.method, request.path) {
    case ("GET", "/health"):
      send(json: describe(), status: "200 OK", on: connection)

    case ("POST", "/generate"):
      guard
        let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
        let prompt = body["prompt"] as? String
      else {
        send(json: ["error": "expected {prompt, maxOutputTokens?}"], status: "400 Bad Request", on: connection)
        return
      }
      do {
        let writer = try await makeWriter()
        let cap = body["maxOutputTokens"] as? Int ?? writer.limits.maxOutputTokens
        let started = Date()
        let text = try await writer.generate(prompt: prompt, maxOutputTokens: cap)
        let seconds = -started.timeIntervalSinceNow
        let characters = text.trimmingCharacters(in: .whitespacesAndNewlines).count
        // Character-derived because the tokenizer is not exposed through
        // DeviceWriter. Close enough to compare devices to each other, which
        // is the only comparison this number is used for.
        let tokens = max(1, characters / 4)
        send(
          json: [
            "text": text,
            "seconds": seconds,
            "characters": characters,
            "approximateTokens": tokens,
            "tokensPerSecond": seconds > 0 ? Double(tokens) / seconds : 0,
          ],
          status: "200 OK", on: connection
        )
      } catch {
        send(json: ["error": String(describing: error)], status: "500 Internal Server Error", on: connection)
      }

    default:
      send(json: ["error": "not found"], status: "404 Not Found", on: connection)
    }
  }

  private func send(json: [String: Any], status: String, on connection: NWConnection) {
    let body =
      (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]))
      ?? Data("{}".utf8)
    var response = Data(
      """
      HTTP/1.1 \(status)\r
      Content-Type: application/json\r
      Content-Length: \(body.count)\r
      Connection: close\r
      \r\n
      """.utf8
    )
    response.append(body)
    connection.send(
      content: response,
      completion: .contentProcessed { _ in connection.cancel() }
    )
  }
}

/// Minimal HTTP request parser. Returns nil until the full request has arrived.
private struct HTTPRequest {
  let method: String
  let path: String
  let body: Data

  init?(_ data: Data) {
    let separator = Data("\r\n\r\n".utf8)
    guard let headerEnd = data.range(of: separator) else { return nil }
    guard
      let headerText = String(data: data[..<headerEnd.lowerBound], encoding: .utf8)
    else { return nil }

    let lines = headerText.components(separatedBy: "\r\n")
    let requestLine = lines.first?.split(separator: " ") ?? []
    guard requestLine.count >= 2 else { return nil }

    let declared =
      lines
      .first { $0.lowercased().hasPrefix("content-length:") }
      .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0

    let bodyStart = headerEnd.upperBound
    let available = data.count - bodyStart
    // Wait for the rest rather than answering a truncated prompt.
    guard available >= declared else { return nil }

    self.method = String(requestLine[0])
    self.path = String(requestLine[1])
    self.body = data[bodyStart..<(bodyStart + declared)]
  }
}
