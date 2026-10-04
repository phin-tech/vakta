//
//  main.swift
//  vakta-github
//
//  Entry point: `vakta-github serve` speaks the Vakta Extension protocol on
//  stdio (through VaktaExtensionServer). See docs/github-extension-plan.md
//  in the Vakta repository.

import Foundation
import VaktaExtensionServer

guard CommandLine.arguments.dropFirst().first == "serve" else {
    FileHandle.standardError.write(Data("usage: vakta-github serve\n".utf8))
    exit(64)
}

let server = ExtensionServer(name: "GitHub")
let github = GitHubServer(server: server)
server.run()
