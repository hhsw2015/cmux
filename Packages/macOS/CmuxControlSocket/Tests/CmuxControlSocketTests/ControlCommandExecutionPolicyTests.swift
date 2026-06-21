import Testing
@testable import CmuxControlSocket

@Suite("ControlCommandExecutionPolicy")
struct ControlCommandExecutionPolicyTests {
    @Test func vmPrefixedMethodsRunOnTheSocketWorker() {
        #expect(ControlCommandExecutionPolicy(forMethod: "vm.create") == .socketWorker(mainThreadCallable: false))
        #expect(ControlCommandExecutionPolicy(forMethod: "vm.anything.else").runsOnSocketWorker)
    }

    @Test func remotesPrefixedMethodsRunOnTheSocketWorker() {
        // `cmux remotes` verbs make blocking authenticated web API calls, so
        // they must run on the worker; otherwise the dispatcher never reaches
        // their handler and returns method_not_found.
        #expect(ControlCommandExecutionPolicy(forMethod: "remotes.list") == .socketWorker(mainThreadCallable: false))
        #expect(ControlCommandExecutionPolicy(forMethod: "remotes.add") == .socketWorker(mainThreadCallable: false))
        #expect(ControlCommandExecutionPolicy(forMethod: "remotes.remove") == .socketWorker(mainThreadCallable: false))
    }

    @Test func fixedWorkerSetRunsOnTheSocketWorker() {
        for method in [
            "system.ping", "system.capabilities", "auth.status", "auth.sign_in_url",
            "feed.push", "browser.download.wait", "system.top", "system.memory",
            "workspace.remote.pty_bridge", "workspace.env", "sidebar.custom.reload",
            "sidebar.custom.open",
            "debug.sidebar.simulate_drag", "mobile.attach_ticket.create",
            // long-blocking surface/notification waits — must NOT run on main
            "surface.wait_for_screen_change",
            "surface.wait_for_idle",
            "surface.wait_for_text",
            "surface.wait_for_kind",
            "surface.wait_for_cursor",
            "surface.expect",
            "notification.wait",
        ] {
            #expect(ControlCommandExecutionPolicy(forMethod: method).runsOnSocketWorker, "\(method)")
        }
    }

    @Test func everythingElseRunsOnTheMainActor() {
        for method in [
            "surface.list", "workspace.create", "window.list", "browser.eval",
            "mobile.terminal.create", "feed.jump", "vmx.create", "",
        ] {
            let policy = ControlCommandExecutionPolicy(forMethod: method)
            #expect(policy == .mainActor, "\(method)")
            #expect(!policy.runsOnSocketWorker, "\(method)")
        }
    }

    @Test func onlyPureProbesAreMainThreadCallable() {
        #expect(ControlCommandExecutionPolicy(forMethod: "system.ping") == .socketWorker(mainThreadCallable: true))
        #expect(ControlCommandExecutionPolicy(forMethod: "system.capabilities") == .socketWorker(mainThreadCallable: true))
        #expect(ControlCommandExecutionPolicy(forMethod: "system.top") == .socketWorker(mainThreadCallable: false))
        #expect(ControlCommandExecutionPolicy(forMethod: "vm.create") == .socketWorker(mainThreadCallable: false))
    }
}
