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
/// `videoSizeRaw` (`videoRawWidth`, `videoRawHeight`)
///   ➤ apply `aspectRatioOverride`
///     ➤ `videoSizeA`
///       ➤ apply `cropBox`
///         ➤ `videoSizeAC` (`videoWidthAC`, `videoHeightAC`). AKA "dsize", per mpv usage
///           ➤ apply `totalRotation`
///             ➤ `videoSizeACR` (`videoWidthACR`, `videoHeightACR`)
///               ➤ apply `videoScale`
///                 ➤ `videoSize` (`WinGeometry`)
struct MPVVideoParams: CustomStringConvertible {
  static let nullParams = MPVVideoParams(videoRawWidth: 0, videoRawHeight: 0, 
                                         selectedAspectRatioLabel: "",
                                         totalRotation: 0, userRotation: 0,
                                         selectedCropLabel: AppData.cropNone, cropBox: nil,
                                         videoScale: 0)

  init(videoRawWidth: Int, videoRawHeight: Int, 
       selectedAspectRatioLabel: String,
       totalRotation: Int, userRotation: Int,
       selectedCropLabel: String, cropBox: CGRect?, 
       videoScale: CGFloat) {
    self.videoRawWidth = videoRawWidth
    self.videoRawHeight = videoRawHeight
    if let aspectRatioOverride = Aspect(string: selectedAspectRatioLabel) {
      self.selectedAspectRatioLabel = selectedAspectRatioLabel
      self.aspectRatioOverride = Aspect.mpvPrecision(of: aspectRatioOverride.value)
    } else {
      self.selectedAspectRatioLabel = AppData.defaultAspectName
      self.aspectRatioOverride = nil
    }
    self.totalRotation = totalRotation
    self.userRotation = userRotation
    self.selectedCropLabel = selectedCropLabel
    self.cropBox = cropBox
    self.videoScale = videoScale
  }

  func clone(videoRawWidth: Int? = nil, videoRawHeight: Int? = nil,
             selectedAspectRatioLabel: String? = nil,
             totalRotation: Int? = nil, userRotation: Int? = nil,
             selectedCropLabel: String? = nil, cropBox: CGRect? = nil,
             videoScale: CGFloat? = nil) -> MPVVideoParams {
    return MPVVideoParams(videoRawWidth: videoRawWidth ?? self.videoRawWidth, videoRawHeight: videoRawHeight ?? self.videoRawHeight,
                          selectedAspectRatioLabel: selectedAspectRatioLabel ?? self.selectedAspectRatioLabel,
                          totalRotation: totalRotation ?? self.totalRotation, userRotation: userRotation ?? self.userRotation,
                          selectedCropLabel: selectedCropLabel ?? self.selectedCropLabel, cropBox: cropBox ?? self.cropBox,
                          videoScale: videoScale ?? self.videoScale)

  }

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
  var videoSizeRaw: CGSize {
    return CGSize(width: videoRawWidth, height: videoRawHeight)
  }

  // Aspect

  /// The currently applied aspect, used for finding current aspect in menu & sidebar segmented control. Does not include rotation(s)
  let selectedAspectRatioLabel: String

  /// Truncates aspect to the first 2 digits after decimal.
  let aspectRatioOverride: CGFloat?

  /// Same as `videoSizeRaw` but with aspect ratio override applied. If no aspect ratio override, then identical to `videoSizeRaw`.
  var videoSizeA: CGSize {
    guard let aspectRatioOverride else {
      // No aspect override
      return videoSizeRaw
    }

    let aspectRatioDefault = videoSizeRaw.mpvAspect
    if aspectRatioDefault > aspectRatioOverride {
      return CGSize(width: videoSizeRaw.width, height: round(videoSizeRaw.height * aspectRatioDefault / aspectRatioOverride))
    }
    return CGSize(width: round(videoSizeRaw.width / aspectRatioDefault * aspectRatioOverride), height: videoSizeRaw.height)
  }

  // Aspect + Crop

  let selectedCropLabel: String

  let cropBox: CGRect?

  /// The video size, after aspect override and crop filter applied, but before rotation or final scaling.
  ///
  /// From the mpv manual:
  /// ```
  /// dwidth, dheight
  /// Video display size. This is the video size after filters and aspect scaling have been applied. The actual
  /// video window size can still be different from this, e.g. if the user resized the video window manually.
  /// These have the same values as video-out-params/dw and video-out-params/dh.
  /// ```
  var videoSizeAC: CGSize {
    return cropBox?.size ?? videoSizeA
  }

  /// Same as mpv `dwidth`. See docs for `videoSizeAC`.
  var videoWidthAC: Int {
    return Int(videoSizeAC.width)
  }
  /// Same as mpv `dheight`. See docs for `videoSizeAC`.
  var videoHeightAC: Int {
    return Int(videoSizeAC.height)
  }

  /// `MPVProperty.videoParamsRotate`.
  /// 
  /// Is refreshed as property change events arrive for `MPVProperty.videoParamsRotate` ("video-params/rotate")
  /// IINA only supports one of [0, 90, 180, 270]
  let totalRotation: Int

  /// `MPVProperty.videoRotate`.
  ///
  /// Is refreshed as property change events arrive for `MPVOption.Video.videoRotate` ("video-rotate").
  /// Not to be confused with the `MPVProperty.videoParamsRotate` ("video-params/rotate")
  let userRotation: Int

  var isWidthSwappedWithHeightByRotation: Bool {
    // 90, 270, etc...
    (totalRotation %% 180) != 0
  }

  // Aspect + Crop + Rotation

  /// Like `dwidth`, but after applying `totalRotation`.
  var videoWidthACR: Int {
    if isWidthSwappedWithHeightByRotation {
      return videoHeightAC
    } else {
      return videoWidthAC
    }
  }

  /// Like `dheight`, but after applying `totalRotation`.
  var videoHeightACR: Int {
    if isWidthSwappedWithHeightByRotation {
      return videoWidthAC
    } else {
      return videoHeightAC
    }
  }

  /// Like `videoSizeAC`, but after applying `totalRotation`.
  var videoSizeACR: CGSize? {
    let drW = videoWidthACR
    let drH = videoHeightACR
    if drW == 0 || drH == 0 {
      Logger.log("Failed to generate videoSizeACR: dwidth or dheight not present!", level: .error)
      return nil
    }
    return CGSize(width: drW, height: drH)
  }

  var hasValidSize: Bool {
    return videoWidthACR > 0 && videoHeightACR > 0
  }

  var videoAspectACR: CGFloat? {
    guard let videoSizeACR else { return nil }
    return videoSizeACR.mpvAspect
  }

  /// `MPVProperty.windowScale`:
  var videoScale: CGFloat

  /// Like `videoSizeACR`, but after applying `videoScale`.
  var videoSizeACRS: CGSize? {
    guard let videoSizeACR else { return nil }
    return CGSize(width: round(videoSizeACR.width * videoScale),
                  height: round(videoSizeACR.height * videoScale))
  }

  /// Final aspect ratio of `videoView` (scale-invariant)
  var videoViewAspect: CGFloat? {
    return videoAspectACR
  }

  // Etc

  var description: String {
    return "MPVVideoParams:{vidSizeRaw=\(videoRawWidth)x\(videoRawHeight), vidSizeAC=\(videoWidthAC)x\(videoHeightAC) selectedAspectLabel=\(selectedAspectRatioLabel.quoted) aspectOverride=\(aspectRatioOverride?.description.quoted ?? "nil") rotTotal=\(totalRotation) rotUser=\(userRotation) crop=\(cropBox?.debugDescription ?? "nil") scale=\(videoScale), aspectACR=\(videoAspectACR?.description ?? "nil") vidSizeACR=\(videoSizeACR?.debugDescription ?? "nil")}"
  }
}
