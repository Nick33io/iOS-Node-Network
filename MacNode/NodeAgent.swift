import Foundation

#if canImport(Glibc)
  // `exit` is not re-exported by Foundation on Linux.
  import Glibc
#endif

#if os(macOS)
  import NodeKit
  import WriteCore
  import WriteLAN

  #if canImport(MLXLLM)
    import MLXLLM
  #endif

  /// This Mac as a node on the mesh.
  ///
  /// Macs were previously modelled as Ollama endpoints: a URL the phones dialled,
  /// outside the fleet, exempt from the device boundary and invisible to any
  /// scheduling decision. That made the Mac a special case in every component
  /// that touched it. Running the same listener the phone runs, on the same
  /// port, behind the same `DeviceLimits`, removes the special case — the
  /// coordinator sees one kind of node, and the Ollama daemon becomes an
  /// implementation detail of one node rather than a second fleet model.
  ///
  /// The limits are the load-bearing part. Ollama will happily accept a prompt
  /// twice the size a phone refuses; if this agent passed that through, a
  /// section could succeed on a Mac and fail on every phone in the fleet, and
  /// the boundary would be advisory rather than real.
  @main
  enum NodeAgent {
    static func main() {
      // Line-buffered so the startup announcement survives being piped to a log.
      // Block buffering is the default off a terminal, and a node whose only
      // record of "here is where I am reachable" sits unflushed in a pipe is
      // indistinguishable from one that never started.
      setvbuf(stdout, nil, _IOLBF, 0)

      let options: AgentOptions
      do {
        options = try AgentOptions.parse(arguments: Array(CommandLine.arguments.dropFirst()))
      } catch {
        if case AgentError.helpRequested = error {
          print(AgentOptions.usage)
          exit(0)
        }
        FileHandle.standardError.write(
          Data("\(String(describing: error))\n\n\(AgentOptions.usage)\n".utf8)
        )
        exit(2)
      }

      do {
        let writer = try makeWriter(options)
        MainActor.assumeIsolated { serve(options: options, writer: writer) }
      } catch {
        FileHandle.standardError.write(Data("\(String(describing: error))\n".utf8))
        exit(1)
      }

      // Never returns. A CLI has no run loop of its own, and `NodeServer`
      // delivers on the main queue. `RunLoop.main.run()` rather than
      // `dispatchMain()` so main-queue work stays on the real main thread —
      // the same arrangement the iOS app already runs this listener under.
      RunLoop.main.run()
    }

    private static func makeWriter(_ options: AgentOptions) throws -> any DeviceWriter {
      switch options.backend {
      case .lan:
        guard let base = options.ollamaBaseURL else {
          throw AgentError.badOllamaHost(options.ollamaHost)
        }
        return LANWriter(model: options.model ?? "", baseURL: base, limits: options.limits)
      case .mlx:
        #if canImport(MLXLLM)
          // Deliberately unreached in the SwiftPM build; see AgentError.mlxUnavailable.
          throw AgentError.mlxUnavailable
        #else
          throw AgentError.mlxUnavailable
        #endif
      }
    }

    /// Holds the listener for the life of the process. `NodeServer` takes itself
    /// weakly in the connection handler — correct for a view that can go away,
    /// fatal for a daemon whose server would otherwise be released the moment
    /// `serve` returns, leaving a bound socket that answers nothing.
    @MainActor private static var server: NodeServer?

    @MainActor
    private static func serve(options: AgentOptions, writer: any DeviceWriter) {
      let model = options.model ?? "unknown"
      let server = NodeServer(
        limits: options.limits,
        makeWriter: { writer },
        describe: {
          BridgeProfileEmitter.payload(
            node: BridgeProfileEmitter.nodeIdentity,
            label: DeviceProfile.localLabel,
            backend: options.backend.label,
            model: model,
            limits: options.limits,
            // Read from the static, not the local: the closure is built before
            // the local `server` is assigned, so capturing it would report an
            // idle node forever.
            load: Self.server?.load ?? .idle
          )
        }
      )
      Self.server = server
      server.start()
      announce(options: options, model: model)
    }

    private static func announce(options: AgentOptions, model: String) {
      let profile = DeviceProfile.current()
      print("NOD3 agent — \(DeviceProfile.localLabel) (\(profile.identifier))")
      print("  node      \(BridgeProfileEmitter.nodeIdentity)")
      print("  backend   \(options.backend.label)  model \(model)")
      print(
        String(
          format: "  memory    %.0f GiB  thermal %@  power %@",
          profile.memoryGB, profile.thermalLabel, profile.powerLabel
        )
      )
      print(
        "  limits    \(options.limits.maxInputCharacters) chars in, "
          + "\(options.limits.maxOutputTokens) tokens out"
      )
      let addresses = NetworkAddresses.current()
      if addresses.isEmpty {
        print("  listening on :\(NodeServer.port) — no non-loopback address found")
      } else {
        for address in addresses {
          print("  listening http://\(address.address):\(NodeServer.port)  (\(address.interface))")
        }
      }
    }
  }
#else
  /// The mesh is Apple-only on this side: the listener is `Network.framework`
  /// and the device profile is Darwin. The target still builds on Linux so the
  /// portable core keeps one manifest and one CI job.
  @main
  enum NodeAgent {
    static func main() {
      FileHandle.standardError.write(Data("NodeAgent runs on macOS only.\n".utf8))
      exit(1)
    }
  }
#endif
