import AppKit
import Foundation

/// App-lifetime owner of per-host event subscription + workspace
/// list polling. Runs whether or not the sidebar Herdr section is
/// visible, so the blocked-agent notification + dock badge fire
/// even when the user has collapsed the sidebar or doesn't have
/// the section in view.
///
/// The sidebar section still acquires its own pump refcount when
/// mounted — this just adds a separate, app-wide refcount that
/// lasts for the process lifetime.
@MainActor
enum HerdrBackgroundService {
    /// Hosts we've called acquire on, keyed by id so we can release
    /// the same host object on removal.
    private static var acquired: [UUID: HerdrHost] = [:]

    static func start() {
        // Reconcile every 5s so host add/remove flows pick up.
        Task { @MainActor in
            while !Task.isCancelled {
                reconcilePumpSubscriptions()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }

        // 60s poll loop, gated on app being active. The sidebar
        // section's own 30s loop covers the foreground "fast path";
        // this catches the case where the section isn't mounted (or
        // the host registry changes while it isn't mounted).
        Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                if !NSApp.isActive { continue }
                for host in HostRegistry.shared.hosts {
                    HerdrWorkspaceListStore.shared.refresh(host: host)
                }
            }
        }
    }

    /// Acquire pump for new hosts, release pump for removed hosts.
    private static func reconcilePumpSubscriptions() {
        let current = HostRegistry.shared.hosts
        let currentIds = Set(current.map { $0.id })

        for host in current where acquired[host.id] == nil {
            acquired[host.id] = host
            Task { await HerdrEventPump.shared.acquire(host: host) }
        }
        for (id, host) in acquired where !currentIds.contains(id) {
            acquired.removeValue(forKey: id)
            Task { await HerdrEventPump.shared.release(host: host) }
        }
    }
}
