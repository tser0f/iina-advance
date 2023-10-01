//
//  CropBoxViewController.swift
//  iina
//
//  Created by lhc on 5/9/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Cocoa

/** The generic view controller of `CropBoxView`. */
class CropBoxViewController: NSViewController {

  weak var windowController: PlayWindowController!

  var cropx: Int = 0
  var cropy: Int = 0  // in flipped coord
  var cropw: Int = 0
  var croph: Int = 0

  var readableCropString: String {
    return "(\(cropx), \(cropy)) (\(cropw)\u{d7}\(croph))"
  }

  lazy var cropBoxView: CropBoxView = {
    let view = CropBoxView()
    view.settingsViewController = self
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  func selectedRectUpdated() {
    guard windowController.isInInteractiveMode else { return }
    let rect = cropBoxView.selectedRect
    updateCropValues(from: rect)
  }

  private func updateCropValues(from rect: NSRect) {
    cropx = Int(rect.minX)
    cropy = Int(CGFloat(windowController.player.info.videoRawHeight!) - rect.height - rect.minY)
    cropw = Int(rect.width)
    croph = Int(rect.height)
  }
}
