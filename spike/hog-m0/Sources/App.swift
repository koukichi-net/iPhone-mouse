import SwiftUI

struct ContentView: View {
    @ObservedObject var peripheral: Peripheral

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(peripheral.header).font(.system(size: 13, weight: .semibold, design: .monospaced)).padding(.horizontal, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(peripheral.lines.enumerated()), id: \.offset) { i, line in
                            Text(line).font(.system(size: 9, design: .monospaced)).id(i)
                        }
                    }.padding(8)
                }
                .onChange(of: peripheral.lines.count) { _, n in
                    if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) }
                }
            }
        }
    }
}

@main
struct HOGM0App: App {
    @StateObject private var peripheral = Peripheral()

    var body: some Scene {
        WindowGroup {
            ContentView(peripheral: peripheral).onAppear { peripheral.start() }
        }
    }
}
