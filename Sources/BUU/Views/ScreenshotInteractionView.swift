import AppKit
import SwiftUI

/// Displays a guest screenshot and maps clicks in the fitted image back to
/// guest pixel coordinates. This is for the external-VM screenshot fallback,
/// not host screen capture.
struct ScreenshotInteractionView: View {
    let image: NSImage
    let pixelSize: CGSize
    var onClick: (Int, Int) -> Void

    var body: some View {
        GeometryReader { proxy in
            let fitted = fittedSize(in: proxy.size)
            ZStack {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFit()
                    .frame(width: fitted.width, height: fitted.height)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                            .strokeBorder(Theme.Colors.separator, lineWidth: 1)
                    }
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture()
                    .onEnded { value in
                        let localX = value.location.x - (proxy.size.width - fitted.width) / 2
                        let localY = value.location.y - (proxy.size.height - fitted.height) / 2
                        guard localX >= 0, localY >= 0,
                              localX <= fitted.width, localY <= fitted.height,
                              fitted.width > 0, fitted.height > 0 else { return }
                        let x = Int((localX / fitted.width) * pixelSize.width)
                        let y = Int((localY / fitted.height) * pixelSize.height)
                        onClick(
                            min(max(x, 0), max(Int(pixelSize.width) - 1, 0)),
                            min(max(y, 0), max(Int(pixelSize.height) - 1, 0))
                        )
                    }
            )
        }
        .aspectRatio(pixelSize.width / max(pixelSize.height, 1), contentMode: .fit)
    }

    private func fittedSize(in available: CGSize) -> CGSize {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return available }
        let scale = min(available.width / pixelSize.width, available.height / pixelSize.height)
        return CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
    }
}
