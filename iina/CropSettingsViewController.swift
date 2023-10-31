//
//  CropSettingsViewController.swift
//  iina
//
//  Created by lhc on 22/12/2016.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa

class CropSettingsViewController: CropBoxViewController {

  @IBOutlet weak var cropRectLabel: NSTextField!
  @IBOutlet weak var predefinedAspectSegment: NSSegmentedControl!

  override func viewDidLoad() {
    super.viewDidLoad()
  }

  override func viewDidAppear() {
    predefinedAspectSegment.selectedSegment = -1
  }

  override func selectedRectUpdated() {
    super.selectedRectUpdated()
    cropRectLabel.stringValue = readableCropString
    // FIXME: update predefinedAspectSegment selection
  }

  @IBAction func doneBtnAction(_ sender: AnyObject) {
    let player = windowController.player

    // Remove saved crop (if any)
    player.info.videoFiltersDisabled.removeValue(forKey: Constants.FilterLabel.crop)
    let isAllSelected = cropx == 0 && cropy == 0 && cropw == player.info.videoRawWidth && croph == player.info.videoRawHeight
    let isNoSelection = cropw == 0 || croph == 0

    if isAllSelected || isNoSelection {
      player.log.verbose("User chose Done button from interactive mode, but isAllSelected=\(isAllSelected.yn) isNoSelection=\(isNoSelection.yn). Setting crop to none")
      // if no crop, remove the crop filter
      if let vf = player.info.cropFilter {
        // Untested - not sure how well this will animate...
        _ = player.removeVideoFilter(vf)
      }
      windowController.exitInteractiveMode()
    } else {
      player.log.verbose("User chose Done button from interactive mode with new crop")
      cropBoxView.didSubmit = true

      /// Set the filter and wait for mpv to respond with a `video-reconfig` before exiting interactive mode
      let filter = MPVFilter.crop(w: self.cropw, h: self.croph, x: self.cropx, y: self.cropy)
      player.setCrop(fromFilter: filter)
    }
  }

  @IBAction func cancelBtnAction(_ sender: AnyObject) {
    let player = windowController.player
    if let prevCropFilter = player.info.videoFiltersDisabled[Constants.FilterLabel.crop] {
      /// Prev filter exists
      player.log.verbose("User chose Cancel button from interactive mode: restoring prev crop")
      cropBoxView.didSubmit = true
      // Remove saved crop (if any)
      player.info.videoFiltersDisabled.removeValue(forKey: Constants.FilterLabel.crop)

      let cropboxRect = prevCropFilter.cropRect(origVideoSize: cropBoxView.actualSize)
      cropw = Int(cropboxRect.width)
      croph = Int(cropboxRect.height)
      cropx = Int(cropboxRect.origin.x)
      cropy = Int(cropboxRect.origin.y)
      // Re-activate filter and wait for mpv to respond with a `video-reconfig` before exiting interactive mode
      player.setCrop(fromFilter: prevCropFilter)
      return
    } else {
      player.log.verbose("User chose Cancel button from interactive mode; exiting")
      // No prev filter.
      windowController.exitInteractiveMode()
    }
  }

  @IBAction func predefinedAspectValueAction(_ sender: NSSegmentedControl) {
    guard let str = sender.label(forSegment: sender.selectedSegment) else { return }
    guard let aspect = Aspect(string: str) else { return }

    let actualSize = cropBoxView.actualSize
    let croppedSize = actualSize.crop(withAspect: aspect)
    let cropped = NSMakeRect((actualSize.width - croppedSize.width) / 2,
                             (actualSize.height - croppedSize.height) / 2,
                             croppedSize.width,
                             croppedSize.height)

    cropBoxView.setSelectedRect(to: cropped)
  }

}
