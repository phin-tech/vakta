//
//  main.swift
//  kata-vakta
//
//  Entry point: `kata-vakta serve` speaks the Vakta Extension protocol on
//  stdio. See docs/extensions-plan.md in the Vakta repository.

import Foundation
import KataVaktaCore
import VaktaExtensionKit

guard CommandLine.arguments.dropFirst().first == "serve" else {
    FileHandle.standardError.write(Data("usage: kata-vakta serve\n".utf8))
    exit(64)
}

let connection = Connection()
let server = KataServer(connection: connection)
connection.run(server.handle)
