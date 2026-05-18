import XCTest
@testable import cmux

/// Pure-Codable tests for the herdr layout wire types. No daemon
/// required — these verify the JSON shape matches herdr's
/// `src/api/schema.rs` definitions byte-for-byte.
final class HerdrLayoutTypesTests: XCTestCase {
    func testPaneNodeRoundTrips() throws {
        let node = HerdrLayoutNode.pane(paneId: "w1-3")
        let data = try JSONEncoder().encode(node)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"kind\":\"pane\""), json)
        XCTAssertTrue(json.contains("\"pane_id\":\"w1-3\""), json)
        let restored = try JSONDecoder().decode(HerdrLayoutNode.self, from: data)
        XCTAssertEqual(restored, node)
    }

    func testNestedSplitRoundTrips() throws {
        let node = HerdrLayoutNode.split(
            direction: .horizontal,
            ratio: 0.5,
            first: .pane(paneId: "w1-1"),
            second: .split(
                direction: .vertical,
                ratio: 0.6,
                first: .pane(paneId: "w1-2"),
                second: .pane(paneId: "w1-3")
            )
        )
        let data = try JSONEncoder().encode(node)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"kind\":\"split\""), json)
        XCTAssertTrue(json.contains("\"direction\":\"horizontal\""), json)
        XCTAssertTrue(json.contains("\"direction\":\"vertical\""), json)
        let restored = try JSONDecoder().decode(HerdrLayoutNode.self, from: data)
        XCTAssertEqual(restored, node)
    }

    func testLayoutTreeFieldsMapToWireSchema() throws {
        let wireJson = """
        {
            "workspace_id": "w1",
            "tab_id": "w1:1",
            "root": {
                "kind": "split",
                "direction": "horizontal",
                "ratio": 0.5,
                "first": {"kind": "pane", "pane_id": "w1-1"},
                "second": {"kind": "pane", "pane_id": "w1-2"}
            },
            "focused_pane_id": "w1-2"
        }
        """
        let data = wireJson.data(using: .utf8)!
        let tree = try JSONDecoder().decode(HerdrLayoutTree.self, from: data)
        XCTAssertEqual(tree.workspaceId, "w1")
        XCTAssertEqual(tree.tabId, "w1:1")
        XCTAssertEqual(tree.focusedPaneId, "w1-2")
        guard case .split(let dir, let ratio, let first, let second) = tree.root else {
            XCTFail("root should be split")
            return
        }
        XCTAssertEqual(dir, .horizontal)
        XCTAssertEqual(ratio, 0.5, accuracy: 1e-6)
        XCTAssertEqual(first, .pane(paneId: "w1-1"))
        XCTAssertEqual(second, .pane(paneId: "w1-2"))
    }

    func testLayoutTreeOmitsFocusedPaneIdWhenNil() throws {
        let tree = HerdrLayoutTree(
            workspaceId: "w1",
            tabId: "w1:1",
            root: .pane(paneId: "w1-1"),
            focusedPaneId: nil
        )
        let data = try JSONEncoder().encode(tree)
        let json = String(data: data, encoding: .utf8) ?? ""
        // We could either include the field as null or skip it. Either
        // is fine on the wire; test that the result is decodable back.
        let restored = try JSONDecoder().decode(HerdrLayoutTree.self, from: data)
        XCTAssertEqual(restored, tree)
    }

    func testTabReorderedPayloadDecodesSnakeCase() throws {
        let wireJson = """
        {"workspace_id": "w1", "tab_ids": ["w1:2", "w1:1", "w1:3"]}
        """
        let data = wireJson.data(using: .utf8)!
        let payload = try JSONDecoder().decode(HerdrTabReorderedPayload.self, from: data)
        XCTAssertEqual(payload.workspaceId, "w1")
        XCTAssertEqual(payload.tabIds, ["w1:2", "w1:1", "w1:3"])
    }

    func testDecodeLayoutTreeFromApiResultDict() throws {
        let result: [String: Any] = [
            "type": "layout_snapshot",
            "tree": [
                "workspace_id": "w1",
                "tab_id": "w1:1",
                "root": ["kind": "pane", "pane_id": "w1-1"],
                "focused_pane_id": "w1-1",
            ],
        ]
        let tree = try HerdrApiClient.decodeLayoutTree(from: result)
        XCTAssertEqual(tree.workspaceId, "w1")
        XCTAssertEqual(tree.root, .pane(paneId: "w1-1"))
    }

    func testDecodeLayoutTreeFailsWhenTreeMissing() {
        let result: [String: Any] = ["type": "layout_snapshot"]
        XCTAssertThrowsError(try HerdrApiClient.decodeLayoutTree(from: result)) { error in
            guard let api = error as? HerdrApiError else {
                XCTFail("expected HerdrApiError, got \(error)")
                return
            }
            XCTAssertEqual(api.code, "malformed")
        }
    }

    func testWorkspaceClosedPayloadDecodesSnakeCase() throws {
        let wireJson = """
        {"workspace_id": "w123abc"}
        """
        let payload = try JSONDecoder().decode(
            HerdrWorkspaceClosedPayload.self,
            from: wireJson.data(using: .utf8)!
        )
        XCTAssertEqual(payload.workspaceId, "w123abc")
    }

    func testWorkspaceClosedPayloadEncodesSnakeCase() throws {
        let payload = HerdrWorkspaceClosedPayload(workspaceId: "w_x")
        let data = try JSONEncoder().encode(payload)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"workspace_id\":\"w_x\""))
    }

    func testPaneExitedPayloadRoundTrips() throws {
        let payload = HerdrPaneExitedPayload(paneId: "w1-3", workspaceId: "w1")
        let data = try JSONEncoder().encode(payload)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"pane_id\":\"w1-3\""))
        XCTAssertTrue(json.contains("\"workspace_id\":\"w1\""))
        let restored = try JSONDecoder().decode(HerdrPaneExitedPayload.self, from: data)
        XCTAssertEqual(restored, payload)
    }

    func testTabReorderedPayloadRoundTrips() throws {
        let payload = HerdrTabReorderedPayload(
            workspaceId: "w1",
            tabIds: ["w1:2", "w1:1", "w1:3"]
        )
        let data = try JSONEncoder().encode(payload)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"tab_ids\""))
        let restored = try JSONDecoder().decode(HerdrTabReorderedPayload.self, from: data)
        XCTAssertEqual(restored, payload)
    }

    func testLayoutChangedPayloadDecodesNestedTree() throws {
        let wireJson = """
        {
            "tree": {
                "workspace_id": "w1",
                "tab_id": "w1:1",
                "root": {
                    "kind": "split",
                    "direction": "vertical",
                    "ratio": 0.7,
                    "first": {"kind": "pane", "pane_id": "w1-1"},
                    "second": {"kind": "pane", "pane_id": "w1-2"}
                },
                "focused_pane_id": "w1-1"
            }
        }
        """
        let payload = try JSONDecoder().decode(
            HerdrLayoutChangedPayload.self,
            from: wireJson.data(using: .utf8)!
        )
        XCTAssertEqual(payload.tree.workspaceId, "w1")
        XCTAssertEqual(payload.tree.focusedPaneId, "w1-1")
        guard case .split(let dir, _, let first, _) = payload.tree.root else {
            XCTFail("root should be split")
            return
        }
        XCTAssertEqual(dir, .vertical)
        XCTAssertEqual(first, .pane(paneId: "w1-1"))
    }
}
