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
        /// Summarises one session with the given engine (and Claude model, for that engine) and
        /// keeps the result as a note. Only ever called after the user has said yes: with Claude
        /// it spends usage.
        public var wrapUp: @MainActor (TriageItem, WrapUpEngine, String) async -> Result<SessionNote, WrapUpFailure>
        /// The notes kept so far.
        public var notes: @Sendable () -> [SessionNote]
        /// The chosen engine and whether this Mac has the on-device model. Asks `fm`, so it is slow.
        public var wrapUpPlan: @Sendable () async -> WrapUpPlan

        public init(
            sessions: @escaping @MainActor () -> [Session], pins: @escaping @MainActor () -> Pins,
            settings: @escaping @Sendable () -> TriageSettings = { TriageSettings() }, gatherer: TriageGatherer = TriageGatherer(),
            remove: @escaping @MainActor (String) async -> ControlOutcome, reload: @escaping @MainActor () async -> Void = {},
            now: @escaping @Sendable () -> Date = { Date() },
            wrapUp: @escaping @MainActor (TriageItem, WrapUpEngine, String) async -> Result<SessionNote, WrapUpFailure> = { _, _, _ in .failure(.couldNotRun("not set up")) },
            notes: @escaping @Sendable () -> [SessionNote] = { [] },
            wrapUpPlan: @escaping @Sendable () async -> WrapUpPlan = { WrapUpPlan() }
        ) {
            self.sessions = sessions
            self.pins = pins
            self.settings = settings
            self.gatherer = gatherer
            self.remove = remove
            self.reload = reload
            self.now = now
            self.wrapUp = wrapUp
            self.notes = notes
            self.wrapUpPlan = wrapUpPlan
        }
    }

    /// A summary that could not be made, with the reason.
    public struct WrapUpProblem: Equatable {
        public let id: String
        public let text: String

        public init(id: String, text: String) {
            self.id = id
            self.text = text
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
    /// The session whose "summarise this?" question is up.
    public private(set) var pendingWrapUp: String?
    /// The session being summarised right now. One at a time: each is a whole conversation read.
    public private(set) var summarising: String?
    /// The engine doing that summary.
    public private(set) var summarisingEngine: WrapUpEngine?
    /// The engine a wrap-up would use, as of the last look.
    public private(set) var plan = WrapUpPlan()
    /// The notes kept so far, by session id. They are Porchlight's own and outlive the sessions.
    public private(set) var notes: [String: SessionNote] = [:]
    public private(set) var wrapUpProblem: WrapUpProblem?
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
        let plan = await services.wrapUpPlan()
        guard mine == generation else { return }
        self.plan = plan
        items = found
        notes = Dictionary(services.notes().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        isLoading = false
        hasLoaded = true
    }

    /// Takes a session off the list straight away, when the user has just pinned it. The next
    /// look would leave it out anyway; this spares the wait.
    public func exclude(_ id: String) {
        items.removeAll { $0.id == id }
        if pendingWrapUp == id { pendingWrapUp = nil }
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

    /// Reads the choice of engine again, after it was changed in the settings.
    public func refreshPlan() async {
        plan = await services.wrapUpPlan()
    }

    /// Puts up the question for one session. Nothing is read or spent until it is answered.
    public func askWrapUp(_ id: String) {
        guard summarising == nil, items.contains(where: { $0.id == id }) else { return }
        pendingWrapUp = id
        wrapUpProblem = nil
    }

    public func cancelWrapUp() {
        pendingWrapUp = nil
    }

    /// Summarises the session the question was about. The session itself is left as it is; the
    /// summary is kept as a note, also after the session has been removed.
    ///
    /// The engine is the one in force. Passing `.claude` is the row's "read all of it" button:
    /// the only other way Claude usage is spent is the engine in force being Claude, which the
    /// question says.
    public func confirmWrapUp(with override: WrapUpEngine? = nil) async {
        guard let id = pendingWrapUp, summarising == nil else { return }
        pendingWrapUp = nil
        guard let item = items.first(where: { $0.id == id }) else { return }
        let engine = override == .claude ? .claude : plan.engine
        summarising = id
        summarisingEngine = engine
        let result = await services.wrapUp(item, engine, plan.model)
        summarising = nil
        summarisingEngine = nil
        switch result {
        case .success(let note): notes[id] = note
        case .failure(let failure): wrapUpProblem = WrapUpProblem(id: id, text: failure.message)
        }
    }

    public func dismissWrapUpProblem() {
        wrapUpProblem = nil
    }

    public func dismissResult() {
        summary = nil
        refusals = []
    }
}
