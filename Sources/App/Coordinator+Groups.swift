import Cocoa

extension Coordinator {
    /// Read-only V7.4 tie-in: arms exact observation of a registered group's whole
    /// membership through the same queued path as a brain pick (`observeBrainPick`).
    /// A disabled or over-limit group is refused up front — nothing is queued, the
    /// current selection stays, and no truncated subset is armed in its place.
    /// Never calls `stimulate`; extInput is untouched.
    @discardableResult
    func observeGroup(_ groupID: String, registry given: GroupRegistry? = nil) -> Result<Int, GroupObservationError> {
        guard let sim else { return .failure(.noSimulation) }
        let registry = given ?? sim.groupRegistry
        switch registry.armPlan(groupID, limit: sim.observer.limit) {
        case .failure(let e): return .failure(e)
        case .success(let members):
            let name = registry.definition(groupID)?.labels.pick ?? groupID
            sim.observer.markPending(name)
            enqueueSimulation { c in _ = c.sim?.setObservation(members, name: name, truncate: false) }
            return .success(members.count)
        }
    }
}

extension GroupText {
    /// The current interface language's text.
    var pick: String { L(en, ko) }
}

extension GroupRegistry {
    /// A selection armed from a group carries its label in the language of the
    /// moment; this shows it in the current one. Other names pass through.
    func relabel(_ name: String) -> String {
        definitions.first { $0.labels.en == name || $0.labels.ko == name }?.labels.pick ?? name
    }
}
