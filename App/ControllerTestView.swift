import SwiftUI
import Input

struct ControllerTestView: View {
    @Bindable var model: LibraryModel
    private var sample: ControllerSnapshot? { model.controllerTest.selected }
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Button test").font(Design.condensed(56))
                    Text(sample == nil ? "Connect a controller to see its buttons and sticks here." : "Press any button. Move both sticks and squeeze the triggers.")
                        .font(Design.body(26)).foregroundStyle(Design.secondary)
                }
                Spacer()
                HStack(spacing: 10) {
                    Circle().fill(sample == nil ? Design.muted : Design.green).frame(width: 10, height: 10)
                    Text(sample == nil ? "Waiting for controller" : "Connected").font(Design.body(22, weight: "Medium"))
                }.padding(.top, 14)
            }
            Rectangle().fill(Design.text.opacity(0.1)).frame(height: 1)
            HStack(alignment: .top, spacing: 56) {
                VStack(spacing: 12) {
                    PairingControllerArt(sample: sample, pairing: false).opacity(sample == nil ? 0.45 : 1)
                    Text(sample?.name ?? "No controller connected").font(Design.condensed(30)).lineLimit(1)
                    Text(model.connectedControllers.count > 1 ? "\(model.connectedControllers.count) connected · press a button to switch controller" : "Live input · controls light up as you use them")
                        .font(Design.body(20)).foregroundStyle(Design.secondary)
                }.frame(width: 700)
                VStack(alignment: .leading, spacing: 26) {
                    SectionLabel(text: "Analog sticks")
                    HStack(spacing: 40) {
                        StickReadout(title: "Left stick", value: sample?.leftStick ?? .init())
                        StickReadout(title: "Right stick", value: sample?.rightStick ?? .init())
                    }
                    SectionLabel(text: "Triggers").padding(.top, 8)
                    TriggerReadout(title: sample?.playStation == false ? "LT" : "L2", value: sample?.buttons[.leftTrigger] ?? 0)
                    TriggerReadout(title: sample?.playStation == false ? "RT" : "R2", value: sample?.buttons[.rightTrigger] ?? 0)
                }.frame(maxWidth: .infinity)
            }
            HStack(spacing: 12) {
                ForEach(ControllerControl.allCases.filter { sample?.buttons[$0] != nil }, id: \.self) { control in
                    let active = sample?.pressed.contains(control) == true
                    let tested = model.controllerTest.tested[sample?.id ?? ""]?.contains(control) == true
                    Text(control.label(playStation: sample?.playStation ?? true)).font(Design.body(19, weight: "SemiBold"))
                        .foregroundStyle(active ? Design.background : tested ? Design.text : Design.muted)
                        .padding(.horizontal, 12).frame(minWidth: 44, minHeight: 44)
                        .background(active ? Design.accent : Design.text.opacity(tested ? 0.12 : 0.04), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(tested && !active ? Design.text.opacity(0.2) : .clear))
                }
                if sample == nil { Text("Pair in macOS Bluetooth settings, then return here.").font(Design.body(24)).foregroundStyle(Design.secondary) }
            }.frame(height: 48)
            Rectangle().fill(Design.text.opacity(0.1)).frame(height: 1)
            HStack(spacing: 24) {
                if sample != nil {
                    LegendItem(glyph: sample?.playStation == false ? "B" : "○", title: "Hold to close")
                    ProgressTrack(value: model.controllerTest.closeProgress, height: 6).frame(width: 120)
                }
                if let last = model.controllerTest.lastInput { Text("Last input: \(last)").font(Design.body(22)).foregroundStyle(Design.secondary) }
                Spacer()
                Button { model.panel = nil } label: { LegendItem(glyph: "ESC", title: "Close") }.buttonStyle(.plain)
            }
        }.padding(48).frame(width: 1540).background(Design.panel, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Design.text.opacity(0.08)))
            .shadow(color: .black.opacity(0.7), radius: 60, y: 30)
    }
}

private struct StickReadout: View {
    let title: String
    let value: StickPosition
    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(Design.background)
                Circle().stroke(Design.text.opacity(0.12), lineWidth: 2)
                Rectangle().fill(Design.text.opacity(0.12)).frame(width: 1)
                Rectangle().fill(Design.text.opacity(0.12)).frame(height: 1)
                Circle().stroke(Design.text.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [3, 4])).frame(width: 40, height: 40)
                Circle().fill(Design.accent).frame(width: 18, height: 18)
                    .offset(x: CGFloat(value.x) * 68, y: -CGFloat(value.y) * 68)
            }.frame(width: 160, height: 160)
            Text(title).font(Design.body(22, weight: "Medium"))
            Text(String(format: "X %+.2f   Y %+.2f", value.x, value.y)).font(Design.body(18)).monospacedDigit().foregroundStyle(Design.secondary)
        }.frame(maxWidth: .infinity)
    }
}

private struct TriggerReadout: View {
    let title: String
    let value: Float
    var body: some View {
        HStack(spacing: 20) {
            Text(title).font(Design.body(22, weight: "Medium")).frame(width: 34)
            ProgressTrack(value: Double(value), height: 10)
            Text("\(Int(value * 100))%").font(Design.body(22)).monospacedDigit().foregroundStyle(Design.secondary).frame(width: 60, alignment: .trailing)
        }
    }
}
