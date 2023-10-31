//
//  CropBoxViewController.swift
//  iina
//
//  Created by lhc on 5/9/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Cocoa

/** The base class view controller of `CropBoxView`. */
class CropBoxViewController: NSViewController {

  weak var windowController: PlayerWindowController!

  var cropx: Int = 0
  var cropy: Int = 0  // in flipped coord (mpv)
  var cropw: Int = 0
  var croph: Int = 0
  var cropyFlippedForMac: Int = 0

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
    updateCropValues(from: cropBoxView.selectedRect)
  }

  private func updateCropValues(from selectedRect: NSRect) {
    var maxHeight = cropBoxView.actualSize.height
    if !maxHeight.isNormal {
      maxHeight = 0
    }
    let mpvY = maxHeight - (selectedRect.origin.y + selectedRect.height)

    cropx = Int(selectedRect.minX)
    cropy = Int(mpvY)
    cropw = Int(selectedRect.width)
    croph = Int(selectedRect.height)
    cropyFlippedForMac = Int(selectedRect.minY)
  }
}
