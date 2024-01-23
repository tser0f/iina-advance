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

  private func animateHideCropSelection() {
    windowController.animationPipeline.submit(IINAAnimation.Task(duration: IINAAnimation.DefaultDuration * 0.5, { [self] in
      // Fade out cropbox selection rect
      cropBoxView.isHidden = true
      cropBoxView.alphaValue = 0
    }))
  }

  @IBAction func doneBtnAction(_ sender: AnyObject) {
    let player = windowController.player

    // Remove saved crop (if any)
    player.info.videoFiltersDisabled.removeValue(forKey: Constants.FilterLabel.crop)
    guard let totalWidth = player.info.videoRawWidth, let totalHeight = player.info.videoRawHeight else {
      player.log.error("User chose Done button from interactive mode, but could not original video size!")
      return
    }
    animateHideCropSelection()

    // Use <=, >= to account for imprecision
    let isAllSelected = cropx <= 0 && cropy <= 0 && cropw >= totalWidth && croph >= totalHeight
    let isNoSelection = cropw <= 0 || croph <= 0

    if isAllSelected || isNoSelection {
      player.log.verbose("User chose Done button from interactive mode, but isAllSelected=\(isAllSelected.yn) isNoSelection=\(isNoSelection.yn). Setting crop to none")
      // if no crop, remove the crop filter
      player.removeCrop()
      windowController.exitInteractiveMode()
    } else {
      player.log.verbose("User chose Done button from interactive mode with new crop")
      let newCropFilter = MPVFilter.crop(w: self.cropw, h: self.croph, x: self.cropx, y: self.cropy)

      /// Set the filter and wait for mpv to respond with a `video-reconfig` before exiting interactive mode
      cropBoxView.didSubmit = true
      player.setCrop(fromFilter: newCropFilter)
    }
  }

  @IBAction func cancelBtnAction(_ sender: AnyObject) {
    animateHideCropSelection()
    
    let player = windowController.player
    if let prevCropFilter = player.info.videoFiltersDisabled[Constants.FilterLabel.crop] {
      /// Prev filter exists. Re-apply it
      player.log.verbose("User chose Cancel button from interactive mode: restoring prev crop")
      let cropboxRect = prevCropFilter.cropRect(origVideoSize: cropBoxView.actualSize)
      /// Need to update these because they will be read when `video-reconfig` is received
      cropw = Int(cropboxRect.width)
      croph = Int(cropboxRect.height)
      cropx = Int(cropboxRect.origin.x)
      cropy = Int(cropboxRect.origin.y)

      // Remove filter from disabled list
      player.info.videoFiltersDisabled.removeValue(forKey: Constants.FilterLabel.crop)

      /// Re-activate filter and wait for mpv to respond with a `video-reconfig` before exiting interactive mode
      cropBoxView.didSubmit = true
      player.setCrop(fromFilter: prevCropFilter)
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
