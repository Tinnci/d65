import SwiftUI

@main
struct D65MacApp: App {
    @StateObject private var model = CalibrationViewModel()

    var body: some Scene {
        WindowGroup("D65") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 360, minHeight: 260)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Reset Correction") { model.reset() }
                    .keyboardShortcut("r")
            }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: CalibrationViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("D65")
                .font(.largeTitle.weight(.semibold))
            Text("White-point balance for external displays, measured by an iPhone probe.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("R").monospaced()
                    Text(model.gains.r, format: .number.precision(.fractionLength(4))).monospacedDigit()
                }
                GridRow {
                    Text("G").monospaced()
                    Text(model.gains.g, format: .number.precision(.fractionLength(4))).monospacedDigit()
                }
                GridRow {
                    Text("B").monospaced()
                    Text(model.gains.b, format: .number.precision(.fractionLength(4))).monospacedDigit()
                }
                if let deltaE = model.lastDeltaE {
                    GridRow {
                        Text("ΔE00").monospaced()
                        Text(deltaE, format: .number.precision(.fractionLength(2))).monospacedDigit()
                    }
                }
            }

            Text(model.status)
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                Button("Apply Demo Correction") { model.applyDemoCorrection() }
                Button("Reset") { model.reset() }
            }
        }
        .padding(24)
    }
}
