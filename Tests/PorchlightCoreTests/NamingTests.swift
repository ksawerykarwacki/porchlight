import Foundation
import Testing

@testable import PorchlightCore

@Suite struct NameTemplateTests {
    let day = Date(timeIntervalSince1970: 1_791_540_000) // 2026-10-09 10:00 UTC
    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func name(_ template: String, prompt: String = "Fix the flaky settings test", branch: String? = "feature/PROJ-12-login", ticket: String? = nil) -> String {
        NameTemplate(settings: NamingSettings(template: template, ticketPattern: ticket))
            .name(prompt: prompt, directory: "/Users/u/code/porchlight", branch: branch, now: day, calendar: utc)
    }

    @Test func theDefaultIsTheSlug() {
        #expect(NamingSettings().template == "{slug}")
        #expect(name(NamingSettings.defaultTemplate) == "fix-flaky-settings-test")
    }

    @Test func everyTokenIsFilledIn() {
        #expect(name("{repo}") == "porchlight")
        #expect(name("{branch}") == "feature/PROJ-12-login")
        #expect(name("{date}") == "2026-10-09")
        #expect(name("{ticket}", ticket: "[A-Z]+-\\d+") == "PROJ-12")
        #expect(name("{repo}: {slug} ({date})") == "porchlight: fix-flaky-settings-test (2026-10-09)")
    }

    @Test func aWorktreeFolderStillNamesItsRepository() {
        let template = NameTemplate(settings: NamingSettings(template: "{repo}"))
        #expect(template.name(prompt: "x", directory: "/Users/u/code/porchlight/.claude/worktrees/fix-login", branch: nil) == "porchlight")
    }

    @Test func theTicketComesFromThePromptFirstThenTheBranch() {
        let pattern = "[A-Z]+-\\d+"
        #expect(name("{ticket}", prompt: "Look at OPS-7 and fix it", ticket: pattern) == "OPS-7")
        #expect(name("{ticket}", prompt: "No id here", ticket: pattern) == "PROJ-12")
        // A capture group picks the part to keep.
        #expect(name("{ticket}", prompt: "see issue #482 please", ticket: "#(\\d+)") == "482")
    }

    @Test func emptyTokensLeaveNoDanglingSeparators() {
        // No ticket pattern set: the token is empty.
        #expect(name("{ticket}-{slug}") == "fix-flaky-settings-test")
        #expect(name("{slug}-{ticket}") == "fix-flaky-settings-test")
        #expect(name("{repo}/{ticket}/{slug}") == "porchlight/fix-flaky-settings-test")
        #expect(name("{repo} - {branch} - {slug}", branch: nil) == "porchlight - fix-flaky-settings-test")
        // A pattern that is not a regular expression, or matches nothing, is an empty ticket.
        #expect(name("{ticket}-{slug}", ticket: "([") == "fix-flaky-settings-test")
        #expect(name("{ticket}-{slug}", prompt: "plain words", branch: "main", ticket: "[A-Z]+-\\d+") == "plain-words")
    }

    @Test func aTemplateThatComesOutEmptyFallsBackToTheSlug() {
        #expect(name("{ticket}") == "fix-flaky-settings-test")
        #expect(name("{branch}", branch: nil) == "fix-flaky-settings-test")
        // Nothing to build from at all: no name, and Claude Code picks one.
        #expect(name("{ticket}", prompt: "   ") == "")
    }

    @Test func unknownTokensStayVisibleAndLongNamesAreCutAtAWord() {
        #expect(name("{slug}-{tikcet}") == "fix-flaky-settings-test-{tikcet}")
        let long = name("{repo}-{branch}-{slug}-{date}-{repo}-{branch}")
        #expect(long.count <= NameTemplate.maxLength)
        #expect(long == "porchlight-feature/PROJ-12-login-fix-flaky-settings-test")
        #expect(!long.hasSuffix("-"))
    }

    @Test func settingsAreReadTolerantly() throws {
        let odd = Data(#"{"naming": {"template": "  ", "ticketPattern": ""}, "terminal": "warp"}"#.utf8)
        let settings = try JSONDecoder().decode(Settings.self, from: odd)
        #expect(settings.terminal == "warp")
        #expect(settings.naming == NamingSettings())
        let set = Data(#"{"naming": {"template": "{repo}-{slug}", "ticketPattern": "T\\d+", "later": 1}}"#.utf8)
        #expect(try JSONDecoder().decode(Settings.self, from: set).naming == NamingSettings(template: "{repo}-{slug}", ticketPattern: "T\\d+"))
        let wrong = Data(#"{"naming": {"template": 7}}"#.utf8)
        #expect(try JSONDecoder().decode(Settings.self, from: wrong).naming == NamingSettings())
    }
}

@Suite struct SlugTests {
    @Test func takesTheFirstSignificantWords() {
        #expect(Slug.make(from: "Fix the flaky settings test in CI") == "fix-flaky-settings-test")
        #expect(Slug.make(from: "Please can you add a retry to the uploader, with backoff") == "add-retry-uploader-backoff")
        #expect(Slug.make(from: "Refactor") == "refactor")
    }

    @Test func usesOnlyTheFirstLineAndDropsPunctuation() {
        #expect(Slug.make(from: "\n\nUpdate README.md (badges)\nHere is a long pasted log…") == "update-readme-md-badges")
        #expect(Slug.make(from: "Don't break the user's login!") == "dont-break-users-login")
        #expect(Slug.make(from: "Bump v2.1.294 → 2.2") == "bump-v2-1-294")
    }

    @Test func keepsLettersOfOtherLanguagesAndSurvivesFillerOnly() {
        #expect(Slug.make(from: "Napraw błąd logowania użytkownika") == "napraw-błąd-logowania-użytkownika")
        // Only filler: use it rather than nothing.
        #expect(Slug.make(from: "Can you do this for me") == "do")
        #expect(Slug.make(from: "can you please") == "can-you-please")
        #expect(Slug.make(from: "") == "")
        #expect(Slug.make(from: "?!… \n") == "")
    }

    @Test func aVeryLongWordIsCut() {
        let slug = Slug.make(from: String(repeating: "x", count: 200) + " tail")
        #expect(slug.count == NameTemplate.maxLength)
    }
}

@Suite struct GitBranchTests {
    func repository(head: String?) throws -> String {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("porchlight-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base.appendingPathComponent(".git"), withIntermediateDirectories: true)
        if let head { try Data(head.utf8).write(to: base.appendingPathComponent(".git/HEAD")) }
        return base.path
    }

    @Test func readsTheBranchOfAClone() throws {
        let repo = try repository(head: "ref: refs/heads/feature/login-form\n")
        defer { try? FileManager.default.removeItem(atPath: repo) }
        #expect(GitBranch.current(in: repo) == "feature/login-form")
    }

    @Test func aDetachedCheckoutHasNoBranch() throws {
        let repo = try repository(head: "4da12375c1f0e0a1b2c3d4e5f60718293a4b5c6d\n")
        defer { try? FileManager.default.removeItem(atPath: repo) }
        #expect(GitBranch.current(in: repo) == nil)
    }

    @Test func followsTheGitFileOfALinkedWorktree() throws {
        let repo = try repository(head: "ref: refs/heads/main\n")
        defer { try? FileManager.default.removeItem(atPath: repo) }
        // What `git worktree add` writes: a HEAD of its own under the main repository.
        let admin = repo + "/.git/worktrees/fix"
        try FileManager.default.createDirectory(atPath: admin, withIntermediateDirectories: true)
        try Data("ref: refs/heads/fix/issue-9\n".utf8).write(to: URL(fileURLWithPath: admin + "/HEAD"))

        let absolute = repo + "/.claude/worktrees/fix"
        try FileManager.default.createDirectory(atPath: absolute, withIntermediateDirectories: true)
        try Data("gitdir: \(admin)\n".utf8).write(to: URL(fileURLWithPath: absolute + "/.git"))
        #expect(GitBranch.current(in: absolute) == "fix/issue-9")

        // Submodules point with a relative path.
        let relative = repo + "/sub"
        try FileManager.default.createDirectory(atPath: relative, withIntermediateDirectories: true)
        try Data("gitdir: ../.git/worktrees/fix\n".utf8).write(to: URL(fileURLWithPath: relative + "/.git"))
        #expect(GitBranch.current(in: relative) == "fix/issue-9")
    }

    @Test func aFolderThatIsNotARepositoryOrIsBrokenHasNoBranch() throws {
        let plain = FileManager.default.temporaryDirectory.appendingPathComponent("porchlight-plain-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: plain) }
        #expect(GitBranch.current(in: plain) == nil)
        #expect(GitBranch.current(in: plain + "/missing") == nil)

        let noHead = try repository(head: nil)
        defer { try? FileManager.default.removeItem(atPath: noHead) }
        #expect(GitBranch.current(in: noHead) == nil)
        let empty = try repository(head: "ref: refs/heads/\n")
        defer { try? FileManager.default.removeItem(atPath: empty) }
        #expect(GitBranch.current(in: empty) == nil)

        try Data("not a pointer\n".utf8).write(to: URL(fileURLWithPath: plain + "/.git"))
        #expect(GitBranch.current(in: plain) == nil)
    }
}
