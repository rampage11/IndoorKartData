import SwiftUI

struct SessionDetailScreen: View {
    let item: SessionsStore.Item
    @State private var effectiveSources: [DataSourceEntry] = []

    var body: some View {
        List {
            Section("Информация") {
                infoRow(label: "ID", value: String(item.manifest.id.uuidString.prefix(8)))
                infoRow(
                    label: "Начало",
                    value: item.manifest.startedAt.formatted(
                        .dateTime.day().month().year().hour().minute().second()
                    )
                )
                if let endedAt = item.manifest.endedAt {
                    infoRow(
                        label: "Конец",
                        value: endedAt.formatted(
                            .dateTime.day().month().year().hour().minute().second()
                        )
                    )
                } else {
                    infoRow(label: "Конец", value: "—")
                }
                infoRow(label: "Устройство", value: item.manifest.deviceName)
                infoRow(label: "Модель", value: item.manifest.deviceModel)
                infoRow(label: "Версия", value: item.manifest.appVersion)
                if let kart = item.manifest.kartNumber {
                    infoRow(label: "Карт", value: "\(kart)")
                }
            }

            Section("Источники") {
                if effectiveSources.isEmpty {
                    Text("Нет данных")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(effectiveSources, id: \.filename) { source in
                        SourceRow(sessionURL: item.url, entry: source)
                    }
                }
            }

            Section {
                ShareLink(
                    item: SessionArchive(sessionURL: item.url),
                    preview: SharePreview(
                        "Сессия \(String(item.manifest.id.uuidString.prefix(8)))",
                        image: Image(systemName: "doc.zipper")
                    )
                ) {
                    Label("Поделиться как .zip", systemImage: "square.and.arrow.up")
                }
            } footer: {
                Text("Папка сессии будет упакована в .zip и отправлена через AirDrop, Files или iCloud.")
            }
        }
        .navigationTitle("Сессия")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Heal manifest at view time: watch-файлы часто прилетают через
            // transferFile ПОСЛЕ стопа и не попадают в manifest. UI сканирует
            // диск и дописывает их в manifest если надо.
            if let healed = try? SessionStorage.shared.healManifest(sessionURL: item.url) {
                effectiveSources = healed.sources
            } else {
                effectiveSources = SessionStorage.shared.effectiveSources(
                    for: item.url,
                    manifestSources: item.manifest.sources
                )
            }
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct SourceRow: View {
    let sessionURL: URL
    let entry: DataSourceEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.filename)
                    .font(.body.monospaced())
                Spacer()
                Text(sizeText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(entry.format)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var sizeText: String {
        let fileURL = sessionURL.appendingPathComponent(entry.filename)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let size = attrs[.size] as? NSNumber {
            return ByteCountFormatter.string(fromByteCount: size.int64Value, countStyle: .file)
        }
        return "—"
    }
}
