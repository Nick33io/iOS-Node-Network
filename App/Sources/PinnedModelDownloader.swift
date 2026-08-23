import Foundation

#if canImport(MLX) && !targetEnvironment(simulator)
  import CryptoKit
  import MLXLMCommon

  /// A `Downloader` that can only ever produce one directory: the ten files of
  /// the pinned Qwen3 revision, each matching a recorded size and digest.
  ///
  /// This is the supply-chain boundary. The weights decide what the writer
  /// says, so "some files from a repo with the right name" is not good enough —
  /// nothing reaches MLX until every byte has been accounted for. Everything
  /// here is policy carried over from the audited 33io plugin, not tuning:
  /// changing an id, a revision, or a digest changes which model the product
  /// runs, so treat it as a reviewed change.
  struct PinnedModelDownloader: Downloader {
    /// The manifest types live outside this guard; see PinnedModel.swift.
    typealias Entry = ModelFile
    typealias FileDigest = ModelFile.Digest

    /// The revision, enumerated. A glob describes names; this describes
    /// content, which is the only thing worth checking.
    /// The model this instance serves. Held rather than read from policy so a
    /// download and the verification that follows it cannot disagree about
    /// which revision they are checking.
    let model: PinnedModel

    init(model: PinnedModel = MLXPolicy.model) {
      self.model = model
    }

    var manifest: [Entry] { model.files }

    var totalBytes: Int64 { manifest.reduce(Int64(0)) { $0 + $1.size } }

    /// What MLX asks for today. Checked rather than obeyed: if a future MLX
    /// asks for a different set, the manifest may no longer be the right answer
    /// to the question being asked, and that deserves a review rather than a
    /// silent substitution.
    static let expectedPatterns: Set<String> = ["*.safetensors", "*.json", "*.jinja"]

    /// The one host this downloader talks to.
    static let host = URL(string: "https://huggingface.co")!

    /// Hugging Face client conventions that would attach an identity or move
    /// the endpoint. Presence alone is fatal: this fetch is meant to be
    /// anonymous and to come from a fixed host, so an environment that expects
    /// otherwise is a misconfiguration to surface, not to quietly ignore.
    static let refusedEnvironmentKeys = [
      "HF_TOKEN", "HUGGING_FACE_HUB_TOKEN", "HF_ENDPOINT", "HF_TOKEN_PATH",
    ]

    func download(
      id: String,
      revision: String?,
      matching patterns: [String],
      useLatest: Bool,
      progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
      guard Set(patterns) == Self.expectedPatterns else {
        throw PinnedDownloadError.unexpectedPatterns(patterns.sorted())
      }
      guard id == model.id else {
        throw PinnedDownloadError.unexpectedModel(id)
      }
      guard let revision, revision == model.revision else {
        throw PinnedDownloadError.unexpectedRevision(revision)
      }
      // A pinned immutable commit has no newer version to look for, so a caller
      // asking for "latest" believes it is tracking something this is not.
      guard !useLatest else { throw PinnedDownloadError.latestRequested }

      let environment = ProcessInfo.processInfo.environment
      for key in Self.refusedEnvironmentKeys where environment[key] != nil {
        throw PinnedDownloadError.refusedEnvironment(key)
      }

      let root = try Self.cacheRoot(id: id, revision: revision)

      // A cache entry is only bytes on disk that something else may also be
      // able to write, so it earns no more trust than the network does. This
      // does mean re-hashing ~2.3 GB on every load; that cost is the point, and
      // it is still far cheaper than the download it replaces.
      if self.isVerified(directory: root) {
        progressHandler(self.progress(completed: totalBytes))
        return root
      }

      do {
        try? FileManager.default.removeItem(at: root)
        try await self.fetchAll(
          into: root, id: id, revision: revision, progressHandler: progressHandler)
        try self.verify(directory: root)
      } catch {
        // Never leave a half-written or rejected tree behind: the next launch
        // would find it and have to decide all over again whether to trust it.
        try? FileManager.default.removeItem(at: root)
        throw error
      }

      return root
    }

    // MARK: - Cache location

    static func cacheRoot(id: String, revision: String) throws -> URL {
      guard
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      else {
        throw PinnedDownloadError.noCacheDirectory
      }
      // Scoped by revision so moving the pin lands in a fresh directory instead
      // of mixing two revisions' files in one.
      let root =
        caches
        .appendingPathComponent("PinnedModels", isDirectory: true)
        .appendingPathComponent(id.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
        .appendingPathComponent(revision, isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      return root.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Resolves a manifest path under `root` and refuses anything that does not
    /// land directly inside it. The manifest holds plain file names, so this can
    /// only fire if the manifest is wrong or something replaced an entry with a
    /// link pointing elsewhere — both worth failing on rather than following.
    private static func location(of entry: Entry, under root: URL) throws -> URL {
      guard !entry.path.contains("/"), entry.path != ".", entry.path != ".." else {
        throw PinnedDownloadError.unsafePath(entry.path)
      }
      let resolved =
        root
        .appendingPathComponent(entry.path, isDirectory: false)
        .resolvingSymlinksInPath()
        .standardizedFileURL
      guard resolved.path.hasPrefix(root.path + "/") else {
        throw PinnedDownloadError.unsafePath(entry.path)
      }
      return resolved
    }

    // MARK: - Verification

    private func isVerified(directory root: URL) -> Bool {
      do {
        try verify(directory: root)
        return true
      } catch {
        return false
      }
    }

    /// Checks the directory holds exactly the manifest: nothing missing,
    /// nothing extra, every size and digest as recorded.
    private func verify(directory root: URL) throws {
      let present = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
      let expected = Set(manifest.map(\.path))
      guard present == expected else {
        throw PinnedDownloadError.contentsMismatch(
          unexpected: present.subtracting(expected).sorted(),
          missing: expected.subtracting(present).sorted())
      }
      for entry in manifest {
        try Self.verify(entry: entry, at: try Self.location(of: entry, under: root))
      }
    }

    private static func verify(entry: Entry, at url: URL) throws {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      guard attributes[.type] as? FileAttributeType == .typeRegular else {
        throw PinnedDownloadError.notARegularFile(entry.path)
      }
      let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
      guard size == entry.size else {
        throw PinnedDownloadError.sizeMismatch(path: entry.path, expected: entry.size, found: size)
      }
      let found = try digest(of: url, for: entry)
      guard found == entry.digest.value.lowercased() else {
        throw PinnedDownloadError.digestMismatch(
          path: entry.path, expected: entry.digest.value, found: found)
      }
    }

    /// 4 MiB at a time. The weights are ~2.3 GB: reading them into memory to
    /// hash them would be a worse failure than the one being guarded against.
    private static let chunkBytes = 4 << 20

    private static func digest(of url: URL, for entry: Entry) throws -> String {
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }

      switch entry.digest {
      case .gitBlob:
        var hasher = Insecure.SHA1()
        // Git hashes the object rather than the file, so the header comes
        // first. The size used is the manifest's, which the check above has
        // already proved is the file's.
        hasher.update(data: Data("blob \(entry.size)\0".utf8))
        try stream(handle) { hasher.update(data: $0) }
        return hexadecimal(hasher.finalize())
      case .sha256:
        var hasher = SHA256()
        try stream(handle) { hasher.update(data: $0) }
        return hexadecimal(hasher.finalize())
      }
    }

    private static func stream(_ handle: FileHandle, into update: (Data) -> Void) throws {
      while let chunk = try handle.read(upToCount: chunkBytes), !chunk.isEmpty {
        update(chunk)
      }
    }

    private static func hexadecimal(_ bytes: some Sequence<UInt8>) -> String {
      bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Fetching

    private func fetchAll(
      into root: URL,
      id: String,
      revision: String,
      progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

      let configuration = URLSessionConfiguration.ephemeral
      // Nothing in this request may carry an identity, and no response may be
      // served from or written to a cache shared with the rest of the app.
      configuration.httpAdditionalHeaders = [:]
      configuration.httpShouldSetCookies = false
      configuration.httpCookieAcceptPolicy = .never
      configuration.httpCookieStorage = nil
      configuration.urlCredentialStorage = nil
      configuration.urlCache = nil
      configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData

      let coordinator = DownloadCoordinator(total: totalBytes, report: progressHandler)
      let session = URLSession(
        configuration: configuration, delegate: coordinator, delegateQueue: nil)
      // The session holds its delegate until it is invalidated.
      defer { session.finishTasksAndInvalidate() }

      for entry in manifest {
        try await coordinator.fetch(
          try Self.fileURL(id: id, revision: revision, path: entry.path),
          to: try Self.location(of: entry, under: root),
          session: session)
        coordinator.settle(bytes: entry.size)
      }
    }

    /// `https://huggingface.co/{id}/resolve/{revision}/{path}`, built against
    /// the fixed host so no environment can point it somewhere else.
    private static func fileURL(id: String, revision: String, path: String) throws -> URL {
      guard var components = URLComponents(url: host, resolvingAgainstBaseURL: false) else {
        throw PinnedDownloadError.malformedURL(path)
      }
      components.path = "/\(id)/resolve/\(revision)/\(path)"
      guard let url = components.url, url.scheme == host.scheme, url.host == host.host else {
        throw PinnedDownloadError.malformedURL(path)
      }
      return url
    }

    fileprivate func progress(completed: Int64) -> Progress {
      let progress = Progress(totalUnitCount: totalBytes)
      progress.completedUnitCount = min(completed, totalBytes)
      return progress
    }
  }

  /// Runs the manifest's downloads one at a time, moving each finished file
  /// into place and reporting bytes as they arrive.
  ///
  /// The session drives this as its delegate rather than using the async
  /// `download(for:)` convenience, which reports no byte-level progress. With
  /// 99% of the manifest in a single 2.3 GB file, per-file progress would leave
  /// a long silence that is indistinguishable from a hang.
  ///
  /// `@unchecked Sendable` because the delegate callbacks arrive on the
  /// session's queue while `fetch` awaits elsewhere: every stored property is
  /// guarded by `lock`.
  private final class DownloadCoordinator: NSObject, URLSessionDownloadDelegate, @unchecked Sendable
  {
    private let lock = NSLock()
    private let total: Int64
    private let report: @Sendable (Progress) -> Void

    /// Bytes from files already downloaded and moved into place.
    private var settled: Int64 = 0
    private var destination: URL?
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?

    init(total: Int64, report: @escaping @Sendable (Progress) -> Void) {
      self.total = total
      self.report = report
    }

    func fetch(_ url: URL, to target: URL, session: URLSession) async throws {
      let task = session.downloadTask(with: URLRequest(url: url))
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          lock.lock()
          self.destination = target
          self.continuation = continuation
          self.failure = nil
          lock.unlock()
          task.resume()
        }
      } onCancel: {
        task.cancel()
      }
    }

    func settle(bytes: Int64) {
      lock.lock()
      settled += bytes
      lock.unlock()
      emit(current: 0)
    }

    private func emit(current: Int64) {
      lock.lock()
      let done = settled + current
      lock.unlock()
      // A fresh Progress per report: the handler is `@Sendable` and may run
      // anywhere, so handing it a shared mutable object would be the kind of
      // race this file exists to rule out.
      let progress = Progress(totalUnitCount: total)
      progress.completedUnitCount = min(done, total)
      report(progress)
    }

    func urlSession(
      _ session: URLSession,
      downloadTask: URLSessionDownloadTask,
      didWriteData bytesWritten: Int64,
      totalBytesWritten: Int64,
      totalBytesExpectedToWrite: Int64
    ) {
      emit(current: totalBytesWritten)
    }

    func urlSession(
      _ session: URLSession,
      task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse,
      newRequest request: URLRequest,
      completionHandler: @escaping (URLRequest?) -> Void
    ) {
      // The large files redirect to a CDN, so redirects have to be followed —
      // but never off TLS. What makes the hop safe is the digest check: a
      // redirect can change where the bytes come from, not what they must be.
      completionHandler(request.url?.scheme == "https" ? request : nil)
    }

    func urlSession(
      _ session: URLSession,
      downloadTask: URLSessionDownloadTask,
      didFinishDownloadingTo location: URL
    ) {
      lock.lock()
      let target = destination
      lock.unlock()

      // An error page downloads just as successfully as the weights do. Naming
      // the status is far more use than letting the digest check report noise.
      if let response = downloadTask.response as? HTTPURLResponse, response.statusCode != 200 {
        record(
          PinnedDownloadError.httpStatus(
            path: target?.lastPathComponent ?? "", code: response.statusCode))
        return
      }
      guard let target else { return }

      // Has to happen before returning: the system reclaims `location` as soon
      // as this method does.
      do {
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: location, to: target)
      } catch {
        record(error)
      }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?)
    {
      lock.lock()
      let pending = continuation
      continuation = nil
      let outcome = error ?? failure
      failure = nil
      destination = nil
      lock.unlock()

      if let outcome {
        pending?.resume(throwing: outcome)
      } else {
        pending?.resume()
      }
    }

    private func record(_ error: Error) {
      lock.lock()
      if failure == nil { failure = error }
      lock.unlock()
    }
  }

  enum PinnedDownloadError: Error, CustomStringConvertible {
    case unexpectedPatterns([String])
    case unexpectedModel(String)
    case unexpectedRevision(String?)
    case latestRequested
    case refusedEnvironment(String)
    case noCacheDirectory
    case unsafePath(String)
    case malformedURL(String)
    case httpStatus(path: String, code: Int)
    case contentsMismatch(unexpected: [String], missing: [String])
    case notARegularFile(String)
    case sizeMismatch(path: String, expected: Int64, found: Int64)
    case digestMismatch(path: String, expected: String, found: String)

    var description: String {
      switch self {
      case .unexpectedPatterns(let patterns):
        return "Refusing a download for unexpected patterns \(patterns)."
      case .unexpectedModel(let id):
        return "Refusing model \(id): only \(MLXPolicy.allowedModel) is pinned."
      case .unexpectedRevision(let revision):
        return "Refusing revision \(revision ?? "none"): only the pinned revision is allowed."
      case .latestRequested:
        return "Refusing to check for a newer version: the revision is pinned to a fixed commit."
      case .refusedEnvironment(let key):
        return "Refusing to download with \(key) set: this fetch must be anonymous and undirected."
      case .noCacheDirectory:
        return "No caches directory is available to hold the model."
      case .unsafePath(let path):
        return "Refusing model file \(path): it does not resolve inside the model cache."
      case .malformedURL(let path):
        return "Could not build a download URL for \(path) on the pinned host."
      case .httpStatus(let path, let code):
        return "Download of \(path) failed with HTTP \(code)."
      case .contentsMismatch(let unexpected, let missing):
        return
          "Model directory does not match the manifest (unexpected: \(unexpected), missing: \(missing))."
      case .notARegularFile(let path):
        return "Model file \(path) is not a regular file."
      case .sizeMismatch(let path, let expected, let found):
        return "Model file \(path) is \(found) bytes, expected \(expected)."
      case .digestMismatch(let path, let expected, let found):
        return "Model file \(path) digest \(found) does not match the pinned \(expected)."
      }
    }
  }
#endif
