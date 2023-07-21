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

fileprivate let uiAnimationDuration: CGFloat = 0.25

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
    return [sectionAppearanceView, sectionWindowView, sectionOSCView, sectionOSDView,
            sectionSidebarsView, sectionThumbnailView, sectionPictureInPictureView]
  }

  private let toolbarSettingsSheetController = PrefOSCToolbarSettingsSheetController()

  @IBOutlet var sectionAppearanceView: NSView!
  @IBOutlet var sectionWindowView: NSView!
  @IBOutlet var sectionOSCView: NSView!
  @IBOutlet var sectionOSDView: NSView!
  @IBOutlet var sectionSidebarsView: NSView!
  @IBOutlet var sectionThumbnailView: NSView!
  @IBOutlet var sectionPictureInPictureView: NSView!

  @IBOutlet weak var themeMenu: NSMenu!
  @IBOutlet weak var showTitleBarTriggerContainerView: NSView!
  @IBOutlet weak var windowPreviewImageView: NSImageView!
  @IBOutlet weak var oscBottomPlacementContainerView: NSView!
  @IBOutlet weak var oscSnapToCenterCheckboxContainerView: NSView!
  @IBOutlet weak var oscToolbarStackView: NSStackView!
  @IBOutlet weak var oscAutoHideTimeoutTextField: NSTextField!
  @IBOutlet weak var hideFadeableViewsOutsideWindowCheckBox: NSButton!

  @IBOutlet var leadingSidebarBox: NSBox!
  @IBOutlet var trailingSidebarBox: NSBox!

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
    .showTopBarTrigger,
    .topBarPlacement,
    .bottomBarPlacement,
    .enableOSC,
    .oscPosition,
    .themeMaterial,
    .settingsTabGroupLocation,
    .playlistTabGroupLocation,
    .controlBarToolbarButtons,
    .oscBarToolbarIconSize,
    .oscBarToolbarIconSpacing,
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

    oscToolbarStackView.wantsLayer = true

    refreshSidebarSection()
    refreshTitleBarAndOSCSection(animate: false)
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
    case PK.showTopBarTrigger.rawValue,
      PK.enableOSC.rawValue,
      PK.topBarPlacement.rawValue,
      PK.bottomBarPlacement.rawValue,
      PK.oscPosition.rawValue,
      PK.themeMaterial.rawValue:
      refreshTitleBarAndOSCSection()
    case PK.settingsTabGroupLocation.rawValue, PK.playlistTabGroupLocation.rawValue:
      refreshSidebarSection()
    case PK.controlBarToolbarButtons.rawValue,
      PK.oscBarToolbarIconSize.rawValue,
      PK.oscBarToolbarIconSpacing.rawValue:

      updateOSCToolbarButtons()
    default:
      break
    }
  }

  private func refreshSidebarSection() {
    let tabGroup1: Preference.SidebarLocation = Preference.enum(for: .settingsTabGroupLocation)
    let tabGroup2: Preference.SidebarLocation = Preference.enum(for: .playlistTabGroupLocation)
    let isUsingLeadingSidebar = tabGroup1 == .leadingSidebar || tabGroup2 == .leadingSidebar
    let isUsingTrailingSidebar = tabGroup1 == .trailingSidebar || tabGroup2 == .trailingSidebar
    setSubViews(of: leadingSidebarBox, enabled: isUsingLeadingSidebar)
    setSubViews(of: trailingSidebarBox, enabled: isUsingTrailingSidebar)
  }

  private func refreshTitleBarAndOSCSection(animate: Bool = true) {
    let ib = PlayerWindowPreviewImageBuilder()

    let titleBarIsOverlay = ib.topBarPlacement == .insideVideo
    let oscIsOverlay = ib.oscEnabled && (ib.oscPosition == .floating ||
                                         (ib.oscPosition == .top && ib.topBarPlacement == .insideVideo) ||
                                         (ib.oscPosition == .bottom && ib.bottomBarPlacement == .insideVideo))
    let hasOverlay = titleBarIsOverlay || oscIsOverlay

    var viewHidePairs: [(NSView, Bool)] = []
    // Use animation where possible to make the transition less jarring
    NSAnimationContext.runAnimationGroup({context in
      context.duration = 0 // TODO animate ? AccessibilityPreferences.adjustedDuration(uiAnimationDuration) : 0
      context.allowsImplicitAnimation = animate ? !AccessibilityPreferences.motionReductionEnabled : false
      context.timingFunction = CAMediaTimingFunction(name: .linear)

      oscAutoHideTimeoutTextField.isEnabled = hasOverlay
      hideFadeableViewsOutsideWindowCheckBox.isEnabled = hasOverlay
      windowPreviewImageView.image = ib.updateWindowPreviewImage()

      let oscIsFloating = ib.oscEnabled && ib.oscPosition == .floating

      if oscSnapToCenterCheckboxContainerView.isHidden != !oscIsFloating {
        viewHidePairs.append((oscSnapToCenterCheckboxContainerView, !oscIsFloating))
      }

      let oscIsBottom = ib.oscEnabled && ib.oscPosition == .bottom
      if oscBottomPlacementContainerView.isHidden != !oscIsBottom {
        viewHidePairs.append((oscBottomPlacementContainerView, !oscIsBottom))
      }

      let showShowTitleBarTrigger = ib.topBarPlacement == .insideVideo
      if showTitleBarTriggerContainerView.isHidden != !showShowTitleBarTrigger {
        viewHidePairs.append((showTitleBarTriggerContainerView, !showShowTitleBarTrigger))
      }

      for (view, shouldHide) in viewHidePairs {
        for subview in view.subviews {
          subview.animator().isHidden = shouldHide
        }
      }

      // Need this to get proper slide effect
      oscBottomPlacementContainerView.superview?.layoutSubtreeIfNeeded()
    }, completionHandler: { [self] in
      oscAutoHideTimeoutTextField.isEnabled = hasOverlay
      hideFadeableViewsOutsideWindowCheckBox.isEnabled = hasOverlay
      windowPreviewImageView.image = ib.updateWindowPreviewImage()

      NSAnimationContext.runAnimationGroup({context in
        context.duration = animate ? AccessibilityPreferences.adjustedDuration(uiAnimationDuration) : 0
        context.allowsImplicitAnimation = animate ? !AccessibilityPreferences.motionReductionEnabled : false
        context.timingFunction = CAMediaTimingFunction(name: .linear)
        for (view, shouldHide) in viewHidePairs {
          view.animator().isHidden = shouldHide
        }
      }, completionHandler: {
      })
    })
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
    Logger.log("Saving pref \(Preference.Key.initialWindowSizePosition.rawValue.quoted) with geometry: \(geometry.quoted)")
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
    }
  }

  private func updateOSCToolbarButtons() {
    oscToolbarStackView.views.forEach { oscToolbarStackView.removeView($0) }
    for buttonType in PrefUIViewController.oscToolbarButtons {
      let button = OSCToolbarButton()
      button.setStyle(buttonType: buttonType)
      oscToolbarStackView.addView(button, in: .trailing)
      oscToolbarStackView.spacing = 2 * button.iconPadding
      oscToolbarStackView.edgeInsets = .init(top: button.iconPadding, left: button.iconPadding, bottom: button.iconPadding, right: button.iconPadding)
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

@objc(IntEqualsZeroTransformer) class IntEqualsZeroTransformer: ValueTransformer {

  static override func allowsReverseTransformation() -> Bool {
    return false
  }

  static override func transformedValueClass() -> AnyClass {
    return NSNumber.self
  }

  override func transformedValue(_ value: Any?) -> Any? {
    guard let number = value as? NSNumber else { return nil }
    return number == 0
  }
}

@objc(IntEqualsTwoTransformer) class IntEqualsTwoTransformer: IntEqualsZeroTransformer {

  override func transformedValue(_ value: Any?) -> Any? {
    guard let number = value as? NSNumber else { return nil }
    return number == 2
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


class PlayerWindowPreviewView: NSView {

  override func awakeFromNib() {
    self.wantsLayer = true
    let cornerRadius = CGFloat(Preference.float(for: .roundedCornerRadius))
    if cornerRadius > 0.0 {
      self.layer?.cornerRadius = cornerRadius
    }
    self.layer?.masksToBounds = true
    self.layer?.borderWidth = 1
    self.layer?.borderColor = CGColor(gray: 0.6, alpha: 0.5)
  }

}
