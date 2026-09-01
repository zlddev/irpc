//
//  ConsoleLogCapture.swift
//  iRPC
//
//  Captures everything written to stdout/stderr (print(), NSLog, and the
//  Discord SDK's own C log callback which prints under the hood) so it can
//  be viewed in-app. This exists because most people running this app don't
//  have a Mac to plug in and watch Xcode's console with.
//

import Foundation
import Combine

public final class ConsoleLogCapture: ObservableObject {
    public static let shared = ConsoleLogCapture()

    public struct LogLine: Identifiable {
        public let id = UUID()
        public let timestamp: Date
        public let text: String
    }

    @Published public private(set) var lines: [LogLine] = []

    /// Cap how many lines we keep around so this can't grow unbounded during
    /// a long session.
    private let maxLines = 2000

    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var originalStdout: Int32 = -1
    private var originalStderr: Int32 = -1
    private var started = false

    private init() {}

    /// Redirects stdout/stderr into this logger. Call once, as early as
    /// possible (e.g. from the App's init), so nothing gets missed.
    public func start() {
        guard !started else { return }
        started = true

        originalStdout = dup(STDOUT_FILENO)
        originalStderr = dup(STDERR_FILENO)
        let mirrorStdout = originalStdout
        let mirrorStderr = originalStderr

        setvbuf(stdout, nil, _IONBF, 0)
        setvbuf(stderr, nil, _IONBF, 0)

        let outPipe = Pipe()
        let errPipe = Pipe()
        stdoutPipe = outPipe
        stderrPipe = errPipe

        dup2(outPipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        dup2(errPipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            ConsoleLogCapture.consume(handle.availableData, mirrorTo: mirrorStdout)
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            ConsoleLogCapture.consume(handle.availableData, mirrorTo: mirrorStderr)
        }
    }

    /// Runs on whatever background queue the pipe's readabilityHandler fires
    /// on — intentionally a plain `static` function (no `self` capture) so
    /// it can't race with anything actor-isolated.
    private static func consume(_ data: Data, mirrorTo originalFD: Int32) {
        guard !data.isEmpty else { return }

        // Still write to the original file descriptor so `print` continues
        // to show up in Xcode's console / `log stream` when one is attached.
        if originalFD >= 0 {
            data.withUnsafeBytes { raw in
                _ = write(originalFD, raw.baseAddress, raw.count)
            }
        }

        guard let text = String(data: data, encoding: .utf8) else { return }
        let newLines = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        guard !newLines.isEmpty else { return }

        DispatchQueue.main.async {
            ConsoleLogCapture.shared.append(newLines)
        }
    }

    private func append(_ newLines: [String]) {
        let now = Date()
        lines.append(contentsOf: newLines.map { LogLine(timestamp: now, text: $0) })
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }

    public func clear() {
        lines.removeAll()
    }

    public var joinedText: String {
        lines.map { "\(Self.timeFormatter.string(from: $0.timestamp)) \($0.text)" }
            .joined(separator: "\n")
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
