//
//  PrefUIViewController.swift
//  iina
//
//  Created by lhc on 25/12/2016.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa

fileprivate let SizeWidthTag = 0
fileprivate let SizeHeightTag = 1
fileprivate let UnitPointTag = 0
fileprivate let UnitPercentTag = 1
fileprivate let SideLeftTag = 0
fileprivate let SideRightTag = 1
fileprivate let SideTopTag = 0
fileprivate let SideBottomTag = 1

@objcMembers
class PrefUIViewController: PreferenceViewController, PreferenceWindowEmbeddable {

  override var nibName: NSNib.Name {
    return NSNib.Name("PrefUIViewController")
  }

  var preferenceTabTitle: String {
    return NSLocalizedString("preference.ui", comment: "UI")
  }

  var preferenceTabImage: NSImage {
    return NSImage(named: NSImage.Name("pref_ui"))!
  }

  static var oscToolbarButtons: [Preference.ToolBarButton] {
    get {
      return (Preference.array(for: .controlBarToolbarButtons) as? [Int] ?? []).compactMap(Preference.ToolBarButton.init(rawValue:))
    }
  }

  override var sectionViews: [NSView] {
    return [sectionAppearanceView, sectionWindowView, sectionOSCView, sectionOSDView, sectionThumbnailView, sectionPictureInPictureView]
  }

  private let toolbarSettingsSheetController = PrefOSCToolbarSettingsSheetController()

  @IBOutlet var sectionAppearanceView: NSView!
  @IBOutlet var sectionWindowView: NSView!
  @IBOutlet var sectionOSCView: NSView!
  @IBOutlet var sectionOSDView: NSView!
  @IBOutlet var sectionThumbnailView: NSView!
  @IBOutlet var sectionPictureInPictureView: NSView!
    
  @IBOutlet weak var themeMenu: NSMenu!
  @IBOutlet weak var windowPreviewImageView: NSImageView!
  @IBOutlet weak var oscPositionPopupButton: NSPopUpButton!
  @IBOutlet weak var oscToolbarStackView: NSStackView!
  @IBOutlet weak var oscAutoHideTimeoutTextField: NSTextField!
  @IBOutlet weak var hideOverlaysOutsideWindowCheckBox: NSButton!

  @IBOutlet weak var windowSizeCheckBox: NSButton!
  @IBOutlet weak var windowSizeTypePopUpButton: NSPopUpButton!
  @IBOutlet weak var windowSizeValueTextField: NSTextField!
  @IBOutlet weak var windowSizeUnitPopUpButton: NSPopUpButton!
  @IBOutlet weak var windowSizeBox: NSBox!
  @IBOutlet weak var windowPosCheckBox: NSButton!
  @IBOutlet weak var windowPosXOffsetTextField: NSTextField!
  @IBOutlet weak var windowPosXUnitPopUpButton: NSPopUpButton!
  @IBOutlet weak var windowPosXAnchorPopUpButton: NSPopUpButton!
  @IBOutlet weak var windowPosYOffsetTextField: NSTextField!
  @IBOutlet weak var windowPosYUnitPopUpButton: NSPopUpButton!
  @IBOutlet weak var windowPosYAnchorPopUpButton: NSPopUpButton!
  @IBOutlet weak var windowPosBox: NSBox!

  @IBOutlet weak var windowResizeAlwaysButton: NSButton!
  @IBOutlet weak var windowResizeOnlyWhenOpenButton: NSButton!
  @IBOutlet weak var windowResizeNeverButton: NSButton!
  
  @IBOutlet weak var pipDoNothing: NSButton!
  @IBOutlet weak var pipHideWindow: NSButton!
  @IBOutlet weak var pipMinimizeWindow: NSButton!

  private let observedPrefKeys: [Preference.Key] = [
    .titleBarLayout,
    .enableOSC,
    .oscPosition,
  ]

  override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
    super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)

    observedPrefKeys.forEach { key in
      UserDefaults.standard.addObserver(self, forKeyPath: key.rawValue, options: .new, context: nil)
    }
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    ObjcUtils.silenced {
      for key in self.observedPrefKeys {
        UserDefaults.standard.removeObserver(self, forKeyPath: key.rawValue)
      }
    }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    updateWindowPreviewImage()
    oscToolbarStackView.wantsLayer = true
    updateOSCToolbarButtons()
    setupGeometryRelatedControls()
    setupResizingRelatedControls()
    setupPipBehaviorRelatedControls()

    let removeThemeMenuItemWithTag = { (tag: Int) in
      if let item = self.themeMenu.item(withTag: tag) {
        self.themeMenu.removeItem(item)
      }
    }
    if #available(macOS 10.14, *) {
      removeThemeMenuItemWithTag(Preference.Theme.mediumLight.rawValue)
      removeThemeMenuItemWithTag(Preference.Theme.ultraDark.rawValue)
    } else {
      removeThemeMenuItemWithTag(Preference.Theme.system.rawValue)
    }
  }

  override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
    guard let keyPath = keyPath, let _ = change else { return }

    switch keyPath {
      case PK.titleBarLayout.rawValue, PK.enableOSC.rawValue, PK.oscPosition.rawValue:
        updateWindowPreviewImage()
      default:
        break
    }
  }

  func updateWindowPreviewImage() {
    let oscEnabled = Preference.bool(for: .enableOSC)
    let oscPosition: Preference.OSCPosition = Preference.enum(for: .oscPosition)
    let titleBarLayout: Preference.TitleBarLayout = Preference.enum(for: .titleBarLayout)

    let isDarkMode = true
    let overlayAlpha: CGFloat = 0.6
    let opaqueControlAlpha: CGFloat = 0.9  // lighten it a bit

    guard let videoViewImg = loadCGImage(named: "preview-videoview") else { return }
    guard let oscFullImg = loadCGImage(named: "preview-osc-full") else { return }
    guard let oscFloatingImg = loadCGImage(named: "preview-osc-floating") else { return }
    guard let titleBarButtonsImg = loadCGImage(named: "preview-titlebar-buttons") else { return }

    let oscFullHeight: Int = oscFullImg.height
    let titleBarHeight: Int = titleBarButtonsImg.height

    var videoViewOffsetY: Int = 0
    if oscEnabled && oscPosition == .outsideBottom {
      videoViewOffsetY += oscFullHeight
    }

    let titleBarOffsetY: Int
    if titleBarLayout == .outsideVideo {
      titleBarOffsetY = videoViewOffsetY + videoViewImg.height
    } else if titleBarLayout == .insideVideoFull && oscEnabled && oscPosition == .insideTop {
      titleBarOffsetY = videoViewOffsetY + videoViewImg.height - titleBarHeight
    } else {
      titleBarOffsetY = videoViewOffsetY + videoViewImg.height - titleBarHeight
    }

    let outputWidth: Int = videoViewImg.width
    let outputHeight: Int = titleBarOffsetY + titleBarHeight

    windowPreviewImageView.image = drawImageInBitmapImageContext(width: outputWidth, height: outputHeight, roundedCornerRadius: 100, drawingCalls: { cgContext in
      // Draw background with opposite color as control color, so we can use alpha to lighten the controls
      let bgColor: CGFloat = isDarkMode ? 1 : 0
      cgContext.setFillColor(CGColor(red: bgColor, green: bgColor, blue: bgColor, alpha: 1))
      cgContext.fill([CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)])

      // draw video
      drawImage(videoViewImg, x: 0, y: videoViewOffsetY, cgContext)

      // draw OSC bar
      if oscEnabled {
        switch oscPosition {
          case .floating:
            let offsetX = (videoViewImg.width / 2) - (oscFloatingImg.width / 2)
            let offsetY = (videoViewImg.height / 2) - oscFloatingImg.height
            drawImage(oscFloatingImg, withAlpha: overlayAlpha, x: offsetX, y: offsetY, cgContext)
          case .insideTop:
            let oscOffsetY: Int
            if titleBarLayout == .insideVideoMinimal {
              // TODO: special osc
              oscOffsetY = videoViewOffsetY + videoViewImg.height - oscFullHeight
            } else if titleBarLayout == .insideVideoFull {
              let adjustment = oscFullHeight / 8 // remove some space between controller & title bar
              oscOffsetY = videoViewOffsetY + videoViewImg.height - oscFullHeight + adjustment - titleBarHeight
              drawImage(oscFullImg, withAlpha: overlayAlpha, x: 0, y: oscOffsetY, height: oscFullHeight - adjustment, cgContext)
              break
            } else {
              oscOffsetY = videoViewOffsetY + videoViewImg.height - oscFullHeight
            }
            drawImage(oscFullImg, withAlpha: overlayAlpha, x: 0, y: oscOffsetY, cgContext)
          case .insideBottom:
            drawImage(oscFullImg, withAlpha: overlayAlpha, x: 0, y: 0, cgContext)
          case .outsideBottom:
            drawImage(oscFullImg, withAlpha: opaqueControlAlpha, x: 0, y: 0, cgContext)
        }
      }

      // draw title bar
      let drawTitleBarButtons = titleBarLayout != .none
      let drawTitleBarBackground: Bool
      var titleBarIsOverlay = true
      switch titleBarLayout {
        case .none:
          drawTitleBarBackground = false
          break
        case .outsideVideo:
          drawTitleBarBackground = true
          titleBarIsOverlay = false
        case .insideVideoMinimal:
          drawTitleBarBackground = false
        case .insideVideoFull:
          drawTitleBarBackground = true
      }
      if drawTitleBarBackground {
        let titleBarAlpha: CGFloat = titleBarIsOverlay ? overlayAlpha : opaqueControlAlpha
        let color: CGFloat = isDarkMode ? 0 : 1
        cgContext.setFillColor(CGColor(red: color, green: color, blue: color, alpha: titleBarAlpha))
        cgContext.fill([CGRect(x: 0, y: titleBarOffsetY, width: outputWidth, height: titleBarHeight)])
      }
      if drawTitleBarButtons {
        drawImage(titleBarButtonsImg, x: 0, y: titleBarOffsetY, cgContext)
      }
    })

    let titleBarIsOverlay = titleBarLayout == .insideVideoFull || titleBarLayout == .insideVideoMinimal
    let oscIsOverlay = oscEnabled && (oscPosition == .insideTop || oscPosition == .insideBottom || oscPosition == .floating)
    let hasOverlay = titleBarIsOverlay || oscIsOverlay
    oscAutoHideTimeoutTextField.isEnabled = hasOverlay
    hideOverlaysOutsideWindowCheckBox.isEnabled = hasOverlay
  }

  func loadCGImage(named name: String) -> CGImage? {
    guard let image = NSImage(named: name) else {
      Logger.log("DrawImage: Failed to load image \(name.quoted)!", level: .error)
      return nil
    }
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      Logger.log("DrawImage: Failed to get CGImage for \(name.quoted)!", level: .error)
      return nil
    }
    return cgImage
  }

  func drawImage(_ cgImage: CGImage, withAlpha alpha: CGFloat = 1, x: Int, y: Int, width widthOverride: Int? = nil, height heightOverride: Int? = nil, _ cgContext: CGContext) {

    let width = widthOverride ?? cgImage.width
    let height = heightOverride ?? cgImage.height
    cgContext.setAlpha(alpha)
    cgContext.draw(cgImage, in: CGRect(x: x, y: y, width: width, height: height))
    cgContext.setAlpha(1)
  }

  func drawImageInBitmapImageContext(width: Int, height: Int, roundedCornerRadius: CGFloat? = nil, drawingCalls: (CGContext) -> Void) -> NSImage? {

    // Create image with alpha channel
    guard let compositeImageRep = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: width,
      pixelsHigh: height,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: NSColorSpaceName.calibratedRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0) else {
      Logger.log("DrawImageInBitmapImageContext: Failed to create NSBitmapImageRep!", level: .error)
      return nil
    }

    guard let context = NSGraphicsContext(bitmapImageRep: compositeImageRep) else {
      Logger.log("DrawImageInBitmapImageContext: Failed to create NSGraphicsContext!", level: .error)
      return nil
    }

    let outputImage = NSImage(size: CGSize(width: width, height: height))

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let cgContext = context.cgContext

    drawingCalls(cgContext)


    if let radius = roundedCornerRadius, radius > 0.0 {
      Logger.log("Rounding image corners to: \(radius)", level: .verbose)
      outputImage.lockFocus()

      let rect = CGRect(x: 0, y: 0, width: width, height: height)
//      let path = NSBezierPath(roundedRect: rect, xRadius: 0.5 * radius, yRadius: 0.5 * radius)
      let path = CGPath(roundedRect: rect, cornerWidth: 0.5 * radius, cornerHeight: 0.5 * radius, transform: nil)
      cgContext.addPath(path)
      cgContext.clip()

      outputImage.unlockFocus()
    }

    // Create the CGImage from the contents of the bitmap context.
    outputImage.addRepresentation(compositeImageRep)

    NSGraphicsContext.restoreGraphicsState()

    return outputImage
  }

  @IBAction func updateGeometryValue(_ sender: AnyObject) {
    var geometry = ""
    // size
    if windowSizeCheckBox.state == .on {
      setSubViews(of: windowSizeBox, enabled: true)
      geometry += windowSizeTypePopUpButton.selectedTag() == SizeWidthTag ? "" : "x"
      geometry += windowSizeValueTextField.stringValue
      geometry += windowSizeUnitPopUpButton.selectedTag() == UnitPointTag ? "" : "%"
    } else {
      setSubViews(of: windowSizeBox, enabled: false)
    }
    // position
    if windowPosCheckBox.state == .on {
      setSubViews(of: windowPosBox, enabled: true)
      geometry += windowPosXAnchorPopUpButton.selectedTag() == SideLeftTag ? "+" : "-"
      geometry += windowPosXOffsetTextField.stringValue
      geometry += windowPosXUnitPopUpButton.selectedTag() == UnitPointTag ? "" : "%"
      geometry += windowPosYAnchorPopUpButton.selectedTag() == SideBottomTag ? "+" : "-"
      geometry += windowPosYOffsetTextField.stringValue
      geometry += windowPosYUnitPopUpButton.selectedTag() == UnitPointTag ? "" : "%"
    } else {
      setSubViews(of: windowPosBox, enabled: false)
    }
    Preference.set(geometry, for: .initialWindowSizePosition)
  }

  @IBAction func setupResizingRelatedControls(_ sender: NSButton) {
    Preference.set(sender.tag, for: .resizeWindowTiming)
  }

  @IBAction func setupPipBehaviorRelatedControls(_ sender: NSButton) {
    Preference.set(sender.tag, for: .windowBehaviorWhenPip)
  }

  @IBAction func customizeOSCToolbarAction(_ sender: Any) {
    toolbarSettingsSheetController.currentItemsView?.initItems(fromItems: PrefUIViewController.oscToolbarButtons)
    toolbarSettingsSheetController.currentButtonTypes = PrefUIViewController.oscToolbarButtons
    view.window?.beginSheet(toolbarSettingsSheetController.window!) { response in
      guard response == .OK else { return }
      let newItems = self.toolbarSettingsSheetController.currentButtonTypes
      let array = newItems.map { $0.rawValue }
      Preference.set(array, for: .controlBarToolbarButtons)
      self.updateOSCToolbarButtons()
    }
  }

  private func updateOSCToolbarButtons() {
    oscToolbarStackView.views.forEach { oscToolbarStackView.removeView($0) }
    for buttonType in PrefUIViewController.oscToolbarButtons {
      let button = NSButton()
      OSCToolbarButton.setStyle(of: button, buttonType: buttonType)
      oscToolbarStackView.addView(button, in: .trailing)
      // Button is actually disabled so that its mouseDown goes to its superview instead
      button.isEnabled = false
      // But don't gray it out
      (button.cell! as! NSButtonCell).imageDimsWhenDisabled = false
    }
  }

  private func setupGeometryRelatedControls() {
    let geometryString = Preference.string(for: .initialWindowSizePosition) ?? ""
    if let geometry = GeometryDef.parse(geometryString) {
      // size
      if let h = geometry.h {
        windowSizeCheckBox.state = .on
        setSubViews(of: windowSizeBox, enabled: true)
        windowSizeTypePopUpButton.selectItem(withTag: SizeHeightTag)
        let isPercent = h.hasSuffix("%")
        windowSizeUnitPopUpButton.selectItem(withTag: isPercent ? UnitPercentTag : UnitPointTag)
        windowSizeValueTextField.stringValue = isPercent ? String(h.dropLast()) : h
      } else if let w = geometry.w {
        windowSizeCheckBox.state = .on
        setSubViews(of: windowSizeBox, enabled: true)
        windowSizeTypePopUpButton.selectItem(withTag: SizeWidthTag)
        let isPercent = w.hasSuffix("%")
        windowSizeUnitPopUpButton.selectItem(withTag: isPercent ? UnitPercentTag : UnitPointTag)
        windowSizeValueTextField.stringValue = isPercent ? String(w.dropLast()) : w
      } else {
        windowSizeCheckBox.state = .off
        setSubViews(of: windowSizeBox, enabled: false)
      }
      // position
      if let x = geometry.x, let xSign = geometry.xSign, let y = geometry.y, let ySign = geometry.ySign {
        windowPosCheckBox.state = .on
        setSubViews(of: windowPosBox, enabled: true)
        let xIsPercent = x.hasSuffix("%")
        windowPosXAnchorPopUpButton.selectItem(withTag: xSign == "+" ? SideLeftTag : SideRightTag)
        windowPosXOffsetTextField.stringValue = xIsPercent ? String(x.dropLast()) : x
        windowPosXUnitPopUpButton.selectItem(withTag: xIsPercent ? UnitPercentTag : UnitPointTag)
        let yIsPercent = y.hasSuffix("%")
        windowPosYAnchorPopUpButton.selectItem(withTag: ySign == "+" ? SideBottomTag : SideTopTag)
        windowPosYOffsetTextField.stringValue = yIsPercent ? String(y.dropLast()) : y
        windowPosYUnitPopUpButton.selectItem(withTag: yIsPercent ? UnitPercentTag : UnitPointTag)
      } else {
        windowPosCheckBox.state = .off
        setSubViews(of: windowPosBox, enabled: false)
      }
    } else {
      windowSizeCheckBox.state = .off
      windowPosCheckBox.state = .off
      setSubViews(of: windowPosBox, enabled: false)
      setSubViews(of: windowSizeBox, enabled: false)
    }
  }

  private func setupResizingRelatedControls() {
    let resizeOption = Preference.enum(for: .resizeWindowTiming) as Preference.ResizeWindowTiming
    ([windowResizeNeverButton, windowResizeOnlyWhenOpenButton, windowResizeAlwaysButton] as [NSButton])
      .first { $0.tag == resizeOption.rawValue }?.state = .on
  }

  private func setupPipBehaviorRelatedControls() {
    let pipBehaviorOption = Preference.enum(for: .windowBehaviorWhenPip) as Preference.WindowBehaviorWhenPip
    ([pipDoNothing, pipHideWindow, pipMinimizeWindow] as [NSButton])
        .first { $0.tag == pipBehaviorOption.rawValue }?.state = .on
  }

  private func setSubViews(of view: NSBox, enabled: Bool) {
    view.contentView?.subviews.forEach { ($0 as? NSControl)?.isEnabled = enabled }
  }
}

@objc(ResizeTimingTransformer) class ResizeTimingTransformer: ValueTransformer {

  static override func allowsReverseTransformation() -> Bool {
    return false
  }

  static override func transformedValueClass() -> AnyClass {
    return NSNumber.self
  }

  override func transformedValue(_ value: Any?) -> Any? {
    guard let timing = value as? NSNumber else { return nil }
    return timing != 2
  }
}

