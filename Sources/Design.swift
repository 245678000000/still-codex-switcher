import AppKit
import SwiftUI

enum Palette {
  static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
    Color(
      nsColor: NSColor(
        name: nil,
        dynamicProvider: { appearance in
          let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
          return NSColor(
            red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
        }))
  }
  static let background = adaptive(0xF8FAF9, 0x181E1B)
  static let sidebar = adaptive(0xEFF3F1, 0x202823)
  static let surface = adaptive(0xFFFFFF, 0x242D27)
  static let ink = adaptive(0x243C32, 0xE4EDE7)
  static let muted = adaptive(0x7A8C82, 0x98AA9D)
  static let line = adaptive(0xE1E8E3, 0x354039)
  static let accent = adaptive(0x326F54, 0x8EC5A1)
  static let accentWash = adaptive(0xE7F0E9, 0x30463A)
  static let button = adaptive(0x2E6049, 0xA5CFB2)
  static let buttonText = adaptive(0xFFFFFF, 0x1D3527)
  static func avatar(_ tone: Int) -> Color {
    switch tone % 4 {
    case 1: return adaptive(0x708A9A, 0x9DBBC9)
    case 2: return adaptive(0xAB8D67, 0xC7AE8D)
    case 3: return adaptive(0x958797, 0xBDAAC0)
    default: return accent
    }
  }
}

struct PressStyle: ButtonStyle {
  var primary = false
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .padding(.horizontal, primary ? 18 : 12).padding(.vertical, primary ? 12 : 9)
      .foregroundStyle(primary ? Palette.buttonText : Palette.ink)
      .background(
        primary ? Palette.button : Palette.surface, in: RoundedRectangle(cornerRadius: 11)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 11).stroke(primary ? .clear : Palette.line, lineWidth: 1)
      )
      .opacity(configuration.isPressed ? 0.82 : 1)
      .scaleEffect(configuration.isPressed ? 0.98 : 1)
  }
}
struct IconButton: View {
  let symbol: String
  let label: String
  var active = false
  var action: () -> Void
  @State private var hovering = false
  var body: some View {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 14, weight: .medium)).frame(
        width: 32, height: 32
      ).foregroundStyle(active ? Palette.accent : Palette.muted).background(
        hovering || active ? Palette.accentWash : .clear, in: RoundedRectangle(cornerRadius: 8))
    }
    .buttonStyle(.plain).onHover { hovering = $0 }.help(label).accessibilityLabel(label)
  }
}
struct AccountAvatar: View {
  let account: SavedAccount
  var size: CGFloat = 44
  var body: some View {
    Text(String(account.label.prefix(1)).uppercased()).font(.system(size: size * 0.4, weight: .medium, design: .rounded))
      .foregroundStyle(Palette.avatar(account.color)).frame(width: size, height: size)
      .background(Palette.avatar(account.color).opacity(0.11), in: RoundedRectangle(cornerRadius: size * 0.28))
  }
}
struct BrandMark: View {
  var size: CGFloat = 34
  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: size * 0.31).fill(Palette.button)
      HStack(spacing: size * 0.08) {
        Capsule().fill(Palette.buttonText).frame(width: size * 0.15, height: size * 0.45)
          .rotationEffect(.degrees(25)).offset(y: size * 0.035)
        Capsule().fill(Palette.buttonText.opacity(0.65)).frame(
          width: size * 0.15, height: size * 0.32
        ).rotationEffect(.degrees(25)).offset(y: -size * 0.05)
      }
    }.frame(width: size, height: size).accessibilityHidden(true)
  }
}
struct Shortcut: View {
  let text: String
  var body: some View {
    Text(text).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(
      Palette.muted
    ).padding(.horizontal, 6).padding(.vertical, 3).background(
      Palette.background.opacity(0.8), in: RoundedRectangle(cornerRadius: 4)
    ).overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.line, lineWidth: 0.5))
  }
}
struct Caption: View {
  let text: String
  var body: some View {
    Text(text).font(.system(size: 10, weight: .semibold)).tracking(1.4).foregroundStyle(
      Palette.muted)
  }
}
struct Hairline: View { var body: some View { Rectangle().fill(Palette.line).frame(height: 1) } }
