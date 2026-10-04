import SwiftUI

struct SessionDetailScreen: View {
    let item: SessionsStore.Item

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
            }

            Section("Источники") {
                if item.manifest.sources.isEmpty {
                    Text("Нет данных")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(item.manifest.sources, id: \.filename) { source in
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
