import SwiftUI

/// Code-native pairing illustration; the two buttons required for Bluetooth pairing are emphasized.
struct PairingControllerArt: View {
    var body: some View {
        ZStack {
            Path { path in
                path.move(to: CGPoint(x: 155, y: 95))
                path.addCurve(to: CGPoint(x: 75, y: 300), control1: CGPoint(x: 100, y: 100), control2: CGPoint(x: 78, y: 210))
                path.addCurve(to: CGPoint(x: 165, y: 355), control1: CGPoint(x: 62, y: 375), control2: CGPoint(x: 123, y: 395))
                path.addLine(to: CGPoint(x: 250, y: 275))
                path.addQuadCurve(to: CGPoint(x: 450, y: 275), control: CGPoint(x: 350, y: 303))
                path.addLine(to: CGPoint(x: 535, y: 355))
                path.addCurve(to: CGPoint(x: 625, y: 300), control1: CGPoint(x: 577, y: 395), control2: CGPoint(x: 638, y: 375))
                path.addCurve(to: CGPoint(x: 545, y: 95), control1: CGPoint(x: 622, y: 210), control2: CGPoint(x: 600, y: 100))
                path.addQuadCurve(to: CGPoint(x: 155, y: 95), control: CGPoint(x: 350, y: 60))
                path.closeSubpath()
            }.fill(LinearGradient(colors: [Color(hex: 0x46423D), Color(hex: 0x211F1C)], startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.65), radius: 30, y: 20)
            RoundedRectangle(cornerRadius: 16).fill(Color(hex: 0x292724)).frame(width: 192, height: 108).overlay(RoundedRectangle(cornerRadius: 16).stroke(Design.text.opacity(0.12), lineWidth: 2)).position(x: 350, y: 139)
            Capsule().fill(Design.accent.opacity(0.8)).frame(width: 126, height: 5).shadow(color: Design.accent, radius: 16).position(x: 350, y: 78)
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(Design.background).frame(width: 25, height: 85)
                RoundedRectangle(cornerRadius: 5).fill(Design.background).frame(width: 85, height: 25)
            }.position(x: 171, y: 173)
            ForEach(0..<4) { index in
                let points = [CGPoint(x: 526, y: 130), CGPoint(x: 568, y: 173), CGPoint(x: 526, y: 216), CGPoint(x: 484, y: 173)]
                Text(["△", "○", "✕", "□"][index]).font(Design.body(25, weight: "Medium"))
                    .foregroundStyle([Design.green, Design.red, Color(hex: 0x6CA4CF), Color(hex: 0xC280B3)][index])
                    .frame(width: 34, height: 34).background(Design.background.opacity(0.8), in: Circle()).position(points[index])
            }
            ForEach([272.0, 428.0], id: \.self) { x in
                Circle().fill(Color(hex: 0x12110F)).frame(width: 65, height: 65)
                    .overlay(Circle().stroke(Design.text.opacity(0.1), lineWidth: 5)).shadow(color: .black.opacity(0.7), radius: 8, y: 5).position(x: x, y: 250)
            }
            Capsule().fill(Design.accent).frame(width: 15, height: 33).shadow(color: Design.accent.opacity(0.8), radius: 16).position(x: 230, y: 125)
            Circle().fill(Design.accent).frame(width: 28, height: 28).overlay(Text("PS").font(Design.body(12, weight: "SemiBold")).foregroundStyle(Design.background)).shadow(color: Design.accent.opacity(0.7), radius: 16).position(x: 350, y: 250)
            Text("SHARE").font(Design.body(18, weight: "SemiBold")).foregroundStyle(Design.accent).position(x: 218, y: 52)
            Path { path in path.move(to: CGPoint(x: 224, y: 69)); path.addLine(to: CGPoint(x: 230, y: 101)) }.stroke(Design.accent.opacity(0.8), lineWidth: 2)
            Text("PS").font(Design.body(18, weight: "SemiBold")).foregroundStyle(Design.accent).position(x: 350, y: 344)
            Path { path in path.move(to: CGPoint(x: 350, y: 273)); path.addLine(to: CGPoint(x: 350, y: 321)) }.stroke(Design.accent.opacity(0.8), lineWidth: 2)
        }.frame(width: 700, height: 410)
    }
}
