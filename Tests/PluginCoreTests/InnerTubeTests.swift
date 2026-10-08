import Testing
import Foundation
@testable import YouTube

/// The plugins' cores tested where only Package.swift builds them — on Linux
/// above all, where Foundation is a different implementation and what passes
/// on a Mac is no evidence. The Mac app's suite has its own, fuller tests of
/// the same code; these are for what differs between platforms.
@Suite struct InnerTubeJSONTests {
    private func parse(_ json: String) -> JSONValue { JSONValue(Data(json.utf8)) }

    /// A one is a count, not a yes. Telling them apart is done differently
    /// on each platform, so it is checked on each.
    @Test func aOneIsANumberAndTrueIsAFlag() {
        let value = parse(#"{"count": 1, "none": 0, "half": 0.5, "on": true, "off": false}"#)
        #expect(value["count"] == .number(1))
        #expect(value["none"] == .number(0))
        #expect(value["half"] == .number(0.5))
        #expect(value["on"] == .bool(true))
        #expect(value["off"] == .bool(false))
    }

    @Test func nestingAndStringsSurvive() {
        let value = parse(#"{"items": [{"title": "a"}, {"title": "b"}], "missing": null}"#)
        #expect(value["items"] == .array([.object(["title": .string("a")]),
                                          .object(["title": .string("b")])]))
        #expect(value["missing"] == .null)
    }
}
