//
//  EspeakProcessGate.swift
//  piper-objc
//
//  Process-wide coordination for espeak-ng, in two parts.
//
//  1. SERIALIZATION. espeak-ng keeps process-global state, so two
//     threads must never be inside espeak at once - not even on
//     separate Piper instances. A synthesize session holds the process
//     mutex from piper_synthesize_start until the final
//     piper_synthesize_next of the sentence, and piper_create_with_options
//     serializes its espeak initialization through the same mutex.
//     (Mirrors the piper-kotlin PR #2 session-lock design.)
//
//  2. TERMINATE DEFERRAL. piper_free() runs espeak_Terminate(), and in
//     the pinned espeak-ng that call UNCONDITIONALLY frees the global
//     phoneme data and voice list - there is no init/terminate refcount.
//     Every synthesizer created before a Terminate is therefore broken
//     until the next piper_create re-initializes espeak. Serialization
//     alone cannot fix that: instance A can free (Terminate) in a
//     gate-free moment and instance B's very next session walks into
//     the freed tables. So a destroy NEVER executes piper_free while
//     other synthesizers are alive. The handle is deferred instead, and
//     deferred frees only ever execute:
//       - inside a create's gate hold, immediately before
//         piper_create_with_options re-initializes espeak, or
//       - when the destroyed handle is the last live synthesizer
//         (nothing remains that a Terminate could break).
//     The recreate path (destroy + create in one operation) therefore
//     frees its old synthesizer promptly, inside its own create.
//
//  Exactly-once: every created handle is registered; destroy claims
//  the handle atomically, so a second destroy of the same handle -
//  e.g. deinit racing releaseSynthesizer on another thread - is a
//  no-op instead of a second espeak_Terminate.
//
//  Field evidence: PiperTTS 1.0.16 (340) macOS crashes, Oct 25, 2026
//  (two memory-pressure handlers inside piper_free -> espeak_Terminate
//  at once; synthesis dereferencing freed phoneme data), and the
//  piper-objc PR #18 CI crash (SIGSEGV in MakePhonemeList during
//  parallel test suites).
//
//  Lock order is always process mutex -> registry lock, never reverse.
//

import Foundation
import piper

final class EspeakProcessGate {
    static let shared = EspeakProcessGate()

    /// Serializes every espeak entry point: synthesize sessions, create,
    /// and last-one-out frees.
    private let processMutex = NSLock()

    /// Guards the live-handle registry and the deferred-free queue.
    private let registryMutex = NSLock()
    private var liveHandles: Set<OpaquePointer> = []
    private var deferredHandles: [OpaquePointer] = []

    /// Internal (not private) so unit tests can exercise an isolated
    /// gate instance instead of the process-wide shared one.
    init() {}

    // MARK: - Process mutex

    func lockProcess() {
        processMutex.lock()
    }

    func unlockProcess() {
        processMutex.unlock()
    }

    /// Runs `body` under the process mutex.
    func withProcessLock<T>(_ body: () -> T) -> T {
        processMutex.lock()
        defer { processMutex.unlock() }
        return body()
    }

    // MARK: - Registry

    /// Records a freshly created synthesizer. Called from
    /// Piper.makeSynthesizer on success, under the process mutex.
    func registerLive(_ handle: OpaquePointer) {
        registryMutex.lock()
        liveHandles.insert(handle)
        registryMutex.unlock()
    }

    var liveCount: Int {
        registryMutex.lock()
        defer { registryMutex.unlock() }
        return liveHandles.count
    }

    var deferredCount: Int {
        registryMutex.lock()
        defer { registryMutex.unlock() }
        return deferredHandles.count
    }

    /// Frees every deferred handle exactly once via `free`.
    /// Callers hold the process mutex and are either about to
    /// re-initialize espeak (create) or shutting down the last
    /// synthesizer, so the Terminates inside piper_free can break
    /// nothing.
    func drainDeferredFrees(free: (OpaquePointer) -> Void = { piper_free($0) }) {
        registryMutex.lock()
        let pending = deferredHandles
        deferredHandles.removeAll()
        registryMutex.unlock()
        for handle in pending {
            free(handle)
        }
    }

    /// The destroy path. Claims the handle exactly once, then:
    /// - other synthesizers still live: defer the free (a Terminate
    ///   now would break them; the next create drains it just before
    ///   re-initializing espeak);
    /// - last live synthesizer and the gate is free: drain any
    ///   deferred handles and free this one immediately;
    /// - last live synthesizer but a session is somehow active:
    ///   defer - correctness over promptness; a later create drains it.
    func destroy(_ handle: OpaquePointer,
                 free: (OpaquePointer) -> Void = { piper_free($0) }) {
        registryMutex.lock()
        guard liveHandles.remove(handle) != nil else {
            registryMutex.unlock()
            return // Already destroyed or never registered: no-op.
        }
        let isLast = liveHandles.isEmpty
        registryMutex.unlock()

        guard isLast else {
            registryMutex.lock()
            deferredHandles.append(handle)
            registryMutex.unlock()
            return
        }

        if processMutex.try() {
            drainDeferredFrees(free: free)
            free(handle)
            processMutex.unlock()
        } else {
            registryMutex.lock()
            deferredHandles.append(handle)
            registryMutex.unlock()
        }
    }
}

/// One Piper instance's hold on the process mutex across a synthesize
/// session. Only ever touched by the owning instance.
final class EspeakSessionLock {
    /// The gate this session belongs to. Piper instances always use the
    /// shared process gate; tests inject an isolated one.
    let gate: EspeakProcessGate

    private(set) var holds = false

    /// The thread that acquired the current hold; only it may release.
    private var ownerThread: Thread?

    init(gate: EspeakProcessGate = .shared) {
        self.gate = gate
    }

    /// Blocks until the process mutex is held by this session.
    /// Re-acquiring drops the previous hold first, so a session
    /// abandoned mid-utterance (cancel without draining) cannot wedge
    /// the process.
    func acquire() {
        release()
        gate.lockProcess()
        holds = true
        ownerThread = Thread.current
    }

    /// Acquires only when not already held; unlike acquire() it never
    /// opens a release/re-acquire window mid-utterance.
    func acquireIfNotHeld() {
        if !holds {
            acquire()
        }
    }

    /// Releases the hold. Safe to call when not held.
    func release() {
        guard holds else { return }
        gate.unlockProcess()
        holds = false
        ownerThread = nil
    }

    deinit {
        // Safety net, as in the Kotlin design. Normal flow releases via
        // doSynthesize's defer. Only unlock from the owning thread: an
        // executing synthesis retains the Piper (and thus this lock),
        // so a held lock here belongs to a live operation on its own
        // thread, which will release it.
        if holds, Thread.current === ownerThread {
            gate.unlockProcess()
            holds = false
            ownerThread = nil
        }
    }
}
