//
//  KonsoleApp.swift
//  Konsole
//
//  Created by kaito on 2026/09/25.
//

import SwiftUI

@main
struct KonsoleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The real settings window is managed by AppDelegate.
        Settings {
            EmptyView()
        }
    }
}
