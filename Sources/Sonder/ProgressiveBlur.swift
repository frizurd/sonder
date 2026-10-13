import AppKit
import SwiftUI

/// A blur whose strength eases from full at the top to none at the bottom, the way the system's soft
/// scroll edge blurs a list under its bar. The editor and Preview are AppKit and WebKit views, which
/// only get the system's hard edge, so they wear this instead.
///
/// It uses Core Animation's variable blur, the filter behind the system effect, inside a standard
/// effect view. If that filter is ever missing, a material fading out with the same curve stands in.
struct ProgressiveBlur: View {
    var body: some View {
        if VariableBlurView.isSupported {
            VariableBlurRepresentable()
        } else {
            Rectangle().fill(.ultraThinMaterial)
                .mask(LinearGradient(stops: ProgressiveBlur.fadeStops(from: .black), startPoint: .top, endPoint: .bottom))
        }
    }

    /// How strong the effect is at `t` (0 at the top, 1 at the bottom): it falls away quickly
    /// below the top and then trails off gently, so there is no visible edge where it ends.
    static func strength(at t: Double) -> Double {
        let remaining = 1 - min(max(t, 0), 1)
        return remaining * remaining
    }

    /// The same curve as gradient stops, for the tint over the blur.
    static func fadeStops(from color: Color, maxOpacity: Double = 1) -> [Gradient.Stop] {
        (0...12).map { i in
            let t = Double(i) / 12
            return .init(color: color.opacity(maxOpacity * strength(at: t)), location: t)
        }
    }
}

private struct VariableBlurRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> VariableBlurView { VariableBlurView() }
    func updateNSView(_ nsView: VariableBlurView, context: Context) {}
}

/// An effect view whose even blur is swapped for the variable one.
final class VariableBlurView: NSVisualEffectView {
    private static let filterClass = NSClassFromString("CAFilter") as? NSObject.Type

    static var isSupported: Bool {
        filterClass?.responds(to: NSSelectorFromString("filterWithType:")) == true
    }

    private let radius: CGFloat = 10
    private var maskHeight = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        blendingMode = .withinWindow
        material = .headerView
        state = .active
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        applyFilter()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The effect view builds its layers on its first display; adjust them right after.
        DispatchQueue.main.async { [weak self] in self?.applyFilter() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        DispatchQueue.main.async { [weak self] in self?.applyFilter() }
    }

    /// Swaps the effect view's even blur for the variable one and hides its fill and tint layers,
    /// so only the blur shows (the tint comes from a gradient over it).
    private func applyFilter() {
        guard let root = layer, let filterClass = Self.filterClass else { return }
        func all(_ l: CALayer) -> [CALayer] { [l] + (l.sublayers ?? []).flatMap(all) }
        for sub in all(root) where sub !== root {
            if String(describing: type(of: sub)).contains("Backdrop") {
                let pixelHeight = Int((bounds.height * (window?.backingScaleFactor ?? 2)).rounded())
                let filters = (sub.filters as? [NSObject]) ?? []
                if filters.count == 1, (filters[0].value(forKey: "type") as? String) == "variableBlur",
                   pixelHeight == maskHeight { continue }
                maskHeight = pixelHeight
                guard let blur = filterClass.perform(NSSelectorFromString("filterWithType:"), with: "variableBlur")?
                    .takeUnretainedValue() as? NSObject else { return }
                blur.setValue(radius, forKey: "inputRadius")
                blur.setValue(mask(pixelHeight: pixelHeight), forKey: "inputMaskImage")
                blur.setValue(true, forKey: "inputNormalizeEdges")
                sub.filters = [blur]
                // The effect view samples at a fraction of full size, which softens even the
                // unblurred bottom; the fade needs it crisp there.
                sub.setValue(1.0, forKey: "scale")
            } else if sub.sublayers == nil {
                sub.isHidden = true
            }
        }
    }

    /// Opaque at the top (full blur) easing to clear at the bottom (no blur). The filter maps the
    /// image pixel for pixel, so it is made at the view's exact height.
    private func mask(pixelHeight height: Int) -> CGImage? {
        guard height > 1, let context = CGContext(data: nil, width: 1, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return nil }
        for row in 0..<height {
            // Core Graphics counts rows from the bottom, so the last row is the top of the view.
            let t = Double(height - 1 - row) / Double(height - 1)
            context.setFillColor(gray: 0, alpha: ProgressiveBlur.strength(at: t))
            context.fill(CGRect(x: 0, y: row, width: 1, height: 1))
        }
        return context.makeImage()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
