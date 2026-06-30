#if canImport(UIKit)
import SwiftUI

// Icon geometry transcribed verbatim from the design SVGs so the rendered
// shapes match the source vectors exactly (rather than being approximated).

/// Microphone glyph (mic.svg, 36x36 viewBox).
struct MicShape: Shape {
    func path(in rect: CGRect) -> Path {
        let n: CGFloat = 36
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x / n * rect.width, y: rect.minY + y / n * rect.height)
        }
        var path = Path()
        path.move(to: p(17.9999, 9.66675))
        path.addCurve(to: p(13.8332, 13.8334), control1: p(15.6987, 9.66675), control2: p(13.8332, 11.5322))
        path.addLine(to: p(13.8332, 17.1667))
        path.addCurve(to: p(17.9999, 21.3334), control1: p(13.8332, 19.4679), control2: p(15.6987, 21.3334))
        path.addCurve(to: p(22.1666, 17.1667), control1: p(20.3011, 21.3334), control2: p(22.1666, 19.4679))
        path.addLine(to: p(22.1666, 13.8334))
        path.addCurve(to: p(17.9999, 9.66675), control1: p(22.1666, 11.5322), control2: p(20.3011, 9.66675))
        path.closeSubpath()
        
        path.move(to: p(12.8776, 20.0464))
        path.addCurve(to: p(11.7249, 19.801), control1: p(12.627, 19.6604), control2: p(12.111, 19.5505))
        path.addCurve(to: p(11.4795, 20.9537), control1: p(11.3388, 20.0516), control2: p(11.2289, 20.5676))
        path.addCurve(to: p(17.1666, 24.6241), control1: p(12.4158, 22.3966), control2: p(14.2053, 24.3154))
        path.addLine(to: p(17.1666, 25.5001))
        path.addCurve(to: p(17.9999, 26.3334), control1: p(17.1666, 25.9603), control2: p(17.5397, 26.3334))
        path.addCurve(to: p(18.8332, 25.5001), control1: p(18.4602, 26.3334), control2: p(18.8332, 25.9603))
        path.addLine(to: p(18.8332, 24.6241))
        path.addCurve(to: p(24.5203, 20.9537), control1: p(21.7945, 24.3154), control2: p(23.584, 22.3966))
        path.addCurve(to: p(24.2749, 19.801), control1: p(24.7709, 20.5676), control2: p(24.661, 20.0516))
        path.addCurve(to: p(23.1223, 20.0464), control1: p(23.8889, 19.5505), control2: p(23.3728, 19.6604))
        path.addCurve(to: p(17.9999, 23.0001), control1: p(22.2559, 21.3814), control2: p(20.6667, 23.0001))
        path.addCurve(to: p(12.8776, 20.0464), control1: p(15.3332, 23.0001), control2: p(13.7439, 21.3814))
        path.closeSubpath()
        return path
    }
}

/// Rounded 5-point star (Icon.svg, 32x32 viewBox).
struct RoundedStar: Shape {
    func path(in rect: CGRect) -> Path {
        let n: CGFloat = 32
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x / n * rect.width, y: rect.minY + y / n * rect.height)
        }
        var path = Path()
        path.move(to: p(15.0869, 2.90627))
        path.addCurve(to: p(16.9131, 2.90627), control1: p(15.4539, 2.14237), control2: p(16.5461, 2.14237))
        path.addLine(to: p(20.0712, 9.47956))
        path.addCurve(to: p(20.8524, 10.0439), control1: p(20.219, 9.78711), control2: p(20.5129, 9.99943))
        path.addLine(to: p(28.1186, 10.9952))
        path.addCurve(to: p(28.6826, 12.7262), control1: p(28.9634, 11.1058), control2: p(29.3013, 12.1428))
        path.addLine(to: p(23.3704, 17.7346))
        path.addCurve(to: p(23.0712, 18.6503), control1: p(23.1212, 17.9695), control2: p(23.0085, 18.3143))
        path.addLine(to: p(24.4053, 25.8059))
        path.addCurve(to: p(22.9281, 26.8761), control1: p(24.5606, 26.639), control2: p(23.6766, 27.2795))
        path.addLine(to: p(16.4819, 23.4012))
        path.addCurve(to: p(15.5181, 23.4012), control1: p(16.1813, 23.2392), control2: p(15.8187, 23.2392))
        path.addLine(to: p(9.0719, 26.876))
        path.addCurve(to: p(7.59474, 25.8059), control1: p(8.32343, 27.2795), control2: p(7.4394, 26.639))
        path.addLine(to: p(8.92882, 18.6503))
        path.addCurve(to: p(8.62958, 17.7346), control1: p(8.99146, 18.3143), control2: p(8.87881, 17.9695))
        path.addLine(to: p(3.31741, 12.7262))
        path.addCurve(to: p(3.88143, 10.9952), control1: p(2.69867, 12.1428), control2: p(3.03657, 11.1058))
        path.addLine(to: p(11.1476, 10.0439))
        path.addCurve(to: p(11.9288, 9.47956), control1: p(11.4871, 9.99943), control2: p(11.781, 9.78711))
        path.closeSubpath()
        return path
    }
}

/// Paper-plane glyph (Button.svg). Native coords are positioned relative to a
/// circle centered at (20, 19) with radius 18, so it maps onto a filled Circle.
struct PaperplaneShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = (rect.width / 2) / 18
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.midX + (x - 20) * s, y: rect.midY + (y - 19) * s)
        }
        var path = Path()
        path.move(to: p(14.6434, 26.664))
        path.addCurve(to: p(12.6176, 24.3538), control1: p(13.243, 27.1308), control2: p(11.9718, 25.6812))
        path.addLine(to: p(18.5015, 12.2591))
        path.addCurve(to: p(21.4989, 12.2591), control1: p(19.1096, 11.0091), control2: p(20.8908, 11.0091))
        path.addLine(to: p(27.3828, 24.3538))
        path.addCurve(to: p(25.357, 26.664), control1: p(28.0286, 25.6812), control2: p(26.7574, 27.1308))
        path.addLine(to: p(20.8334, 25.1561))
        path.addLine(to: p(20.8334, 21.5))
        path.addCurve(to: p(20, 20.6667), control1: p(20.8334, 21.0398), control2: p(20.4603, 20.6667))
        path.addCurve(to: p(19.1667, 21.5), control1: p(19.5398, 20.6667), control2: p(19.1667, 21.0398))
        path.addLine(to: p(19.1667, 25.1563))
        path.closeSubpath()
        return path
    }
}

/// Paperclip glyph (Button (1).svg, 36x36 viewBox). Fill with even-odd rule.
struct PaperclipShape: Shape {
    func path(in rect: CGRect) -> Path {
        let n: CGFloat = 36
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x / n * rect.width, y: rect.minY + y / n * rect.height)
        }
        var path = Path()
        path.move(to: p(17.1667, 12.5834))
        path.addCurve(to: p(20.0833, 9.66675), control1: p(17.1667, 10.9726), control2: p(18.4725, 9.66675))
        path.addCurve(to: p(23, 12.5834), control1: p(21.6942, 9.66675), control2: p(23, 10.9726))
        path.addLine(to: p(23, 21.3334))
        path.addCurve(to: p(18, 26.3334), control1: p(23, 24.0948), control2: p(20.7614, 26.3334))
        path.addCurve(to: p(13, 21.3334), control1: p(15.2386, 26.3334), control2: p(13, 24.0948))
        path.addLine(to: p(13, 15.5001))
        path.addCurve(to: p(13.8333, 14.6667), control1: p(13, 15.0398), control2: p(13.3731, 14.6667))
        path.addCurve(to: p(14.6667, 15.5001), control1: p(14.2936, 14.6667), control2: p(14.6667, 15.0398))
        path.addLine(to: p(14.6667, 21.3334))
        path.addCurve(to: p(18, 24.6667), control1: p(14.6667, 23.1744), control2: p(16.1591, 24.6667))
        path.addCurve(to: p(21.3333, 21.3334), control1: p(19.8409, 24.6667), control2: p(21.3333, 23.1744))
        path.addLine(to: p(21.3333, 12.5834))
        path.addCurve(to: p(20.0833, 11.3334), control1: p(21.3333, 11.8931), control2: p(20.7737, 11.3334))
        path.addCurve(to: p(18.8333, 12.5834), control1: p(19.393, 11.3334), control2: p(18.8333, 11.8931))
        path.addLine(to: p(18.8333, 20.5001))
        path.addCurve(to: p(18, 21.3334), control1: p(18.8333, 20.9603), control2: p(18.4602, 21.3334))
        path.addCurve(to: p(17.1667, 20.5001), control1: p(17.5398, 21.3334), control2: p(17.1667, 20.9603))
        path.closeSubpath()
        return path
    }
}

/// Phone handset glyph (Button (2).svg, 36x36 viewBox) for the start-call button.
struct PhoneShape: Shape {
    func path(in rect: CGRect) -> Path {
        let n: CGFloat = 36
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x / n * rect.width, y: rect.minY + y / n * rect.height)
        }
        var path = Path()
        
        path.move(to: p(13.0004, 10.5))
        path.addCurve(to: p(10.6095, 13.0996), control1: p(11.6513, 10.5), control2: p(10.4253, 11.6196))
        path.addCurve(to: p(22.9008, 25.3909), control1: p(11.4075, 19.5121), control2: p(16.4882, 24.5929))
        path.addCurve(to: p(25.5004, 23), control1: p(24.3807, 25.575), control2: p(25.5004, 24.349))
        path.addLine(to: p(25.5004, 21.9067))
        path.addCurve(to: p(23.7187, 19.5122), control1: p(25.5004, 20.8027), control2: p(24.7762, 19.8294))
        path.addLine(to: p(22.4432, 19.1295))
        path.addCurve(to: p(20.1021, 19.7197), control1: p(21.6137, 18.8806), control2: p(20.7145, 19.1073))
        path.addCurve(to: p(19.4132, 19.8438), control1: p(19.88, 19.9419), control2: p(19.5944, 19.9559))
        path.addCurve(to: p(16.1566, 16.5871), control1: p(18.0916, 19.026), control2: p(16.9744, 17.9088))
        path.addCurve(to: p(16.2806, 15.8983), control1: p(16.0445, 16.406), control2: p(16.0585, 16.1204))
        path.addCurve(to: p(16.8709, 13.5571), control1: p(16.893, 15.2859), control2: p(17.1197, 14.3867))
        path.addLine(to: p(16.4882, 12.2816))
        path.addCurve(to: p(14.0936, 10.5), control1: p(16.171, 11.2242), control2: p(15.1977, 10.5))
        path.addLine(to: p(13.0004, 10.5))
        path.closeSubpath()
        
        return path
    }
}

/// Rounded "stop" square for ending text chats (end-chat.svg, 36x36 viewBox).
struct EndChatSquareShape: Shape {
    func path(in rect: CGRect) -> Path {
        let n: CGFloat = 36
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x / n * rect.width, y: rect.minY + y / n * rect.height)
        }
        var path = Path()
        path.move(to: p(20.7011, 10.5))
        path.addLine(to: p(15.2989, 10.5))
        path.addCurve(to: p(13.6235, 10.5368), control1: p(14.6281, 10.5), control2: p(14.0745, 10.5))
        path.addCurve(to: p(12.32, 10.8633), control1: p(13.1551, 10.5751), control2: p(12.7245, 10.6572))
        path.addCurve(to: p(10.8633, 12.32), control1: p(11.6928, 11.1829), control2: p(11.1829, 11.6928))
        path.addCurve(to: p(10.5368, 13.6235), control1: p(10.6572, 12.7245), control2: p(10.5751, 13.1551))
        path.addCurve(to: p(10.5, 15.2989), control1: p(10.5, 14.0745), control2: p(10.5, 14.6281))
        path.addLine(to: p(10.5, 20.7011))
        path.addCurve(to: p(10.5368, 22.3765), control1: p(10.5, 21.3719), control2: p(10.5, 21.9255))
        path.addCurve(to: p(10.8633, 23.68), control1: p(10.5751, 22.8449), control2: p(10.6572, 23.2755))
        path.addCurve(to: p(12.32, 25.1367), control1: p(11.1829, 24.3072), control2: p(11.6928, 24.8171))
        path.addCurve(to: p(13.6235, 25.4632), control1: p(12.7245, 25.3428), control2: p(13.1551, 25.4249))
        path.addCurve(to: p(15.2989, 25.5), control1: p(14.0745, 25.5), control2: p(14.6281, 25.5))
        path.addLine(to: p(20.7011, 25.5))
        path.addCurve(to: p(22.3765, 25.4632), control1: p(21.3719, 25.5), control2: p(21.9255, 25.5))
        path.addCurve(to: p(23.68, 25.1367), control1: p(22.8449, 25.4249), control2: p(23.2755, 25.3428))
        path.addCurve(to: p(25.1367, 23.68), control1: p(24.3072, 24.8171), control2: p(24.8171, 24.3072))
        path.addCurve(to: p(25.4632, 22.3765), control1: p(25.3428, 23.2755), control2: p(25.4249, 22.8449))
        path.addCurve(to: p(25.5, 20.7011), control1: p(25.5, 21.9255), control2: p(25.5, 21.3719))
        path.addLine(to: p(25.5, 15.2989))
        path.addCurve(to: p(25.4632, 13.6235), control1: p(25.5, 14.6281), control2: p(25.5, 14.0745))
        path.addCurve(to: p(25.1367, 12.32), control1: p(25.4249, 13.1551), control2: p(25.3428, 12.7245))
        path.addCurve(to: p(23.68, 10.8633), control1: p(24.8171, 11.6928), control2: p(24.3072, 11.1829))
        path.addCurve(to: p(22.3765, 10.5368), control1: p(23.2755, 10.6572), control2: p(22.8449, 10.5751))
        path.addCurve(to: p(20.7011, 10.5), control1: p(21.9255, 10.5), control2: p(21.3719, 10.5))
        path.closeSubpath()
        return path
    }
}

#endif
