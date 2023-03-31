//
//  PlayerWindowPreviewImageBuilder.swift
//  iina
//
//  Created by Matt Svoboda on 2023-03-01.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

fileprivate let overlayAlpha: CGFloat = 0.6
fileprivate let opaqueControlAlpha: CGFloat = 1.0
fileprivate let outputImgWidth: Int = 640
fileprivate let outputImgHeight: Int = 480
fileprivate let menuBarHeight: Int = 20

class PlayerWindowPreviewImageBuilder {
  static var cgImageCache: [String: CGImage] = [:]

  let oscEnabled = Preference.bool(for: .enableOSC)
  let oscPosition: Preference.OSCPosition = Preference.enum(for: .oscPosition)
  let titleBarStyle: Preference.TitleBarStyle = Preference.enum(for: .titleBarStyle)
  let topPanelPlacement: Preference.PanelPlacement = Preference.enum(for: .topPanelPlacement)
  let bottomPanelPlacement: Preference.PanelPlacement = Preference.enum(for: .bottomPanelPlacement)
  let theme: Preference.Theme = Preference.enum(for: .themeMaterial)


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
    let isDarkTheme = !(theme == .light || theme == .mediumLight)  // default to dark
    let roundedCornerRadius = CGFloat(Preference.float(for: .roundedCornerRadius))

    let oscFullHeight: Int = oscFullImg.height
    let titleBarHeight: Int = titleBarButtonsImg.height

    var videoViewOffsetY: Int = 0
    if oscEnabled && oscPosition == .bottom && bottomPanelPlacement == .outsideVideo {
      // add extra space for bottom panel
      videoViewOffsetY += oscFullHeight
    }

    let oscImg: CGImage?
    let oscOffsetY: Int
    let oscHeight: Int
    let oscAlpha: CGFloat
    if oscEnabled {

      switch oscPosition {

      case .top:
        switch topPanelPlacement {

        case .outsideVideo:
          oscAlpha = opaqueControlAlpha
          oscImg = oscFullImg
          oscHeight = oscFullHeight - (oscFullHeight / 8)  // remove some space between controller & title bar
          oscOffsetY = videoViewOffsetY + videoViewImg.height

        case .insideVideo:
          oscAlpha = overlayAlpha

          switch titleBarStyle {
          case .minimal:
            // Special in-title accessory controller
            oscImg = oscTitleImg
            oscHeight = oscTitleImg.height
            oscOffsetY = videoViewOffsetY + videoViewImg.height - oscHeight
          case .full:
            oscImg = oscFullImg
            let adjustment = oscFullHeight / 8 // remove some space between controller & title bar
            oscHeight = oscFullHeight - adjustment
            oscOffsetY = videoViewOffsetY + videoViewImg.height - oscHeight - titleBarHeight
          case .none:
            oscImg = oscFullImg
            oscHeight = oscFullHeight
            oscOffsetY = videoViewOffsetY + videoViewImg.height - oscHeight
          }  // end switch titleBarStyle

        }  // end switch topPanelPlacement

      case .bottom:
        oscImg = oscFullImg
        oscHeight = oscFullHeight

        switch bottomPanelPlacement {
        case .outsideVideo:
          oscAlpha = opaqueControlAlpha
          oscOffsetY = videoViewOffsetY - oscFullHeight
        case .insideVideo:
          oscAlpha = overlayAlpha
          oscOffsetY = videoViewOffsetY
        }  // end switch bottomPanelPlacement

      case .floating:
        oscAlpha = overlayAlpha
        oscImg = oscFloatingImg
        oscHeight = oscFullHeight
        oscOffsetY = videoViewOffsetY + (videoViewImg.height / 2) - oscFloatingImg.height

      }  // end switch oscPosition

    } else {
      // OSC disabled
      oscAlpha = overlayAlpha
      oscImg = nil
      oscHeight = 0
      oscOffsetY = 0
    }

    let titlebarDownshiftY: Int
    if topPanelPlacement == .outsideVideo {
      if oscEnabled && oscPosition == .top {
        titlebarDownshiftY = -oscHeight
      } else {
        titlebarDownshiftY = 0  // right above video
      }
    } else {
      titlebarDownshiftY = titleBarHeight  // inside video
    }
    let titleBarOffsetY: Int = videoViewOffsetY + videoViewImg.height - titlebarDownshiftY

    let winWidth: Int = videoViewImg.width
    let winHeight: Int = titleBarOffsetY + titleBarHeight
    let winOriginX: Int = (outputImgWidth - winWidth) / 2
    let winOriginY: Int = (outputImgHeight - winHeight) / 2 - menuBarHeight

    let winRect = NSRect(x: winOriginX, y: winOriginY, width: winWidth, height: winHeight)

    let drawingCalls: (CGContext) -> Void = { [self] cgContext in
      let bgColor = NSColor.underPageBackgroundColor.cgColor
      cgContext.setFillColor(bgColor)
      cgContext.fill([CGRect(x: 0, y: 0, width: outputImgWidth, height: outputImgHeight)])

      // Draw menu bar
      let menuBarColor: CGColor = addAlpha(opaqueControlAlpha, to: NSColor.windowBackgroundColor)
      cgContext.setFillColor(menuBarColor)
      cgContext.fill([CGRect(x: 0, y: outputImgHeight - titleBarHeight, width: outputImgWidth, height: titleBarHeight)])

      if #available(macOS 11.0, *) {
        if let appleLogo = NSImage(systemSymbolName: "apple.logo", accessibilityDescription: nil)?.tinted(.textColor) {

          let paddingY = titleBarHeight / 8
          let logoHeight = titleBarHeight - (paddingY * 2)
          let logoWidth = Int(CGFloat(logoHeight) * appleLogo.size.aspect)
          cgContext.draw(appleLogo.cgImage!, in: CGRect(x: paddingY * 2, y: outputImgHeight - titleBarHeight + paddingY, width: logoWidth, height: logoHeight))
        }
      } else {
        // Fallback on earlier versions
      }


      // Start drawing window. Clip its corners to round it:
      cgContext.beginPath()
      cgContext.addPath(CGPath(roundedRect: winRect, cornerWidth: roundedCornerRadius * 2, cornerHeight: roundedCornerRadius * 2, transform: nil))
      cgContext.closePath()
      cgContext.clip()

      // draw video
      draw(image: videoViewImg, in: cgContext, x: winOriginX, y: winOriginY + videoViewOffsetY)

      // draw OSC bar
      if let oscImg = oscImg {
        let oscOffsetX: Int
        if oscPosition == .floating {
          oscOffsetX = (videoViewImg.width / 2) - (oscFloatingImg.width / 2)
        } else {
          oscOffsetX = 0
        }
        draw(image: oscImg, in: cgContext, withAlpha: oscAlpha, x: winOriginX + oscOffsetX, y: winOriginY + oscOffsetY, height: oscHeight)
      }

      // draw title bar
      let isTitleBarInside = topPanelPlacement == .insideVideo
      let drawTitleBarBackground: Bool
      if isTitleBarInside {
        switch titleBarStyle {
        case .none, .minimal:
          drawTitleBarBackground = false
        case .full:
          drawTitleBarBackground = true
        }
      } else {
        drawTitleBarBackground = true
      }

      if drawTitleBarBackground {
        let titleBarAlpha: CGFloat = isTitleBarInside ? overlayAlpha : opaqueControlAlpha
        let titleBarColor: CGColor = addAlpha(titleBarAlpha, to: NSColor.windowBackgroundColor)
        cgContext.setFillColor(titleBarColor)
        cgContext.fill([CGRect(x: winOriginX, y: winOriginY + titleBarOffsetY, width: winWidth, height: titleBarHeight)])
      }

      let drawTitleBarButtons = !isTitleBarInside || titleBarStyle != .none
      if drawTitleBarButtons {
        draw(image: titleBarButtonsImg, in: cgContext, x: winOriginX, y: winOriginY + titleBarOffsetY)
      }
    }  // drawingCalls

    let previewImage = drawImageInBitmapImageContext(width: outputImgWidth, height: outputImgHeight, drawingCalls: drawingCalls)?
      .roundCorners(withRadius: roundedCornerRadius)

    return previewImage
  }

  private func addAlpha(_ alpha: CGFloat, to color: NSColor) -> CGColor {
    color.withAlphaComponent(alpha).cgColor
  }

  private func tintImage(_ inputImage: CGImage, _ context: CGContext) -> CGImage? {
    let ciContext = CIContext()
    guard let filter = CIFilter(name:"CISepiaTone") else { return nil }
    filter.setValue(inputImage, forKey: kCIInputImageKey)
    filter.setValue(0.9, forKey: kCIInputIntensityKey)
    guard let outputCIImage = filter.outputImage else { return nil }
    return ciContext.createCGImage(outputCIImage, from: outputCIImage.extent)
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

  private func drawImageInBitmapImageContext(width: Int, height: Int, drawingCalls: (CGContext) -> Void) -> NSImage? {

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
