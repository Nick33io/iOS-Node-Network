import Foundation
import Observation

/// Manages which models are on disk and which is resident.
///
/// Downloading and loading are separate states and the UI has to show both.
/// A model can be present and cold, or absent entirely, and the failure modes
/// differ: the first costs seconds, the second costs gigabytes over a relayed
/// connection.
@MainActor
@Observable
final class ModelStore {
  struct Entry: Identifiable {
    let model: PinnedModel
    var isDownloaded: Bool
    var bytesOnDisk: Int64
    var id: String { model.id }

    var shortName: String {
      model.id.split(separator: "/").last.map(String.init) ?? model.id
    }
    var sizeLabel: String {
      String(format: "%.2f GB", Double(model.totalBytes) / 1_073_741_824)
    }
    /// What it needs resident to generate, not just what it occupies on disk.
    var residentLabel: String {
      String(format: "%.2f GB", Double(model.residentBytes(context: 4096)) / 1_073_741_824)
    }
  }

  var entries: [Entry] = []
  /// Model currently held in memory, if any.
  var loadedModelID: String?
  var busyModelID: String?
  var progress: Double = 0
  var status: String = ""
  var lastError: String?

  static let catalogue: [PinnedModel] = [
    .qwen3_1_7B_4bit, .qwen3_4B_4bit, .qwen3_8B_3bit, .qwen3_8B_4bit,
  ]

  init() {
    refresh()
  }

  /// Rescans the cache. Cheap — a directory listing, not a digest pass.
  func refresh() {
    entries = Self.catalogue.map { model in
      let bytes = Self.bytesOnDisk(for: model)
      return Entry(
        model: model,
        // Size alone is not proof of integrity; the downloader re-verifies
        // digests on load. This only answers "is it worth showing a download
        // button", which does not warrant hashing gigabytes on every refresh.
        isDownloaded: bytes >= model.totalBytes,
        bytesOnDisk: bytes
      )
    }
  }

  var totalOnDiskBytes: Int64 { entries.reduce(0) { $0 + $1.bytesOnDisk } }

  var diskLabel: String {
    String(format: "%.2f GB cached", Double(totalOnDiskBytes) / 1_073_741_824)
  }

  /// Free space on the volume holding the cache.
  var freeSpaceLabel: String {
    guard let root = try? PinnedModelDownloader.cacheRoot(
      id: Self.catalogue[0].id, revision: Self.catalogue[0].revision),
      let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
      let free = values.volumeAvailableCapacityForImportantUsage
    else { return "unknown" }
    return String(format: "%.0f GB free", Double(free) / 1_073_741_824)
  }

  // MARK: Actions

  #if canImport(MLX) && !targetEnvironment(simulator)
    /// Downloads and verifies, without loading. Separating the two lets a
    /// device fetch weights while plugged in and load them later, which is the
    /// only sane order on a phone.
    func download(_ entry: Entry, using writer: MLXWriter) async {
      busyModelID = entry.id
      progress = 0
      status = "downloading \(entry.shortName)"
      lastError = nil
      defer {
        busyModelID = nil
        refresh()
      }
      do {
        try await writer.prefetch(entry.model) { [weak self] fraction in
          Task { @MainActor in
            self?.progress = fraction
            self?.status = "downloading \(entry.shortName) \(Int(fraction * 100))%"
          }
        }
        status = "verified \(entry.shortName)"
      } catch {
        lastError = String(describing: error)
        status = ""
      }
    }

    func load(_ entry: Entry, using writer: MLXWriter) async {
      busyModelID = entry.id
      status = "loading \(entry.shortName)"
      lastError = nil
      defer { busyModelID = nil }
      do {
        try await writer.load(entry.model) { [weak self] fraction in
          Task { @MainActor in self?.progress = fraction }
        }
        loadedModelID = entry.id
        status = "loaded \(entry.shortName)"
        refresh()
      } catch {
        lastError = String(describing: error)
        status = ""
      }
    }

    func unload(using writer: MLXWriter) {
      writer.unload()
      loadedModelID = nil
      status = "unloaded"
    }
  #endif

  /// Deletes the cached weights. The download is expensive to repeat, so this
  /// is the only destructive action here and it is deliberately explicit.
  func evict(_ entry: Entry) {
    guard
      let root = try? PinnedModelDownloader.cacheRoot(
        id: entry.model.id, revision: entry.model.revision)
    else { return }
    try? FileManager.default.removeItem(at: root)
    status = "evicted \(entry.shortName)"
    refresh()
  }

  private static func bytesOnDisk(for model: PinnedModel) -> Int64 {
    guard let root = try? PinnedModelDownloader.cacheRoot(id: model.id, revision: model.revision)
    else { return 0 }
    var total: Int64 = 0
    guard
      let walker = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.fileSizeKey])
    else { return 0 }
    for case let url as URL in walker {
      total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
    return total
  }
}
