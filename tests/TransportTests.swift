import Foundation
import XCTest

@testable import Bitsrun

@MainActor
final class TransportTests: XCTestCase {
  func testPlusAndUnicodeSurviveFormQueryEncoding() throws {
    let target = try HTTPClient.target("/cgi-bin/srun_portal", query: ["username": "a+b 用户"])
    XCTAssertTrue(target.contains("%2B"))
    XCTAssertFalse(target.contains("+"))
    let url = try XCTUnwrap(URLComponents(string: target))
    XCTAssertEqual(url.queryItems?.first?.value, "a+b 用户")
  }

  func testRepeatedCookiesAreAccepted() throws {
    let response = Data(
      "HTTP/1.1 200 OK\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\nContent-Length: 1\r\n\r\nx".utf8
    )
    XCTAssertEqual(try HTTPResponse.body(response, complete: true), Data("x".utf8))
  }

  func testContentLengthAcrossEveryFragmentBoundary() throws {
    let response = Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello".utf8)
    for count in 0..<response.count {
      XCTAssertNil(try HTTPResponse.body(response.prefix(count), complete: false))
    }
    XCTAssertEqual(try HTTPResponse.body(response, complete: false), Data("hello".utf8))
  }

  func testChunkedBodyAcrossEveryFragmentBoundary() throws {
    let response = Data(
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2;test=1\r\nhe\r\n3\r\nllo\r\n0\r\n\r\n"
        .utf8
    )
    for count in 0..<response.count {
      XCTAssertNil(try HTTPResponse.body(response.prefix(count), complete: false))
    }
    XCTAssertEqual(try HTTPResponse.body(response, complete: false), Data("hello".utf8))
  }

  func testTrailersAndConnectionClose() throws {
    let response = Data(
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1\r\na\r\n0\r\nX-End: yes\r\n\r\n".utf8
    )
    XCTAssertEqual(try HTTPResponse.body(response, complete: true), Data("a".utf8))
    let closed = Data("HTTP/1.0 200 OK\r\n\r\nhello".utf8)
    XCTAssertNil(try HTTPResponse.body(closed, complete: false))
    XCTAssertEqual(try HTTPResponse.body(closed, complete: true), Data("hello".utf8))
  }

  func testRedirectTruncatedAndAmbiguousResponsesAreRejected() {
    for text in [
      "HTTP/1.1 302 Found\r\nLocation: http://elsewhere/\r\n\r\n",
      "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\na",
      "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\na",
      "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n",
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n-1\r\n",
    ] {
      XCTAssertThrowsError(try HTTPResponse.body(Data(text.utf8), complete: true))
    }
  }

  func testOversizedResponseIsRejected() {
    XCTAssertThrowsError(
      try HTTPResponse.body(Data(repeating: 65, count: 1_048_577), complete: false))
  }

}
