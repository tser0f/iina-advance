//
//  MPVVideoParams.swift
//  iina
//
//  Created by Matt Svoboda on 11/14/23.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

struct MPVVideoParams: CustomStringConvertible {
  /// Current video's native stored dimensions, before aspect correction applied.
  /// In most cases `videoDisplayWidth` and `videoDisplayHeight` will be more useful.
  /// From the mpv manual:
  /// ```
  /// width, height
  ///   Video size. This uses the size of the video as decoded, or if no video frame has been decoded yet,
  ///   the (possibly incorrect) container indicated size.
  /// ```
  let videoRawWidth: Int
  let videoRawHeight: Int

  /// The video size, with aspect correction applied, but before scaling or rotation.
  /// From the mpv manual:
  /// ```
  /// dwidth, dheight
  /// Video display size. This is the video size after filters and aspect scaling have been applied. The actual
  /// video window size can still be different from this, e.g. if the user resized the video window manually.
  /// These have the same values as video-out-params/dw and video-out-params/dh.
  /// ```
  let videoDisplayWidth: Int
  /// `dheight`:
  let videoDisplayHeight: Int

  /// `MPVProperty.videoParamsRotate`:
  let totalRotation: Int
  /// `MPVProperty.videoRotate`:
  let userRotation: Int

  var isWidthSwappedWithHeightByRotation: Bool {
    // 90, 270, etc...
    (userRotation %% 180) != 0
  }

  /// Like `dwidth`, but after applying `userRotation`.
  var videoDisplayRotatedWidth: Int {
    if isWidthSwappedWithHeightByRotation {
      return videoDisplayHeight
    } else {
      return videoDisplayWidth
    }
  }

  /// Like `dheight`, but after applying `userRotation`.
  var videoDisplayRotatedHeight: Int {
    if isWidthSwappedWithHeightByRotation {
      return videoDisplayWidth
    } else {
      return videoDisplayHeight
    }
  }

  var videoDisplayRotatedAspect: CGFloat {
    guard let videoBaseDisplaySize else { return 1 }
    return videoBaseDisplaySize.aspect
  }

  var videoBaseDisplaySize: CGSize? {
    let drW = videoDisplayRotatedWidth
    let drH = videoDisplayRotatedHeight
    if drW == 0 || drH == 0 {
      Logger.log("Failed to generate videoBaseDisplaySize: dwidth or dheight not present!", level: .error)
      return nil
    }
      return CGSize(width: drW, height: drH)
  }

  var description: String {
    return "MPVVideoParams:{rawSize:\(videoRawWidth)x\(videoRawHeight), dSize:\(videoDisplayWidth)x\(videoDisplayHeight), rotTotal: \(totalRotation), rotUser: \(userRotation)}"
  }
}
