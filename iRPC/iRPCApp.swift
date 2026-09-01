//
//  iRPCApp.swift
//  iRPC
//
//  Created by Adrian Castro on 8/5/25.
//

import DiscordSocialKit
import SwiftData
import SwiftUI

@main
struct iRPCApp: App {
	let container: ModelContainer

	init() {
		// Start capturing stdout/stderr before anything else has a chance to
		// print, so the in-app console (Views/ConsoleLogView.swift) doesn't
		// miss the earliest logs.
		ConsoleLogCapture.shared.start()

		// BGTaskScheduler requires registration before the app finishes
		// launching — this is the backup keep-alive path for when the
		// silent-audio background session gets suspended.
		BackgroundController.shared.registerBackgroundTasks()

		do {
			let schema = Schema([DiscordTokenModel.self])
			let config = ModelConfiguration(
				schema: schema,
				isStoredInMemoryOnly: false,
				allowsSave: true
			)

			container = try ModelContainer(
				for: schema,
				configurations: config
			)
			print("✅ ModelContainer initialized for CloudKit sync")
		} catch {
			print("❌ Failed to initialize ModelContainer: \(error)")
			fatalError("Failed to initialize ModelContainer: \(error)")
		}
	}

	var body: some Scene {
		WindowGroup {
			ContentView()
		}
		.modelContainer(container)
	}
}
