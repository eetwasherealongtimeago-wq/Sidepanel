import XCTest
@testable import SidePanelCore

final class PTYProcessTests: XCTestCase {
    func testRunsCommandThroughPTYAndReportsExit() throws {
        let queue = DispatchQueue(label: "test.pty")
        let process = try PTYProcess(executable: "/bin/sh",
                                     arguments: ["sh", "-c", "stty size; printf 'tty:'; tty >/dev/null && echo yes; exit 7"],
                                     environment: PTYProcess.shellEnvironment(),
                                     workingDirectory: "/",
                                     columns: 101, rows: 37,
                                     callbackQueue: queue)
        var output = Data()
        let exited = expectation(description: "exit")
        var code: Int32 = -1
        process.onOutput = { output.append($0) }
        process.onExit = { code = $0; exited.fulfill() }
        process.start()
        wait(for: [exited], timeout: 10)
        let text = queue.sync { String(decoding: output, as: UTF8.self) }
        XCTAssertTrue(text.contains("37 101"), text)
        XCTAssertTrue(text.contains("tty:yes"), text)
        XCTAssertEqual(code, 7)
    }

    func testInteractiveInputAndResize() throws {
        let queue = DispatchQueue(label: "test.pty2")
        let process = try PTYProcess(executable: "/bin/sh", arguments: ["sh"],
                                     environment: ["PATH": "/usr/bin:/bin", "PS1": "$ ", "TERM": "xterm-256color"],
                                     workingDirectory: nil, columns: 80, rows: 24, callbackQueue: queue)
        var output = Data()
        var fulfilled = false
        let gotSize = expectation(description: "size")
        process.onOutput = { data in
            output.append(data)
            if !fulfilled && String(decoding: output, as: UTF8.self).contains("50 132") {
                fulfilled = true
                gotSize.fulfill()
            }
        }
        let exited = expectation(description: "exit")
        process.onExit = { _ in exited.fulfill() }
        process.start()
        process.resize(columns: 132, rows: 50)
        process.write("stty size\n")
        wait(for: [gotSize], timeout: 10)
        process.write("exit\n")
        wait(for: [exited], timeout: 10)
        XCTAssertFalse(process.isRunning)
    }

    func testFeedingEmulatorFromShell() throws {
        let queue = DispatchQueue(label: "test.pty3")
        let emulator = TerminalEmulator(columns: 40, rows: 10)
        let process = try PTYProcess(executable: "/bin/sh",
                                     arguments: ["sh", "-c", "printf '\\033[1;32mgreen\\033[0m plain'"],
                                     environment: ["PATH": "/usr/bin:/bin"],
                                     workingDirectory: nil, columns: 40, rows: 10, callbackQueue: queue)
        let exited = expectation(description: "exit")
        process.onOutput = { emulator.feed($0) }
        process.onExit = { _ in exited.fulfill() }
        process.start()
        wait(for: [exited], timeout: 10)
        queue.sync {
            XCTAssertEqual(emulator.screen[0].text, "green plain")
            XCTAssertEqual(emulator.screen[0].cells[0].attributes.foreground, .indexed(2))
        }
    }

    func testReportsWorkingDirectoryAndForegroundProcess() throws {
        let queue = DispatchQueue(label: "test.pty4")
        let process = try PTYProcess(executable: "/bin/sh", arguments: ["sh", "-c", "sleep 2"],
                                     environment: ["PATH": "/usr/bin:/bin"],
                                     workingDirectory: "/tmp", columns: 80, rows: 24, callbackQueue: queue)
        process.start()
        Thread.sleep(forTimeInterval: 0.3)
        let cwd = try XCTUnwrap(process.currentDirectory)
        XCTAssertTrue(cwd == "/tmp" || cwd == "/private/tmp", cwd)
        XCTAssertNotNil(process.foregroundProcessName)
        process.terminate()
        XCTAssertFalse(process.isRunning)
    }

    func testDefaultShellExists() {
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: PTYProcess.defaultShell()))
        let env = PTYProcess.shellEnvironment(base: [:])
        XCTAssertEqual(env["TERM"], "xterm-256color")
        XCTAssertEqual(env["LANG"], "en_US.UTF-8")
    }
}
