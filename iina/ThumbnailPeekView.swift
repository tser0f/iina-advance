//
//  ThumbnailPeekView.swift
//  iina
//
//  Created by lhc on 12/6/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Cocoa

class ThumbnailPeekView: NSView {

  @IBOutlet var imageView: NSImageView!

  override func awakeFromNib() {
    wantsLayer = true
    layer?.masksToBounds = true
    imageView.wantsLayer = true
    imageView.layer?.masksToBounds = true

    refreshColors()
  }

  func refreshBorderStyle() {
    guard let layer = self.layer else { return }

    let cornerRadius: CGFloat
    let style: Preference.ThumnailBorderStyle = Preference.enum(for: .thumbnailBorderStyle)
    switch style {
    case .plain:
      layer.borderWidth = 0
      layer.shadowRadius = 0
      cornerRadius = 0
    case .outlineSharpCorners:
      layer.borderWidth = outlineRoundedCornersWidth()
      layer.shadowRadius = 0
      cornerRadius = 0
    case .outlineRoundedCorners:
      layer.borderWidth = outlineRoundedCornersWidth()
      layer.shadowRadius = 0
      cornerRadius = roundedCornerRadius()
    case .shadowSharpCorners:
      layer.borderWidth = 0
      layer.shadowRadius = shadowRadius()
      cornerRadius = 0
    case .shadowRoundedCorners:
      layer.borderWidth = 0
      layer.shadowRadius = shadowRadius()
      cornerRadius = roundedCornerRadius()
    case .outlinePlusShadowSharpCorners:
      layer.borderWidth = outlineRoundedCornersWidth()
      layer.shadowRadius = shadowRadius()
      cornerRadius = 0
    case .outlinePlusShadowRoundedCorners:
      layer.borderWidth = outlineRoundedCornersWidth()
      layer.shadowRadius = shadowRadius()
      cornerRadius = roundedCornerRadius()
    }

    layer.cornerRadius = cornerRadius
    imageView.layer?.cornerRadius = cornerRadius
  }

  private func roundedCornerRadius() -> CGFloat {
    // Set corner radius to betwen 10 and 20
    return 10 + min(10, max(0, (frame.height - 400) * 0.01))
  }

  private func shadowRadius() -> CGFloat {
    // Set shadow radius to between 0 and 10 based on frame height
    // shadow is set in xib
    return min(10, 2 + (frame.height * 0.005))
  }

  private func outlineRoundedCornersWidth() -> CGFloat {
    return 1
  }

  func refreshColors() {
    guard let layer = self.layer else { return }

    layer.borderColor = CGColor(gray: 0.6, alpha: 0.5)

    if effectiveAppearance.isDark {
      layer.shadowColor = CGColor(gray: 1, alpha: 0.75)
    } else {
      layer.shadowColor = CGColor(gray: 0, alpha: 0.75)
    }
  }
}
