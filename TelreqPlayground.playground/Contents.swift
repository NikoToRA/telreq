import SwiftUI
import PlaygroundSupport

@available(iOS 15.0, *)
struct TelreqDemo: View {
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Image(systemName: "phone.circle.fill")
                    .font(.system(size: 80))
                    .foregroundColor(.blue)
                
                Text("Telreq Demo")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                Text("iPhone電話自動文字起こし・要約アプリ")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                
                Button("通話開始デモ") {
                    print("通話開始")
                }
                .buttonStyle(.borderedProminent)
                
                Button("転写開始デモ") {
                    print("転写開始")
                }
                .buttonStyle(.borderedProminent)
                
                Spacer()
            }
            .padding()
            .navigationTitle("Telreq")
        }
    }
}

PlaygroundPage.current.setLiveView(TelreqDemo())