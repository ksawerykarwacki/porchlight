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
        #expect(bitmap.pixelsHigh < 400)
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
        #expect(many < 620)
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

    /// Draws the icon large on a menu-bar-like background, for a look with PORCHLIGHT_SNAPSHOT_DIR.
    func preview(_ status: MenuBarStatus, dark: Bool, named name: String) throws -> NSBitmapImageRep {
        let side: CGFloat = 180
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            (dark ? NSColor(calibratedWhite: 0.16, alpha: 1) : NSColor(calibratedWhite: 0.93, alpha: 1)).setFill()
            rect.fill()
            // Unlit ink is whatever the menu bar uses: white on dark, near-black on light.
            let unlit = dark ? NSColor.white : NSColor(calibratedWhite: 0.1, alpha: 1)
            StatusIcon.draw(in: rect.insetBy(dx: 18, dy: 18), ink: unlit, light: StatusIcon.tint(for: status), rays: StatusIcon.showsRays(for: status))
            return true
        }
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        if let directory = ProcessInfo.processInfo.environment["PORCHLIGHT_SNAPSHOT_DIR"] {
            let url = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: url.appendingPathComponent("\(name).png"))
        }
        return bitmap
    }

    /// How many sampled pixels are strongly coloured amber (hue near 40 degrees) or red (near 8).
    func colours(_ bitmap: NSBitmapImageRep) -> (warm: Int, red: Int) {
        var warm = 0, red = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      c.saturationComponent > 0.45, c.brightnessComponent > 0.7 else { continue }
                let degrees = c.hueComponent * 360
                if (25...60).contains(degrees) { warm += 1 } else if degrees < 20 || degrees > 345 { red += 1 }
            }
        }
        return (warm, red)
    }

    /// How many sampled pixels are the frame's ink: near white on a dark bar, near black on a light one.
    func inkPixels(_ bitmap: NSBitmapImageRep, dark: Bool) throws -> Int {
        var count = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.saturationComponent < 0.15 else { continue }
                if dark ? c.brightnessComponent > 0.9 : c.brightnessComponent < 0.25 { count += 1 }
            }
        }
        return count
    }

    @Test func theIconIsUnlitLitAmberOrLitRedWithRays() throws {
        // Idle follows the menu bar's own colour; the other two carry a fixed colour.
        #expect(StatusIcon.image(for: .idle).isTemplate)
        #expect(!StatusIcon.image(for: .waiting(count: 1)).isTemplate)
        #expect(!StatusIcon.image(for: .overdue(count: 1)).isTemplate)
        #expect(StatusIcon.image(for: .idle).size == NSSize(width: 18, height: 18))
        #expect(!StatusIcon.showsRays(for: .waiting(count: 1)))
        #expect(StatusIcon.showsRays(for: .overdue(count: 1)))

        for dark in [true, false] {
            let suffix = dark ? "dark" : "light"
            let idle = colours(try preview(.idle, dark: dark, named: "icon-idle-\(suffix)"))
            let waiting = colours(try preview(.waiting(count: 1), dark: dark, named: "icon-waiting-\(suffix)"))
            let overdue = colours(try preview(.overdue(count: 1), dark: dark, named: "icon-overdue-\(suffix)"))
            // Unlit has no colour; waiting is amber, not red; overdue is red, not amber.
            #expect(idle.warm == 0 && idle.red == 0)
            // (A few blended edge pixels can fall on the other side, hence the ratio.)
            #expect(waiting.warm > 150 && waiting.red * 10 < waiting.warm)
            #expect(overdue.red > 150 && overdue.warm * 10 < overdue.red)
            // Only the light is coloured: most of the lantern stays the menu bar's own colour.
            let ink = try inkPixels(preview(.waiting(count: 1), dark: dark, named: "icon-waiting-\(suffix)"), dark: dark)
            #expect(ink > 300)
        }

        // The rendered label shows the count next to the icon from two up, and nothing below.
        let idle = try render(StatusLabel(status: .idle).padding(4), named: "status-idle")
        let one = try render(StatusLabel(status: .waiting(count: 1)).padding(4), named: "status-one")
        #expect(one.pixelsWide == idle.pixelsWide)
        let waiting = try render(StatusLabel(status: .waiting(count: 3)).padding(4), named: "status-waiting")
        let overdue = try render(StatusLabel(status: .overdue(count: 12)).padding(4), named: "status-overdue")
        #expect(waiting.pixelsWide > idle.pixelsWide)
        #expect(overdue.pixelsWide > waiting.pixelsWide)
    }

    @Test func theTerminalChoiceSaysWhatAutomaticMeans() {
        var actions = InboxActions()
        actions.terminals = [(id: "warp", name: "Warp"), (id: "ghostty", name: "Ghostty")]
        #expect(actions.terminalTitle(nil) == "Whichever is running")
        actions.automaticTerminalName = "Warp"
        #expect(actions.terminalTitle(nil) == "Whichever is running (now Warp)")
        #expect(actions.terminalTitle("ghostty") == "Ghostty")
        // A terminal saved by hand that is not installed still shows, as itself.
        #expect(actions.terminalTitle("kitty") == "kitty")
    }

    @Test func theFooterKeepsOnlySessionActionsAndTheTabsCarryTheRest() throws {
        var actions = InboxActions()
        actions.terminals = [(id: "warp", name: "Warp")]
        let sessions = try render(InboxView(snapshot: StoreSnapshot(), actions: actions, scrolls: false), named: "tabs-sessions")
        actions.showsSettings = true
        let settings = try render(InboxView(snapshot: StoreSnapshot(), actions: actions, scrolls: false), named: "tabs-settings")
        // The settings tab is the taller page, and it includes the terminal section.
        #expect(settings.pixelsHigh > sessions.pixelsHigh + 300)
        var withoutTerminals = actions
        withoutTerminals.terminals = []
        let shorter = try render(InboxView(snapshot: StoreSnapshot(), actions: withoutTerminals, scrolls: false), named: "tabs-settings-no-terminal")
        #expect(settings.pixelsHigh > shorter.pixelsHigh + 100)
    }

    @Test func aRowUnderThePointerIsHighlightedAndLeavingClearsIt() throws {
        let hover = HoverTracker()
        hover.set("22222222", true)
        #expect(hover.hovered == "22222222")
        // Leaving a row that is no longer the hovered one must not clear the new one.
        hover.set("55555555", true)
        hover.set("22222222", false)
        #expect(hover.hovered == "55555555")
        hover.set("55555555", false)
        #expect(hover.hovered == nil)

        let plain = try render(InboxView(snapshot: try fixtureSnapshot(), now: now, scrolls: false), named: "inbox")
        let hovered = try render(
            InboxView(snapshot: try fixtureSnapshot(), now: now, hover: HoverTracker(hovered: "22222222"), scrolls: false),
            named: "inbox-hover")
        // Same layout, different pixels: the highlight and the open arrow.
        #expect(hovered.pixelsHigh == plain.pixelsHigh)
        #expect(hovered.tiffRepresentation != plain.tiffRepresentation)
    }

    @Test func theAppIconIsALitLanternOnADarkTile() throws {
        let bitmap = try #require(StatusIcon.appIconBitmap(pixels: 256))
        #expect(bitmap.pixelsWide == 256 && bitmap.pixelsHigh == 256)
        if let directory = ProcessInfo.processInfo.environment["PORCHLIGHT_SNAPSHOT_DIR"] {
            let url = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: url.appendingPathComponent("app-icon.png"))
        }
        // Transparent outside the tile, dark blue at its edge, amber where the lantern is.
        #expect(bitmap.colorAt(x: 2, y: 2)?.alphaComponent == 0)
        let edge = try #require(bitmap.colorAt(x: 128, y: 34)?.usingColorSpace(.deviceRGB))
        #expect(edge.alphaComponent == 1 && edge.blueComponent > edge.redComponent)
        #expect(colours(bitmap).warm > 250)
    }

    @Test func onlyTheSnoozedRowLosesItsLamp() throws {
        let snapshot = try fixtureSnapshot()
        let plain = try render(InboxView(snapshot: snapshot, now: now, scrolls: false), named: "inbox")
        let snoozed = try render(
            InboxView(snapshot: snapshot, now: now, snoozes: ["22222222": .until(now + 3600)], scrolls: false),
            named: "inbox-snoozed")
        // Three rows are lit without a snooze, two with one: a third of the lamp colour goes.
        let before = colours(plain), after = colours(snoozed)
        #expect(before.warm > 0 && before.red > 0)
        #expect(after.red == before.red)
        #expect(after.warm < before.warm)
        #expect(after.warm > 0)
    }

    @Test func aPanelThatChangesHeightKeepsItsTopEdge() {
        // Open under the menu bar: 600 tall, top edge at y = 1000.
        let top: CGFloat = 1000
        let open = CGRect(x: 300, y: 400, width: 400, height: 600)
        #expect(!PanelPinning.needsPinning(open, top: top))

        // AppKit shrinks it from the bottom-left corner: the top drops by 250.
        let shrunk = CGRect(x: 300, y: 400, width: 400, height: 350)
        #expect(PanelPinning.needsPinning(shrunk, top: top))
        let pinned = PanelPinning.pinned(shrunk, top: top)
        #expect(pinned == CGRect(x: 300, y: 650, width: 400, height: 350))
        #expect(pinned.maxY == top)
        #expect(!PanelPinning.needsPinning(pinned, top: top))

        // Growing again moves the bottom down, not the top up.
        let grown = PanelPinning.pinned(CGRect(x: 300, y: 650, width: 400, height: 700), top: top)
        #expect(grown.maxY == top && grown.minY == 300)
        // A sub-pixel difference is left alone.
        #expect(!PanelPinning.needsPinning(CGRect(x: 0, y: 400.3, width: 400, height: 600), top: top))
    }

    @Test func closingThePanelReturnsToTheSessionsTab() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("porchlight-panel-\(UUID().uuidString)")
        let model = InboxModel(settingsURL: Settings.fileURL(in: directory), remindersURL: ReminderState.fileURL(in: directory))
        model.showsSettings = true
        // What the app wires to the window observer.
        let observer = PanelWindowObserver { model.showsSettings = false }
        observer.onClose()
        #expect(!model.showsSettings)
    }

    @Test func rowButtonsCallTheirActions() throws {
        var opened: [String] = []
        var actions = InboxActions()
        actions.open = { opened.append($0) }
        actions.open("55555555")
        #expect(opened == ["55555555"])
    }
}
