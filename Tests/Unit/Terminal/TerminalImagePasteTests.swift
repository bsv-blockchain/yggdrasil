import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import Yggdrasil

/// Covers the image-aware paste logic: prefer an existing image file's path,
/// materialize a temp PNG only for raw image data, and ignore non-image
/// clipboards (so normal text paste still happens).
@MainActor
final class TerminalImagePasteTests: XCTestCase {
    private func scratchPasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ygg-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    private func tinyRep() throws -> NSBitmapImageRep {
        try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
    }

    private func tinyPNGData() throws -> Data {
        try XCTUnwrap(tinyRep().representation(using: .png, properties: [:]))
    }

    private func unquote(_ value: String) -> String {
        guard value.hasPrefix("'"), value.hasSuffix("'") else { return value }
        return String(value.dropFirst().dropLast())
    }

    // MARK: - isImageFile

    func testIsImageFileByExtension() throws {
        XCTAssertTrue(DroppableTerminalView.isImageFile(URL(fileURLWithPath: "/tmp/a.png")))
        XCTAssertTrue(DroppableTerminalView.isImageFile(URL(fileURLWithPath: "/tmp/a.jpg")))
        XCTAssertTrue(DroppableTerminalView.isImageFile(URL(fileURLWithPath: "/tmp/a.gif")))
        XCTAssertFalse(DroppableTerminalView.isImageFile(URL(fileURLWithPath: "/tmp/a.txt")))
        XCTAssertFalse(DroppableTerminalView.isImageFile(URL(fileURLWithPath: "/tmp/a.swift")))
        let remote = try XCTUnwrap(URL(string: "https://example.com/a.png"))
        XCTAssertFalse(DroppableTerminalView.isImageFile(remote))
    }

    // MARK: - imagePastePayload

    func testTextOnlyClipboardReturnsNil() {
        let pasteboard = scratchPasteboard()
        pasteboard.setString("just text", forType: .string)
        XCTAssertNil(DroppableTerminalView.imagePastePayload(from: pasteboard))
    }

    func testExistingImageFileLinksItsPath() throws {
        // A real on-disk .png referenced by the clipboard → its own path, no temp copy.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ygg-img-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("shot.png")
        try tinyPNGData().write(to: file)

        let pasteboard = scratchPasteboard()
        pasteboard.writeObjects([file as NSURL])

        let payload = try XCTUnwrap(DroppableTerminalView.imagePastePayload(from: pasteboard))
        XCTAssertEqual(unquote(payload), file.path)
    }

    func testRawImageDataWritesTempPng() throws {
        let pasteboard = scratchPasteboard()
        try pasteboard.setData(tinyPNGData(), forType: .png)

        let payload = try XCTUnwrap(DroppableTerminalView.imagePastePayload(from: pasteboard))
        let path = unquote(payload)
        XCTAssertTrue(path.hasSuffix(".png"), "expected a .png temp path, got \(path)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "temp image should exist on disk")
        let written = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertNotNil(NSBitmapImageRep(data: written))
    }

    func testTiffDataIsTranscodedToPng() throws {
        let pasteboard = scratchPasteboard()
        let tiff = try XCTUnwrap(tinyRep().representation(using: .tiff, properties: [:]))
        pasteboard.setData(tiff, forType: .tiff)
        XCTAssertNotNil(DroppableTerminalView.pngData(from: pasteboard))
    }
}
