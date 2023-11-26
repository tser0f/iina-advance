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

  func refreshStyle() {
    guard let layer = self.layer else { return }

    let thumbnailHeight = frame.height

    // Set corner radius to betwen 10 and 20
    let cornerRadius: CGFloat
    if Preference.bool(for: .enableThumbnailRoundedCorners) {
      cornerRadius = 10 + min(10, max(0, (thumbnailHeight - 400) * 0.01))
    } else {
      cornerRadius = 0
    }
    layer.cornerRadius = cornerRadius
    imageView.layer?.cornerRadius = cornerRadius

    // Adjust border width based on frame height
    let style: Preference.ThumnailBorderStyle = Preference.enum(for: .thumbnailBorderStyle)
    switch style {
    case .none:
      layer.borderWidth = 0
      layer.shadowRadius = 0
    case .solidBorder:
      // Set border width to between 1 and 2 based on frame height
      let borderWidth: CGFloat
      switch thumbnailHeight {
      case 0..<1000:
        borderWidth = 1
      default:
        borderWidth = 2
      }
      layer.borderWidth = borderWidth
      layer.shadowRadius = 0
    case .shadowOrGlow:
      layer.borderWidth = 0
      // Set shadow radius to between 0 and 10 based on frame height
      // shadow is set in xib
      layer.shadowRadius = min(10, 2 + (thumbnailHeight * 0.005))
    }
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
