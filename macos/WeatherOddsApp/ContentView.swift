import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Weather Odds")
                        .font(.largeTitle.bold())
                    Text("An ensemble forecast that shows its confidence")
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "cloud.sun.rain.fill")
                    .font(.system(size: 44))
                    .symbolRenderingMode(.multicolor)
            }

            VStack(alignment: .leading, spacing: 14) {
                instruction(1, "Control-click the desktop and choose Edit Widgets.")
                instruction(2, "Find Weather Odds and add the size you prefer.")
                instruction(3, "Control-click the widget, choose Edit, and enter a US zip code.")
            }

            Divider()

            Text("Each widget has its own zip code and unit setting, so you can watch more than one city.")
                .fixedSize(horizontal: false, vertical: true)

            Link("Forecast data via Open-Meteo", destination: URL(string: "https://open-meteo.com")!)
                .font(.footnote)
        }
        .padding(32)
        .frame(width: 560)
    }

    private func instruction(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(.tint, in: Circle())
            Text(text)
        }
    }
}

#Preview {
    ContentView()
}
