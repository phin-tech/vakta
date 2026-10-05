//
//  KataDaemonHTTPTests.swift
//  KataVaktaCoreTests

import XCTest
@testable import KataVaktaCore

final class KataDaemonHTTPTests: XCTestCase {
    func test_address_unixSocket_orOther() {
        let unix = #"{"kata_api_version":1,"source":"local_default","kind":"local","network":"unix","scheme":"http","address":"unix:///var/folders/T/kata-501/c0/daemon.sock"}"#
        XCTAssertEqual(KataDaemonAddress.parse(Data(unix.utf8)), .unix(path: "/var/folders/T/kata-501/c0/daemon.sock"))
        let tcp = #"{"kata_api_version":1,"kind":"remote","network":"tcp","scheme":"https","address":"https://daemon.example","request_base_url":"https://daemon.example"}"#
        XCTAssertEqual(KataDaemonAddress.parse(Data(tcp.utf8)), .other)
        XCTAssertNil(KataDaemonAddress.parse(Data("nope".utf8)))
    }

    func test_request_isHTTP11_withBearerAndClose() {
        let text = String(decoding: KataHTTP.request(method: "GET", path: "/api/v1/projects/5/ready?limit=0", token: "t0k"), as: UTF8.self)
        XCTAssertEqual(text, "GET /api/v1/projects/5/ready?limit=0 HTTP/1.1\r\nHost: kata\r\nAuthorization: Bearer t0k\r\nAccept: application/json\r\nConnection: close\r\n\r\n")
    }

    func test_request_withBody_setsTypeAndLength_andOmitsAMissingToken() {
        let body = Data(#"{"start_path":"/r"}"#.utf8)
        let text = String(decoding: KataHTTP.request(method: "POST", path: "/api/v1/projects/resolve", token: nil, body: body), as: UTF8.self)
        XCTAssertEqual(text, "POST /api/v1/projects/resolve HTTP/1.1\r\nHost: kata\r\nAccept: application/json\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: 19\r\n\r\n{\"start_path\":\"/r\"}")
    }

    func test_parse_contentLengthBody() {
        let raw = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}"
        XCTAssertEqual(KataHTTP.parse(Data(raw.utf8)), KataHTTPResponse(status: 200, body: Data("{}".utf8)))
    }

    func test_parse_chunkedBody_withExtensionsAndTrailers() {
        let raw = "HTTP/1.1 404 Not Found\r\nTransfer-Encoding: chunked\r\n\r\n4;ext=1\r\n{\"a\"\r\n5\r\n:1}  \r\n0\r\nX-Trailer: y\r\n\r\n"
        XCTAssertEqual(KataHTTP.parse(Data(raw.utf8)), KataHTTPResponse(status: 404, body: Data("{\"a\":1}  ".utf8)))
    }

    func test_parse_rejectsMalformed() {
        XCTAssertNil(KataHTTP.parse(Data("garbage".utf8)))
        XCTAssertNil(KataHTTP.parse(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n".utf8)))
        XCTAssertNil(KataHTTP.parse(Data("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n{}".utf8)), "a truncated body isn't a response")
    }

    func test_resolved() {
        XCTAssertEqual(
            KataHTTP.resolved(KataHTTPResponse(status: 200, body: Data(#"{"project":{"id":5,"name":"vakta"},"alias":{},"workspace_root":"/r"}"#.utf8))),
            .project(id: 5)
        )
        XCTAssertEqual(
            KataHTTP.resolved(KataHTTPResponse(status: 404, body: Data(#"{"status":404,"error":{"code":"project_not_initialized","message":"no .kata.toml ancestor"}}"#.utf8))),
            .notInitialized
        )
        XCTAssertEqual(
            KataHTTP.resolved(KataHTTPResponse(status: 401, body: Data(#"{"error":{"code":"auth_required","message":"Authorization bearer required"}}"#.utf8))),
            .failed("Authorization bearer required")
        )
        XCTAssertEqual(KataHTTP.resolved(KataHTTPResponse(status: 500, body: Data())), .failed("The Kata daemon answered 500."))
    }

    func test_resolveBody() throws {
        let object = try JSONSerialization.jsonObject(with: KataHTTP.resolveBody(startPath: "/r \"q\"")) as? [String: String]
        XCTAssertEqual(object, ["start_path": "/r \"q\""])
    }
}
