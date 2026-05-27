@testable import Yggdrasil
import XCTest

final class OutputRingBufferTests: XCTestCase {

    func testEmptyAfterInit() {
        let ring = OutputRingBuffer(capacity: 16)
        XCTAssertEqual(ring.count, 0)
        XCTAssertEqual(ring.contents(), Data())
    }

    func testRetainsAppendsSmallerThanCapacity() {
        var ring = OutputRingBuffer(capacity: 16)
        ring.append(Data("hello".utf8))
        XCTAssertEqual(ring.count, 5)
        XCTAssertEqual(ring.contents(), Data("hello".utf8))
    }

    func testRetainsLastNBytesWhenSingleAppendOverflows() {
        var ring = OutputRingBuffer(capacity: 4)
        ring.append(Data("0123456789".utf8))
        XCTAssertEqual(ring.count, 4)
        XCTAssertEqual(ring.contents(), Data("6789".utf8))
    }

    func testRetainsLastNBytesAcrossMultipleAppendsThatOverflow() {
        var ring = OutputRingBuffer(capacity: 4)
        ring.append(Data("abc".utf8))   // ring: abc
        ring.append(Data("def".utf8))   // ring: cdef (last 4 of "abcdef")
        ring.append(Data("g".utf8))     // ring: defg
        XCTAssertEqual(ring.contents(), Data("defg".utf8))
    }

    func testSingleByteAppendsRotateCorrectly() {
        var ring = OutputRingBuffer(capacity: 3)
        for byte in Data("ABCDE".utf8) {
            ring.append(Data([byte]))
        }
        XCTAssertEqual(ring.contents(), Data("CDE".utf8))
    }

    func testCapacityOfZeroIsInert() {
        var ring = OutputRingBuffer(capacity: 0)
        ring.append(Data("anything".utf8))
        XCTAssertEqual(ring.count, 0)
        XCTAssertEqual(ring.contents(), Data())
    }

    func testHandlesEmptyAppend() {
        var ring = OutputRingBuffer(capacity: 4)
        ring.append(Data("ab".utf8))
        ring.append(Data())
        XCTAssertEqual(ring.contents(), Data("ab".utf8))
    }

    func testFourKBDefaultMatchesSpec() {
        // Spec calls for last 4KB.
        let ring = OutputRingBuffer.makeAgentOutputRing()
        XCTAssertEqual(ring.capacity, 4096)
    }
}
