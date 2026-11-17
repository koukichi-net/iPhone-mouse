// Which connected host receives input (design §7.3). Pure rules; the app supplies the state.

/// Active-host selection rules.
///
/// - A host that subscribes to the mouse report becomes active only when there is no active
///   host that is still subscribed (first host, or the active one went away). It never steals
///   input from a host the user is controlling.
/// - Exception at launch: when several hosts connect within the first seconds, the host that
///   was active last time (`preferred`, persisted by the app) wins over whichever subscribed
///   first.
/// - When the active host goes away, the preferred host takes over if it is subscribed, else
///   the most recent subscriber.
/// - `pinned` (`--active-central`, automated tests) overrides everything: only that host is
///   ever chosen automatically.
public enum HostSelection {
    /// The active host after `newcomer` subscribed to the mouse report.
    /// - Parameters:
    ///   - subscribed: hosts currently subscribed to the mouse report (including `newcomer`).
    ///   - inLaunchWindow: true during the first seconds after the app started.
    public static func afterSubscribe<ID: Hashable>(_ newcomer: ID, active: ID?, subscribed: Set<ID>,
                                                    pinned: ID?, preferred: ID?, inLaunchWindow: Bool) -> ID? {
        if let pinned {
            return newcomer == pinned ? newcomer : active
        }
        guard let active, subscribed.contains(active) else { return newcomer }
        if inLaunchWindow, newcomer == preferred, active != preferred { return newcomer }
        return active
    }

    /// The active host after the active one stopped being subscribed to the mouse report.
    /// - Parameter remaining: still-subscribed hosts, oldest subscription first.
    public static func afterActiveGone<ID: Hashable>(remaining: [ID], pinned: ID?, preferred: ID?) -> ID? {
        if let pinned { return remaining.contains(pinned) ? pinned : nil }
        if let preferred, remaining.contains(preferred) { return preferred }
        return remaining.last
    }
}
