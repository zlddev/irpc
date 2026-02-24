//
//  ContentView.swift
//  iRPC
//
//  Created by Adrian Castro on 8/5/25.
//

import Combine
import DiscordSocialKit
import NowPlayingKit
import SwiftData
import SwiftUI
import MusicKit
import MusadoraKit

struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var hSizeClass

    @State private var nowPlaying = NowPlayingData(id: "", title: "Loading...", artist: "")
    @State private var lastPlayed: Song?
    @State private var isShowingLastPlayed = false
    @State private var isAuthorized = false
    @State private var isLoading = true
    @State private var isAuthenticating = false
    @State private var userEnabledRPC = false
    @State private var showRPCToggle = false
    @StateObject private var discord = DiscordManager(applicationId: 1_370_062_110_272_520_313)
    private let manager = NowPlayingManager.shared
    @State private var lastUpdateTime: TimeInterval = 0
    private let updateInterval: TimeInterval = 1
    @Environment(\.modelContext) private var modelContext
    @State private var isMusicCurrentlyPlaying = false
    @State private var playbackSubscription: AnyCancellable?
    @State private var onAppearExecuted = false
    @State private var connectionCheckTimer: AnyCancellable?
    @State private var forceConnectionRefresh = UUID()

    // Direct state tracking to force UI updates
    @State private var isDiscordAuthenticated = false
    @State private var isDiscordReady = false
    @State private var discordUsername: String? = nil
    @State private var showDebugInfo = false  // Toggle via toolbar menu

    private var timer: Publishers.Autoconnect<Timer.TimerPublisher> {
        Timer.publish(every: updateInterval, on: .main, in: .common).autoconnect()
    }

    enum ConnectionState: Equatable {
        case connecting
        case authenticating
        case connected(username: String?)
        case failed(error: String?)
        case disconnected

        static func == (lhs: ConnectionState, rhs: ConnectionState) -> Bool {
            switch (lhs, rhs) {
            case (.connecting, .connecting):
                return true
            case (.authenticating, .authenticating):
                return true
            case (.connected(let lhsUsername), .connected(let rhsUsername)):
                return lhsUsername == rhsUsername
            case (.failed(let lhsError), .failed(let rhsError)):
                return lhsError == rhsError
            case (.disconnected, .disconnected):
                return true
            default:
                return false
            }
        }
    }

    private var connectionState: ConnectionState {
        if discord.isAuthorizing || isAuthenticating || isLoading {
            return .connecting
        } else if isDiscordAuthenticated {
            if isDiscordReady {
                return .connected(username: discordUsername)
            } else {
                return .connecting
            }
        } else if let error = discord.errorMessage {
            return .failed(error: error)
        } else {
            return .disconnected
        }
    }

    private var shouldShowRPCToggle: Bool {
        discord.isAuthenticated && discord.isReady && (manager.isPlaying || userEnabledRPC)
    }

    // Adaptive navigation title that reflects the content
    private var navigationTitleText: String {
        if !isAuthorized {
            return "Welcome"
        }
        if manager.isPlaying, !nowPlaying.title.isEmpty, nowPlaying.title != "Loading..." {
            return nowPlaying.title
        }
        return "Apple Music"
    }

    var body: some View {
        NavigationStack {
            detailContent
                .navigationTitle(navigationTitleText)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
        }
        // Floating bottom capsule toggle — feels modern and stays reachable
        .safeAreaInset(edge: .bottom) {
            if shouldShowRPCToggle {
                HStack(spacing: 12) {
                    Image(systemName: userEnabledRPC ? "dot.radiowaves.left.and.right" : "dot.radiowaves.up.forward")
                        .imageScale(.large)
                        .symbolVariant(userEnabledRPC ? .fill : .none)
                        .foregroundStyle(userEnabledRPC ? .blue : .secondary)

                    Toggle("Rich Presence", isOn: $userEnabledRPC)
                        .onChange(of: userEnabledRPC) { _, isEnabled in
                            withAnimation(.easeInOut(duration: 0.25)) {
                                handleUserToggleRPC(enabled: isEnabled)
                            }
                        }
                        .labelsHidden()
                        .tint(.blue)

                    Text(userEnabledRPC ? "On" : "Off")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .monospacedDigit()
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
                .frame(maxWidth: 600)
                .background(.ultraThinMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 6)
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.snappy, value: shouldShowRPCToggle)
            }
        }
        .onChange(of: manager.isPlaying) { _, newValue in
            print("🎵 Music playing state changed: \(newValue)")
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.3)) {
                    showRPCToggle = shouldShowRPCToggle
                }

                if newValue {
                    print("▶️ Music started playing - updating UI and Discord")
                    if userEnabledRPC && discord.isAuthenticated && discord.isReady {
                        Task { await updateDiscordWithCurrentSong() }
                    }
                } else {
                    print("⏸️ Music stopped playing")
                    if userEnabledRPC && discord.isAuthenticated {
                        print("🛑 Clearing Discord presence")
                        discord.clearPlayback()
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: SystemMusicPlayer.playbackStateDidChangeNotification)) { _ in
            print("🎵📣 System Music Player state changed!")
            handleMusicPlaybackStateChange()
        }
        .task(id: "initializeMusic") {
            if isAuthorized {
                print("🎵 Initializing music display")
                await updateNowPlaying(forceRefresh: true)
            }
        }
        .task(priority: .high) {
            isLoading = true
            await MainActor.run {
                discord.setModelContext(modelContext)
            }

            let hasExistingToken = await checkExistingToken()
            if hasExistingToken {
                isAuthenticating = true
                await discord.setupWithExistingToken()
            }
            isLoading = false
        }
        .task {
            await requestAuthorization()
            if isAuthorized {
                print("🎵 Music access authorized")
                await updateNowPlaying(forceRefresh: true)
            }
            isLoading = false
        }
        .onReceive(timer) { _ in
            guard isAuthorized else { return }
            Task {
                await updatePlaybackTime()
            }
        }
        .onAppear {
            if !onAppearExecuted {
                onAppearExecuted = true
                DispatchQueue.main.async {
                    let isPlaying = manager.isPlaying
                    print("📱 Initial music state: \(isPlaying)")

                    withAnimation(.easeInOut(duration: 0.3)) {
                        showRPCToggle = discord.isAuthenticated &&
                                        discord.isReady &&
                                        (isPlaying || userEnabledRPC)
                    }

                    setupMusicStatusObservers()
                    setupConnectionMonitoring()
                }
            }
            handleMusicPlaybackStateChange()
        }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            updateTrackedDiscordState()
        }
    }

    // MARK: - Detail Content
    private var detailContent: some View {
        List {
            if !isAuthorized {
                Section {
                    AuthorizationView(requestAuthorization: requestAuthorization)
                        .frame(maxWidth: 700)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            } else {
                Section {
                    NowPlayingView(
                        nowPlaying: nowPlaying,
                        manager: manager,
                        isLastPlayed: isShowingLastPlayed
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden, edges: .all)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .animation(.snappy, value: nowPlaying.id)
                }
            }

            // Discord Status — keep row full width, center inner content, remove separator
            Section {
                HStack {
                    Spacer(minLength: 0)
                    VStack(spacing: 12) {
                        HStack(alignment: .center, spacing: 12) {
                            Image("Discord")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 24, height: 24)

                            ConnectionStatusView(
                                isAuthenticated: isDiscordAuthenticated,
                                isReady: isDiscordReady,
                                username: discordUsername
                            )
                            .animation(.snappy, value: isDiscordAuthenticated)
                            .animation(.snappy, value: isDiscordReady)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)

                        if showDebugInfo {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Auth: \(discord.isAuthenticated ? "✅" : "❌")")
                                    Text("Ready: \(discord.isReady ? "✅" : "❌")")
                                    Text("User: \(discord.username ?? "none")")
                                }
                                .font(.caption)
                                .padding(6)
                                .background(Color.gray.opacity(0.12))
                                .cornerRadius(6)
                                Spacer()
                            }
                            .transition(.opacity)
                            .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }
                    .frame(maxWidth: 400)
                    Spacer(minLength: 0)
                }
                .listRowInsets(EdgeInsets())
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden, edges: .all)
            } header: {
                Text("Discord Status")
                    .frame(maxWidth: .infinity, alignment: .center)
            } footer: {
                ConnectionFooterView(
                    isAuthenticated: isDiscordAuthenticated,
                    isReady: isDiscordReady,
                    isPlaying: manager.isPlaying,
                    showRPCToggle: shouldShowRPCToggle,
                    userEnabledRPC: userEnabledRPC
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .listRowSeparator(.hidden, edges: .all)
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(.compact)
        .listRowSeparator(.hidden, edges: .all)
        .refreshable {
            await updateNowPlaying(forceRefresh: true)
            updateTrackedDiscordState()
        }
    }

    // MARK: - Toolbar
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if discord.isAuthenticated {
                    Button {
                        discord.clearPlayback()
                    } label: {
                        Label("Clear Presence", systemImage: "xmark.circle")
                    }

                    Button {
                        isAuthenticating = true
                        discord.authorize()
                    } label: {
                        Label("Reconnect", systemImage: "arrow.clockwise")
                    }
                } else {
                    Button {
                        isAuthenticating = true
                        discord.authorize()
                    } label: {
                        Label("Connect Discord", systemImage: "person.badge.key.fill")
                    }
                }

                Divider()

                Toggle(isOn: $showDebugInfo) {
                    Label("Show Debug Info", systemImage: "ladybug")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    // MARK: - Observers and State
    private func setupMusicStatusObservers() {
        playbackSubscription?.cancel()

        playbackSubscription = manager.playbackStatePublisher
            .receive(on: RunLoop.main)
            .sink { isPlaying in
                print("🎹 Playback state publisher update: \(isPlaying)")
                self.isMusicCurrentlyPlaying = isPlaying
                self.handleMusicPlaybackStateChange()
            }

        print("🎧 Music status observers setup complete")
    }

    private func setupConnectionMonitoring() {
        connectionCheckTimer?.cancel()

        connectionCheckTimer = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                self.updateTrackedDiscordState()

                let shouldShow = self.shouldShowRPCToggle
                if self.showRPCToggle != shouldShow {
                    DispatchQueue.main.async {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            self.showRPCToggle = shouldShow
                        }
                    }
                }
            }

        print("🔌 Discord connection monitoring started")
    }

    private func updateTrackedDiscordState() {
        let authenticated = discord.isAuthenticated
        let ready = discord.isReady
        let username = discord.username

        if isDiscordAuthenticated != authenticated ||
            isDiscordReady != ready ||
            discordUsername != username {

            print("🔄 Discord state changed: Auth=\(authenticated) Ready=\(ready) User=\(username ?? "none")")

            isDiscordAuthenticated = authenticated
            isDiscordReady = ready
            discordUsername = username

            forceConnectionRefresh = UUID()
        }
    }

    private func handleMusicPlaybackStateChange() {
        let isCurrentlyPlaying = manager.isPlaying

        print("🎮 Handling music state change: \(isCurrentlyPlaying ? "playing" : "paused")")

        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.25)) {
                let shouldShow = self.discord.isAuthenticated &&
                                self.discord.isReady &&
                                (isCurrentlyPlaying || self.userEnabledRPC)

                self.showRPCToggle = shouldShow
            }

            if isCurrentlyPlaying {
                if self.userEnabledRPC && self.discord.isAuthenticated && self.discord.isReady {
                    Task { await self.updateDiscordWithCurrentSong() }
                }
            } else {
                if self.userEnabledRPC && self.discord.isAuthenticated {
                    self.discord.clearPlayback()
                }
            }

            Task { await self.updateNowPlaying() }
        }
    }

    private func updateToggleVisibility() {
        let shouldShow = shouldShowRPCToggle
        if showRPCToggle != shouldShow {
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.25)) {
                    self.showRPCToggle = shouldShow
                }
            }
        }
    }

    private func forceShowToggle() {
        guard discord.isAuthenticated && discord.isReady else {
            print("⚠️ Cannot show toggle - Discord not ready/authenticated")
            return
        }

        DispatchQueue.main.async {
            withAnimation(.easeInOut) {
                self.showRPCToggle = true
                print("🎯 Forcing toggle visibility to true")
            }
        }
    }

    private func checkMusicPlaybackState() {
        let isPlaying = manager.isPlaying

        print("🔎 Checking music state: \(isPlaying ? "playing" : "not playing")")

        let shouldShow = discord.isAuthenticated && discord.isReady && (isPlaying || userEnabledRPC)

        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.25)) {
                self.showRPCToggle = shouldShow

                if isPlaying && shouldShow && self.userEnabledRPC {
                    Task { await self.updateDiscordWithCurrentSong() }
                }
            }
        }
    }

    // MARK: - Data Updates
    private func updateNowPlaying(forceRefresh: Bool = false) async {
        guard isAuthorized else {
            print("⚠️ Music not authorized yet, skipping updateNowPlaying")
            return
        }

        if !manager.isPlaying {
            do {
                let recentSongs = try await MHistory.recentlyPlayedSongs(limit: 1)
                if let lastSong = recentSongs.first {
                    await MainActor.run {
                        print("🎵 No active playback, showing last played: \(lastSong.title)")
                        lastPlayed = lastSong
                        isShowingLastPlayed = true

                        nowPlaying = NowPlayingData(
                            id: lastSong.id.rawValue,
                            title: lastSong.title,
                            artist: lastSong.artistName,
                            album: lastSong.albumTitle,
                            artworkURL: lastSong.artwork?.url(width: 300, height: 300),
                            playbackTime: 0,
                            duration: lastSong.duration ?? 0
                        )

                        if userEnabledRPC && discord.isAuthenticated && discord.isReady {
                            if forceRefresh {
                                Task {
                                    try? await Task.sleep(nanoseconds: 500_000_000)
                                    discord.clearPlayback()
                                }
                            } else {
                                discord.clearPlayback()
                            }
                        }
                    }
                } else {
                    await showNoSongPlaying()
                }
            } catch {
                print("⚠️ Failed to get recently played: \(error.localizedDescription)")
                await showNoSongPlaying()
            }
            return
        }

        do {
            let newPlayback = try await manager.getCurrentPlayback()
            await MainActor.run {
                isShowingLastPlayed = false
                nowPlaying = newPlayback
                print("🎵 Now Playing updated: \(newPlayback.title)")

                if userEnabledRPC && discord.isAuthenticated && discord.isReady {
                    updateDiscordDirectly(with: newPlayback)
                }

                updateToggleVisibility()
            }
        } catch {
            print("⚠️ Error getting now playing: \(error.localizedDescription)")
            await showNoSongPlaying()
        }
    }

    private func showNoSongPlaying() async {
        await MainActor.run {
            isShowingLastPlayed = false
            nowPlaying = NowPlayingData(id: "", title: "No song playing", artist: "")

            if userEnabledRPC && discord.isAuthenticated {
                discord.clearPlayback()
            }
        }
    }

    private func updateDiscordDirectly(with playback: NowPlayingData) {
        discord.updateCurrentPlayback(
            id: playback.id,
            title: playback.title,
            artist: playback.artist,
            duration: playback.duration,
            currentTime: playback.playbackTime,
            artworkURL: playback.artworkURL
        )
    }

    private func updatePlaybackTime() async {
        do {
            let current = try await manager.getCurrentPlayback()
            await MainActor.run {
                nowPlaying = current

                if userEnabledRPC && discord.isAuthenticated && discord.isReady && manager.isPlaying {
                    updateDiscordDirectly(with: current)
                }
            }
        } catch {
        }
    }

    private func updateDiscordWithCurrentSong() async {
        do {
            guard manager.isPlaying else {
                print("⚠️ Not updating Discord - music not playing")
                return
            }

            let current = try await manager.getCurrentPlayback()
            await MainActor.run {
                print("🎮 Updating Discord with: \(current.title)")
                updateDiscordDirectly(with: current)
            }
        } catch {
            print("⚠️ Failed to update Discord: \(error.localizedDescription)")
        }
    }

    private func handleUserToggleRPC(enabled: Bool) {
        print("🎮 User toggled Discord RPC: \(enabled ? "ON" : "OFF")")

        if enabled {
            discord.startPresenceUpdates()
            if manager.isPlaying {
                Task { await updateDiscordWithCurrentSong() }
            }
            BackgroundController.shared.start()
        } else {
            discord.stopPresenceUpdates()
            BackgroundController.shared.stop()
        }
    }

    private func requestAuthorization() async {
        let status = await manager.authorize()
        isAuthorized = status == .authorized
    }

    private func checkExistingToken() async -> Bool {
        var descriptor = FetchDescriptor<DiscordToken>(
            sortBy: [SortDescriptor(\DiscordToken.expiresAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1

        do {
            if let token = try modelContext.fetch(descriptor).first {
                print("🔍 Found existing token with ID: \(token.tokenId)")
                return true
            }
            print("ℹ️ No existing token found")
            return false
        } catch {
            print("❌ Failed to check for existing token: \(error)")
            return false
        }
    }
}

extension View {
    fileprivate func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
