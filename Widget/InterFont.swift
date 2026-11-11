import CoreText
import SwiftUI

extension Font {
    /// Inter (Widget/Fonts/InterVariable.ttf, listed in UIAppFonts) at any weight from 100 to 900.
    /// The variable font has a weight axis and an optical size axis. The optical size follows the
    /// point size, so large text uses the tighter "Display" shapes, as in the Revolut widget.
    static func inter(size: CGFloat, weight: CGFloat) -> Font {
        let weightAxis = 0x7767_6874 // 'wght'
        let opticalSizeAxis = 0x6F70_737A // 'opsz'
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontNameAttribute: "InterVariable",
            kCTFontVariationAttribute: [weightAxis: weight, opticalSizeAxis: size],
        ] as CFDictionary)
        return Font(CTFontCreateWithFontDescriptor(descriptor, size, nil))
    }
}
