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
    let cornerRadius = CGFloat(Preference.float(for: .roundedCornerRadius))
    if cornerRadius > 0.0 {
      self.layer?.cornerRadius = cornerRadius
      self.layer?.masksToBounds = true
      self.imageView.wantsLayer = true
      self.imageView.layer?.cornerRadius = cornerRadius
      self.imageView.layer?.masksToBounds = true
    }
    // shadow is set in xib
    self.layer?.shadowRadius = 6
    self.layer?.borderWidth = 0
    refreshColors()
  }

  func refreshColors() {
    self.layer?.shadowColor = CGColor(gray: 0.7, alpha: 0.75)
    self.layer?.borderColor = CGColor(gray: 0.6, alpha: 0.5)
  }
}
