import SwiftUI

struct KartNumberPickerScreen: View {
    @EnvironmentObject private var controller: WatchRecordingController
    @Environment(\.dismiss) private var dismiss

    // Локальный буфер: применяем только по кнопке «Готово», чтобы крутилка
    // не слала событие на каждый тик — а сразу «готовое» значение.
    @State private var selection: Double = 1

    var body: some View {
        VStack(spacing: 8) {
            Text("Номер карта")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text("\(Int(selection))")
                .font(.system(size: 64, weight: .bold, design: .rounded).monospacedDigit())
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .focusable()
                .digitalCrownRotation(
                    $selection,
                    from: 1,
                    through: 99,
                    by: 1,
                    sensitivity: .medium,
                    isContinuous: false,
                    isHapticFeedbackEnabled: true
                )

            Button {
                controller.kartNumber = Int(selection)
                dismiss()
            } label: {
                Text("Готово")
                    .font(.footnote.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
        }
        .padding(.horizontal, 4)
        .onAppear {
            // Если номер ещё не задан — стартуем с 1, иначе — с текущего.
            let stored = controller.kartNumber
            selection = stored >= 1 ? Double(stored) : 1
        }
    }
}

#Preview {
    KartNumberPickerScreen()
        .environmentObject(WatchRecordingController())
}
