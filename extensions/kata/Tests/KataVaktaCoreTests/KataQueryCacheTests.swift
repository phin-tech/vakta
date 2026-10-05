//
//  KataQueryCacheTests.swift
//  KataVaktaCoreTests

import XCTest
@testable import KataVaktaCore

final class KataQueryCacheTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func loaded(project: Int, _ ids: [String]) -> KataQueryCache.Value {
        .loaded(open: ids.map {
            KataIssue(shortID: $0, projectID: project, title: $0, status: "open", priority: 1, owner: nil, labels: [], body: nil, parent: nil)
        }, readyIDs: Set(ids))
    }

    func test_storedValues_areServedUntilTheyExpire() {
        var cache = KataQueryCache(ttl: 30)
        cache.store(loaded(project: 5, ["a"]), for: "/vakta", at: t0)
        XCTAssertEqual(cache.value(for: "/vakta", at: t0.addingTimeInterval(29)), loaded(project: 5, ["a"]))
        XCTAssertNil(cache.value(for: "/vakta", at: t0.addingTimeInterval(30)))
        XCTAssertNil(cache.value(for: "/other", at: t0))
    }

    func test_invalidateProject_dropsOnlyThatProjectsWorkspaces() {
        var cache = KataQueryCache()
        cache.store(loaded(project: 5, ["a"]), for: "/vakta", at: t0)
        cache.store(loaded(project: 5, ["a"]), for: "/vakta/worktree", at: t0)
        cache.store(loaded(project: 7, ["b"]), for: "/tanker", at: t0)
        cache.store(.notInitialized, for: "/tmp", at: t0)

        cache.invalidate(projectID: 5)

        XCTAssertNil(cache.value(for: "/vakta", at: t0))
        XCTAssertNil(cache.value(for: "/vakta/worktree", at: t0))
        XCTAssertEqual(cache.value(for: "/tanker", at: t0), loaded(project: 7, ["b"]))
        XCTAssertEqual(cache.value(for: "/tmp", at: t0), .notInitialized)
    }

    func test_invalidateAll() {
        var cache = KataQueryCache()
        cache.store(loaded(project: 5, ["a"]), for: "/vakta", at: t0)
        cache.invalidateAll()
        XCTAssertNil(cache.value(for: "/vakta", at: t0))
    }
}
