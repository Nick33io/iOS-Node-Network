#if canImport(Network)
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
  /// offer whether or not it can be reached. A Mac has no such ceiling, which is
  /// the only difference between the two nodes running this code.
  ///
  /// Routes:
  ///   GET  /health    -> device identity, memory, thermal state, model, backend
  ///   POST /generate  -> {prompt, maxOutputTokens} -> text plus timings
  @MainActor
  @Observable
  public final class NodeServer {
    public nonisolated static let port: UInt16 = 8833

    public private(set) var isListening = false
    public private(set) var lastError: String?
    public private(set) var served = 0
    /// Bytes written to clients. Sampled as a rate by the telemetry panel, so
    /// a cumulative counter is all that is needed here.
    public private(set) var servedBytes: UInt64 = 0
    /// Throughput of the most recent generation this node served.
    ///
    /// A serving node never initiates a task, so without recording what it did
    /// for someone else it has no throughput to report — the one device in the
    /// fleet whose speed is invisible to itself.
    public private(set) var lastTokensPerSecond: Double = 0
    public private(set) var tokensServed = 0
    /// Requests currently generating. The reading that says whether a node is
    /// idle or working — every other meter describes capacity, not use.
    public private(set) var inFlight = 0
    public private(set) var completed = 0
    public private(set) var failed = 0
    /// When this listener came up, for uptime.
    public private(set) var servingSince: Date?

    /// Snapshot for the profile payload.
    public var load: NodeLoad {
      NodeLoad(
        inFlight: inFlight, completed: completed, failed: failed,
        uptimeSeconds: servingSince.map { Int(-$0.timeIntervalSinceNow) } ?? 0,
        tokensPerSecond: lastTokensPerSecond
      )
    }

    private var listener: NWListener?
    private let makeWriter: @MainActor () async throws -> any DeviceWriter
    private let describe: @MainActor () -> [String: Any]
  /// Supplies the current ambient frame, when this node is capturing one.
  /// Injected rather than imported so NodeKit stays free of AVFoundation and
  /// keeps building on hosts with no camera at all.
  private var glyphs: (@MainActor () -> Data?)?
    /// Held separately from the writer so a request can be refused before the
    /// writer is built. On a phone that build is a multi-second model load; the
    /// boundary must not cost that much to enforce.
    private let limits: DeviceLimits

    public init(
      limits: DeviceLimits,
      makeWriter: @escaping @MainActor () async throws -> any DeviceWriter,
      describe: @escaping @MainActor () -> [String: Any]
    ) {
      self.limits = limits
      self.makeWriter = makeWriter
      self.describe = describe
    }

    private var fetchModel: (@MainActor () async throws -> Void)?
    private var fetching = false
    private var fetchError: String?

    /// Registers the handler for `POST /fetch`.
    ///
    /// Injected for the same reason as the glyph supplier: NodeKit must not
    /// import MLX. Without this the only way to put a model on a device was to
    /// tap its MODELS panel, which does not scale past the device you are
    /// holding — provisioning a new model across the fleet meant picking up
    /// every phone.
    public func provideFetch(_ handler: @escaping @MainActor () async throws -> Void) {
      fetchModel = handler
    }

    /// Registers a supplier for the ambient frame served on `/glyphs`.
    ///
    /// Injected rather than imported so NodeKit stays free of AVFoundation and
    /// keeps building on hosts that have no camera at all.
    public func provideGlyphs(_ provider: @escaping @MainActor () -> Data?) {
      glyphs = provider
    }

    public func start() {
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
            case .ready:
            self?.isListening = true
            self?.servingSince = Date()
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

    public func stop() {
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
      case ("GET", "/glyphs"):
      // 204 rather than an empty object: a viewer polling a node that is not
      // capturing should see "nothing here" without parsing a body.
      guard let data = glyphs?() else {
        sendRaw(status: "204 No Content", body: Data(), on: connection)
        return
      }
      sendRaw(status: "200 OK", body: data, on: connection)

      case ("POST", "/echo"):
        // Returns a payload of the requested size. Measuring a link needs
        // bytes moving in both directions: a request that only uploads
        // measures upstream, and a link is rarely symmetric.
        let requested = (try? JSONSerialization.jsonObject(with: request.body))
          .flatMap { ($0 as? [String: Any])?["bytes"] as? Int } ?? request.body.count
        // Capped: this is a measurement tool, not a way to make a phone
        // allocate whatever a caller asks for.
        let size = min(max(0, requested), 4 << 20)
        sendRaw(status: "200 OK", body: Data(repeating: 0x2E, count: size), on: connection)

      case ("POST", "/fetch"):
        // 202 and return. A model is gigabytes; holding the connection open for
        // the length of the download is how `/generate` used to hang, and the
        // caller cannot tell a slow download from a wedged node. Poll /health
        // for `fetching`, or just retry /generate until it stops refusing.
        guard let fetchModel else {
          send(json: ["error": "this node cannot fetch"], status: "501 Not Implemented", on: connection)
          return
        }
        if fetching {
          send(json: ["status": "already fetching"], status: "202 Accepted", on: connection)
          return
        }
        fetching = true
        fetchError = nil
        Task { @MainActor in
          do { try await fetchModel() } catch { self.fetchError = String(describing: error) }
          self.fetching = false
        }
        send(json: ["status": "fetching"], status: "202 Accepted", on: connection)

    case ("GET", "/health"):
        // Fetch state rides on /health so a caller can tell "still downloading"
        // from "refusing work", which otherwise look identical from outside.
        var payload = describe()
        payload["fetching"] = fetching
        if let fetchError { payload["fetchError"] = fetchError }
        send(json: payload, status: "200 OK", on: connection)

      case ("POST", "/generate"):
        inFlight += 1
        defer { inFlight -= 1 }
        let generate: GenerateRequest
        do {
          generate = try GenerateRequest(body: request.body, limits: limits)
        } catch let failure as NodeRequestError {
          send(json: ["error": failure.description], status: failure.status, on: connection)
          return
        } catch {
          send(json: ["error": String(describing: error)], status: "400 Bad Request", on: connection)
          return
        }

        do {
          let writer = try await makeWriter()
          let started = Date()
          let text = try await writer.generate(
            prompt: generate.prompt, maxOutputTokens: generate.maxOutputTokens
          )
          let seconds = -started.timeIntervalSinceNow
          let characters = text.trimmingCharacters(in: .whitespacesAndNewlines).count
          // Character-derived because the tokenizer is not exposed through
          // DeviceWriter. Close enough to compare devices to each other, which
          // is the only comparison this number is used for.
          let tokens = max(1, characters / 4)
          // Record what this node just did, so /health can answer "how fast
          // are you" without the caller running a benchmark of its own.
          let rate = seconds > 0 ? Double(tokens) / seconds : 0
          lastTokensPerSecond = rate
          tokensServed += tokens
          completed += 1
          send(
            json: [
              "text": text,
              "seconds": seconds,
              "characters": characters,
              "approximateTokens": tokens,
              "tokensPerSecond": seconds > 0 ? Double(tokens) / seconds : 0,
              // The cap actually applied. A caller that asked for more than the
              // node allows should be able to see that it was cut, rather than
              // inferring it from a short answer.
              "maxOutputTokens": generate.maxOutputTokens,
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

    private func sendRaw(status: String, body: Data, on connection: NWConnection) {
      servedBytes &+= UInt64(body.count)
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
      content: response, completion: .contentProcessed { _ in connection.cancel() })
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
      servedBytes &+= UInt64(body.count)
      connection.send(
        content: response,
        completion: .contentProcessed { _ in connection.cancel() }
      )
    }
  }
#endif
