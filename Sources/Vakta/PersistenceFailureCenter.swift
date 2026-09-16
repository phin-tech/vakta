//
//  PersistenceFailureCenter.swift
//  Vakta
//
//  Observes `.vaktaPersistedFileSaveFailed` (posted by every
//  `PersistedFileStore.save` failure -- see `PersistedFileStore.swift`) and
//  exposes the latest one for the Preferences window to show. Every store's
//  `save` call site discards its `FileSaveOutcome`, so without this a write
//  failure was previously indistinguishable from success anywhere the user
//  could see.

import Foundation

@MainActor
final class PersistenceFailureCenter: ObservableObject {
    @Published private(set) var latestMessage: String?

    private var observer: NSObjectProtocol?

    init() {
        // `queue: nil` delivers synchronously on the posting thread, rather
        // than asynchronously hopping onto `OperationQueue.main` -- every
        // `PersistedFileStore.save` call site is already on the main actor
        // (all stores are `@MainActor`), so this closure always runs there
        // too even though `NotificationCenter`'s API can't express that
        // statically. `assumeIsolated` documents that invariant instead of
        // adding an unstructured `Task { @MainActor in ... }` hop, which
        // would make `latestMessage` update asynchronously relative to the
        // failed save for no reason.
        observer = NotificationCenter.default.addObserver(
            forName: .vaktaPersistedFileSaveFailed,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let message = notification.userInfo?[PersistedFileSaveFailureUserInfoKey.message] as? String
            MainActor.assumeIsolated {
                self?.latestMessage = message
            }
        }
    }

    func dismiss() {
        latestMessage = nil
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
