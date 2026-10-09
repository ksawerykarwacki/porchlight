import Foundation
import Testing

@testable import PorchlightCore

@Suite struct ShellEnvironmentTests {
    /// A stand-in shell: prints what a noisy profile would, then does what it was asked.
    func shell(_ body: String) throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("porchlight-shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("shell")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    let bare = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/Users/u", "__CFBundleIdentifier": "io.github.ksawerykarwacki.porchlight"]

    @Test func theShellIsAskedAsALoginInteractiveOneAndItsAnswerIsReadBetweenTheMarkers() async throws {
        // What rc files print, before and after, is not part of the answer.
        let path = try shell("""
            echo "Welcome back! PATH=/not/this"
            [ "$1" = "-l" ] && [ "$2" = "-i" ] && [ "$3" = "-c" ] || exit 9
            export PATH="/opt/homebrew/bin:/Users/u/.nvm/bin:/usr/bin:/bin" NVM_DIR="/Users/u/.nvm" MULTI="two
            lines" EMPTY=""
            eval "$4"
            echo "bye"
            """)
        let found = try #require(await ShellEnvironment.resolve(shell: path))
        #expect(found["PATH"] == "/opt/homebrew/bin:/Users/u/.nvm/bin:/usr/bin:/bin" && found["NVM_DIR"] == "/Users/u/.nvm")
        #expect(found["MULTI"] == "two\nlines" && found["EMPTY"] == "")
        #expect(ShellEnvironment.arguments().prefix(3) == ["-l", "-i", "-c"])
    }

    @Test func aShellThatCannotBeAskedLeavesThingsAsTheyAre() async throws {
        #expect(await ShellEnvironment.resolve(shell: "/nonexistent/shell") == nil)
        #expect(await ShellEnvironment.resolve(shell: try shell("exit 3")) == nil)
        #expect(await ShellEnvironment.resolve(shell: try shell("echo no markers here")) == nil)
        #expect(await ShellEnvironment.resolve(shell: try shell("sleep 20"), timeout: 0.5) == nil)
        #expect(ShellEnvironment.parse("") == nil)
        #expect(ShellEnvironment.parse("\(ShellEnvironment.marker)\(ShellEnvironment.marker)") == nil)
        // Nothing is set when there is no answer.
        var set: [String: String] = [:]
        #expect(!ShellEnvironment.adopt(current: bare, shell: "/nonexistent/shell") { set[$0] = $1 })
        #expect(set.isEmpty)
    }

    @Test func theAppTakesOnTheShellsVariablesButNotTheShellsOwn() {
        let fromShell = [
            "PATH": "/opt/homebrew/bin:/usr/bin:/bin", "HOME": "/Users/u", "JAVA_HOME": "/opt/java", "SHLVL": "2", "PWD": "/Users/u", "_": "/usr/bin/env",
            "TERM": "dumb",
        ]
        let merged = ShellEnvironment.merged(current: bare, shell: fromShell)
        #expect(merged["PATH"] == "/opt/homebrew/bin:/usr/bin:/bin" && merged["JAVA_HOME"] == "/opt/java")
        // What the app had and the shell did not mention stays; the shell's own bookkeeping is not taken.
        #expect(merged["__CFBundleIdentifier"] == "io.github.ksawerykarwacki.porchlight")
        #expect(merged["SHLVL"] == nil && merged["PWD"] == nil && merged["_"] == nil && merged["TERM"] == nil)
        // A shell that answers with no path at all does not take the app's away.
        #expect(ShellEnvironment.merged(current: bare, shell: ["PATH": "", "X": "1"])["PATH"] == bare["PATH"])
        #expect(ShellEnvironment.merged(current: bare, shell: ["X": "1"])["PATH"] == bare["PATH"])
    }

    @Test func adoptingSetsOnlyWhatDiffersAndIsSkippedInATerminal() throws {
        let path = try shell(#"export PATH="/opt/homebrew/bin:/usr/bin:/bin" HOME="/Users/u" EDITOR="vim"; eval "$4""#)
        var set: [String: String] = [:]
        #expect(ShellEnvironment.adopt(current: bare, shell: path) { set[$0] = $1 })
        #expect(set["PATH"] == "/opt/homebrew/bin:/usr/bin:/bin" && set["EDITOR"] == "vim")
        // HOME was the same already, and the shell's own variables are never set.
        #expect(set["HOME"] == nil && set["SHLVL"] == nil && set["PWD"] == nil)

        // Started from a terminal, the process has the user's environment already: the shell is not asked.
        set = [:]
        var inTerminal = bare
        inTerminal["TERM_PROGRAM"] = "WarpTerminal"
        #expect(!ShellEnvironment.adopt(current: inTerminal, shell: path) { set[$0] = $1 })
        var optedOut = bare
        optedOut["PORCHLIGHT_KEEP_ENVIRONMENT"] = "1"
        #expect(!ShellEnvironment.adopt(current: optedOut, shell: path) { set[$0] = $1 })
        #expect(set.isEmpty)
    }

    /// Many at once, each on a thread the tests share: it must not wait for a task.
    @Test func adoptingDoesNotHangWhenManyRunSideBySide() async throws {
        let path = try shell(#"export PATH="/opt/homebrew/bin:/usr/bin:/bin"; eval "$4""#)
        let bare = bare
        let changed = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<24 {
                group.addTask { ShellEnvironment.adopt(current: bare, shell: path) { _, _ in } }
            }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        #expect(changed == 24)
    }

    @Test func theLoginShellIsARealProgram() {
        let shell = ShellEnvironment.loginShell()
        #expect(shell.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: shell))
    }
}
