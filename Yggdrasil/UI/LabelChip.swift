import SwiftUI

/// Coloured chip for a single GitHub label. Background uses the label's hex
/// color at low alpha so dark + light themes both read.
struct LabelChip: View {
    let data: Data
    let scheme: ColorScheme

    struct Data: Hashable {
        let name: String
        let color: String
    }

    var body: some View {
        Text(data.name)
            .font(.system(size: 9.5, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(textColor)
            .background(
                Capsule().fill(parsedColor.opacity(0.22))
            )
            .overlay(
                Capsule().stroke(parsedColor.opacity(0.45), lineWidth: 0.5)
            )
    }

    private var parsedColor: Color {
        var hex: UInt64 = 0
        Scanner(string: data.color).scanHexInt64(&hex)
        let red = Double((hex >> 16) & 0xFF) / 255.0
        let green = Double((hex >> 8) & 0xFF) / 255.0
        let blue = Double(hex & 0xFF) / 255.0
        return Color(red: red, green: green, blue: blue)
    }

    private var textColor: Color {
        scheme == .dark ? Color.white.opacity(0.9) : Color.black.opacity(0.75)
    }
}
