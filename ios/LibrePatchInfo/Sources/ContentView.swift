import SwiftUI

struct ContentView: View {
    @StateObject private var reader = SensorReader()

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text(reader.status)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                if let r = reader.result {
                    VStack(alignment: .leading, spacing: 12) {
                        row("UID", r.uid)
                        row("UID (invertido)", r.uidReversed)
                        row("patchInfo", r.patchInfo)
                        row("Familia", r.family)
                        row("Generación", r.generation)
                        Divider()
                        Text(r.verdict).font(.footnote)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)

                    ShareLink(item: shareText(r)) {
                        Label("Compartir resultado", systemImage: "square.and.arrow.up")
                    }
                }

                Button {
                    reader.scan()
                } label: {
                    Label("Escanear sensor", systemImage: "wave.3.right.circle.fill")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .disabled(reader.isScanning)
                .padding(.horizontal)

                Spacer()
            }
            .padding(.top, 40)
            .navigationTitle("Libre patchInfo")
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(value).font(.system(.body, design: .monospaced)).textSelection(.enabled)
        }
    }

    private func shareText(_ r: SensorReader.Result) -> String {
        """
        LibreLibreLink — lectura de sensor
        UID: \(r.uid)
        UID invertido: \(r.uidReversed)
        patchInfo: \(r.patchInfo)
        Familia: \(r.family)
        Generación: \(r.generation)
        \(r.verdict)
        """
    }
}

#Preview { ContentView() }
