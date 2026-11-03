import XCTest

/// `yggctl`'s argument handling and its HTTP framing. The tool's own source
/// is compiled into this bundle; nothing here talks to a running app.
final class YggctlTests: XCTestCase {
    private let schema: [String: Any] = [
        "properties": [
            "tab": ["type": "integer"],
            "text": ["type": "string"],
            "submit": ["type": "boolean"],
            "args": ["type": "array"],
            "env": ["type": "object"]
        ]
    ]

    func testCommands() throws {
        XCTAssertEqual(try Yggctl.parse(["actions"]), .actions)
        XCTAssertEqual(try Yggctl.parse(["help", "tab.send"]), .help("tab.send"))
        XCTAssertEqual(
            try Yggctl.parse(["tab.send", "tab=3", "text=fix the build", "submit=false"]),
            .run(action: "tab.send", pairs: ["tab": "3", "text": "fix the build", "submit": "false"], json: nil)
        )
        XCTAssertEqual(
            try Yggctl.parse(["tab.open", "--json", "{\"branch\":\"x\"}"]),
            .run(action: "tab.open", pairs: [:], json: "{\"branch\":\"x\"}")
        )
        XCTAssertThrowsError(try Yggctl.parse([]))
        XCTAssertThrowsError(try Yggctl.parse(["tab.send", "notapair"]))
    }

    func testValuesFollowTheActionsSchema() throws {
        let params = try Yggctl.params(
            pairs: ["tab": "3", "text": "42", "submit": "no", "args": "--a,--b"], json: nil, schema: schema
        )
        XCTAssertEqual(params["tab"] as? Int, 3)
        XCTAssertEqual(
            params["text"] as? String,
            "42",
            "a string param stays a string even when it looks like a number"
        )
        XCTAssertEqual(params["submit"] as? Bool, false)
        XCTAssertEqual(params["args"] as? [String], ["--a", "--b"])
        XCTAssertThrowsError(try Yggctl.params(pairs: ["tab": "three"], json: nil, schema: schema))
    }

    func testJSONArgumentsAreUsedAsGivenAndPairsWin() throws {
        let params = try Yggctl.params(pairs: ["tab": "4"], json: "{\"tab\":3,\"env\":{\"A\":\"1\"}}", schema: schema)
        XCTAssertEqual(params["tab"] as? Int, 4)
        XCTAssertEqual(params["env"] as? [String: String], ["A": "1"])
        XCTAssertThrowsError(try Yggctl.params(pairs: [:], json: "[1]", schema: schema))
    }

    func testRequestCarriesTheKeyAndTheBody() throws {
        let body = Data("{}".utf8)
        let request = try XCTUnwrap(String(bytes: Yggctl.httpRequest(body: body, key: "ygg_k"), encoding: .utf8))
        XCTAssertTrue(request.hasPrefix("POST /rpc HTTP/1.1\r\n"))
        XCTAssertTrue(request.contains("\r\nAuthorization: Bearer ygg_k\r\n"))
        XCTAssertTrue(request.contains("\r\nContent-Length: 2\r\n"))
        XCTAssertTrue(request.hasSuffix("\r\n\r\n{}"))
    }

    func testResponseStatusAndBody() throws {
        let raw = Data("HTTP/1.1 403 Forbidden\r\nContent-Length: 2\r\n\r\n{}".utf8)
        let response = try Yggctl.parseResponse(raw)
        XCTAssertEqual(response.status, 403)
        XCTAssertEqual(response.body, Data("{}".utf8))
    }

    func testMCPLinesGoToTheMCPEndpoint() throws {
        XCTAssertEqual(try Yggctl.parse(["mcp"]), .mcp)
        let request = try XCTUnwrap(String(
            bytes: Yggctl.httpRequest(body: Data("{}".utf8), key: "k", path: "/mcp"), encoding: .utf8
        ))
        XCTAssertTrue(request.hasPrefix("POST /mcp HTTP/1.1\r\n"))
        XCTAssertTrue(request.contains("\r\nAccept: application/json, text/event-stream\r\n"))
    }

    func testMCPRepliesAreOneLineEachAndNotificationsGetNone() {
        let request = Data(#"{"jsonrpc":"2.0","id":7,"method":"tools/list"}"#.utf8)
        XCTAssertEqual(
            Yggctl.mcpReply(status: 200, body: Data("{\n\"id\": 7, \"result\": 1}".utf8), request: request),
            #"{"id":7,"result":1}"#
        )
        let unreachable = Yggctl.mcpReply(status: nil, body: Data(), request: request)
        XCTAssertTrue(unreachable?.contains(#""id":7"#) ?? false)
        XCTAssertTrue(unreachable?.contains("isn't running") ?? false)
        let notification = Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
        XCTAssertNil(Yggctl.mcpReply(status: 202, body: Data(), request: notification))
        XCTAssertNil(Yggctl.mcpReply(status: nil, body: Data(), request: notification))
    }

    func testAnAuthErrorIsAnsweredWithTheRequestsID() throws {
        // The app can't know the id of a request it refused unread.
        let request = Data(#"{"jsonrpc":"2.0","id":7,"method":"initialize"}"#.utf8)
        let body = Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32001,"message":"A valid API key is required."}}"#
            .utf8)
        let reply = try XCTUnwrap(Yggctl.mcpReply(status: 401, body: body, request: request))
        XCTAssertTrue(reply.contains(#""id":7"#), reply)
        XCTAssertTrue(reply.contains("A valid API key is required."), reply)
    }

    func testARequestIsAlwaysAnswered() throws {
        let request = Data(#"{"jsonrpc":"2.0","id":7,"method":"tools/list"}"#.utf8)
        for (status, body) in [(200, ""), (200, "data: {}"), (202, ""), (413, "")] {
            let reply = try XCTUnwrap(
                Yggctl.mcpReply(status: status, body: Data(body.utf8), request: request),
                "\(status)"
            )
            XCTAssertTrue(reply.contains(#""id":7"#) && reply.contains(#""error""#), reply)
        }
    }

    func testAMalformedLineGetsAParseError() throws {
        let reply = try XCTUnwrap(Yggctl.mcpReply(status: nil, body: Data(), request: Data("{not json".utf8)))
        XCTAssertTrue(reply.contains("-32700") && reply.contains(#""id":null"#), reply)
    }

    func testAListCanBeGivenAsJSONToKeepItsCommas() throws {
        let schema: [String: Any] = ["properties": ["args": ["type": "array"]]]
        let split = try Yggctl.params(pairs: ["args": "a,b"], json: nil, schema: schema)
        XCTAssertEqual(split["args"] as? [String], ["a", "b"])
        let kept = try Yggctl.params(pairs: ["args": #"["--allowedTools=Bash,Read"]"#], json: nil, schema: schema)
        XCTAssertEqual(kept["args"] as? [String], ["--allowedTools=Bash,Read"])
        XCTAssertThrowsError(try Yggctl.params(pairs: ["args": "[1]"], json: nil, schema: schema))
    }

    func testEmptyListsPrintOnOneLine() {
        XCTAssertEqual(Yggctl.render([Any]()), "[]")
        let output = Yggctl.render(["args": [Any](), "env": [String: Any](), "text": "[  ]"])
        XCTAssertTrue(output.contains(#""args" : []"#), output)
        XCTAssertTrue(output.contains(#""env" : {}"#), output)
        XCTAssertTrue(output.contains(#""text" : "[  ]""#), output)
    }

    func testExitCodes() {
        XCTAssertEqual(Yggctl.exitCode(status: 200, hasError: false), 0)
        XCTAssertEqual(Yggctl.exitCode(status: 200, hasError: true), 1)
        XCTAssertEqual(Yggctl.exitCode(status: 401, hasError: true), 4)
        XCTAssertEqual(Yggctl.exitCode(status: 403, hasError: true), 4)
    }
}
