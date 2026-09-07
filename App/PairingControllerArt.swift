import SwiftUI
import Input

/// Code-native pairing illustration; the two buttons required for Bluetooth pairing are emphasized.
struct PairingControllerArt: View {
    var sample: ControllerSnapshot? = nil
    var pairing = true
    private func active(_ control: ControllerControl) -> Bool { sample?.pressed.contains(control) == true }
    private func fill(_ control: ControllerControl) -> Color { active(control) ? Design.accent : Design.background }
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
            RoundedRectangle(cornerRadius: 16).fill(active(.touchpad) ? Design.accent : Color(hex: 0x292724)).frame(width: 192, height: 108).overlay(RoundedRectangle(cornerRadius: 16).stroke(Design.text.opacity(0.12), lineWidth: 2)).position(x: 350, y: 139)
            Capsule().fill(Design.accent.opacity(0.8)).frame(width: 126, height: 5).shadow(color: Design.accent, radius: 16).position(x: 350, y: 78)
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(Design.background).frame(width: 25, height: 85)
                RoundedRectangle(cornerRadius: 5).fill(Design.background).frame(width: 85, height: 25)
                ForEach(Array([ControllerControl.up, .right, .down, .left].enumerated()), id: \.offset) { i, control in
                    let points = [CGPoint(x: 0, y: -29), CGPoint(x: 29, y: 0), CGPoint(x: 0, y: 29), CGPoint(x: -29, y: 0)]
                    RoundedRectangle(cornerRadius: 3).fill(active(control) ? Design.accent : .clear).frame(width: 22, height: 22).offset(x: points[i].x, y: points[i].y)
                }
            }.position(x: 171, y: 173)
            ForEach(0..<4) { index in
                let points = [CGPoint(x: 526, y: 130), CGPoint(x: 568, y: 173), CGPoint(x: 526, y: 216), CGPoint(x: 484, y: 173)]
                let control: ControllerControl = [.north, .east, .south, .west][index]
                ButtonSymbol(text: control.label(playStation: sample?.playStation ?? true), size: 21)
                    .foregroundStyle(active(control) ? Design.background : [Design.green, Design.red, Color(hex: 0x6CA4CF), Color(hex: 0xC280B3)][index])
                    .frame(width: 34, height: 34).background(fill(control), in: Circle()).position(points[index])
            }
            ForEach([272.0, 428.0], id: \.self) { x in
                let control: ControllerControl = x == 272 ? .leftStick : .rightStick
                let stick = x == 272 ? sample?.leftStick : sample?.rightStick
                Circle().fill(fill(control)).frame(width: 65, height: 65)
                    .overlay(Circle().stroke(Design.text.opacity(0.1), lineWidth: 5)).shadow(color: .black.opacity(0.7), radius: 8, y: 5).overlay(Circle().fill(Design.text.opacity(0.16)).frame(width: 42, height: 42).offset(x: CGFloat(stick?.x ?? 0) * 12, y: -CGFloat(stick?.y ?? 0) * 12)).position(x: x, y: 250)
            }
            Capsule().fill(pairing ? Design.accent : fill(.share)).frame(width: 15, height: 33).shadow(color: Design.accent.opacity(pairing || active(.share) ? 0.8 : 0), radius: 16).position(x: 230, y: 125)
            Capsule().fill(fill(.menu)).frame(width: 15, height: 33).position(x: 470, y: 125)
            Circle().fill(pairing ? Design.accent : fill(.home)).frame(width: 28, height: 28).overlay(Text("PS").font(Design.body(12, weight: "SemiBold")).foregroundStyle(pairing || active(.home) ? Design.background : Design.secondary)).shadow(color: Design.accent.opacity(pairing || active(.home) ? 0.7 : 0), radius: 16).position(x: 350, y: 250)
            if pairing {
            Text("SHARE").font(Design.body(18, weight: "SemiBold")).foregroundStyle(Design.accent).position(x: 218, y: 52)
            Path { path in path.move(to: CGPoint(x: 224, y: 69)); path.addLine(to: CGPoint(x: 230, y: 101)) }.stroke(Design.accent.opacity(0.8), lineWidth: 2)
            Text("PS").font(Design.body(18, weight: "SemiBold")).foregroundStyle(Design.accent).position(x: 350, y: 344)
            Path { path in path.move(to: CGPoint(x: 350, y: 273)); path.addLine(to: CGPoint(x: 350, y: 321)) }.stroke(Design.accent.opacity(0.8), lineWidth: 2)
            } else {
                ForEach(Array([ControllerControl.leftShoulder, .leftTrigger, .rightTrigger, .rightShoulder].enumerated()), id: \.offset) { i, control in
                    Text(control.label(playStation: sample?.playStation ?? true)).font(Design.body(20, weight: "SemiBold"))
                        .foregroundStyle(active(control) ? Design.background : Design.secondary)
                        .frame(width: 70, height: 36).background(fill(control), in: RoundedRectangle(cornerRadius: 8))
                        .position(x: [163.0, 246.0, 454.0, 537.0][i], y: 50)
                }
            }
        }.frame(width: 700, height: 410)
    }
}
