import Foundation
import Observation

#if canImport(AVFoundation) && canImport(Vision) && !targetEnvironment(simulator)
  import AVFoundation
  import CoreImage
  import Vision

  /// Turns the front camera into a stream of `GlyphFrame`s.
  ///
  /// Captures at the lowest preset that still resolves a face, because the
  /// output is a ~60x40 grid — anything more is pixels we immediately throw
  /// away, paid for in power on a device that may also be generating text.
  ///
  /// Simulator has no camera, so this whole file compiles out and the ambient
  /// view falls back to the synthetic rain.
  @MainActor
  @Observable
  final class CameraGlyphSource: NSObject {
    private(set) var frame: GlyphFrame = .empty
    private(set) var isRunning = false
    private(set) var lastError: String?

    /// Grid size. Kept modest: at arm's length a denser grid stops reading as
    /// glyphs and starts reading as texture.
    ///
    /// Constants rather than settings, and deliberately non-isolated: the
    /// capture delegate runs on its own queue and must read them without a hop
    /// to the main actor for every frame.
    nonisolated static let columns = 64
    nonisolated static let rows = 44

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "io.thirtythree.nod3.camera")
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private var sequence = 0
    /// Reused across frames; allocating a mask request per frame is the single
    /// most expensive mistake available here.
    ///
    /// `nonisolated(unsafe)` because Vision requests are mutable classes and
    /// this one is configured once in `init`, then touched only from the
    /// capture queue — which is serial, so there is no concurrent access to
    /// protect against.
    private nonisolated(unsafe) let personRequest = VNGeneratePersonSegmentationRequest()

    override init() {
      super.init()
      personRequest.qualityLevel = .fast
      personRequest.outputPixelFormat = kCVPixelFormatType_OneComponent8
    }

    func start() async {
      guard !isRunning else { return }
      guard await Self.authorized() else {
        lastError = "camera access denied"
        return
      }
      session.beginConfiguration()
      session.sessionPreset = .vga640x480
      guard
        let device = AVCaptureDevice.default(
          .builtInWideAngleCamera, for: .video, position: .front),
        let input = try? AVCaptureDeviceInput(device: device),
        session.canAddInput(input)
      else {
        session.commitConfiguration()
        lastError = "no front camera"
        return
      }
      session.addInput(input)

      let output = AVCaptureVideoDataOutput()
      output.videoSettings = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
      ]
      // Dropping is correct: a stale frame shown late is worse than a gap.
      output.alwaysDiscardsLateVideoFrames = true
      output.setSampleBufferDelegate(self, queue: queue)
      guard session.canAddOutput(output) else {
        session.commitConfiguration()
        lastError = "cannot attach output"
        return
      }
      session.addOutput(output)
      session.commitConfiguration()

      queue.async { [session] in session.startRunning() }
      isRunning = true
    }

    func stop() {
      guard isRunning else { return }
      queue.async { [session] in session.stopRunning() }
      isRunning = false
    }

    private static func authorized() async -> Bool {
      switch AVCaptureDevice.authorizationStatus(for: .video) {
      case .authorized: return true
      case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
      default: return false
      }
    }
  }

  extension CameraGlyphSource: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
      _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
      from connection: AVCaptureConnection
    ) {
      guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

      // Person mask first, at capture resolution, so the downsample below can
      // sample it on the same grid as luminance.
      var mask: CVPixelBuffer?
      let handler = VNImageRequestHandler(cvPixelBuffer: pixels, options: [:])
      if (try? handler.perform([personRequest])) != nil {
        mask = (personRequest.results?.first)?.pixelBuffer
      }

      let built = Self.grid(
        from: pixels, mask: mask, columns: Self.columns, rows: Self.rows)
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.sequence += 1
        self.frame = GlyphFrame(
          columns: built.columns, glyphs: built.glyphs, levels: built.levels,
          subject: built.subject, sequence: self.sequence
        )
      }
    }

    /// Box-samples the frame down to the glyph grid.
    ///
    /// Averaging over each cell rather than point-sampling matters: a single
    /// pixel per cell makes the whole field shimmer as noise, because adjacent
    /// frames pick different pixels out of the same feature.
    nonisolated static func grid(
      from pixels: CVPixelBuffer, mask: CVPixelBuffer?, columns: Int, rows: Int
    ) -> (columns: Int, glyphs: [UInt8], levels: [UInt8], subject: [Bool]) {
      CVPixelBufferLockBaseAddress(pixels, .readOnly)
      defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
      guard let base = CVPixelBufferGetBaseAddress(pixels) else {
        return (0, [], [], [])
      }
      let width = CVPixelBufferGetWidth(pixels)
      let height = CVPixelBufferGetHeight(pixels)
      let stride = CVPixelBufferGetBytesPerRow(pixels)
      let bytes = base.assumingMemoryBound(to: UInt8.self)

      var maskBytes: UnsafeMutablePointer<UInt8>?
      var maskWidth = 0, maskHeight = 0, maskStride = 0
      if let mask {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        maskWidth = CVPixelBufferGetWidth(mask)
        maskHeight = CVPixelBufferGetHeight(mask)
        maskStride = CVPixelBufferGetBytesPerRow(mask)
        maskBytes = CVPixelBufferGetBaseAddress(mask)?.assumingMemoryBound(to: UInt8.self)
      }
      defer { if let mask { CVPixelBufferUnlockBaseAddress(mask, .readOnly) } }

      var glyphs = [UInt8](repeating: 0, count: columns * rows)
      var levels = [UInt8](repeating: 0, count: columns * rows)
      var subject = [Bool](repeating: false, count: columns * rows)

      let cellWidth = max(1, width / columns)
      let cellHeight = max(1, height / rows)
      // Sample a sparse lattice inside each cell rather than every pixel: at
      // VGA that is ~16 reads instead of ~300 for a visually identical result.
      let stepX = max(1, cellWidth / 4)
      let stepY = max(1, cellHeight / 4)

      for row in 0..<rows {
        for column in 0..<columns {
          // Mirror horizontally: a front camera is a mirror, and an unmirrored
          // ambient display reads as someone else in the room.
          let x0 = (columns - 1 - column) * cellWidth
          let y0 = row * cellHeight
          var total = 0
          var samples = 0
          var y = y0
          while y < min(y0 + cellHeight, height) {
            var x = x0
            while x < min(x0 + cellWidth, width) {
              let offset = y * stride + x * 4
              // BGRA. Rec. 601 luma, integer-weighted to stay off the FPU in
              // the hot loop.
              let b = Int(bytes[offset])
              let g = Int(bytes[offset + 1])
              let r = Int(bytes[offset + 2])
              total += (r * 77 + g * 150 + b * 29) >> 8
              samples += 1
              x += stepX
            }
            y += stepY
          }
          let level = samples > 0 ? UInt8(min(255, total / samples)) : 0
          let index = row * columns + column
          levels[index] = level
          glyphs[index] = GlyphRamp.index(for: level)

          if let maskBytes, maskWidth > 0, maskHeight > 0 {
            let mx = min(maskWidth - 1, (columns - 1 - column) * maskWidth / columns)
            let my = min(maskHeight - 1, row * maskHeight / rows)
            subject[index] = maskBytes[my * maskStride + mx] > 128
          }
        }
      }
      return (columns, glyphs, levels, subject)
    }
  }
#endif
