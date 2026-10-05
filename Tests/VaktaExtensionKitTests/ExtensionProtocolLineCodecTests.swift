//
//  ExtensionProtocolLineCodecTests.swift
//  VaktaExtensionKitTests
//
//  The JSON-RPC 2.0 envelope and newline framing: every message is exactly
//  one line on stdio, so an Extension in any language can read it with a
//  line reader.

import XCTest
import VaktaExtensionKit

final class ExtensionProtocolLineCodecTests: XCTestCase {
    func test_encodeLine_isOneLineEndingInNewline_evenWhenStringsContainNewlines() throws {
        let message = JSONRPCMessage.notification(
            method: ProtocolMethod.log,
            params: .object(["level": .string("info"), "message": .string("first\nsecond\r\nthird")])
        )

        let line = try ExtensionProtocolCodec.encodeLine(message)

        XCTAssertTrue(line.hasSuffix("\n"))
        XCTAssertFalse(line.dropLast().contains(where: \.isNewline), line)
        XCTAssertEqual(try ExtensionProtocolCodec.decodeLine(line), message)
    }

    func test_encodeLine_alwaysDeclaresJSONRPC2() throws {
        let line = try ExtensionProtocolCodec.encodeLine(.request(id: .number(1), method: "shutdown", params: nil))

        assertSameJSON(line, #"{"jsonrpc":"2.0","id":1,"method":"shutdown"}"#)
    }

    func test_decodeLine_requestWithNumberID() throws {
        XCTAssertEqual(
            try ExtensionProtocolCodec.decodeLine(#"{"jsonrpc":"2.0","id":4,"method":"view/render","params":{"view":"issues"}}"#),
            .request(id: .number(4), method: "view/render", params: .object(["view": .string("issues")]))
        )
    }

    func test_decodeLine_requestWithStringID_andTrailingNewline() throws {
        XCTAssertEqual(
            try ExtensionProtocolCodec.decodeLine(#"{"jsonrpc":"2.0","id":"r-1","method":"shutdown"}"# + "\n"),
            .request(id: .string("r-1"), method: "shutdown", params: nil)
        )
    }

    func test_decodeLine_notificationWithoutParams() throws {
        XCTAssertEqual(
            try ExtensionProtocolCodec.decodeLine(#"{"jsonrpc":"2.0","method":"status/clear"}"#),
            .notification(method: "status/clear", params: nil)
        )
    }

    func test_decodeLine_responseWithNullResult_isAResponseNotAnError() throws {
        XCTAssertEqual(
            try ExtensionProtocolCodec.decodeLine(#"{"jsonrpc":"2.0","id":99,"result":null}"#),
            .response(id: .number(99), result: .null)
        )
    }

    func test_decodeLine_errorResponse_withAndWithoutID() throws {
        XCTAssertEqual(
            try ExtensionProtocolCodec.decodeLine(#"{"jsonrpc":"2.0","id":3,"error":{"code":-32601,"message":"no such method"}}"#),
            .errorResponse(id: .number(3), error: JSONRPCError(code: -32601, message: "no such method"))
        )
        XCTAssertEqual(
            try ExtensionProtocolCodec.decodeLine(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"parse error"}}"#),
            .errorResponse(id: nil, error: JSONRPCError(code: -32700, message: "parse error"))
        )
    }

    func test_decodeLine_ignoresUnknownEnvelopeFields() throws {
        XCTAssertEqual(
            try ExtensionProtocolCodec.decodeLine(#"{"jsonrpc":"2.0","method":"status/clear","trace":"abc"}"#),
            .notification(method: "status/clear", params: nil)
        )
    }

    func test_decodeLine_textThatIsNotAJSONObject_isMalformedLine() {
        for line in ["", "not json", "[1,2]", #""a string""#, "{\"jsonrpc\":"] {
            XCTAssertThrowsError(try ExtensionProtocolCodec.decodeLine(line), line) { error in
                XCTAssertEqual(error as? ExtensionProtocolError, .malformedLine, line)
            }
        }
    }

    func test_decodeLine_objectThatIsNotJSONRPC2_isNotJSONRPC() {
        let lines = [
            #"{"id":1,"method":"shutdown"}"#,                    // no jsonrpc
            #"{"jsonrpc":"1.0","id":1,"method":"shutdown"}"#,   // wrong version
            #"{"jsonrpc":"2.0","id":1}"#,                        // neither method, result nor error
            #"{"jsonrpc":"2.0","id":true,"method":"shutdown"}"#, // id is neither number nor string
        ]
        for line in lines {
            XCTAssertThrowsError(try ExtensionProtocolCodec.decodeLine(line), line) { error in
                XCTAssertEqual(error as? ExtensionProtocolError, .notJSONRPC, line)
            }
        }
    }
}
