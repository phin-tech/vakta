//
//  RepoCheckout.swift
//  Vakta
//
//  A working directory's git checkout as Extension Contexts report it: the
//  work-tree root and current branch. (Pull request targeting now lives in
//  the GitHub Extension.)

import Foundation

struct RepoCheckout: Equatable {
    let root: String
    /// nil when HEAD is detached.
    let branch: String?
}
