import CoreText
import SwiftUI

extension Font {
    /// Inter (Widget/Fonts/InterVariable.ttf, listed in UIAppFonts) at any weight from 100 to 900.
    /// The optical size axis stays at 14, the "text" design. Revolut ships the static Inter 3 fonts,
    /// which only have that design: at larger sizes its strokes are heavier and wider than Inter 4's
    /// automatic optical size.
    static func inter(size: CGFloat, weight: CGFloat) -> Font {
        let weightAxis = 0x7767_6874 // 'wght'
        let opticalSizeAxis = 0x6F70_737A // 'opsz'
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontNameAttribute: "InterVariable",
            kCTFontVariationAttribute: [weightAxis: weight, opticalSizeAxis: 14],
        ] as CFDictionary)
        return Font(CTFontCreateWithFontDescriptor(descriptor, size, nil))
    }
}
