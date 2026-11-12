import Foundation
import Cocoa
import AVFoundation
import Security
import ApplicationServices
import ServiceManagement

// MARK: - Minimal XCTest Compatibility Shim for Standalone Testing on CLI Tools

public final class XCTestExpectation {
    public let description: String
    private let lock = NSLock()
    private var _isFulfilled = false

    public var isFulfilled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isFulfilled
    }

    public init(description: String) {
        self.description = description
    }

    public func fulfill() {
        lock.lock()
        defer { lock.unlock() }
        _isFulfilled = true
    }
}

public var currentTestFailures: [String] = []

public func XCTAssertTrue(_ expression: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) {
    do {
        if !(try expression()) {
            let msg = message()
            let detail = msg.isEmpty ? "XCTAssertTrue failed" : msg
            currentTestFailures.append("\(file):\(line): \(detail)")
        }
    } catch {
        currentTestFailures.append("\(file):\(line): Exception thrown: \(error)")
    }
}

public func XCTAssertFalse(_ expression: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) {
    do {
        if try expression() {
            let msg = message()
            let detail = msg.isEmpty ? "XCTAssertFalse failed" : msg
            currentTestFailures.append("\(file):\(line): \(detail)")
        }
    } catch {
        currentTestFailures.append("\(file):\(line): Exception thrown: \(error)")
    }
}

public func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) {
    do {
        let valA = try a()
        let valB = try b()
        if valA != valB {
            let msg = message()
            let detail = msg.isEmpty ? "XCTAssertEqual failed: ('\(valA)') is not equal to ('\(valB)')" : "\(msg) (got '\(valA)', expected '\(valB)')"
            currentTestFailures.append("\(file):\(line): \(detail)")
        }
    } catch {
        currentTestFailures.append("\(file):\(line): Exception thrown: \(error)")
    }
}

public func XCTAssertNotEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) {
    do {
        let valA = try a()
        let valB = try b()
        if valA == valB {
            let msg = message()
            let detail = msg.isEmpty ? "XCTAssertNotEqual failed: ('\(valA)') is equal to ('\(valB)')" : msg
            currentTestFailures.append("\(file):\(line): \(detail)")
        }
    } catch {
        currentTestFailures.append("\(file):\(line): Exception thrown: \(error)")
    }
}

public func XCTAssertGreaterThan<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) {
    do {
        let valA = try a()
        let valB = try b()
        if !(valA > valB) {
            let msg = message()
            let detail = msg.isEmpty ? "XCTAssertGreaterThan failed: ('\(valA)') is not greater than ('\(valB)')" : msg
            currentTestFailures.append("\(file):\(line): \(detail)")
        }
    } catch {
        currentTestFailures.append("\(file):\(line): Exception thrown: \(error)")
    }
}

public func XCTAssertNil(_ a: @autoclosure () throws -> Any?, _ message: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) {
    do {
        if try a() != nil {
            let msg = message()
            let detail = msg.isEmpty ? "XCTAssertNil failed" : msg
            currentTestFailures.append("\(file):\(line): \(detail)")
        }
    } catch {
        currentTestFailures.append("\(file):\(line): Exception thrown: \(error)")
    }
}

public func XCTAssertNotNil(_ a: @autoclosure () throws -> Any?, _ message: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) {
    do {
        if try a() == nil {
            let msg = message()
            let detail = msg.isEmpty ? "XCTAssertNotNil failed" : msg
            currentTestFailures.append("\(file):\(line): \(detail)")
        }
    } catch {
        currentTestFailures.append("\(file):\(line): Exception thrown: \(error)")
    }
}

public func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line, _ errorHandler: (_ error: Error) -> Void = { _ in }) {
    do {
        _ = try expression()
        let msg = message()
        let detail = msg.isEmpty ? "XCTAssertThrowsError failed: did not throw an error" : msg
        currentTestFailures.append("\(file):\(line): \(detail)")
    } catch {
        errorHandler(error)
    }
}

public func XCTFail(_ message: String = "", file: StaticString = #file, line: UInt = #line) {
    let detail = message.isEmpty ? "XCTFail" : message
    currentTestFailures.append("\(file):\(line): \(detail)")
}

open class XCTestCase {
    public init() {}
    open func setUpWithError() throws {}
    open func tearDownWithError() throws {}

    public func expectation(description: String) -> XCTestExpectation {
        return XCTestExpectation(description: description)
    }

    public func wait(for expectations: [XCTestExpectation], timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            if expectations.allSatisfy({ $0.isFulfilled }) {
                return
            }
        }
        for exp in expectations where !exp.isFulfilled {
            currentTestFailures.append("Expectation '\(exp.description)' timed out after \(timeout)s")
        }
    }
}
