import Foundation
import Observation
import PorchlightCore

/// The Triage tab: the sessions that are no longer moving, what each holds, and clearing away
/// the ones that hold nothing.
@MainActor
@Observable
public final class TriageModel {
    /// What the tab needs from outside itself, so tests can stand in for the disk, `gh` and
    /// `claude`.
    public struct Services {
        public var sessions: @MainActor () -> [Session]
        public var pins: @MainActor () -> Pins
        public var settings: @Sendable () -> TriageSettings
        public var gatherer: TriageGatherer
        /// Removes one session with plain `claude rm`. Never forces anything.
        public var remove: @MainActor (String) async -> ControlOutcome
        /// Reads the sessions again after removals.
        public var reload: @MainActor () async -> Void
        public var now: @Sendable () -> Date

        public init(
            sessions: @escaping @MainActor () -> [Session], pins: @escaping @MainActor () -> Pins,
            settings: @escaping @Sendable () -> TriageSettings = { TriageSettings() }, gatherer: TriageGatherer = TriageGatherer(),
            remove: @escaping @MainActor (String) async -> ControlOutcome, reload: @escaping @MainActor () async -> Void = {},
            now: @escaping @Sendable () -> Date = { Date() }
        ) {
            self.sessions = sessions
            self.pins = pins
            self.settings = settings
            self.gatherer = gatherer
            self.remove = remove
            self.reload = reload
            self.now = now
        }
    }

    /// One removal Claude Code refused during a bulk removal, in its own words.
    public struct Refusal: Equatable, Identifiable {
        public let id: String
        public let name: String
        public let text: String
    }

    private let services: Services

    public private(set) var items: [TriageItem] = []
    public private(set) var isLoading = false
    /// False until the first look has finished: an empty list before that means "not looked yet".
    public private(set) var hasLoaded = false
    /// True while the question "remove the safe ones?" is up.
    public private(set) var isConfirmingBulk = false
    /// The session being removed right now, during a bulk removal.
    public private(set) var removing: String?
    /// What the last bulk removal came to.
    public private(set) var summary: String?
    public private(set) var refusals: [Refusal] = []
    private var generation = 0

    public init(services: Services) {
        self.services = services
    }

    public var safe: [TriageItem] { items.filter { $0.verdict == .safeToRemove } }

    public func items(_ verdict: TriageVerdict) -> [TriageItem] { items.filter { $0.verdict == verdict } }

    /// Looks at every idle session again. A second call while one is running replaces it, so the
    /// list always reflects the latest look.
    public func load() async {
        generation += 1
        let mine = generation
        isLoading = true
        let found = await services.gatherer.items(
            sessions: services.sessions(), pins: services.pins(), settings: services.settings(), now: services.now())
        guard mine == generation else { return }
        items = found
        isLoading = false
        hasLoaded = true
    }

    /// Takes a session off the list straight away, when the user has just pinned it. The next
    /// look would leave it out anyway; this spares the wait.
    public func exclude(_ id: String) {
        items.removeAll { $0.id == id }
        if safe.isEmpty { isConfirmingBulk = false }
    }

    public func askRemoveSafe() {
        guard !safe.isEmpty, removing == nil else { return }
        isConfirmingBulk = true
    }

    public func cancelRemoveSafe() {
        isConfirmingBulk = false
    }

    /// Removes every session judged safe, one after another, with plain `claude rm`. The verdict
    /// is advice: Claude Code checks each one again and may refuse, and a refusal is reported,
    /// never overridden.
    public func confirmRemoveSafe() async {
        guard isConfirmingBulk else { return }
        isConfirmingBulk = false
        let targets = safe
        guard !targets.isEmpty else { return }
        var removed = 0
        var refused: [Refusal] = []
        for item in targets {
            // Pinned in the meantime: keep it.
            if services.pins().isPinned(item.id) { continue }
            removing = item.id
            let outcome = await services.remove(item.id)
            if outcome.succeeded {
                removed += 1
            } else {
                refused.append(Refusal(id: item.id, name: item.session.name, text: outcome.message))
            }
        }
        removing = nil
        refusals = refused
        summary = Self.summary(removed: removed, refused: refused.count)
        await services.reload()
        await load()
    }

    static func summary(removed: Int, refused: Int) -> String {
        let done = "\(removed) \(removed == 1 ? "session" : "sessions") removed"
        return refused == 0 ? "\(done)." : "\(done); Claude Code refused \(refused), listed below."
    }

    public func dismissResult() {
        summary = nil
        refusals = []
    }
}
