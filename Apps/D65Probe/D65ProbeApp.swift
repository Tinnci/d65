import SwiftUI

@main
struct D65ProbeApp: App {
    var body: some Scene {
        WindowGroup {
            ProbeView()
        }
    }
}

struct ProbeView: View {
    @State private var status = "Not connected"

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sensor.tag.radiowaves.forward")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("D65 Probe")
                .font(.title2.weight(.semibold))
            Text("Measures the display and streams samples to the Mac. The probe holds no colour maths.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            Text(status)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding()
    }
}
