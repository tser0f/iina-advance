//
//  PlayerWindowPreviewImageBuilder.swift
//  iina
//
//  Created by Matt Svoboda on 2023-03-01.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

fileprivate let overlayAlpha: CGFloat = 0.6
fileprivate let opaqueControlAlpha: CGFloat = 0.9  // don't be completely white or black

class PlayerWindowPreviewImageBuilder {
  static var cgImageCache: [String: CGImage] = [:]

  let oscEnabled = Preference.bool(for: .enableOSC)
  let oscPosition: Preference.OSCPosition = Preference.enum(for: .oscPosition)
  let titleBarStyle: Preference.TitleBarStyle = Preference.enum(for: .titleBarStyle)
  let topPanelPlacement: Preference.PanelPlacement = Preference.enum(for: .topPanelPlacement)
  let bottomPanelPlacement: Preference.PanelPlacement = Preference.enum(for: .bottomPanelPlacement)
  let isDarkTheme = true  // TODO fully support light preview. Need to find way to invert colors for OSC imgs
  //    let theme: Preference.Theme = Preference.enum(for: .themeMaterial)
  //    let isDarkTheme = !(theme == .light || theme == .mediumLight)  // default to dark


  // TODO (1): draw border around window
  // TODO (2): embed window preview into screen preview to make it prettier
  // TODO (3): support light themes (above)
  func updateWindowPreviewImage() -> NSImage? {
    guard let videoViewImg = loadCGImage(named: "preview-videoview"),
          let oscFullImg = loadCGImage(named: "preview-osc-full"),
          let oscTitleImg = loadCGImage(named: "preview-osc-title"),
          let oscFloatingImg = loadCGImage(named: "preview-osc-floating"),
          let titleBarButtonsImg = loadCGImage(named: "preview-titlebar-buttons") else {
      Logger.log("Cannot generate window preview image: failed to load asset(s)", level: .error)
      return nil
    }

    let oscFullHeight: Int = oscFullImg.height
    let titleBarHeight: Int = titleBarButtonsImg.height

    var videoViewOffsetY: Int = 0
    if oscEnabled && oscPosition == .bottom && bottomPanelPlacement == .outsideVideo {
      // add extra space for bottom panel
      videoViewOffsetY += oscFullHeight
    }

    let titleBarOffsetY: Int
    if topPanelPlacement == .outsideVideo {
      // extra space for title bar
      titleBarOffsetY = videoViewOffsetY + videoViewImg.height
    } else if topPanelPlacement == .insideVideo && oscEnabled && oscPosition == .top {
      titleBarOffsetY = videoViewOffsetY + videoViewImg.height - titleBarHeight
    } else {
      titleBarOffsetY = videoViewOffsetY + videoViewImg.height - titleBarHeight
    }

    let outputWidth: Int = videoViewImg.width
    let outputHeight: Int = titleBarOffsetY + titleBarHeight


    let drawingCalls: (CGContext) -> Void = { cgContext in
      // Draw background with opposite color as control color, so we can use alpha to lighten the controls
      let bgColor: CGFloat = self.isDarkTheme ? 1 : 0
      cgContext.setFillColor(CGColor(red: bgColor, green: bgColor, blue: bgColor, alpha: 1))
      cgContext.fill([CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)])

      // draw video
      self.draw(image: videoViewImg, in: cgContext, x: 0, y: videoViewOffsetY)

      // draw OSC bar
      if self.oscEnabled {
        switch self.oscPosition {
        case .floating:
          let offsetX = (videoViewImg.width / 2) - (oscFloatingImg.width / 2)
          let offsetY = videoViewOffsetY + (videoViewImg.height / 2) - oscFloatingImg.height
          self.draw(image: oscFloatingImg, in: cgContext, withAlpha: overlayAlpha, x: offsetX, y: offsetY)
        case .top:
          // FIXME: This is INSIDE. Need support for OUTSIDE also!
          switch self.titleBarStyle {
          case .minimal:
            // Special in-title accessory controller
            let oscOffsetY = videoViewOffsetY + videoViewImg.height - oscTitleImg.height
            self.draw(image: oscTitleImg, in: cgContext, withAlpha: overlayAlpha, x: 0, y: oscOffsetY)
          case .full:
            let adjustment = oscFullHeight / 8 // remove some space between controller & title bar
            let oscOffsetY = videoViewOffsetY + videoViewImg.height - oscFullHeight + adjustment - titleBarHeight
            self.draw(image: oscFullImg, in: cgContext, withAlpha: overlayAlpha, x: 0, y: oscOffsetY, height: oscFullHeight - adjustment)
          case .none:
            let oscOffsetY = videoViewOffsetY + videoViewImg.height - oscFullHeight
            self.draw(image: oscFullImg, in: cgContext,  withAlpha: overlayAlpha, x: 0, y: oscOffsetY)
          }
        case .bottom:
          switch self.bottomPanelPlacement {
          case .insideVideo:
            self.draw(image: oscFullImg, in: cgContext,  withAlpha: overlayAlpha, x: 0, y: videoViewOffsetY)
            cgContext.setBlendMode(.normal)
          case .outsideVideo:
            self.draw(image: oscFullImg, in: cgContext, withAlpha: opaqueControlAlpha, x: 0, y: 0)
          }
        }
      }

      // draw title bar
      let drawTitleBarButtons = self.titleBarStyle != .none
      let drawTitleBarBackground: Bool
      let titleBarIsOverlay = self.topPanelPlacement == .insideVideo
      if titleBarIsOverlay {
        switch self.titleBarStyle {
        case .none:
          drawTitleBarBackground = false
          break
        case .minimal:
          drawTitleBarBackground = false
        case .full:
          drawTitleBarBackground = true
        }
      } else {
        drawTitleBarBackground = true
      }
      if drawTitleBarBackground {
        let titleBarAlpha: CGFloat = titleBarIsOverlay ? overlayAlpha : opaqueControlAlpha
        let color: CGFloat = self.isDarkTheme ? 0 : 1
        cgContext.setFillColor(CGColor(red: color, green: color, blue: color, alpha: titleBarAlpha))
        cgContext.fill([CGRect(x: 0, y: titleBarOffsetY, width: outputWidth, height: titleBarHeight)])
      }
      if drawTitleBarButtons {
        self.draw(image: titleBarButtonsImg, in: cgContext, x: 0, y: titleBarOffsetY)
      }
    }

    let roundedCornerRadius: CGFloat = CGFloat(Preference.float(for: .roundedCornerRadius)) * 2
    let previewImage = drawImageInBitmapImageContext(width: outputWidth, height: outputHeight, drawingCalls: drawingCalls)?
      .roundCorners(withRadius: roundedCornerRadius)

    return previewImage
  }


  private func loadCGImage(named name: String) -> CGImage? {
    if let cachedImage = PlayerWindowPreviewImageBuilder.cgImageCache[name] {
      return cachedImage
    }
    guard let image = NSImage(named: name) else {
      Logger.log("DrawImage: Failed to load image \(name.quoted)!", level: .error)
      return nil
    }
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      Logger.log("DrawImage: Failed to get CGImage for \(name.quoted)!", level: .error)
      return nil
    }
    PlayerWindowPreviewImageBuilder.cgImageCache[name] = cgImage
    return cgImage
  }

  private func draw(image cgImage: CGImage, in cgContext: CGContext,
                    withAlpha alpha: CGFloat = 1,
                    x: Int, y: Int, width widthOverride: Int? = nil, height heightOverride: Int? = nil) {
    let width = widthOverride ?? cgImage.width
    let height = heightOverride ?? cgImage.height
    cgContext.setAlpha(alpha)
    cgContext.draw(cgImage, in: CGRect(x: x, y: y, width: width, height: height))
    cgContext.setAlpha(1)
  }

  private func drawImageInBitmapImageContext(width: Int, height: Int, roundedCornerRadius: CGFloat? = nil, drawingCalls: (CGContext) -> Void) -> NSImage? {

    guard let compositeImageRep = makeNewImgRep(width: width, height: height) else {
      Logger.log("DrawImageInBitmapImageContext: Failed to create NSBitmapImageRep!", level: .error)
      return nil
    }

    guard let context = NSGraphicsContext(bitmapImageRep: compositeImageRep) else {
      Logger.log("DrawImageInBitmapImageContext: Failed to create NSGraphicsContext!", level: .error)
      return nil
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let cgContext = context.cgContext

    drawingCalls(cgContext)

    defer {
      NSGraphicsContext.restoreGraphicsState()
    }

    let outputImage = NSImage(size: CGSize(width: width, height: height))
    // Create the CGImage from the contents of the bitmap context.
    outputImage.addRepresentation(compositeImageRep)

    return outputImage
  }

  // Creates RGB image with alpha channel
  private func makeNewImgRep(width: Int, height: Int) -> NSBitmapImageRep? {
    return NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: width,
      pixelsHigh: height,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: NSColorSpaceName.calibratedRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0)
  }
}
