//
//  MPVVideoParams.swift
//  iina
//
//  Created by Matt Svoboda on 11/14/23.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

/// `MPVVideoParams`: collection of metadata for the current video.Fetched from mpv.
///
/// Processing pipeline:
/// `videoRawSize` (`videoRawWidth`, `videoRawHeight`)
///   ➤ apply `aspectRatio`
///     ➤ `videoWithAspectOverrideSize`
///       ➤ apply crop
///         ➤ `videoDisplaySize` (`videoDisplayWidth`, `videoDisplayHeight`)
///           ➤ apply `totalRotation`
///             ➤ `videoDisplayRotatedSize` (`videoDisplayRotatedWidth`, `videoDisplayRotatedHeight`)
///               ➤ apply `videoScale`
struct MPVVideoParams: CustomStringConvertible {
  /// Current video's native stored dimensions, before aspect correction applied.
  /// From the mpv manual:
  /// ```
  /// width, height
  ///   Video size. This uses the size of the video as decoded, or if no video frame has been decoded yet,
  ///   the (possibly incorrect) container indicated size.
  /// ```
  let videoRawWidth: Int
  let videoRawHeight: Int

  /// The native size of the current video, before any filters, rotations, or other transformations applied
  var videoRawSize: CGSize {
    return CGSize(width: videoRawWidth, height: videoRawHeight)
  }

  /// Decimal number given by mpv with 6 digits after decimal.
  /// When comparing to other aspect ratio, use only the first 2 digits after decimal.
  let aspectRatio: String?

  /// Same as `videoRawSize` but with aspect ratio override applied. If no aspect ratio override, then identical to `videoRawSize`.
  var videoWithAspectOverrideSize: CGSize {
    let videoRawSize = videoRawSize
    let rawAspectDouble = videoRawSize.aspect
    guard let aspectRatio, let aspectRatioDouble = Double(aspectRatio),
            aspectRatioDouble.aspectNormalDecimalString != rawAspectDouble.aspectNormalDecimalString else {
      return videoRawSize
    }
    if rawAspectDouble > aspectRatioDouble {
      return CGSize(width: videoRawSize.width, height: round(videoRawSize.height * rawAspectDouble / aspectRatioDouble))
    }
    return CGSize(width: round(videoRawSize.width / rawAspectDouble * aspectRatioDouble), height: videoRawSize.height)
  }

  // dVideo

  /// The video size, with aspect override, crop and other filters applied, but before rotation or final scaling.
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

  var videoDisplaySize: CGSize {
    return CGSize(width: videoDisplayWidth, height: videoDisplayHeight)
  }

  /// `MPVProperty.videoParamsRotate`:
  let totalRotation: Int
  /// `MPVProperty.videoRotate`:
  let userRotation: Int

  var isWidthSwappedWithHeightByRotation: Bool {
    // 90, 270, etc...
    (totalRotation %% 180) != 0
  }

  // drVideo

  /// Like `dwidth`, but after applying `userRotation`.
  var videoDisplayRotatedWidth: Int {
    if isWidthSwappedWithHeightByRotation {
      return videoDisplayHeight
    } else {
      return videoDisplayWidth
    }
  }

  /// Like `dheight`, but after applying `totalRotation`.
  var videoDisplayRotatedHeight: Int {
    if isWidthSwappedWithHeightByRotation {
      return videoDisplayWidth
    } else {
      return videoDisplayHeight
    }
  }

  /// Like `videoDisplaySize`, but after applying `totalRotation`.
  var videoDisplayRotatedSize: CGSize? {
    let drW = videoDisplayRotatedWidth
    let drH = videoDisplayRotatedHeight
    if drW == 0 || drH == 0 {
      Logger.log("Failed to generate videoDisplayRotatedSize: dwidth or dheight not present!", level: .error)
      return nil
    }
      return CGSize(width: drW, height: drH)
  }

  var videoDisplayRotatedAspect: CGFloat {
    guard let videoDisplayRotatedSize else { return 1 }
    return videoDisplayRotatedSize.aspect
  }

  /// `MPVProperty.windowScale`:
  var videoScale: CGFloat

  // Etc

  var description: String {
    return "MPVVideoParams:{rawSize:\(videoRawWidth)x\(videoRawHeight), dSize:\(videoDisplayWidth)x\(videoDisplayHeight), rotTotal: \(totalRotation), rotUser: \(userRotation), scale: \(videoScale)}"
  }
}
