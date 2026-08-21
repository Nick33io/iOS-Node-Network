import Foundation
import WriteCore

/// How this node was asked to serve.
///
/// A Mac can host the model itself or front an Ollama daemon, and the fleet is
/// entitled to know which — `/health` reports the backend and the model, so the
/// choice cannot be left implicit.
enum AgentBackend: String {
  case lan
  case mlx

  var label: String {
    switch self {
    case .lan: return "LAN"
    case .mlx: return "on-device MLX"
    }
  }
}

struct AgentOptions {
  var backend: AgentBackend
  /// Required for `lan`: the daemon serves many models and will not guess.
  var model: String?
  var ollamaHost: String
  /// Policy, not a knob. The Mac deliberately runs the phone's boundary so a
  /// section written here is a section a phone could have written — see
  /// `DeviceLimits`.
  var limits: DeviceLimits = .qwen3_4B_4bit

  var ollamaBaseURL: URL? { URL(string: "http://\(ollamaHost):11434") }

  static let usage = """
    NodeAgent — this Mac as a node on the 33 mesh.

      --backend lan        front a local Ollama daemon (default)
      --backend mlx        run the pinned model on this Mac's GPU
      --model <name>       model the LAN backend serves; required for --backend lan
      --ollama-host <host> where the daemon listens (default 127.0.0.1)

    Environment: NODE_AGENT_BACKEND, NODE_AGENT_MODEL, NODE_AGENT_OLLAMA_HOST.
    Flags win over the environment.
    """

  /// Defaults to `lan` so the agent runs on a fresh checkout without first
  /// downloading gigabytes of weights.
  static func parse(
    arguments: [String],
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> AgentOptions {
    var backendName = environment["NODE_AGENT_BACKEND"] ?? AgentBackend.lan.rawValue
    var model = environment["NODE_AGENT_MODEL"]
    var ollamaHost = environment["NODE_AGENT_OLLAMA_HOST"] ?? "127.0.0.1"

    var index = arguments.startIndex
    while index < arguments.endIndex {
      let flag = arguments[index]
      func value() throws -> String {
        let next = arguments.index(after: index)
        guard next < arguments.endIndex else { throw AgentError.missingValue(flag) }
        index = next
        return arguments[next]
      }
      switch flag {
      case "--backend": backendName = try value()
      case "--model": model = try value()
      case "--ollama-host": ollamaHost = try value()
      case "--help", "-h": throw AgentError.helpRequested
      default: throw AgentError.unknownFlag(flag)
      }
      index = arguments.index(after: index)
    }

    guard let backend = AgentBackend(rawValue: backendName) else {
      throw AgentError.unknownBackend(backendName)
    }
    if backend == .lan, model?.isEmpty ?? true {
      throw AgentError.modelRequired
    }
    return AgentOptions(backend: backend, model: model, ollamaHost: ollamaHost)
  }
}

enum AgentError: Error, CustomStringConvertible {
  case helpRequested
  case missingValue(String)
  case unknownFlag(String)
  case unknownBackend(String)
  case modelRequired
  case badOllamaHost(String)
  case mlxUnavailable

  var description: String {
    switch self {
    case .helpRequested: return AgentOptions.usage
    case .missingValue(let flag): return "\(flag) needs a value."
    case .unknownFlag(let flag): return "Unknown flag \(flag)."
    case .unknownBackend(let name): return "Unknown backend '\(name)'. Use lan or mlx."
    case .modelRequired: return "--backend lan needs --model <name>."
    case .badOllamaHost(let host): return "Cannot build a URL for host '\(host)'."
    case .mlxUnavailable:
      // Said plainly rather than papered over with a silent fall back to LAN:
      // a node that claims to be running weights locally when it is proxying
      // Ollama misrepresents exactly the property this project measures.
      return """
        The MLX backend is not compiled into this build. mlx-swift-lm is an \
        Apple-GPU dependency and this package's manifest is also resolved by \
        the Linux CI job, which cannot carry it. The MLX node ships through \
        the Xcode project; use --backend lan here.
        """
    }
  }
}
