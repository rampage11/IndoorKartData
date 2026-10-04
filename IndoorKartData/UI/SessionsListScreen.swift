import SwiftUI

struct SessionsListScreen: View {
    @EnvironmentObject var sessionsStore: SessionsStore

    var body: some View {
        NavigationStack {
            Group {
                if sessionsStore.items.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(sessionsStore.items) { item in
                            NavigationLink {
                                SessionDetailScreen(item: item)
                            } label: {
                                SessionRow(item: item)
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                let url = sessionsStore.items[index].url
                                sessionsStore.delete(url: url)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Сессии")
            .refreshable {
                sessionsStore.reload()
            }
            .onAppear {
                sessionsStore.reload()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Записей ещё нет")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SessionRow: View {
    let item: SessionsStore.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.manifest.startedAt.formatted(
                    .dateTime.day().month().year().hour().minute()
                ))
                .font(.body)
                Spacer()
                Text(durationText)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(sourcesText(count: item.manifest.sources.count))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var durationText: String {
        guard let seconds = item.durationSeconds else { return "—" }
        let total = Int(seconds)
        let minutes = total / 60
        let secs = total % 60
        return String(format: "%02d:%02d", minutes, secs)
    }

    private func sourcesText(count: Int) -> String {
        // Склонение «источник / источника / источников» для русского интерфейса.
        let mod10 = count % 10
        let mod100 = count % 100
        let word: String
        if mod10 == 1 && mod100 != 11 {
            word = "источник"
        } else if (2...4).contains(mod10) && !(12...14).contains(mod100) {
            word = "источника"
        } else {
            word = "источников"
        }
        return "\(count) \(word)"
    }
}
