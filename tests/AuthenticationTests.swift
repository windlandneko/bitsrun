import Foundation
import XCTest

@testable import Bitsrun

@MainActor
final class AuthenticationTests: XCTestCase {
  private let address = "10.1.2.3"

  func testMatchesUpstreamWithUnicodeAndEscapes() throws {
    struct Golden: Decodable {
      struct Parameters: Decodable {
        let password: String
        let info: String
        let chksum: String
      }
      let username: String
      let password: String
      let token: String
      let params: Parameters
    }
    let url = try XCTUnwrap(Bundle.module.url(forResource: "authentication", withExtension: "json"))
    let fixtures = try JSONDecoder().decode([Golden].self, from: Data(contentsOf: url))
    for fixture in fixtures {
      let actual = Srun.parameters(
        credentials: Credentials(
          username: fixture.username, password: fixture.password, interface: nil),
        address: address, challenge: fixture.token
      )
      XCTAssertEqual(actual["password"], fixture.params.password)
      XCTAssertEqual(actual["info"], fixture.params.info)
      XCTAssertEqual(actual["chksum"], fixture.params.chksum)
      XCTAssertEqual(actual["ac_id"], "43")
    }
  }

}
