import AppKit
import OSLog
import SwiftUI

/// Reads the last ~100 `os_log` entries written under JellySleeve's subsystem
/// and renders them with a copy-to-clipboard helper (plan §6 Fase 6).
struct DiagnosticsTab: View {
    @State private var entries: [LogEntry] = []
    @State private var isLoading = false
    @State private var loadError: String?

    struct LogEntry: Identifiable, Sendable {
        let id: UUID
        let date: Date
        let category: String
        let level: String
        let message: String
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            list
        }
        .task { await reload() }
    }

    private var toolbar: some View {
        HStack {
            Button {
                Task { await reload() }
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .disabled(isLoading)

            Spacer()

            Text("\(entries.count) entries")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                copyAll()
            } label: {
                Label("Copy all", systemImage: "doc.on.clipboard")
            }
            .disabled(entries.isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var list: some View {
        if let loadError {
            ContentUnavailableView {
                Label("Couldn't read logs", systemImage: "exclamationmark.triangle")
            } description: {
                Text(loadError)
            }
        } else if isLoading && entries.isEmpty {
            VStack(spacing: 8) {
                ProgressView()
                Text("Reading os_log…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entries.isEmpty {
            ContentUnavailableView {
                Label("No log entries yet", systemImage: "tray")
            } description: {
                Text("JellySleeve writes to os_log under the subsystem software.trypwood.jellysleeve. As soon as something happens (a poll, a command, an error), it will show up here.")
                    .padding(.horizontal)
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(entries) { entry in
                        LogEntryRow(entry: entry)
                        Divider().opacity(0.4)
                    }
                }
            }
        }
    }

    // MARK: - Loading

    private func reload() async {
        isLoading = true
        loadError = nil
        do {
            entries = try await Self.readEntries()
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    /// Lifted onto a detached task because `OSLogStore.getEntries` is
    /// synchronous and can take a moment to walk the per-process buffer.
    private static func readEntries() async throws -> [LogEntry] {
        try await Task.detached(priority: .userInitiated) {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(timeIntervalSinceLatestBoot: 1)
            let entries = try store.getEntries(at: position)
            let mapped = entries
                .compactMap { $0 as? OSLogEntryLog }
                .filter { $0.subsystem == "software.trypwood.jellysleeve" }
                .suffix(100)
                .map { entry in
                    LogEntry(
                        id: UUID(),
                        date: entry.date,
                        category: entry.category,
                        level: Self.string(for: entry.level),
                        message: entry.composedMessage
                    )
                }
            return Array(mapped)
        }.value
    }

    nonisolated private static func string(for level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .notice: return "NOTICE"
        case .error: return "ERROR"
        case .fault: return "FAULT"
        case .undefined: return "—"
        @unknown default: return "—"
        }
    }

    // MARK: - Copy

    private func copyAll() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let text = entries.map { entry in
            "\(formatter.string(from: entry.date)) [\(entry.category)] \(entry.level) \(entry.message)"
        }.joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

private struct LogEntryRow: View {
    let entry: DiagnosticsTab.LogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(timestamp)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 78, alignment: .leading)
            Text(entry.category)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(entry.level)
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .foregroundStyle(levelColor)
                .frame(width: 56, alignment: .leading)
            Text(entry.message)
                .font(.caption)
                .lineLimit(3)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var timestamp: String {
        entry.date.formatted(date: .omitted, time: .standard)
    }

    private var levelColor: Color {
        switch entry.level {
        case "ERROR", "FAULT": return .red
        case "NOTICE": return .blue
        case "INFO": return .secondary
        default: return .secondary
        }
    }
}

#Preview {
    DiagnosticsTab()
        .frame(width: 520, height: 420)
}
