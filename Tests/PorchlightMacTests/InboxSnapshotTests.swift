import AppKit
import Foundation
import PorchlightMac
import SwiftUI
import Testing

@testable import PorchlightCore
@testable import PorchlightUI

/// Renders the inbox offscreen. Set PORCHLIGHT_SNAPSHOT_DIR to keep the images for a look:
///   PORCHLIGHT_SNAPSHOT_DIR=/tmp/shots swift test --filter InboxSnapshotTests
@MainActor
@Suite struct InboxSnapshotTests {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("PorchlightCoreTests/Fixtures")
    let now = Date(timeIntervalSince1970: 1_791_480_200)

    func fixtureSnapshot() throws -> StoreSnapshot {
        let json = try String(contentsOf: Self.fixtures.appendingPathComponent("agents-all.json"), encoding: .utf8)
        var snapshot = StoreSnapshot()
        snapshot.sessions = JobStateSource(jobsDirectory: Self.fixtures.appendingPathComponent("jobs"))
            .enrich(try AgentsCLISource.decode(json).sessions)
        snapshot.fetchedAt = now
        return snapshot
    }

    func render(_ view: some View, named name: String) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view.background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        if let directory = ProcessInfo.processInfo.environment["PORCHLIGHT_SNAPSHOT_DIR"] {
            let url = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: url.appendingPathComponent("\(name).png"))
        }
        return bitmap
    }

    @Test func rendersEveryGroup() throws {
        let bitmap = try render(InboxView(snapshot: try fixtureSnapshot(), now: now, scrolls: false), named: "inbox")
        #expect(bitmap.pixelsWide == 800)
        // Six rows with details: far taller than the empty state.
        #expect(bitmap.pixelsHigh > 700)
    }

    @Test func rendersTheStaleBannerAndANotice() throws {
        var snapshot = try fixtureSnapshot()
        snapshot.problem = .timedOut
        snapshot.fetchedAt = now - 180
        let fresh = try render(InboxView(snapshot: try fixtureSnapshot(), now: now, scrolls: false), named: "inbox")
        let stale = try render(InboxView(snapshot: snapshot, now: now, notice: "Opened in Warp", scrolls: false), named: "inbox-stale")
        #expect(stale.pixelsHigh > fresh.pixelsHigh)
    }

    @Test func rendersTheEmptyState() throws {
        var snapshot = StoreSnapshot()
        snapshot.fetchedAt = now
        let bitmap = try render(InboxView(snapshot: snapshot, now: now, scrolls: false), named: "inbox-empty")
        #expect(bitmap.pixelsWide == 800)
        #expect(bitmap.pixelsHigh < 300)
    }

    /// The height the menu-bar window gives the panel, scroll area included: the smallest size the
    /// view accepts. The offscreen renders above draw the list without its scroll area, and the
    /// view's ideal size looked fine too, so neither saw the scroll area collapse to nothing.
    func livePanelHeight(_ snapshot: StoreSnapshot) -> CGFloat {
        NSHostingController(rootView: InboxView(snapshot: snapshot, now: now)).sizeThatFits(in: .zero).height
    }

    func blocked(_ count: Int) -> StoreSnapshot {
        var snapshot = StoreSnapshot()
        snapshot.fetchedAt = now
        snapshot.sessions = (0..<count).map { index in
            Session(
                summary: SessionSummary(id: "id\(index)", name: "session \(index)", cwd: "/Users/u/code/repo\(index)", state: .blocked),
                observedBlockedSince: now - Double(index * 60))
        }
        return snapshot
    }

    @Test func theLivePanelGrowsWithItsRowsUntilItHasToScroll() throws {
        let empty = livePanelHeight(blocked(0))
        let two = livePanelHeight(blocked(2))
        let three = livePanelHeight(blocked(3))
        let many = livePanelHeight(blocked(60))

        // Rows take real space: each one adds height while the list still fits.
        #expect(two > empty + 40)
        #expect(three > two + 20)
        // A long list stops growing and scrolls instead of running off the screen.
        #expect(many > three)
        #expect(many < 560)
        #expect(livePanelHeight(blocked(120)) == many)
        // The fixture has six detailed rows: taller than the cap, so it sits at the cap too.
        #expect(livePanelHeight(try fixtureSnapshot()) == many)
    }

    @Test func theTerminalChoiceIsSavedAndUsedForTheNextOpen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("porchlight-choice-\(UUID().uuidString)")
        let url = Settings.fileURL(in: directory)
        try Settings(terminal: nil, claudePath: "/custom/claude").save(to: url)

        let model = InboxModel(settingsURL: url)
        #expect(model.chosenTerminal == nil)
        #expect(model.installedTerminals.contains(.terminal))

        model.chooseTerminal(.terminal)
        #expect(model.chosenTerminal == .terminal)
        #expect(model.notice == "Sessions will open in Terminal")
        // Saved without losing the other setting, and picked up by a fresh model.
        #expect(Settings.load(from: url) == Settings(terminal: "terminal", claudePath: "/custom/claude"))
        #expect(InboxModel(settingsURL: url).chosenTerminal == .terminal)

        model.chooseTerminal(nil)
        #expect(Settings.load(from: url).terminal == nil)
        #expect(InboxModel(settingsURL: url).chosenTerminal == nil)

        #expect(!model.prefersAgentView)
        model.setPrefersAgentView(true)
        #expect(Settings.load(from: url) == Settings(terminal: nil, claudePath: "/custom/claude", preferAgentView: true))
        #expect(InboxModel(settingsURL: url).prefersAgentView)
    }

    @Test func saysSoWhenNotificationsAreOff() throws {
        let plain = try render(InboxView(snapshot: try fixtureSnapshot(), now: now, scrolls: false), named: "inbox")
        let warned = try render(
            InboxView(snapshot: try fixtureSnapshot(), now: now,
                      notificationProblem: "Notifications are turned off for Porchlight in System Settings > Notifications.", scrolls: false),
            named: "inbox-notifications-off")
        #expect(warned.pixelsHigh > plain.pixelsHigh + 30)
    }

    @Test func rowButtonsCallTheirActions() throws {
        var opened: [String] = []
        var actions = InboxActions()
        actions.open = { opened.append($0) }
        actions.open("55555555")
        #expect(opened == ["55555555"])
    }
}
