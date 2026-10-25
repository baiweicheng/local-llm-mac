import Foundation
import XCTest
@testable import LocalLLM

final class MLXToolSupportTests: XCTestCase {
    func testNoDescriptorsMeansNoToolSpecs() {
        XCTAssertNil(MLXToolSupport.specs(for: []))
    }

    func testSpecsEncodeTheFunctionSchemaExpectedByMLX() throws {
        let descriptor = ToolDescriptor(
            name: "example", displayName: "Example",
            modelDescription: "An example tool.", source: nil,
            argumentFields: [.query, .limit, .append], symbolName: "gear")
        let specs = try XCTUnwrap(MLXToolSupport.specs(for: [descriptor]))
        let data = try JSONSerialization.data(withJSONObject: specs)
        let objects = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(objects.count, 1)
        XCTAssertEqual(objects.first?["type"] as? String, "function")
        let function = try XCTUnwrap(objects.first?["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, descriptor.name)
        XCTAssertEqual(function["description"] as? String, descriptor.modelDescription)
        let parameters = try XCTUnwrap(function["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["type"] as? String, "object")
        XCTAssertEqual(parameters["required"] as? [String], [])
        let properties = try XCTUnwrap(parameters["properties"] as? [String: [String: String]])
        XCTAssertEqual(Set(properties.keys), ["query", "limit", "append"])
        XCTAssertEqual(properties["query"]?["type"], "string")
        XCTAssertEqual(properties["limit"]?["type"], "integer")
        XCTAssertEqual(properties["append"]?["type"], "boolean")
        XCTAssertEqual(properties["query"]?["description"], ToolArgumentField.query.fieldDescription)
    }

    func testTypedJSONArgumentsKeepScalarsAndIgnoreStructuredValues() {
        let arguments = MLXToolSupport.arguments(from: .init(function: .init(
            name: "example", arguments: [
                "query": .string("hello"),
                "days": .int(7),
                "limit": .double(2.0),
                "index": .int(1),
                "append": .bool(true),
                "text": .bool(false),
                "path": .null,
                "destination": .array([.string("ignored")]),
                "newName": .object(["nested": .string("ignored")])
            ])))
        XCTAssertEqual(arguments, ToolArguments(
            query: "hello", text: "false", days: 7, limit: 2, index: 1, append: true))
    }
}
