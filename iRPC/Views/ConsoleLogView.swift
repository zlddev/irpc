//
//  ConsoleLogView.swift
//  iRPC
//
//  In-app stand-in for the Xcode console, for people running iRPC without a
//  Mac to plug the device into.
//

import SwiftUI

struct ConsoleLogView: View {
    @ObservedObject private var capture = ConsoleLogCapture.shared
    @State private var autoScroll = true
    @State private var filterText = ""
    @Environment(\.dismiss) private var dismiss

    private var filteredLines: [ConsoleLogCapture.LogLine] {
        guard !filterText.isEmpty else { return capture.lines }
        return capture.lines.filter { $0.text.localizedCaseInsensitiveContains(filterText) }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(filteredLines) { line in
                            Text(line.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(color(for: line.text))
                                .textSelection(.enabled)
                                .id(line.id)
                        }
                        // Anchor to scroll to when new lines arrive
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color.black.opacity(0.92))
                .onChange(of: capture.lines.count) { _, _ in
                    guard autoScroll else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .onAppear {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .searchable(text: $filterText, prompt: "Filter logs")
            .navigationTitle("Console")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        autoScroll.toggle()
                    } label: {
                        Image(systemName: autoScroll ? "arrow.down.circle.fill" : "arrow.down.circle")
                    }
                    .help("Auto-scroll")

                    ShareLink(item: capture.joinedText) {
                        Image(systemName: "square.and.arrow.up")
                    }

                    Button(role: .destructive) {
                        capture.clear()
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
    }

    private func color(for text: String) -> Color {
        if text.contains("❌") || text.contains("ERROR") {
            return .red
        } else if text.contains("⚠️") || text.contains("WARN") {
            return .yellow
        } else if text.contains("✅") {
            return .green
        }
        return .white.opacity(0.85)
    }
}
