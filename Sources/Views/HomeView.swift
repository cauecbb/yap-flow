import SwiftUI
import SwiftData

/// The landing page: how much you've dictated, and what you said lately, by day.
struct HomeView: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \Transcript.createdAt, order: .reverse) private var transcripts: [Transcript]

    /// Home shows the latest stretch; the full list and search live in History.
    private static let recentLimit = 60

    var body: some View {
        let stats = DictationStats.make(from: transcripts)
        let recent = DayGroup.group(Array(transcripts.prefix(Self.recentLimit)), date: \.createdAt)

        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s6) {
                header
                statsGrid(stats)

                if transcripts.isEmpty {
                    emptyState
                } else {
                    VStack(alignment: .leading, spacing: Theme.s5) {
                        ForEach(recent) { group in
                            VStack(alignment: .leading, spacing: Theme.s2) {
                                SectionLabel(DayGroup<Transcript>.title(for: group.day))
                                Card(padding: Theme.s1) {
                                    VStack(spacing: 0) {
                                        ForEach(Array(group.items.enumerated()), id: \.element.id) { index, transcript in
                                            if index > 0 {
                                                Divider().overlay(Theme.hairline).padding(.horizontal, Theme.s3)
                                            }
                                            TimelineRow(transcript: transcript) {
                                                context.delete(transcript)
                                                try? context.save()
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        if transcripts.count > Self.recentLimit {
                            Button("See all \(transcripts.count) in History") { app.mainPage = .history }
                                .buttonStyle(GhostButtonStyle())
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.s6)
            .padding(.bottom, Theme.s6)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.s1) {
            Text(greeting)
                .font(.system(size: 24, weight: .semibold))
            Text(app.pushToTalkFn
                 ? "Hold fn and talk. Yap pastes it wherever you are."
                 : "Press your shortcut and talk. Yap pastes it wherever you are.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    private func statsGrid(_ stats: DictationStats) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: Theme.s3)], spacing: Theme.s3) {
            StatTile(
                icon: "text.word.spacing",
                value: stats.words.formatted(),
                label: stats.dictations == 1 ? "words in 1 dictation" : "words in \(stats.dictations.formatted()) dictations"
            )
            StatTile(
                icon: "speedometer",
                value: stats.wordsPerMinute.map { "\($0)" } ?? "–",
                label: "words per minute"
            )
            StatTile(
                icon: "flame",
                value: "\(stats.streakDays)",
                label: stats.streakDays == 1 ? "day in a row" : "days in a row"
            )
            StatTile(
                icon: "hourglass",
                value: DictationStats.formatMinutes(stats.minutesSaved),
                label: "saved vs typing"
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.s3) {
            Image(systemName: "waveform")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Nothing dictated yet")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            Text("What you say shows up here, grouped by day.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.s6 * 2)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let part = switch hour {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
        let firstName = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        return firstName.isEmpty ? part : "\(part), \(firstName)"
    }
}

private struct StatTile: View {
    let icon: String
    let value: String
    let label: String

    var body: some View {
        Card(padding: Theme.s4) {
            VStack(alignment: .leading, spacing: Theme.s2) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 22, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
    }
}

/// One dictation on the Home timeline: time on the left, what you said on the right.
private struct TimelineRow: View {
    let transcript: Transcript
    let onDelete: () -> Void

    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.s4) {
            Text(transcript.createdAt, format: .dateTime.hour().minute())
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 64, alignment: .leading)

            Text(transcript.text)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            HStack(spacing: Theme.s3) {
                Button(action: copy) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? Theme.success : .secondary)
                .help("Copy")

                Button(action: onDelete) {
                    Image(systemName: "trash").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Delete")
            }
            .opacity(hovering || copied ? 1 : 0)
        }
        .padding(.horizontal, Theme.s3)
        .padding(.vertical, Theme.s3)
        .background(hovering ? Theme.surfaceHover : .clear,
                    in: RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript.text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            copied = false
        }
    }
}
