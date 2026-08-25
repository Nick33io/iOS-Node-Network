import Foundation

/// One file of a pinned revision.
///
/// Deliberately outside the MLX availability guard. A manifest is data, and the
/// simulator — which has no Metal GPU and therefore no MLX — still has to
/// compile the app that carries it.
struct ModelFile: Sendable {
  /// How the repository stores a file, which decides what its recorded digest
  /// is taken over.
  enum Digest: Sendable {
    /// Git object SHA-1: `sha1("blob <size>\0" + contents)`. Plain git blobs.
    case gitBlob(String)
    /// Content SHA-256, as recorded in the pointer for git-lfs files.
    case sha256(String)

    var value: String {
      switch self {
      case .gitBlob(let value), .sha256(let value): return value
      }
    }
  }

  let path: String
  let size: Int64
  let digest: Digest
}

/// A model pinned to an immutable revision with a verified file manifest.
///
/// Grouping the id, revision, and manifest into one value is what makes
/// switching models a safe edit: the three can no longer drift apart, and a
/// half-updated pin fails at compile time rather than at digest verification
/// after a multi-gigabyte download.
struct PinnedModel: Sendable {
  let id: String
  let revision: String

  /// Transformer shape, for sizing the KV cache.
  let layers: Int
  let kvHeads: Int
  let headDim: Int

  let files: [ModelFile]

  var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

  /// Bytes this model needs resident to generate at `context` tokens.
  ///
  /// Weights plus KV cache plus a fixed allowance for the tokenizer, MLX's
  /// arenas, and the app itself. This replaces a flat "double the weights"
  /// rule, which was wrong in both directions: far too generous for a small
  /// model and needlessly strict for a large one, because the KV cache scales
  /// with context and layer count, not with weight size.
  func residentBytes(context: Int) -> Int64 {
    let kv = Int64(context * layers * 2 * kvHeads * headDim * 2)
    // 1.2 GB, set from a measured failure rather than a guess. At 400 MB three
    // iOS devices each cleared the 8B by 60-90 MB; two were killed the moment
    // they tried to load it, while the third — which had landed on the 4B —
    // ran a 35 second sustained test without a single failure. The crash puts
    // real overhead above 460 MB. Erring high costs a size class; erring low
    // costs the node.
    let overhead: Int64 = 1200 * 1024 * 1024
    return totalBytes + kv + overhead
  }

  /// 0.98 GB. Default: small enough to load on an 8 GB device with room for
  /// the KV cache, even without the increased-memory-limit entitlement.
  ///
  /// Captured from the Hugging Face tree for this revision on 2026-08-20.
  /// Git blobs carry their Git object SHA-1; LFS payloads their content
  /// SHA-256. This repository ships no `chat_template.jinja` — the template
  /// lives inside `tokenizer_config.json`.
  static let qwen3_1_7B_4bit = PinnedModel(
    id: "mlx-community/Qwen3-1.7B-4bit",
    revision: "3b1b1768f8f8cf8351c712464f906e86c2b8269e",
    layers: 28, kvHeads: 8, headDim: 128,
    files: [
      .init(path: "added_tokens.json", size: 707, digest: .gitBlob("b54f9135e44c1e81047e8d05cb027af8bc039eed")),
      .init(path: "config.json", size: 937, digest: .gitBlob("0a78ffc3980b062021a450199988d0ed8537239d")),
      .init(path: "model.safetensors", size: 968_080_210, digest: .sha256("0e86d9677e519323849eac1bc272caae88567a481ff188c431f70be543d9995f")),
      .init(path: "model.safetensors.index.json", size: 49_731, digest: .gitBlob("8607d041b6549c15a4db85e7b4c5cf30d3ab890a")),
      .init(path: "special_tokens_map.json", size: 613, digest: .gitBlob("ac23c0aaa2434523c494330aeb79c58395378103")),
      .init(path: "tokenizer.json", size: 11_422_654, digest: .sha256("aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4")),
      .init(path: "tokenizer_config.json", size: 9_706, digest: .gitBlob("7345216a0785dc7086e8c245b2a9d3896ce2b756")),
      .init(path: "vocab.json", size: 2_776_833, digest: .gitBlob("4783fe10ac3adce15ac8f358ef5462739852c569")),
    ]
  )

  /// 4.62 GB. For devices with both the headroom and the entitlement — an M4
  /// iPad, not a phone. Captured from the Hugging Face tree on 2026-08-23.
  /// Qwen3-8B at 3-bit — the largest model that fits an iOS jetsam budget.
  ///
  /// The 4-bit build needs 6.50 GB against a measured 6.00 GB ceiling and is
  /// killed on load; at 3-bit the same model needs 5.41 GB and fits with the
  /// conservative 1.2 GB overhead left untouched. Capability on a phone comes
  /// from fewer bits, not from more memory: the ceiling is jetsam, and no
  /// entitlement moves it further than increased-memory-limit already has.
  static let qwen3_8B_3bit = PinnedModel(
    id: "mlx-community/Qwen3-8B-3bit",
    revision: "619ded35b7d1d083ccafc367ea5ccdab1840b74d",
    layers: 36, kvHeads: 8, headDim: 128,
    files: [
      ModelFile(path: "added_tokens.json", size: 707, digest: .gitBlob("b54f9135e44c1e81047e8d05cb027af8bc039eed")),
      ModelFile(path: "config.json", size: 939, digest: .gitBlob("cf5cea411b6080b89ac0d37918f7fda6ed85ed04")),
      ModelFile(path: "merges.txt", size: 1671853, digest: .gitBlob("31349551d90c7606f325fe0f11bbb8bd5fa0d7c7")),
      ModelFile(path: "model.safetensors", size: 3584031644, digest: .sha256("b9694bdb1f737223836235c0427b424ace11d566eeab0ac91ff8050143bd20a1")),
      ModelFile(path: "model.safetensors.index.json", size: 64065, digest: .gitBlob("01bae3b53a5c5d19ec5657dd1a7a2efe8482e94c")),
      ModelFile(path: "special_tokens_map.json", size: 613, digest: .gitBlob("ac23c0aaa2434523c494330aeb79c58395378103")),
      ModelFile(path: "tokenizer.json", size: 11422654, digest: .sha256("aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4")),
      ModelFile(path: "tokenizer_config.json", size: 9706, digest: .gitBlob("7345216a0785dc7086e8c245b2a9d3896ce2b756")),
      ModelFile(path: "vocab.json", size: 2776833, digest: .gitBlob("4783fe10ac3adce15ac8f358ef5462739852c569")),
    ]
  )

  static let qwen3_8B_4bit = PinnedModel(
    id: "mlx-community/Qwen3-8B-4bit",
    revision: "545dc4251c05440727734bcd94334791f6ab0192",
    layers: 36, kvHeads: 8, headDim: 128,
    files: [
      .init(path: "added_tokens.json", size: 707, digest: .gitBlob("b54f9135e44c1e81047e8d05cb027af8bc039eed")),
      .init(path: "config.json", size: 939, digest: .gitBlob("6f2a32b76648381bea25bdc81fad0e7160f86ac5")),
      .init(path: "model.safetensors", size: 4_607_835_174, digest: .sha256("f2d29621aab300336ad645567ff38c42aac755513006ef4e8a579cf7ef5256d8")),
      .init(path: "model.safetensors.index.json", size: 64_065, digest: .gitBlob("4af62897c345f277e7b17aab48230d7ba119d87e")),
      .init(path: "special_tokens_map.json", size: 613, digest: .gitBlob("ac23c0aaa2434523c494330aeb79c58395378103")),
      .init(path: "tokenizer.json", size: 11_422_654, digest: .sha256("aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4")),
      .init(path: "tokenizer_config.json", size: 9_706, digest: .gitBlob("7345216a0785dc7086e8c245b2a9d3896ce2b756")),
      .init(path: "vocab.json", size: 2_776_833, digest: .gitBlob("4783fe10ac3adce15ac8f358ef5462739852c569")),
    ]
  )

  /// 2.3 GB. Better prose, but needs the increased-memory-limit entitlement on
  /// an 8 GB device. Carried over from the audited 33io plugin manifest.
  static let qwen3_4B_4bit = PinnedModel(
    id: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
    revision: "50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b",
    layers: 36, kvHeads: 8, headDim: 128,
    files: [
      .init(path: "added_tokens.json", size: 707, digest: .gitBlob("b54f9135e44c1e81047e8d05cb027af8bc039eed")),
      .init(path: "chat_template.jinja", size: 4_040, digest: .gitBlob("a18870ad4ba26ac6c43758fc506c1bb6ff206bb4")),
      .init(path: "config.json", size: 938, digest: .gitBlob("ce8b8eccd1cdf6d8a30767f58e8ff858dd15eab5")),
      .init(path: "generation_config.json", size: 238, digest: .gitBlob("432531a002c181a19de338313d2375e9d7494d7e")),
      .init(path: "model.safetensors", size: 2_263_022_417, digest: .sha256("2a73c6c248601ab904e035548abd8e6abb65ea27dcb5f342fb0a8910eb44173f")),
      .init(path: "model.safetensors.index.json", size: 63_964, digest: .gitBlob("4741a210f9920c2949ca73bbb2a7ce9583e7fd83")),
      .init(path: "special_tokens_map.json", size: 613, digest: .gitBlob("ac23c0aaa2434523c494330aeb79c58395378103")),
      .init(path: "tokenizer.json", size: 11_422_654, digest: .sha256("aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4")),
      .init(path: "tokenizer_config.json", size: 5_440, digest: .gitBlob("474bbcd82077828bdec32b8dbc1826cdff2a792a")),
      .init(path: "vocab.json", size: 2_776_833, digest: .gitBlob("4783fe10ac3adce15ac8f358ef5462739852c569")),
    ]
  )
}
