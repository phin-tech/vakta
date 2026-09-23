//
//  GitChangesTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for the file sidebar's Changes mode: parsing
//  `git status --porcelain=v1 -z`, scoping repo-relative paths to the
//  sidebar root, building the changed-files tree, and classifying the two
//  helper runs into an outcome. No git, no filesystem -- see
//  `GitStatusQueryShellTests` for the real repository.
//

import XCTest
@testable import Vakta

final class GitStatusParserTests: XCTestCase {
    private func z(_ records: String...) -> String {
        records.map { $0 + "\0" }.joined()
    }

    func test_emptyOutput_hasNoChanges() {
        XCTAssertEqual(GitStatusParser.parse(""), [])
    }

    func test_worktreeAndIndexModifications_areModified() {
        let changes = GitStatusParser.parse(z(" M a.txt", "M  b.txt", "MM c.txt", " T d.txt"))
        XCTAssertEqual(changes, [
            GitChange(path: "a.txt", kind: .modified),
            GitChange(path: "b.txt", kind: .modified),
            GitChange(path: "c.txt", kind: .modified),
            GitChange(path: "d.txt", kind: .modified),
        ])
    }

    func test_addedDeletedAndUntracked() {
        let changes = GitStatusParser.parse(z("A  new.swift", "AM staged-then-edited.swift", " D gone.txt", "D  staged-gone.txt", "?? scratch.md"))
        XCTAssertEqual(changes, [
            GitChange(path: "new.swift", kind: .added),
            GitChange(path: "staged-then-edited.swift", kind: .added),
            GitChange(path: "gone.txt", kind: .deleted),
            GitChange(path: "staged-gone.txt", kind: .deleted),
            GitChange(path: "scratch.md", kind: .untracked),
        ])
    }

    func test_rename_consumesTheOriginalPathRecord() {
        // -z writes a rename as "R  new\0old\0": the old path is its own
        // NUL-terminated field and must not become a second change.
        let changes = GitStatusParser.parse(z("R  renamed.txt", "a.txt", " M sub/b.txt"))
        XCTAssertEqual(changes, [
            GitChange(path: "renamed.txt", kind: .renamed),
            GitChange(path: "sub/b.txt", kind: .modified),
        ])
    }

    func test_copy_consumesTheSourceRecord_andReadsAsAdded() {
        let changes = GitStatusParser.parse(z("C  copy.txt", "orig.txt"))
        XCTAssertEqual(changes, [GitChange(path: "copy.txt", kind: .added)])
    }

    func test_unmergedPairs_areConflicted() {
        let changes = GitStatusParser.parse(z("UU a", "AA b", "DD c", "AU d", "UA e", "DU f", "UD g"))
        XCTAssertEqual(changes.map(\.kind), Array(repeating: .conflicted, count: 7))
        XCTAssertEqual(changes.map(\.path), ["a", "b", "c", "d", "e", "f", "g"])
    }

    func test_stagedAddOrRename_deletedFromTheWorktree_isDeleted() {
        // `git add f; rm f` is AD and `git mv a b; rm b` is RD: the file no
        // longer exists, so it must not read as openable added/renamed.
        let changes = GitStatusParser.parse(z("AD added.txt", "RD renamed.txt", "old.txt", " M kept.txt"))
        XCTAssertEqual(changes, [
            GitChange(path: "added.txt", kind: .deleted),
            GitChange(path: "renamed.txt", kind: .deleted),
            GitChange(path: "kept.txt", kind: .modified),
        ])
    }

    func test_nonUTF8Path_skipsOnlyThatRecord() {
        var data = Data(" M latin-".utf8) + Data([0xE9, 0])
        data += Data(" M ok.txt\0".utf8)
        XCTAssertEqual(GitStatusParser.parse(data), [GitChange(path: "ok.txt", kind: .modified)])
    }

    func test_nonUTF8RenameSource_isStillConsumed() {
        var data = Data("R  new.txt\0old-".utf8) + Data([0xE9, 0])
        data += Data(" M ok.txt\0".utf8)
        XCTAssertEqual(GitStatusParser.parse(data), [
            GitChange(path: "new.txt", kind: .renamed),
            GitChange(path: "ok.txt", kind: .modified),
        ])
    }

    func test_untrackedDirectory_isOneEntry_keepingItsTrailingSlash() {
        // Default untracked mode collapses a new directory (e.g. build/) to
        // one record instead of every file inside it.
        XCTAssertEqual(GitStatusParser.parse(z("?? build/")), [GitChange(path: "build/", kind: .untracked)])
    }

    func test_ignoredEntries_areDropped() {
        XCTAssertEqual(GitStatusParser.parse(z("!! build/", "?? keep.txt")), [GitChange(path: "keep.txt", kind: .untracked)])
    }

    func test_pathsWithSpacesAndArrows_areKeptVerbatim() {
        // -z disables quoting, so a name is exactly the bytes after "XY ".
        let changes = GitStatusParser.parse(z(" M My File -> x.txt"))
        XCTAssertEqual(changes, [GitChange(path: "My File -> x.txt", kind: .modified)])
    }

    func test_malformedShortRecord_isSkipped_withoutDroppingTheRest() {
        let changes = GitStatusParser.parse(z("M", " M ok.txt"))
        XCTAssertEqual(changes, [GitChange(path: "ok.txt", kind: .modified)])
    }

    func test_missingTrailingNUL_stillParsesTheLastRecord() {
        XCTAssertEqual(GitStatusParser.parse(" M a.txt"), [GitChange(path: "a.txt", kind: .modified)])
    }
}

final class GitChangeScopeTests: XCTestCase {
    private let changes = [
        GitChange(path: "README.md", kind: .modified),
        GitChange(path: "Sources/Vakta/App.swift", kind: .modified),
        GitChange(path: "Sources/VaktaExtra/x.swift", kind: .added),
        GitChange(path: "Tests/t.swift", kind: .untracked),
    ]

    func test_emptyPrefix_isTheRepositoryRoot_keepsEverything() {
        XCTAssertEqual(GitChangeScope.scoped(changes, toPrefix: ""), changes)
    }

    func test_subdirectoryPrefix_keepsOnlyItsChanges_relativeToIt() {
        XCTAssertEqual(
            GitChangeScope.scoped(changes, toPrefix: "Sources/Vakta/"),
            [GitChange(path: "App.swift", kind: .modified)]
        )
    }

    func test_prefixWithoutTrailingSlash_doesNotMatchASiblingWithTheSameStem() {
        XCTAssertEqual(
            GitChangeScope.scoped(changes, toPrefix: "Sources/Vakta"),
            [GitChange(path: "App.swift", kind: .modified)]
        )
    }
}

final class GitChangeTreeTests: XCTestCase {
    private func file(_ name: String, _ path: String, _ kind: GitChangeKind) -> GitChangeTreeNode {
        GitChangeTreeNode(name: name, path: path, content: .file(kind))
    }

    private func dir(_ name: String, _ path: String, _ children: [GitChangeTreeNode]) -> GitChangeTreeNode {
        GitChangeTreeNode(name: name, path: path, content: .directory(children))
    }

    func test_noChanges_isAnEmptyTree() {
        XCTAssertEqual(GitChangeTree.build([]), [])
    }

    func test_nestsFilesUnderTheirDirectories_directoriesFirst_caseInsensitive() {
        let tree = GitChangeTree.build([
            GitChange(path: "zeta.txt", kind: .modified),
            GitChange(path: "src/b.swift", kind: .added),
            GitChange(path: "Alpha.txt", kind: .untracked),
            GitChange(path: "src/A.swift", kind: .modified),
            GitChange(path: "docs/guide/intro.md", kind: .deleted),
        ])

        XCTAssertEqual(tree, [
            dir("docs", "docs", [
                dir("guide", "docs/guide", [file("intro.md", "docs/guide/intro.md", .deleted)]),
            ]),
            dir("src", "src", [
                file("A.swift", "src/A.swift", .modified),
                file("b.swift", "src/b.swift", .added),
            ]),
            file("Alpha.txt", "Alpha.txt", .untracked),
            file("zeta.txt", "zeta.txt", .modified),
        ])
    }

    func test_dotfilesAreShown_becauseTheirChangesMatter() {
        let tree = GitChangeTree.build([GitChange(path: ".github/ci.yml", kind: .modified)])
        XCTAssertEqual(tree, [dir(".github", ".github", [file("ci.yml", ".github/ci.yml", .modified)])])
    }

    func test_untrackedDirectory_isALeafNamedWithItsSlash_notAnExpandableFolder() {
        let tree = GitChangeTree.build([
            GitChange(path: "build/", kind: .untracked),
            GitChange(path: "src/gen/", kind: .untracked),
        ])
        XCTAssertEqual(tree, [
            dir("src", "src", [file("gen/", "src/gen/", .untracked)]),
            file("build/", "build/", .untracked),
        ])
    }

    func test_visibleRows_flattenDepthFirst_withDepths() {
        let tree = GitChangeTree.build([
            GitChange(path: "a/b/c.txt", kind: .modified),
            GitChange(path: "a/d.txt", kind: .added),
            GitChange(path: "e.txt", kind: .untracked),
        ])
        let rows = GitChangeTree.visibleRows(tree, collapsed: [])
        XCTAssertEqual(rows.map(\.node.path), ["a", "a/b", "a/b/c.txt", "a/d.txt", "e.txt"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 2, 1, 0])
    }

    func test_visibleRows_skipTheContentsOfCollapsedDirectories() {
        let tree = GitChangeTree.build([
            GitChange(path: "a/b/c.txt", kind: .modified),
            GitChange(path: "a/d.txt", kind: .added),
            GitChange(path: "e.txt", kind: .untracked),
        ])
        XCTAssertEqual(GitChangeTree.visibleRows(tree, collapsed: ["a/b"]).map(\.node.path), ["a", "a/b", "a/d.txt", "e.txt"])
        XCTAssertEqual(GitChangeTree.visibleRows(tree, collapsed: ["a"]).map(\.node.path), ["a", "e.txt"])
    }

    func test_directoryPaths_listEveryDirectoryInTheTree() {
        let tree = GitChangeTree.build([
            GitChange(path: "a/b/c.txt", kind: .modified),
            GitChange(path: "d/e.txt", kind: .modified),
            GitChange(path: "f.txt", kind: .modified),
        ])
        XCTAssertEqual(GitChangeTree.directoryPaths(in: tree), ["a", "a/b", "d"])
    }
}

final class GitStatusOutcomeTests: XCTestCase {
    private func ok(_ stdout: String) -> ProcessRawResult {
        ProcessRawResult(exitCode: 0, stdout: Data(stdout.utf8))
    }

    func test_notARepository_whenRevParseExits128() {
        XCTAssertEqual(GitStatusQuery.interpret(prefix: .nonZeroExit(128), status: nil), .notARepository)
    }

    func test_unavailable_whenGitIsMissingOrFails() {
        // `/usr/bin/env git` with no git on PATH exits 127.
        XCTAssertEqual(GitStatusQuery.interpret(prefix: .nonZeroExit(127), status: nil), .unavailable)
        XCTAssertEqual(GitStatusQuery.interpret(prefix: .launchFailed, status: nil), .unavailable)
        XCTAssertEqual(GitStatusQuery.interpret(prefix: .timedOut, status: nil), .unavailable)
    }

    func test_unavailable_whenStatusFailsAfterPrefixSucceeds() {
        XCTAssertEqual(GitStatusQuery.interpret(prefix: .success("\n"), status: ProcessRawResult(exitCode: 1)), .unavailable)
        XCTAssertEqual(GitStatusQuery.interpret(prefix: .success("\n"), status: ProcessRawResult(timedOut: true)), .unavailable)
        XCTAssertEqual(GitStatusQuery.interpret(prefix: .success("\n"), status: nil), .unavailable)
    }

    func test_changes_scopedByThePrefixLine() {
        let outcome = GitStatusQuery.interpret(
            prefix: .success("sub/\n"),
            status: ok(" M sub/b.txt\0 M top.txt\0")
        )
        XCTAssertEqual(outcome, .changes([GitChange(path: "b.txt", kind: .modified)]))
    }

    func test_changes_keepOnlyModifiedAndNewFiles() {
        // Deleted files and untracked directories (e.g. an un-ignored build/)
        // are noise in the sidebar: nothing to open, or thousands of files.
        let outcome = GitStatusQuery.interpret(
            prefix: .success("\n"),
            status: ok(" M edited.swift\0A  staged.swift\0?? new.swift\0R  moved.swift\0old.swift\0UU conflict.swift\0 D gone.swift\0D  staged-gone.swift\0?? build/\0")
        )
        XCTAssertEqual(outcome, .changes([
            GitChange(path: "edited.swift", kind: .modified),
            GitChange(path: "staged.swift", kind: .added),
            GitChange(path: "new.swift", kind: .untracked),
            GitChange(path: "moved.swift", kind: .renamed),
            GitChange(path: "conflict.swift", kind: .conflicted),
        ]))
    }

    func test_cleanRepository_isAnEmptyChangeList() {
        XCTAssertEqual(GitStatusQuery.interpret(prefix: .success("\n"), status: ok("")), .changes([]))
    }

    func test_prefix_dropsOnlyTheTerminatingNewline() {
        // A directory can be named "\nsub"; git prints "\nsub/\n".
        let outcome = GitStatusQuery.interpret(prefix: .success("\nsub/\n"), status: ok("A  \nsub/file\0"))
        XCTAssertEqual(outcome, .changes([GitChange(path: "file", kind: .added)]))
    }

    func test_nonUTF8Path_doesNotHideTheOtherChanges() {
        var stdout = Data(" M latin-".utf8) + Data([0xE9, 0])
        stdout += Data(" M ok.txt\0".utf8)
        let outcome = GitStatusQuery.interpret(prefix: .success("\n"), status: ProcessRawResult(exitCode: 0, stdout: stdout))
        XCTAssertEqual(outcome, .changes([GitChange(path: "ok.txt", kind: .modified)]))
    }
}
