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
    self.wantsLayer = true
    self.imageView.wantsLayer = true
    refreshStyle()
    refreshColors()
  }

  func refreshStyle() {
    guard let layer = self.layer else { return }

    let cornerRadius = CGFloat(Preference.float(for: .roundedCornerRadius))
    if cornerRadius > 0.0 {
      layer.cornerRadius = cornerRadius
      layer.masksToBounds = true
      self.imageView.layer?.cornerRadius = cornerRadius
      self.imageView.layer?.masksToBounds = true
    } else {
      layer.masksToBounds = false
      self.imageView.layer?.masksToBounds = false
    }

    let style: Preference.ThumnailBorderStyle = Preference.enum(for: .thumbnailBorderStyle)
    switch style {
    case .none:
      layer.borderWidth = 0
      layer.shadowRadius = 0
    case .solidBorder:
      layer.borderWidth = 2
      layer.shadowRadius = 0
    case .shadowOrGlow:
      // shadow is set in xib
      layer.borderWidth = 0
      layer.shadowRadius = 6
    }
  }

  func refreshColors() {
    guard let layer = self.layer else { return }

    if effectiveAppearance.isDark {
      layer.shadowColor = CGColor(gray: 1, alpha: 0.7)
    } else {
      layer.shadowColor = CGColor(gray: 0, alpha: 0.75)
    }
    layer.borderColor = CGColor(gray: 0.6, alpha: 0.5)
  }
}
