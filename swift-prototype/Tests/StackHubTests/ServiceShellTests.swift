import Foundation
import XCTest
@testable import StackHub

final class ServiceShellTests: XCTestCase {
    func testStartupFilesConfigureTheServiceEnvironmentBeforeExec() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StackHub-shell-\(UUID())")
        let directory = root.appendingPathComponent("项目 with spaces")
        let bin = directory.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "export STACKHUB_TEST_STARTUP=env\n".write(to: root.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
        try "export STACKHUB_TEST_STARTUP=\"$STACKHUB_TEST_STARTUP,profile\"\n".write(to: root.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)
        try """
        [[ -o interactive ]] || return
        export STACKHUB_TEST_STARTUP="$STACKHUB_TEST_STARTUP,rc"
        export JAVA_HOME="$PWD/jdk-from-zshrc"
        export PATH="$PWD/bin:$PATH"
        """.write(to: root.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        try "export STACKHUB_TEST_STARTUP=\"$STACKHUB_TEST_STARTUP,login\"\n".write(to: root.appendingPathComponent(".zlogin"), atomically: true, encoding: .utf8)
        let tool = bin.appendingPathComponent("stackhub-test-tool")
        try """
        #!/bin/sh
        printf '%s\\n' "$STACKHUB_TEST_STARTUP" "$JAVA_HOME" "$PWD" "$$"
        """.write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        let process = ServiceShell.makeProcess(command: "stackhub-test-tool", directory: directory)
        let result = try run(process, startupDirectory: root)
        XCTAssertEqual(process.terminationStatus, 0, result)
        let lines = result.split(separator: "\n").map(String.init)
        // zsh exposes macOS's physical /private/var path in PWD.
        let expectedDirectory = directory.path.replacingOccurrences(of: "/var/folders", with: "/private/var/folders")
        XCTAssertEqual(lines, ["env,profile,rc,login", expectedDirectory + "/jdk-from-zshrc",
                               expectedDirectory, String(process.processIdentifier)])
    }

    func testMissingZshrcAndExplicitCommandEnvironmentStillWork() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StackHub-shell-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "export JAVA_HOME=profile-jdk\n".write(to: root.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)
        let process = ServiceShell.makeProcess(command: "env JAVA_HOME=command-jdk /bin/sh -c 'printf %s \"$JAVA_HOME\"; exit 7'", directory: root)
        XCTAssertEqual(try run(process, startupDirectory: root), "command-jdk")
        XCTAssertEqual(process.terminationStatus, 7)
    }

    func testLoginStartupRestoresToolPriorityInsteadOfInheritingLauncherPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StackHub-path-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let preferred = root.appendingPathComponent("preferred")
        let stale = root.appendingPathComponent("stale")
        for (directory, value) in [(preferred, "preferred"), (stale, "stale")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let tool = directory.appendingPathComponent("stackhub-path-tool")
            try "#!/bin/sh\nprintf '%s' \(value)\n".write(to: tool, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        }
        try """
        case ":$PATH:" in
          *":$STACKHUB_PREFERRED_BIN:"*) ;;
          *) export PATH="$STACKHUB_PREFERRED_BIN:$PATH" ;;
        esac
        """.write(to: root.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(stale.path):\(preferred.path):/usr/bin:/bin"
        environment["STACKHUB_PREFERRED_BIN"] = preferred.path
        environment["ZDOTDIR"] = root.path
        let process = ServiceShell.makeProcess(command: "stackhub-path-tool", directory: root, environment: environment)
        XCTAssertEqual(try RuntimeProbe.run(process, timeout: 3), "preferred")
    }

    private func run(_ process: Process, startupDirectory: URL) throws -> String {
        var environment = process.environment ?? ProcessInfo.processInfo.environment
        environment["ZDOTDIR"] = startupDirectory.path
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
