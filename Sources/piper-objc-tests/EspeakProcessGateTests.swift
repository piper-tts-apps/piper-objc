import Testing
import Foundation
@testable import piper_objc

/// Unit tests for the process-wide espeak gate. Each test injects an
/// isolated EspeakProcessGate (Piper itself always uses .shared), so
/// the tests are deterministic even while other suites run real Piper
/// instances in the same process. Fake handles are never dereferenced:
/// every free goes through a recorder closure, and every destroyed
/// handle is registered first, mirroring the production contract.
@Suite("Espeak Process Gate Tests", .serialized)
struct EspeakProcessGateTests {

    private func fakeHandle(_ n: Int) -> OpaquePointer {
        return OpaquePointer(bitPattern: 0xE500_0000 + n)!
    }

    @Test("A session blocks a second session until it releases")
    func sessionBlocksSecondSession() {
        let gate = EspeakProcessGate()
        let first = EspeakSessionLock(gate: gate)
        let second = EspeakSessionLock(gate: gate)
        first.acquire()

        let acquired = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            second.acquire()
            acquired.signal()
        }
        #expect(acquired.wait(timeout: .now() + 0.3) == .timedOut,
                "Second session must not acquire while the first holds the gate")

        first.release()
        #expect(acquired.wait(timeout: .now() + 2) == .success,
                "Second session must acquire once the first releases")
        second.release()
    }

    @Test("Destroy defers the free while other synthesizers are alive")
    func destroyDefersWhileSiblingsAlive() {
        let gate = EspeakProcessGate()
        var freed: [OpaquePointer] = []
        let first = fakeHandle(1)
        let second = fakeHandle(2)
        gate.registerLive(first)
        gate.registerLive(second)

        // A piper_free here would espeak_Terminate under the surviving
        // synthesizer, so the free must be deferred, not executed.
        gate.destroy(first) { freed.append($0) }
        #expect(freed.isEmpty)
        #expect(gate.deferredCount == 1)
        #expect(gate.liveCount == 1)

        // Destroying the last live synthesizer drains the deferred
        // free first, then frees its own handle.
        gate.destroy(second) { freed.append($0) }
        #expect(freed == [first, second])
        #expect(gate.deferredCount == 0)
        #expect(gate.liveCount == 0)
    }

    @Test("Destroying the only synthesizer frees it immediately")
    func destroyLastOutFreesImmediately() {
        let gate = EspeakProcessGate()
        var freed: [OpaquePointer] = []
        let handle = fakeHandle(3)
        gate.registerLive(handle)

        gate.destroy(handle) { freed.append($0) }

        #expect(freed == [handle])
        #expect(gate.deferredCount == 0)
        #expect(gate.liveCount == 0)
    }

    @Test("Destroying the same handle twice frees it exactly once")
    func destroySameHandleTwice() {
        let gate = EspeakProcessGate()
        var freed: [OpaquePointer] = []
        let handle = fakeHandle(4)
        gate.registerLive(handle)

        gate.destroy(handle) { freed.append($0) }
        // A second destroy (e.g. deinit racing releaseSynthesizer)
        // must be a no-op: a second piper_free would run a second
        // espeak_Terminate for a single Initialize.
        gate.destroy(handle) { freed.append($0) }

        #expect(freed == [handle])
        #expect(gate.liveCount == 0)
    }

    @Test("Deferred frees drain exactly once at the next create")
    func deferredDrainExactlyOnce() {
        let gate = EspeakProcessGate()
        var freed: [OpaquePointer] = []
        let first = fakeHandle(5)
        let second = fakeHandle(6)
        let survivor = fakeHandle(7)
        gate.registerLive(first)
        gate.registerLive(second)
        gate.registerLive(survivor)

        gate.destroy(first) { freed.append($0) }
        gate.destroy(second) { freed.append($0) }
        #expect(gate.deferredCount == 2)

        // The create path drains deferred frees (just before it
        // re-initializes espeak); each handle frees exactly once.
        gate.drainDeferredFrees { freed.append($0) }
        #expect(freed == [first, second])
        #expect(gate.deferredCount == 0)

        gate.drainDeferredFrees { freed.append($0) }
        #expect(freed == [first, second], "A second drain must not free anything again")
    }

    @Test("Destroy defers even for the last synthesizer while a session is active")
    func destroyDefersWhenGateBusy() {
        let gate = EspeakProcessGate()
        let session = EspeakSessionLock(gate: gate)
        session.acquire()

        var freed: [OpaquePointer] = []
        let handle = fakeHandle(8)
        gate.registerLive(handle)
        gate.destroy(handle) { freed.append($0) }

        #expect(freed.isEmpty, "No free may execute while a session holds the gate")
        #expect(gate.deferredCount == 1)
        #expect(gate.liveCount == 0)

        session.release()
        gate.drainDeferredFrees { freed.append($0) }
        #expect(freed == [handle])
    }

    @Test("acquireIfNotHeld never re-acquires an existing hold")
    func acquireIfNotHeldIdempotent() {
        let gate = EspeakProcessGate()
        let session = EspeakSessionLock(gate: gate)
        session.acquireIfNotHeld()
        #expect(session.holds)
        // A second acquireIfNotHeld must be a no-op; re-locking the
        // non-recursive NSLock here would deadlock the test.
        session.acquireIfNotHeld()
        #expect(session.holds)
        session.release()
        #expect(!session.holds)
    }
}
