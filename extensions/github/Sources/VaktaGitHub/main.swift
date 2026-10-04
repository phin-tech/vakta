//
//  main.swift
//  vakta-github
//
//  `vakta-github serve` speaks the Vakta Extension protocol on stdio. See
//  docs/github-extension-plan.md in the Vakta repository.

import Foundation

guard CommandLine.arguments.dropFirst().first == "serve" else {
    FileHandle.standardError.write(Data("usage: vakta-github serve\n".utf8))
    exit(64)
}

let connection = Connection()
let server = GitHubServer(connection: connection)
connection.run(server.handle)
