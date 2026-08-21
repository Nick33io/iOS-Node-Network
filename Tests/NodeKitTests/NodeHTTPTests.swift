#if canImport(Darwin)
  import Foundation
  import WriteCore
  import XCTest

  @testable import NodeKit

  final class HTTPRequestTests: XCTestCase {
    private func raw(_ text: String) -> Data { Data(text.utf8) }

    func testParsesRequestLineAndBody() throws {
      let request = try XCTUnwrap(
        HTTPRequest(
          raw(
            "POST /generate HTTP/1.1\r\nContent-Length: 16\r\n\r\n{\"prompt\":\"hi\"}\n"
          )
        )
      )
      XCTAssertEqual(request.method, "POST")
      XCTAssertEqual(request.path, "/generate")
      XCTAssertEqual(request.body.count, 16)
    }

    func testWaitsForIncompleteHeaders() {
      XCTAssertNil(HTTPRequest(raw("POST /generate HTTP/1.1\r\nContent-Length: 4\r\n")))
    }

    /// A prompt large enough to cross a TCP segment is the common case, not an
    /// edge case, so a truncated body must never be answered.
    func testWaitsForTheDeclaredBody() {
      XCTAssertNil(HTTPRequest(raw("POST /generate HTTP/1.1\r\nContent-Length: 40\r\n\r\n{\"a\":1}")))
    }

    func testContentLengthIsCaseInsensitive() throws {
      let request = try XCTUnwrap(
        HTTPRequest(raw("POST /generate HTTP/1.1\r\ncontent-length: 3\r\n\r\nabc"))
      )
      XCTAssertEqual(request.body, raw("abc"))
    }

    func testBodylessGetParses() throws {
      let request = try XCTUnwrap(HTTPRequest(raw("GET /health HTTP/1.1\r\nHost: x\r\n\r\n")))
      XCTAssertEqual(request.method, "GET")
      XCTAssertEqual(request.path, "/health")
      XCTAssertTrue(request.body.isEmpty)
    }

    /// Trailing bytes from a pipelined or padded write must not leak into the
    /// prompt the writer sees.
    func testBodyIsTruncatedToContentLength() throws {
      let request = try XCTUnwrap(
        HTTPRequest(raw("POST /generate HTTP/1.1\r\nContent-Length: 3\r\n\r\nabcEXTRA"))
      )
      XCTAssertEqual(request.body, raw("abc"))
    }
  }

  final class GenerateRequestLimitTests: XCTestCase {
    private let limits = DeviceLimits.qwen3_4B_4bit

    private func body(_ json: [String: Any]) throws -> Data {
      try JSONSerialization.data(withJSONObject: json)
    }

    func testAcceptsAPromptInsideTheLimit() throws {
      let request = try GenerateRequest(body: try body(["prompt": "write a memo"]), limits: limits)
      XCTAssertEqual(request.prompt, "write a memo")
      XCTAssertEqual(request.maxOutputTokens, limits.maxOutputTokens)
    }

    /// The point of the whole exercise: an Ollama-backed node must refuse the
    /// prompt a phone refuses, and refuse it before a writer is ever built.
    func testRejectsAnOverLongPrompt() throws {
      let oversized = String(repeating: "x", count: limits.maxInputCharacters + 1)
      XCTAssertThrowsError(
        try GenerateRequest(body: try body(["prompt": oversized]), limits: limits)
      ) { error in
        guard case NodeRequestError.promptOverLimit(let characters, let limit) = error else {
          return XCTFail("expected promptOverLimit, got \(error)")
        }
        XCTAssertEqual(characters, limits.maxInputCharacters + 1)
        XCTAssertEqual(limit, limits.maxInputCharacters)
        XCTAssertEqual(NodeRequestError.promptOverLimit(characters: characters, limit: limit).status,
                       "413 Content Too Large")
      }
    }

    func testAcceptsAPromptExactlyAtTheLimit() throws {
      let exact = String(repeating: "x", count: limits.maxInputCharacters)
      let request = try GenerateRequest(body: try body(["prompt": exact]), limits: limits)
      XCTAssertEqual(request.prompt.count, limits.maxInputCharacters)
    }

    func testClampsAnOversizedOutputRequest() throws {
      let request = try GenerateRequest(
        body: try body(["prompt": "hi", "maxOutputTokens": 100_000]), limits: limits
      )
      XCTAssertEqual(request.maxOutputTokens, limits.maxOutputTokens)
    }

    func testClampsANonPositiveOutputRequest() throws {
      let request = try GenerateRequest(
        body: try body(["prompt": "hi", "maxOutputTokens": 0]), limits: limits
      )
      XCTAssertEqual(request.maxOutputTokens, 1)
    }

    func testHonoursASmallerOutputRequest() throws {
      let request = try GenerateRequest(
        body: try body(["prompt": "hi", "maxOutputTokens": 32]), limits: limits
      )
      XCTAssertEqual(request.maxOutputTokens, 32)
    }

    func testRejectsABodyWithoutAPrompt() throws {
      XCTAssertThrowsError(try GenerateRequest(body: try body(["maxOutputTokens": 8]), limits: limits)) {
        XCTAssertEqual(($0 as? NodeRequestError)?.status, "400 Bad Request")
      }
    }

    func testRejectsNonJSON() {
      XCTAssertThrowsError(try GenerateRequest(body: Data("not json".utf8), limits: limits)) {
        guard case NodeRequestError.malformedBody = $0 else {
          return XCTFail("expected malformedBody, got \($0)")
        }
      }
    }
  }
#endif
