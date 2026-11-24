import SwiftUI
import UIKit

/// Design tokens from prototype/index.html (light and dark).
enum Theme {
    static let surface    = dynamic(0xF6F8F8, 0x121A1D)
    static let card       = dynamic(0xFFFFFF, 0x1A2428)
    static let ink        = dynamic(0x1C2A30, 0xE5EDEF)
    static let muted      = dynamic(0x5B6B72, 0x93A4AA)
    static let line       = dynamic(0xDCE4E6, 0x2A383D)
    static let accent     = dynamic(0x2C6A77, 0x80C1CD)
    static let accentInk  = dynamic(0xFFFFFF, 0x0E1A1D)
    static let accentSoft = dynamic(0xDDEBEE, 0x1E3A40)
    static let gold       = dynamic(0xA97A22, 0xE2B865)
    static let goldSoft   = dynamic(0xF4E8CF, 0x3A301C)

    /// Category colors are stored as token names in the database ("pro", "per", "c4", ...).
    static func category(_ token: String) -> Color {
        switch token {
        case "pro": return dynamic(0x4A6EA3, 0x8EADDA)
        case "per": return dynamic(0xB0627A, 0xDE9CAE)
        case "phy": return dynamic(0x4F8757, 0x95C59B)
        case "c4":  return dynamic(0x7B66A8, 0xB6A3DF)
        case "c5":  return dynamic(0x2F8A84, 0x7FCBC4)
        case "c6":  return dynamic(0x9A7043, 0xD3AA7C)
        default:    return muted
        }
    }

    /// Daily thoughts use New York italic, the system serif.
    static let thoughtFont = Font.system(.title3, design: .serif).italic()

    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
