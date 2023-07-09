//
//  MainWindowController.swift
//  iina
//
//  Created by lhc on 8/7/16.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa
import Mustache
import WebKit

// MARK: - Constants

fileprivate let isMacOS11: Bool = {
  if #available(macOS 11.0, *) {
    if #unavailable(macOS 12.0) {
        return true
    }
  }
  return false
}()

/**
 `NSWindow` doesn't provide title bar height directly, but we can derive it by asking `NSWindow` for
 the dimensions of a prototypical window with titlebar, then subtracting the height of its `contentView`.
 Note that we can't use this trick to get it from our window instance directly, because our window has the
 `fullSizeContentView` style and so its `frameRect` does not include any extra space for its title bar.
 */
fileprivate let StandardTitleBarHeight: CGFloat = {
  // Probably doesn't matter what dimensions we pick for the dummy contentRect, but to be safe let's make them nonzero.
  let dummyContentRect = NSRect(x: 0, y: 0, width: 10, height: 10)
  let dummyFrameRect = NSWindow.frameRect(forContentRect: dummyContentRect, styleMask: .titled)
  let titleBarHeight = dummyFrameRect.height - dummyContentRect.height
  return titleBarHeight
}()

/// Sidebar tab buttons
private let defaultDownshift: CGFloat = 0
private let defaultTabHeight: CGFloat = 48

/// Preferred height for "full-width" OSCs (i.e. top and bottom, not floating or in title bar)
fileprivate var oscBarHeight: CGFloat {
  max(16, CGFloat(Preference.integer(for: .oscBarHeight)))
}

/// Size of a side the 3 square playback button icons (Play/Pause, LeftArrow, RightArrow):
fileprivate var oscBarPlaybackIconSize: CGFloat {
  CGFloat(Preference.integer(for: .oscBarPlaybackIconSize)).clamped(to: 8...oscBarHeight)
}
/// Scale of spacing to the left & right of each playback button (for top/bottom OSC):
fileprivate var oscBarPlaybackIconSpacing: CGFloat {
  max(0, CGFloat(Preference.integer(for: .oscBarPlaybackIconSpacing)))
}

fileprivate let oscFloatingPlayBtnsSize: CGFloat = 24
fileprivate let oscFloatingPlayBtnsHPad: CGFloat = 8
fileprivate let oscFloatingToolbarButtonIconSize: CGFloat = 14
fileprivate let oscFloatingToolbarButtonIconPadding: CGFloat = 5

// TODO: reimplement OSC title bar feature
fileprivate let oscTitleBarPlayBtnsSize: CGFloat = 18
fileprivate let oscTitleBarPlayBtnsHPad: CGFloat = 6
fileprivate let oscTitleBarToolbarButtonIconSize: CGFloat = 14
fileprivate let oscTitleBarToolbarButtonIconPadding: CGFloat = 5

fileprivate let InteractiveModeBottomViewHeight: CGFloat = 60

/** For Force Touch. */
fileprivate let minimumPressDuration: TimeInterval = 0.5

fileprivate extension NSStackView.VisibilityPriority {
  static let detachEarly = NSStackView.VisibilityPriority(rawValue: 850)
  static let detachEarlier = NSStackView.VisibilityPriority(rawValue: 800)
  static let detachEarliest = NSStackView.VisibilityPriority(rawValue: 750)
}

// MARK: - Constants

class MainWindowController: PlayerWindowController {

  override var windowNibName: NSNib.Name {
    return NSNib.Name("MainWindowController")
  }

  @objc let monospacedFont: NSFont = {
    let fontSize = NSFont.systemFontSize(for: .small)
    return NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
  }()

  lazy var reducedTitleBarHeight: CGFloat = {
    if let heightOfCloseButton = window?.standardWindowButton(.closeButton)?.frame.height {
      // add 2 because button's bounds seems to be a bit larger than its visible size
      return StandardTitleBarHeight - ((StandardTitleBarHeight - heightOfCloseButton) / 2 + 2)
    }
    Logger.log("reducedTitleBarHeight may be incorrect (could not get close button)", level: .error)
    return StandardTitleBarHeight
  }()

  /// Minimum allowed video size. Does not include any panels which are outside the video.
  var minSize: NSSize { return PlayerCore.minVideoSize }

  // MARK: - Objects, Views

  var bestScreen: NSScreen {
    window?.screen ?? NSScreen.main!
  }

  /** For blacking out other screens. */
  var cachedScreenIDs = Set<UInt32>()
  var blackWindows: [NSWindow] = []

  // Is non-nil if within the activation rect of one of the sidebars
  var sidebarResizeCursor: NSCursor? = nil

  /** The quick setting sidebar (video, audio, subtitles). */
  lazy var quickSettingView: QuickSettingViewController = {
    let quickSettingView = QuickSettingViewController()
    quickSettingView.mainWindow = self
    return quickSettingView
  }()

  /** The playlist and chapter sidebar. */
  lazy var playlistView: PlaylistViewController = {
    let playlistView = PlaylistViewController()
    playlistView.mainWindow = self
    return playlistView
  }()

  /** The control view for interactive mode. */
  var cropSettingsView: CropBoxViewController?

  // For Pinch To Magnify gesture:
  var lastMagnification: CGFloat = 0.0
  var windowFrameAtMagnificationBegin = NSRect()
  var videoContainerFrameAtMagnificationBegin = NSRect()
  private lazy var magnificationGestureRecognizer: NSMagnificationGestureRecognizer = {
    return NSMagnificationGestureRecognizer(target: self, action: #selector(MainWindowController.handleMagnifyGesture(recognizer:)))
  }()

  // For Rotate gesture:
  /// Current rotation of `self.videoView`: see `VideoRotationHandler`
  let rotationHandler = VideoRotationHandler()
  private lazy var rotationGestureRecognizer: NSRotationGestureRecognizer = {
    return NSRotationGestureRecognizer(target: self, action: #selector(MainWindowController.handleRotationGesture(recognizer:)))
  }()

  /** For auto hiding UI after a timeout. */
  var hideFadeableViewsTimer: Timer?
  var hideOSDTimer: Timer?

  let animationQueue = UIAnimation.Queue()

  // MARK: - Status

  override var isOntop: Bool {
    didSet {
      updatePinToTopButton()
      updateSpacingForTitleBarAccessories()
    }
  }

  var isOpen: Bool {
    if !self.loaded {
      return false
    }
    guard let window = self.window else { return false }
    // Also check if hidden due to PIP
    return window.isVisible || isWindowHidden
  }
  private var isWindowHidden: Bool = false

  var hasKeyboardFocus: Bool {
    window?.isKeyWindow ?? false
  }

  /** For mpv's `geometry` option. We cache the parsed structure
   so never need to parse it every time. */
  var cachedGeometry: GeometryDef?

  var mousePosRelatedToWindow: CGPoint?
  var isDragging: Bool = false

  var pipStatus = PIPStatus.notInPIP
  var isInInteractiveMode: Bool = false

  var shouldApplyInitialWindowSize = true
  var isWindowMiniaturizedDueToPip = false
  var denyNextWindowResize = false

  // might use another obj to handle slider?
  var isMouseInWindow: Bool = false
  var isMouseInSlider: Bool = false

  var isFastforwarding: Bool = false

  var isPausedDueToInactive: Bool = false
  var isPausedDueToMiniaturization: Bool = false
  var isPausedPriorToInteractiveMode: Bool = false

  /** Views that will show/hide when cursor moving in/out the window. */
  var fadeableViews = Set<NSView>()

  var systemFadeableViews = Set<NSView>()

  // Left and right arrow buttons

  /** The maximum pressure recorded when clicking on the arrow buttons. */
  var maxPressure: Int32 = 0

  /** The value of speedValueIndex before Force Touch. */
  var oldIndex: Int = AppData.availableSpeedValues.count / 2

  /** When the arrow buttons were last clicked. */
  var lastClick = Date()

  /** The index of current speed in speed value array. */
  var speedValueIndex: Int = AppData.availableSpeedValues.count / 2 {
    didSet {
      if speedValueIndex < 0 || speedValueIndex >= AppData.availableSpeedValues.count {
        speedValueIndex = AppData.availableSpeedValues.count / 2
      }
    }
  }

  /** For force touch action */
  var isCurrentPressInSecondStage = false

  /** Whether current osd needs user interaction to be dismissed */
  var isShowingPersistentOSD = false
  var osdContext: Any?

  private var isClosing = false

  // MARK: - Enums

  // Window state

  var currentLayout = LayoutPlan(spec: LayoutSpec.initial())

  enum FullScreenState: Equatable {
    case windowed
    case animating(toFullscreen: Bool, legacy: Bool, priorWindowedFrame: NSRect)
    case fullscreen(legacy: Bool, priorWindowedFrame: NSRect)

    var isFullscreen: Bool {
      switch self {
      case .fullscreen: return true
      case let .animating(toFullscreen: toFullScreen, legacy: _, priorWindowedFrame: _): return toFullScreen
      default: return false
      }
    }

    var priorWindowedFrame: NSRect? {
      get {
        switch self {
        case .windowed: return nil
        case .animating(_, _, let p): return p
        case .fullscreen(_, let p): return p
        }
      }
      set {
        guard let newRect = newValue else { return }
        switch self {
        case .windowed: return
        case let .animating(toFullscreen, legacy, _):
          self = .animating(toFullscreen: toFullscreen, legacy: legacy, priorWindowedFrame: newRect)
        case let .fullscreen(legacy, _):
          self = .fullscreen(legacy: legacy, priorWindowedFrame: newRect)
        }
      }
    }

    mutating func startAnimatingToFullScreen(legacy: Bool, priorWindowedFrame: NSRect) {
      self = .animating(toFullscreen: true, legacy: legacy, priorWindowedFrame: priorWindowedFrame)
    }

    mutating func startAnimatingToWindow() {
      guard case .fullscreen(let legacy, let priorWindowedFrame) = self else { return }
      self = .animating(toFullscreen: false, legacy: legacy, priorWindowedFrame: priorWindowedFrame)
    }

    mutating func finishAnimating() {
      switch self {
      case .windowed, .fullscreen: assertionFailure("something went wrong with the state of the world. One must be .animating to finishAnimating. Not \(self)")
      case .animating(let toFullScreen, let legacy, let frame):
        if toFullScreen {
          self = .fullscreen(legacy: legacy, priorWindowedFrame: frame)
        } else{
          self = .windowed
        }
      }
    }
  }

  var fsState: FullScreenState = .windowed {
    didSet {
      // Must not access mpv while it is asynchronously processing stop and quit commands.
      guard !isClosing else { return }
      switch fsState {
      case .fullscreen: player.mpv.setFlag(MPVOption.Window.fullscreen, true)
      case .animating:  break
      case .windowed:   player.mpv.setFlag(MPVOption.Window.fullscreen, false)
      }
    }
  }

  /// Sidebars: see file `Sidebars.swift`
  var leadingSidebar = Sidebar(.leadingSidebar)
  var trailingSidebar = Sidebar(.trailingSidebar)
  lazy var sidebarsByID: [Preference.SidebarLocation: Sidebar] = [ leadingSidebar.locationID: self.leadingSidebar, trailingSidebar.locationID: self.trailingSidebar]

  enum PIPStatus {
    case notInPIP
    case inPIP
    case intermediate
  }

  enum InteractiveMode {
    case crop
    case freeSelecting

    func viewController() -> CropBoxViewController {
      var vc: CropBoxViewController
      switch self {
      case .crop:
        vc = CropSettingsViewController()
      case .freeSelecting:
        vc = FreeSelectingViewController()
      }
      return vc
    }
  }

  // Animation state

  /// Animation state of he hide/show part
  enum UIAnimationState {
    case shown, hidden, willShow, willHide

    var isInTransition: Bool {
      return self == .willShow || self == .willHide
    }
  }

  var animationState: UIAnimationState = .shown
  var osdAnimationState: UIAnimationState = .hidden

  // MARK: - Observed user defaults

  // Cached user default values
  private lazy var arrowBtnFunction: Preference.ArrowButtonAction = Preference.enum(for: .arrowButtonAction)
  private lazy var pinchAction: Preference.PinchAction = Preference.enum(for: .pinchAction)
  lazy var displayTimeAndBatteryInFullScreen: Bool = Preference.bool(for: .displayTimeAndBatteryInFullScreen)

  private static let mainWindowPrefKeys: [Preference.Key] = PlayerWindowController.playerWindowPrefKeys + [
    .osdPosition,
    .enableOSC,
    .oscPosition,
    .topPanelPlacement,
    .bottomPanelPlacement,
    .oscBarHeight,
    .oscBarPlaybackIconSize,
    .oscBarPlaybackIconSpacing,
    .controlBarToolbarButtons,
    .oscBarToolbarIconSize,
    .oscBarToolbarIconSpacing,
    .enableThumbnailPreview,
    .enableThumbnailForRemoteFiles,
    .thumbnailLength,
    .showChapterPos,
    .arrowButtonAction,
    .pinchAction,
    .blackOutMonitor,
    .useLegacyFullScreen,
    .displayTimeAndBatteryInFullScreen,
    .alwaysShowOnTopIcon,
    .leadingSidebarPlacement,
    .trailingSidebarPlacement,
    .settingsTabGroupLocation,
    .playlistTabGroupLocation,
    .showLeadingSidebarToggleButton,
    .showTrailingSidebarToggleButton
  ]

  override var observedPrefKeys: [Preference.Key] {
    MainWindowController.mainWindowPrefKeys
  }

  override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
    guard let keyPath = keyPath, let change = change else { return }
    super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)

    switch keyPath {
    case PK.enableOSC.rawValue,
      PK.oscPosition.rawValue,
      PK.topPanelPlacement.rawValue,
      PK.bottomPanelPlacement.rawValue,
      PK.oscBarHeight.rawValue,
      PK.oscBarPlaybackIconSize.rawValue,
      PK.oscBarPlaybackIconSpacing.rawValue,
      PK.showLeadingSidebarToggleButton.rawValue,
      PK.showTrailingSidebarToggleButton.rawValue,
      PK.oscBarToolbarIconSize.rawValue,
      PK.oscBarToolbarIconSpacing.rawValue,
      PK.controlBarToolbarButtons.rawValue:

      updateTitleBarAndOSC()
    case PK.thumbnailLength.rawValue:
      if let newValue = change[.newKey] as? Int {
        DispatchQueue.main.asyncAfter(deadline: .now() + AppData.thumbnailRegenerationDelay) {
          if newValue == Preference.integer(for: .thumbnailLength) && newValue != self.player.info.thumbnailLength {
            Logger.log("Pref \(Preference.Key.thumbnailLength.rawValue.quoted) changed to \(newValue)px: requesting thumbs regen",
                       subsystem: self.player.subsystem)
            self.player.reloadThumbnails()
          }
        }
      }
    case PK.enableThumbnailPreview.rawValue, PK.enableThumbnailForRemoteFiles.rawValue:
      // May need to remove thumbs or generate new ones: let method below figure it out:
      self.player.reloadThumbnails()

    case PK.showChapterPos.rawValue:
      if let newValue = change[.newKey] as? Bool {
        (playSlider.cell as! PlaySliderCell).drawChapters = newValue
      }
    case PK.verticalScrollAction.rawValue:
      if let newValue = change[.newKey] as? Int {
        verticalScrollAction = Preference.ScrollAction(rawValue: newValue)!
      }
    case PK.horizontalScrollAction.rawValue:
      if let newValue = change[.newKey] as? Int {
        horizontalScrollAction = Preference.ScrollAction(rawValue: newValue)!
      }
    case PK.arrowButtonAction.rawValue:
      if let newValue = change[.newKey] as? Int {
        arrowBtnFunction = Preference.ArrowButtonAction(rawValue: newValue)!
        updateArrowButtonImages()
      }
    case PK.pinchAction.rawValue:
      if let newValue = change[.newKey] as? Int {
        pinchAction = Preference.PinchAction(rawValue: newValue)!
      }
    case PK.blackOutMonitor.rawValue:
      if let newValue = change[.newKey] as? Bool {
        if fsState.isFullscreen {
          newValue ? blackOutOtherMonitors() : removeBlackWindows()
        }
      }
    case PK.useLegacyFullScreen.rawValue:
      resetCollectionBehavior()
    case PK.displayTimeAndBatteryInFullScreen.rawValue:
      if let newValue = change[.newKey] as? Bool {
        displayTimeAndBatteryInFullScreen = newValue
        if !newValue {
          additionalInfoView.isHidden = true
        }
      }
    case PK.alwaysShowOnTopIcon.rawValue:
      updatePinToTopButton()
      updateSpacingForTitleBarAccessories()
    case PK.leadingSidebarPlacement.rawValue:
      if leadingSidebar.isVisible {
        // Close whatever is showing, then open with new placement:
        hideSidebarThenShowAgain(leadingSidebar.locationID)
      }
    case PK.trailingSidebarPlacement.rawValue:
      if trailingSidebar.isVisible {
        hideSidebarThenShowAgain(trailingSidebar.locationID)
      }
    case PK.settingsTabGroupLocation.rawValue:
      if let newRawValue = change[.newKey] as? Int, let newLocationID = Preference.SidebarLocation(rawValue: newRawValue) {
        self.moveTabGroup(.settings, toSidebarLocation: newLocationID)
      }
    case PK.playlistTabGroupLocation.rawValue:
      if let newRawValue = change[.newKey] as? Int, let newLocationID = Preference.SidebarLocation(rawValue: newRawValue) {
        self.moveTabGroup(.playlist, toSidebarLocation: newLocationID)
      }
    case PK.osdPosition.rawValue:
      // If OSD is showing, it will move over as a neat animation:
      animationQueue.run(UIAnimation.zeroDurationTask {
        self.updateOSDPosition()
      })
    default:
      return
    }
  }

  // MARK: - Outlets

  // - Outlets: Constraints

  // Spacers in left title bar accessory view:
  @IBOutlet weak var leadingTitleBarLeadingSpaceConstraint: NSLayoutConstraint!
  @IBOutlet weak var leadingTitleBarTrailingSpaceConstraint: NSLayoutConstraint!

  // Spacers in right title bar accessory view:
  @IBOutlet weak var trailingTitleBarLeadingSpaceConstraint: NSLayoutConstraint!
  @IBOutlet weak var trailingTitleBarTrailingSpaceConstraint: NSLayoutConstraint!

  // - Top panel (title bar and/or top OSC) constraints
  @IBOutlet weak var videoContainerTopOffsetFromTopPanelBottomConstraint: NSLayoutConstraint!
  @IBOutlet weak var videoContainerTopOffsetFromTopPanelTopConstraint: NSLayoutConstraint!
  @IBOutlet weak var videoContainerTopOffsetFromContentViewTopConstraint: NSLayoutConstraint!
  // Needs to be changed to align with either sidepanel or left of screen:
  @IBOutlet weak var topPanelLeadingSpaceConstraint: NSLayoutConstraint!
  // Needs to be changed to align with either sidepanel or right of screen:
  @IBOutlet weak var topPanelTrailingSpaceConstraint: NSLayoutConstraint!

  // - Bottom OSC constraints
  @IBOutlet weak var videoContainerBottomOffsetFromBottomPanelTopConstraint: NSLayoutConstraint!
  @IBOutlet weak var videoContainerBottomOffsetFromBottomPanelBottomConstraint: NSLayoutConstraint!
  @IBOutlet weak var videoContainerBottomOffsetFromContentViewBottomConstraint: NSLayoutConstraint!
  // Needs to be changed to align with either sidepanel or left of screen:
  @IBOutlet weak var bottomPanelLeadingSpaceConstraint: NSLayoutConstraint!
  // Needs to be changed to align with either sidepanel or right of screen:
  @IBOutlet weak var bottomPanelTrailingSpaceConstraint: NSLayoutConstraint!

  // - Leading sidebar constraints
  @IBOutlet weak var videoContainerLeadingOffsetFromContentViewLeadingConstraint: NSLayoutConstraint!
  @IBOutlet weak var videoContainerLeadingOffsetFromLeadingSidebarLeadingConstraint: NSLayoutConstraint!
  @IBOutlet weak var videoContainerLeadingOffsetFromLeadingSidebarTrailingConstraint: NSLayoutConstraint!

  // - Trailing sidebar constraints
  @IBOutlet weak var videoContainerTrailingOffsetFromContentViewTrailingConstraint: NSLayoutConstraint!
  @IBOutlet weak var videoContainerTrailingOffsetFromTrailingSidebarLeadingConstraint: NSLayoutConstraint!
  @IBOutlet weak var videoContainerTrailingOffsetFromTrailingSidebarTrailingConstraint: NSLayoutConstraint!

  /**
   OSD: shown here in "upper-left" configuration.
   For "upper-right" config: swap OSD & AdditionalInfo anchors in A & B, and invert all the params of B.
   ┌───────────────────────┐
   │ A ┌────┐  ┌───────┐ B │  A: leadingSidebarToOSDSpaceConstraint
   │◄─►│ OSD│  │ AddNfo│◄─►│  B: trailingSidebarToOSDSpaceConstraint
   │   └────┘  └───────┘   │
   └───────────────────────┘
   */
  @IBOutlet weak var leadingSidebarToOSDSpaceConstraint: NSLayoutConstraint!
  @IBOutlet weak var trailingSidebarToOSDSpaceConstraint: NSLayoutConstraint!

  // The OSD should always be below the top panel + 8. But if top panel/title bar is transparent, we need this constraint
  @IBOutlet weak var osdMinOffsetFromTopConstraint: NSLayoutConstraint!

  @IBOutlet weak var bottomPanelBottomConstraint: NSLayoutConstraint!
  // Sets the size of the spacer view in the top overlay which reserves space for a title bar:
  @IBOutlet weak var titleBarHeightConstraint: NSLayoutConstraint!
  /// Size of each side of the 3 square playback buttons ⏪⏯️⏩ (`leftArrowButton`, Play/Pause, `rightArrowButton`):
  @IBOutlet weak var playbackButtonsSquareWidthConstraint: NSLayoutConstraint!
  /// Space added to the left and right of *each* of the 3 square playback buttons:
  @IBOutlet weak var playbackButtonsHorizontalPaddingConstraint: NSLayoutConstraint!
  @IBOutlet weak var topOSCHeightConstraint: NSLayoutConstraint!

  @IBOutlet weak var timePreviewWhenSeekHorizontalCenterConstraint: NSLayoutConstraint!

  // - Outlets: Views

  @IBOutlet var leadingTitleBarAccessoryView: NSView!
  @IBOutlet var trailingTitleBarAccessoryView: NSView!

  /** Top-of-video panel, may contain `titleBarView` and/or top OSC if configured. */
  @IBOutlet weak var topPanelView: NSVisualEffectView!
  /** Bottom border of `topPanelView`. */
  @IBOutlet weak var topPanelBottomBorder: NSBox!
  /** Reserves space for the title bar components. Does not contain any child views. */
  @IBOutlet weak var titleBarView: NSView!
  @IBOutlet weak var leadingSidebarToggleButton: NSButton!
  @IBOutlet weak var trailingSidebarToggleButton: NSButton!
  /** "Pin to Top" button in title bar, if configured to  be shown */
  @IBOutlet weak var pinToTopButton: NSButton!

  @IBOutlet weak var controlBarTitleBar: NSView!
  @IBOutlet weak var controlBarTop: NSView!
  @IBOutlet weak var controlBarFloating: ControlBarView!
  @IBOutlet weak var controlBarBottom: NSVisualEffectView!
  /** Top border of `controlBarBottom`. */
  @IBOutlet weak var controlBarBottomTopBorder: NSBox!
  @IBOutlet weak var timePreviewWhenSeek: NSTextField!
  @IBOutlet weak var leftArrowButton: NSButton!
  @IBOutlet weak var rightArrowButton: NSButton!
  @IBOutlet weak var leadingSidebarView: NSVisualEffectView!
  @IBOutlet weak var trailingSidebarView: NSVisualEffectView!
  @IBOutlet weak var bottomView: NSView!
  @IBOutlet weak var bufferIndicatorView: NSVisualEffectView!
  @IBOutlet weak var bufferProgressLabel: NSTextField!
  @IBOutlet weak var bufferSpin: NSProgressIndicator!
  @IBOutlet weak var bufferDetailLabel: NSTextField!
  @IBOutlet weak var thumbnailPeekView: ThumbnailPeekView!
  @IBOutlet weak var additionalInfoView: NSVisualEffectView!
  @IBOutlet weak var additionalInfoLabel: NSTextField!
  @IBOutlet weak var additionalInfoStackView: NSStackView!
  @IBOutlet weak var additionalInfoTitle: NSTextField!
  @IBOutlet weak var additionalInfoBatteryView: NSView!
  @IBOutlet weak var additionalInfoBattery: NSTextField!

  @IBOutlet weak var oscFloatingPlayButtonsContainerView: NSStackView!
  @IBOutlet weak var oscFloatingUpperView: NSStackView!
  @IBOutlet weak var oscFloatingLowerView: NSStackView!
  @IBOutlet weak var oscBottomMainView: NSStackView!
  @IBOutlet weak var oscTopMainView: NSStackView!

  private var fragToolbarView: NSStackView? = nil
  @IBOutlet weak var fragVolumeView: NSView!
  @IBOutlet weak var fragPositionSliderView: NSView!
  @IBOutlet weak var fragPlaybackControlButtonsView: NSView!

  @IBOutlet weak var leftArrowLabel: NSTextField!
  @IBOutlet weak var rightArrowLabel: NSTextField!

  @IBOutlet weak var osdVisualEffectView: NSVisualEffectView!
  @IBOutlet weak var osdStackView: NSStackView!
  @IBOutlet weak var osdLabel: NSTextField!
  @IBOutlet weak var osdAccessoryText: NSTextField!
  @IBOutlet weak var osdAccessoryProgress: NSProgressIndicator!

  @IBOutlet weak var pipOverlayView: NSVisualEffectView!
  @IBOutlet weak var videoContainerView: NSView!

  private var standardWindowButtons: [NSButton] {
    get {
      return ([.closeButton, .miniaturizeButton, .zoomButton, .documentIconButton] as [NSWindow.ButtonType]).compactMap {
        window?.standardWindowButton($0)
      }
    }
  }

  private var documentIconButton: NSButton? {
    get {
      window?.standardWindowButton(.documentIconButton)
    }
  }

  private var trafficLightButtons: [NSButton] {
    get {
      return ([.closeButton, .miniaturizeButton, .zoomButton] as [NSWindow.ButtonType]).compactMap {
        window?.standardWindowButton($0)
      }
    }
  }

  // Width of the 3 traffic light buttons
  private lazy var trafficLightButtonsWidth: CGFloat = {
    var maxX: CGFloat = 0
    for buttonType in [NSWindow.ButtonType.closeButton, NSWindow.ButtonType.miniaturizeButton, NSWindow.ButtonType.zoomButton] {
      if let button = window!.standardWindowButton(buttonType) {
        maxX = max(maxX, button.frame.origin.x + button.frame.width)
      }
    }
    return maxX
  }()

  /** Get the `NSTextField` of widow's title. */
  private var titleTextField: NSTextField? {
    get {
      return window?.standardWindowButton(.closeButton)?.superview?.subviews.compactMap({ $0 as? NSTextField }).first
    }
  }

  private var leadingTitlebarAccesoryViewController: NSTitlebarAccessoryViewController!
  private var trailingTitlebarAccesoryViewController: NSTitlebarAccessoryViewController!

  /** Current OSC view. May be top, bottom, or floating depneding on user pref. */
  private var currentControlBar: NSView?

  lazy var pluginOverlayViewContainer: NSView! = {
    guard let window = window, let cv = window.contentView else { return nil }
    let view = NSView(frame: .zero)
    view.translatesAutoresizingMaskIntoConstraints = false
    cv.addSubview(view, positioned: .below, relativeTo: bufferIndicatorView)
    Utility.quickConstraints(["H:|[v]|", "V:|[v]|"], ["v": view])
    return view
  }()

  lazy var subPopoverView = playlistView.subPopover?.contentViewController?.view

  struct VideoViewConstraints {
    let eqOffsetTop: NSLayoutConstraint
    let eqOffsetRight: NSLayoutConstraint
    let eqOffsetBottom: NSLayoutConstraint
    let eqOffsetLeft: NSLayoutConstraint

    let gtOffsetTop: NSLayoutConstraint
    let gtOffsetRight: NSLayoutConstraint
    let gtOffsetBottom: NSLayoutConstraint
    let gtOffsetLeft: NSLayoutConstraint

    let centerX: NSLayoutConstraint
    let centerY: NSLayoutConstraint
  }

  private var videoViewConstraints: VideoViewConstraints? = nil

  private var oscFloatingLeadingTrailingConstraint: [NSLayoutConstraint]?

  override var mouseActionDisabledViews: [NSView?] {[leadingSidebarView, trailingSidebarView, currentControlBar, titleBarView, oscTopMainView, subPopoverView]}

  // MARK: - PIP

  lazy var _pip: PIPViewController = {
    let pip = VideoPIPViewController()
    if #available(macOS 10.12, *) {
      pip.delegate = self
    }
    return pip
  }()
  
  @available(macOS 10.12, *)
  var pip: PIPViewController {
    _pip
  }

  var pipVideo: NSViewController!

  // MARK: - Initialization

  override init(playerCore: PlayerCore) {
    super.init(playerCore: playerCore)
    self.windowFrameAutosaveName = String(format: Constants.WindowAutosaveName.mainPlayer, playerCore.label)
    Logger.log("MainWindowController init, autosaveName: \(self.windowFrameAutosaveName.quoted)", level: .verbose, subsystem: playerCore.subsystem)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func windowDidLoad() {
    super.windowDidLoad()

    guard let window = window else { return }

    window.orderOut(self)

    // need to deal with control bar, so we handle it manually
    window.isMovableByWindowBackground  = false

    // set background color to black
    window.backgroundColor = .black

    // Sidebars

    leadingSidebar.placement = Preference.enum(for: .leadingSidebarPlacement)
    trailingSidebar.placement = Preference.enum(for: .trailingSidebarPlacement)

    let settingsSidebarLocation: Preference.SidebarLocation = Preference.enum(for: .settingsTabGroupLocation)
    sidebarsByID[settingsSidebarLocation]?.tabGroups.insert(.settings)

    let playlistSidebarLocation: Preference.SidebarLocation = Preference.enum(for: .playlistTabGroupLocation)
    sidebarsByID[playlistSidebarLocation]?.tabGroups.insert(.playlist)

    // Titlebar accessories

    // Update this here to reduce animation jitter on older versions of MacOS:
    videoContainerTopOffsetFromTopPanelTopConstraint.constant = StandardTitleBarHeight

    leadingTitlebarAccesoryViewController = NSTitlebarAccessoryViewController()
    leadingTitlebarAccesoryViewController.view = leadingTitleBarAccessoryView
    leadingTitlebarAccesoryViewController.layoutAttribute = .leading
    window.addTitlebarAccessoryViewController(leadingTitlebarAccesoryViewController)
    leadingTitleBarAccessoryView.translatesAutoresizingMaskIntoConstraints = false
    leadingTitleBarAccessoryView.heightAnchor.constraint(equalToConstant: StandardTitleBarHeight).isActive = true

    trailingTitlebarAccesoryViewController = NSTitlebarAccessoryViewController()
    trailingTitlebarAccesoryViewController.view = trailingTitleBarAccessoryView
    trailingTitlebarAccesoryViewController.layoutAttribute = .trailing
    window.addTitlebarAccessoryViewController(trailingTitlebarAccesoryViewController)
    trailingTitleBarAccessoryView.translatesAutoresizingMaskIntoConstraints = false
    trailingTitleBarAccessoryView.heightAnchor.constraint(equalToConstant: StandardTitleBarHeight).isActive = true

    // size
    window.minSize = PlayerCore.minVideoSize

    // osc views
    oscFloatingPlayButtonsContainerView.addView(fragPlaybackControlButtonsView, in: .center)

    updateArrowButtonImages()

    // video view
    guard let cv = window.contentView else { return }

    // gesture recognizers
    rotationHandler.mainWindowController = self
    cv.addGestureRecognizer(magnificationGestureRecognizer)
    cv.addGestureRecognizer(rotationGestureRecognizer)

    // Work around a bug in macOS Ventura where HDR content becomes dimmed when playing in full
    // screen mode once overlaying views are fully hidden (issue #3844). After applying this
    // workaround another bug in Ventura where an external monitor goes black could not be
    // reproduced (issue #4015). The workaround adds a tiny subview with such a low alpha level it
    // is invisible to the human eye. This workaround may not be effective in all cases.
    if #available(macOS 13, *) {
      let view = NSView(frame: NSRect(origin: .zero, size: NSSize(width: 0.1, height: 0.1)))
      view.wantsLayer = true
      view.layer?.backgroundColor = NSColor.black.cgColor
      view.layer?.opacity = 0.01
      cv.addSubview(view)
    }

    let roundedCornerRadius: CGFloat = CGFloat(Preference.float(for: .roundedCornerRadius))

    // init quick setting view now
    let _ = quickSettingView

    // other initialization
    osdAccessoryProgress.usesThreadedAnimation = false
    if #available(macOS 10.14, *) {
      topPanelBottomBorder.fillColor = NSColor(named: .titleBarBorder)!
    }
    cachedScreenIDs.removeAll()
    for screen in NSScreen.screens {
      cachedScreenIDs.insert(screen.displayId)
    }
    // Do not make visual effects views opaque when window is not in focus
    for view in [topPanelView, osdVisualEffectView, controlBarBottom, controlBarFloating,
                 leadingSidebarView, trailingSidebarView, osdVisualEffectView, pipOverlayView, bufferIndicatorView] {
      view?.state = .active
    }

    // buffer indicator view
    if roundedCornerRadius > 0.0 {
      bufferIndicatorView.roundCorners(withRadius: roundedCornerRadius)
      osdVisualEffectView.roundCorners(withRadius: roundedCornerRadius)
      additionalInfoView.roundCorners(withRadius: roundedCornerRadius)
    }
    updateBufferIndicatorView()
    updateOSDPosition()
    
    if player.disableUI { hideFadeableViews() }

    // add notification observers

    addObserver(to: .default, forName: .iinaFileLoaded, object: player) { [unowned self] _ in
      self.quickSettingView.reload()
    }

    addObserver(to: .default, forName: NSApplication.didChangeScreenParametersNotification) { [unowned self] _ in
      // This observer handles when the user connected a new screen or removed a screen, or shows/hides the Dock.

      // FIXME: this also handles the case where Dock was shown/hidden! Need to update window sizes accordingly

      var screenIDs = Set<UInt32>()
      for screen in NSScreen.screens {
        screenIDs.insert(screen.displayId)
      }
      Logger.log("Got \(NSApplication.didChangeScreenParametersNotification.rawValue.quoted); screenIDs was: \(self.cachedScreenIDs), is now: \(screenIDs)", subsystem: player.subsystem)
      if self.fsState.isFullscreen && Preference.bool(for: .blackOutMonitor) && screenIDs != self.cachedScreenIDs {
        self.removeBlackWindows()
        self.blackOutOtherMonitors()
      }
      // Update the cached value
      self.cachedScreenIDs = screenIDs

      self.videoView.updateDisplayLink()
      // In normal full screen mode AppKit will automatically adjust the window frame if the window
      // is moved to a new screen such as when the window is on an external display and that display
      // is disconnected. In legacy full screen mode IINA is responsible for adjusting the window's
      // frame.
      guard self.fsState.isFullscreen, Preference.bool(for: .useLegacyFullScreen) else { return }
      setWindowFrameForLegacyFullScreen()
    }

    // Observe the loop knobs on the progress bar and update mpv when the knobs move.
    addObserver(to: .default, forName: .iinaPlaySliderLoopKnobChanged, object: playSlider.abLoopA) { [weak self] _ in
      guard let self = self else { return }
      let seconds = self.percentToSeconds(self.playSlider.abLoopA.doubleValue)
      self.player.abLoopA = seconds
      self.player.sendOSD(.abLoopUpdate(.aSet, VideoTime(seconds).stringRepresentation))
    }
    addObserver(to: .default, forName: .iinaPlaySliderLoopKnobChanged, object: playSlider.abLoopB) { [weak self] _ in
      guard let self = self else { return }
      let seconds = self.percentToSeconds(self.playSlider.abLoopB.doubleValue)
      self.player.abLoopB = seconds
      self.player.sendOSD(.abLoopUpdate(.bSet, VideoTime(seconds).stringRepresentation))
    }

    player.events.emit(.windowLoaded)
  }

  /// Returns the position in seconds for the given percent of the total duration of the video the percentage represents.
  ///
  /// The number of seconds returned must be considered an estimate that could change. The duration of the video is obtained from
  /// the [mpv](https://mpv.io/manual/stable/) `duration` property. The documentation for this property cautions that
  /// mpv is not always able to determine the duration and when it does return a duration it may be an estimate. If the duration is
  /// unknown this method will fallback to using the current playback position, if that is known. Otherwise this method will return zero.
  /// - Parameter percent: Position in the video as a percentage of the duration.
  /// - Returns: The position in the video the given percentage represents.
  private func percentToSeconds(_ percent: Double) -> Double {
    if let duration = player.info.videoDuration?.second {
      return duration * percent / 100
    } else if let position = player.info.videoPosition?.second {
      return position * percent / 100
    } else {
      return 0
    }
  }

  /// When entering "windowed" mode (either from initial load, PIP, or music mode), call this to add/return `videoView`
  /// to this window. Will do nothing if it's already there.
  func addVideoViewToWindow() {
    guard !videoContainerView.subviews.contains(videoView) else { return }
    videoContainerView.addSubview(videoView)
    videoView.translatesAutoresizingMaskIntoConstraints = false
    // add constraints
    constrainVideoViewForWindowedMode()
  }

  // - MARK: VideoView Constraints

  private func addOrUpdate(_ existing: NSLayoutConstraint?,
                           _ attr: NSLayoutConstraint.Attribute, _ relation: NSLayoutConstraint.Relation, _ constant: CGFloat,
                           _ priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
    let constraint: NSLayoutConstraint
    if let existing = existing {
      constraint = existing
      constraint.animateToConstant(constant)
    } else {
      constraint = existing ?? NSLayoutConstraint(item: videoView, attribute: attr, relatedBy: relation, toItem: videoContainerView,
                                                  attribute: attr, multiplier: 1, constant: constant)
    }
    constraint.priority = priority
    return constraint
  }

  private func rebuildVideoViewConstraints(top: CGFloat = 0, right: CGFloat = 0, bottom: CGFloat = 0, left: CGFloat = 0,
                                           eqPriority: NSLayoutConstraint.Priority,
                                           gtPriority: NSLayoutConstraint.Priority,
                                           centerPriority: NSLayoutConstraint.Priority) -> VideoViewConstraints {
    let existing = self.videoViewConstraints
    let newConstraints = VideoViewConstraints(
      eqOffsetTop: addOrUpdate(existing?.eqOffsetTop, .top, .equal, top, eqPriority),
      eqOffsetRight: addOrUpdate(existing?.eqOffsetRight, .right, .equal, right, eqPriority),
      eqOffsetBottom: addOrUpdate(existing?.eqOffsetBottom, .bottom, .equal, bottom, eqPriority),
      eqOffsetLeft: addOrUpdate(existing?.eqOffsetLeft, .left, .equal, left, eqPriority),

      gtOffsetTop: addOrUpdate(existing?.gtOffsetTop, .top, .greaterThanOrEqual, top, gtPriority),
      gtOffsetRight: addOrUpdate(existing?.gtOffsetRight, .right, .lessThanOrEqual, right, gtPriority),
      gtOffsetBottom: addOrUpdate(existing?.gtOffsetBottom, .bottom, .lessThanOrEqual, bottom, gtPriority),
      gtOffsetLeft: addOrUpdate(existing?.gtOffsetLeft, .left, .greaterThanOrEqual, left, gtPriority),

      centerX: existing?.centerX ?? videoView.centerXAnchor.constraint(equalTo: videoContainerView.centerXAnchor),
      centerY: existing?.centerY ?? videoView.centerYAnchor.constraint(equalTo: videoContainerView.centerYAnchor)
    )
    newConstraints.centerX.priority = centerPriority
    newConstraints.centerY.priority = centerPriority
    return newConstraints
  }

  // TODO: figure out why this 2px adjustment is necessary
  private func constrainVideoViewForWindowedMode(top: CGFloat = -2, right: CGFloat = 0, bottom: CGFloat = 0, left: CGFloat = -2) {
    // Remove GT & center constraints. Use only EQ
    let existing = self.videoViewConstraints
    if let existing = existing {
      existing.gtOffsetTop.isActive = false
      existing.gtOffsetRight.isActive = false
      existing.gtOffsetBottom.isActive = false
      existing.gtOffsetLeft.isActive = false

      existing.centerX.isActive = false
      existing.centerY.isActive = false
    }
    let newConstraints = rebuildVideoViewConstraints(top: top, right: right, bottom: bottom, left: left,
                                                     eqPriority: .required,
                                                     gtPriority: .defaultLow,
                                                     centerPriority: .defaultLow)
    newConstraints.eqOffsetTop.isActive = true
    newConstraints.eqOffsetRight.isActive = true
    newConstraints.eqOffsetBottom.isActive = true
    newConstraints.eqOffsetLeft.isActive = true
    videoViewConstraints = newConstraints
    window?.layoutIfNeeded()
  }

  private func constrainVideoViewForFullScreen() {
    // GT + center constraints are main priority, but include EQ as hint for ideal placement
    let newConstraints = rebuildVideoViewConstraints(eqPriority: .defaultLow,
                                                     gtPriority: .required,
                                                     centerPriority: .required)
    newConstraints.gtOffsetTop.isActive = true
    newConstraints.gtOffsetRight.isActive = true
    newConstraints.gtOffsetBottom.isActive = true
    newConstraints.gtOffsetLeft.isActive = true

    newConstraints.centerX.isActive = true
    newConstraints.centerY.isActive = true
    videoViewConstraints = newConstraints
    window?.layoutIfNeeded()
  }

  /** Set material for OSC and title bar */
  override internal func setMaterial(_ theme: Preference.Theme?) {
    if #available(macOS 10.14, *) {
      super.setMaterial(theme)
      return
    }
    guard let window = window, let theme = theme else { return }

    let (appearance, material) = Utility.getAppearanceAndMaterial(from: theme)
    let isDarkTheme = appearance?.isDark ?? true
    (playSlider.cell as? PlaySliderCell)?.isInDarkTheme = isDarkTheme

    for view in [topPanelView, controlBarFloating, controlBarBottom,
                 osdVisualEffectView, pipOverlayView, additionalInfoView, bufferIndicatorView] {
      view?.material = material
      view?.appearance = appearance
    }

    for sidebar in [leadingSidebarView, trailingSidebarView] {
      sidebar?.material = .dark
      sidebar?.appearance = NSAppearance(named: .vibrantDark)
    }

    window.appearance = appearance
  }

  // - MARK: Controllers & Title Bar Layout

  /**
   This ONLY updates the constraints to toggle between `inside` and `outside` placement types.
   Whether it is actually shown is a concern for somewhere else.
           "Outside"
         ┌─────────────┐
         │  Title Bar  │   Top of    Top of
         ├─────────────┤    Video    Video
         │   Top OSC   │        │    │            "Inside"
   ┌─────┼─────────────┼─────┐◄─┘    └─►┌─────┬─────────────┬─────┐
   │     │            V│     │          │     │  Title Bar V│     │
   │ Left│            I│Right│          │ Left├────────────I│Right│
   │ Side│            D│Side │          │ Side│   Top OSC  D│Side │
   │  bar│            E│bar  │          │  bar├────────────E│bar  │
   │     │  VIDEO     O│     │          │     │  VIDEO     O│     │
   └─────┴─────────────┴─────┘          └─────┴─────────────┴─────┘
   */
  private func updateTopPanelPlacement(placement: Preference.PanelPlacement) {
    Logger.log("Updating top panel placement to: \(placement)", level: .verbose)
    guard let window = window, let contentView = window.contentView else { return }
    contentView.removeConstraint(topPanelLeadingSpaceConstraint)
    contentView.removeConstraint(topPanelTrailingSpaceConstraint)

    switch placement {
    case .outsideVideo:
      // Align left & right sides with window (sidebars go below top panel)
      topPanelLeadingSpaceConstraint = topPanelView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 0)
      topPanelTrailingSpaceConstraint = topPanelView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: 0)

      // No shadow when outside
      /// NOTE: in order to do less work, these assume `trailingSidebarView` is above `leadingSidebarView`
      /// (i.e. comes after it in the list of `contentView`'s subviews in the XIB)
      contentView.addSubview(topPanelView, positioned: .above, relativeTo: trailingSidebarView)
    case .insideVideo:
      // Align left & right sides with sidebars (top panel will squeeze to make space for sidebars)
      topPanelLeadingSpaceConstraint = topPanelView.leadingAnchor.constraint(equalTo: leadingSidebarView.trailingAnchor, constant: 0)
      topPanelTrailingSpaceConstraint = topPanelView.trailingAnchor.constraint(equalTo: trailingSidebarView.leadingAnchor, constant: 0)

      // Sidebars cast shadow on top panel
      contentView.addSubview(topPanelView, positioned: .below, relativeTo: leadingSidebarView)
    }
    topPanelLeadingSpaceConstraint.isActive = true
    topPanelTrailingSpaceConstraint.isActive = true
  }

  private func updateTopPanelHeight(to topPanelHeight: CGFloat, transition: LayoutTransition) {
    let placement = transition.toLayout.topPanelPlacement
    Logger.log("TopPanel height: \(topPanelHeight), placement: \(placement)", level: .verbose, subsystem: player.subsystem)

    switch placement {
    case .outsideVideo:
      videoContainerTopOffsetFromTopPanelBottomConstraint.animateToConstant(0)
      videoContainerTopOffsetFromTopPanelTopConstraint.animateToConstant(topPanelHeight)
      videoContainerTopOffsetFromContentViewTopConstraint.animateToConstant(topPanelHeight)
    case .insideVideo:
      videoContainerTopOffsetFromTopPanelBottomConstraint.animateToConstant(-topPanelHeight)
      videoContainerTopOffsetFromTopPanelTopConstraint.animateToConstant(0)
      videoContainerTopOffsetFromContentViewTopConstraint.animateToConstant(0)
    }
  }

  private func updateBottomPanelPlacement(placement: Preference.PanelPlacement) {
    Logger.log("Updating bottom panel placement to: \(placement)", level: .verbose, subsystem: player.subsystem)
    guard let window = window, let contentView = window.contentView else { return }
    contentView.removeConstraint(bottomPanelLeadingSpaceConstraint)
    contentView.removeConstraint(bottomPanelTrailingSpaceConstraint)

    switch placement {
    case .outsideVideo:
      controlBarBottomTopBorder.isHidden = false

      // Align left & right sides with window (sidebars go below top panel)
      bottomPanelLeadingSpaceConstraint = controlBarBottom.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 0)
      bottomPanelTrailingSpaceConstraint = controlBarBottom.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: 0)

      // No shadow (because bottom panel does not cast a shadow)
      /// NOTE: in order to do less work, these assume `trailingSidebarView` is above `leadingSidebarView`
      /// (i.e. comes after it in the list of `contentView`'s subviews in the XIB)
      contentView.addSubview(controlBarBottom, positioned: .above, relativeTo: trailingSidebarView)
    case .insideVideo:
      controlBarBottomTopBorder.isHidden = true

      // Align left & right sides with sidebars (top panel will squeeze to make space for sidebars)
      bottomPanelLeadingSpaceConstraint = controlBarBottom.leadingAnchor.constraint(equalTo: leadingSidebarView.trailingAnchor, constant: 0)
      bottomPanelTrailingSpaceConstraint = controlBarBottom.trailingAnchor.constraint(equalTo: trailingSidebarView.leadingAnchor, constant: 0)

      // Sidebars cast shadow on bottom OSC
      contentView.addSubview(controlBarBottom, positioned: .below, relativeTo: leadingSidebarView)
    }
    bottomPanelLeadingSpaceConstraint.isActive = true
    bottomPanelTrailingSpaceConstraint.isActive = true
  }

  private func updateBottomPanelHeight(to bottomOSCHeight: CGFloat, transition: LayoutTransition) {
    let placement = transition.toLayout.bottomPanelPlacement
    Logger.log("Updating bottomOSC height to: \(bottomOSCHeight), placement: \(placement)", level: .verbose, subsystem: player.subsystem)

    switch placement {
    case .outsideVideo:
      videoContainerBottomOffsetFromBottomPanelTopConstraint.animateToConstant(0)
      videoContainerBottomOffsetFromBottomPanelBottomConstraint.animateToConstant(-bottomOSCHeight)
      videoContainerBottomOffsetFromContentViewBottomConstraint.animateToConstant(bottomOSCHeight)
    case .insideVideo:
      videoContainerBottomOffsetFromBottomPanelTopConstraint.animateToConstant(bottomOSCHeight)
      videoContainerBottomOffsetFromBottomPanelBottomConstraint.animateToConstant(0)
      videoContainerBottomOffsetFromContentViewBottomConstraint.animateToConstant(0)
    }
  }

  private func updatePinToTopButton() {
    let buttonVisibility = currentLayout.computePinToTopButtonVisibility(isOnTop: isOntop)
    pinToTopButton.state = isOntop ? .on : .off
    apply(visibility: buttonVisibility, to: pinToTopButton)
    if buttonVisibility == .showFadeable {
      showFadeableViews()
    }
  }

  private func rebuildToolbar(iconSize: CGFloat? = nil, iconPadding: CGFloat? = nil) -> NSStackView {
    let buttonTypeRawValues = Preference.array(for: .controlBarToolbarButtons) as? [Int] ?? []
    var buttonTypes = buttonTypeRawValues.compactMap(Preference.ToolBarButton.init(rawValue:))
    if #available(macOS 10.12.2, *) {} else {
      buttonTypes = buttonTypes.filter { $0 != .pip }
    }
    Logger.log("Adding buttons to OSC toolbar: \(buttonTypes)", level: .verbose, subsystem: player.subsystem)

    var toolButtons: [OSCToolbarButton] = []
    for buttonType in buttonTypes {
      let button = OSCToolbarButton()
      button.setStyle(buttonType: buttonType, iconSize: iconSize, iconPadding: iconPadding)
      button.action = #selector(self.toolBarButtonAction(_:))
      toolButtons.append(button)
    }

    if let stackView = fragToolbarView {
      stackView.views.forEach { stackView.removeView($0) }
      stackView.removeFromSuperview()
      fragToolbarView = nil
    }
    let toolbarView = NSStackView(views: toolButtons)
    toolbarView.orientation = .horizontal

    for button in toolButtons {
      toolbarView.setVisibilityPriority(.detachOnlyIfNecessary, for: button)
    }

    // FIXME: this causes a crash due to conflicting constraints. Need to rewrite layout for toolbar button spacing!
    // It's not possible to control the icon padding from inside the buttons in all cases.
    // Instead we can get the same effect with a little more work, by controlling the stack view:
//    if !toolButtons.isEmpty {
//      let button = toolButtons[0]
//      toolbarView.spacing = 2 * button.iconPadding
//      toolbarView.edgeInsets = .init(top: button.iconPadding, left: button.iconPadding,
//                                     bottom: button.iconPadding, right: button.iconPadding)
//      Logger.log("Toolbar spacing: \(toolbarView.spacing), edgeInsets: \(toolbarView.edgeInsets)", level: .verbose, subsystem: player.subsystem)
//    }
    return toolbarView
  }

  enum Visibility {
    case hidden
    case showAlways
    case showFadeable

    var isShowable: Bool {
      return self != .hidden
    }
  }

  struct LayoutSpec {
    let isFullScreen:  Bool
    let topPanelPlacement: Preference.PanelPlacement
    let bottomPanelPlacement: Preference.PanelPlacement
    let enableOSC: Bool
    let oscPosition: Preference.OSCPosition

    static func fromPreferences(isFullScreen: Bool) -> LayoutSpec {
      // If in fullscreen, top & bottom panels are always .insideVideo
      return LayoutSpec(isFullScreen: isFullScreen,
                        topPanelPlacement: Preference.enum(for: .topPanelPlacement),
                        bottomPanelPlacement: Preference.enum(for: .bottomPanelPlacement),
                        enableOSC: Preference.bool(for: .enableOSC),
                        oscPosition: Preference.enum(for: .oscPosition))
    }

    // Matches what is shown in the XIB
    static func initial() -> LayoutSpec {
      return LayoutSpec(isFullScreen: false,
                        topPanelPlacement:.insideVideo,
                        bottomPanelPlacement: .insideVideo,
                        enableOSC: false,
                        oscPosition: .floating)
    }

    func clone(fullScreen: Bool) -> LayoutSpec {
      return LayoutSpec(isFullScreen: fullScreen,
                        topPanelPlacement: self.topPanelPlacement,
                        bottomPanelPlacement: self.bottomPanelPlacement,
                        enableOSC: self.enableOSC,
                        oscPosition: self.oscPosition)
    }
  }

  /// "Layout" would be a better name for this class, but it's already taken by AppKit.
  class LayoutPlan {
    // All other variables in this class are derived from this spec:
    let spec: LayoutSpec

    // Visiblity of views/categories:

    var titleIconAndText: Visibility = .hidden

    var trafficLightButtons: Visibility = .hidden
    var titlebarAccessoryViewControllers: Visibility = .hidden
    var leadingSidebarToggleButton: Visibility = .hidden
    var trailingSidebarToggleButton: Visibility = .hidden
    var pinToTopButton: Visibility = .hidden

    var controlBarFloating: Visibility = .hidden
    var controlBarBottom: Visibility = .hidden
    var topPanelView: Visibility = .hidden

    var titleBarHeight: CGFloat = 0
    var topOSCHeight: CGFloat = 0
    var topPanelHeight: CGFloat {
      self.titleBarHeight + self.topOSCHeight
    }

    var bottomOSCHeight: CGFloat = 0
    /// This exists as a fallback for the case where the title bar has a transparent background but still shows its items.
    /// For most cases, spacing between OSD and top of `videoContainerView` >= 8pts
    var osdMinOffsetFromTop: CGFloat = 8

    var setupControlBarInternalViews: TaskFunc? = nil

    init(spec: LayoutSpec) {
      self.spec = spec
    }

    var isFullScreen: Bool {
      return spec.isFullScreen
    }

    var enableOSC: Bool {
      return spec.enableOSC
    }

    var oscPosition: Preference.OSCPosition {
      return spec.oscPosition
    }

    var topPanelPlacement: Preference.PanelPlacement {
      return spec.topPanelPlacement
    }

    var bottomPanelPlacement: Preference.PanelPlacement {
      return spec.bottomPanelPlacement
    }

    var hasFloatingOSC: Bool {
      return enableOSC && oscPosition == .floating
    }

    var hasTopOSC: Bool {
      return enableOSC && oscPosition == .top
    }

    var hasPermanentOSC: Bool {
      return enableOSC && ((oscPosition == .top && topPanelPlacement == .outsideVideo) ||
                           (oscPosition == .bottom && bottomPanelPlacement == .outsideVideo))
    }

    func computePinToTopButtonVisibility(isOnTop: Bool) -> Visibility {
      let showOnTopStatus = Preference.bool(for: .alwaysShowOnTopIcon) || isOnTop
      if isFullScreen || !showOnTopStatus {
        return .hidden
      }

      if topPanelPlacement == .insideVideo {
        return .showFadeable
      }

      return .showAlways
    }
  }  // end class LayoutPlan

  private func apply(visibility: Visibility, to view: NSView) {
    switch visibility {
    case .hidden:
      view.alphaValue = 0
      view.isHidden = true
      fadeableViews.remove(view)
    case .showAlways:
      view.alphaValue = 1
      view.isHidden = false
      fadeableViews.remove(view)
    case .showFadeable:
      view.alphaValue = 1
      view.isHidden = false
      fadeableViews.insert(view)
    }
  }

  private func apply(visibility: Visibility, _ views: NSView?...) {
    for view in views {
      if let view = view {
        apply(visibility: visibility, to: view)
      }
    }
  }

  private func applyHiddenOnly(visibility: Visibility, to view: NSView) {
    guard visibility == .hidden else { return }
    apply(visibility: visibility, view)
  }

  private func applyShowableOnly(visibility: Visibility, to view: NSView) {
    guard visibility != .hidden else { return }
    apply(visibility: visibility, view)
  }

  class LayoutTransition {
    let fromLayout: LayoutPlan
    let toLayout: LayoutPlan
    let isInitialLayout: Bool

    var animationTasks: [UIAnimation.Task] = []

    init(from fromLayout: LayoutPlan, to toLayout: LayoutPlan, isInitialLayout: Bool = false) {
      self.fromLayout = fromLayout
      self.toLayout = toLayout
      self.isInitialLayout = isInitialLayout
    }

    var isTogglingFullScreen: Bool {
      return self.fromLayout.isFullScreen != self.toLayout.isFullScreen
    }

    var isTogglingToFullScreen: Bool {
      return !self.fromLayout.isFullScreen && self.toLayout.isFullScreen
    }

    var isTogglingFromFullScreen: Bool {
      return self.fromLayout.isFullScreen && !self.toLayout.isFullScreen
    }

    var isTopPanelPlacementChanging: Bool {
      return self.fromLayout.topPanelPlacement != self.toLayout.topPanelPlacement
    }

    var isBottomPanelPlacementChanging: Bool {
      return self.fromLayout.bottomPanelPlacement != self.toLayout.bottomPanelPlacement
    }
  }

  private func transitionToInitialLayout() {
    Logger.log("Setting initial layout", level: .verbose, subsystem: player.subsystem)
    let initialLayoutSpec = LayoutSpec.fromPreferences(isFullScreen: fsState.isFullscreen)
    let initialLayout = buildFutureLayoutPlan(from: initialLayoutSpec)

    let transition = LayoutTransition(from: currentLayout, to: initialLayout, isInitialLayout: true)
    // For initial layout (when window is first shown), to reduce jitteriness when drawing,
    // do all the layout in a single animation block

    UIAnimation.disableAnimation{
      controlBarFloating.isDragging = false
      currentLayout = initialLayout
      fadeOutOldViews(transition)
      closeOldPanels(transition)
      updateHiddenViewsAndConstraints(transition)
      openNewPanels(transition)
      fadeInNewViews(transition)
      updatePanelBlendingModes(to: transition.toLayout)
      apply(visibility: transition.toLayout.titleIconAndText, titleTextField, documentIconButton)
      animationState = .shown
      resetFadeTimer()
    }
  }

  private func updateTitleBarAndOSC() {
    guard !isInInteractiveMode else {
      Logger.log("Skipping layout refresh due to interactive mode", level: .verbose, subsystem: player.subsystem)
      return
    }
    let futureLayoutSpec = LayoutSpec.fromPreferences(isFullScreen: fsState.isFullscreen)
    let transition = buildLayoutTransition(to: futureLayoutSpec)
    animationQueue.run(transition.animationTasks)
  }

  // TODO: Prevent sidebars from opening if not enough space?
  // FIXME: bug: size of window is not restored properly during fullscreen exit animation if "outside" sidebars opened/closed
  /// First builds a new `LayoutPlan` based on the given `LayoutSpec`, then builds & returns a `LayoutTransition`,
  /// which contains all the information needed to animate the UI changes from the current `LayoutPlan` to the new one.
  private func buildLayoutTransition(to layoutSpec: LayoutSpec,
                                     totalStartingDuration: CGFloat? = nil,
                                     totalEndingDuration: CGFloat? = nil,
                                     extraTaskFunc: TaskFunc? = nil) -> LayoutTransition {

    let futureLayout = buildFutureLayoutPlan(from: layoutSpec)
    let transition = LayoutTransition(from: currentLayout, to: futureLayout, isInitialLayout: false)

    let startingAnimationCount: CGFloat = 3

    let startingAnimationDuration: CGFloat
    let endingAnimationDuration: CGFloat = totalEndingDuration ?? UIAnimation.DefaultDuration
    if let totalStartingDuration = totalStartingDuration {
      startingAnimationDuration = totalStartingDuration / startingAnimationCount
    } else {
      startingAnimationDuration = UIAnimation.DefaultDuration
    }

    /// When toggling panel layout configurations, need to use `linear` or else panels of different sizes
    /// won't line up as they move. But during the fullscreen transition, this looks tediously slow.
    /// Fortunately, we don't need `linear` for the fullscreen transition.
    let panelTimingFunction = transition.isTogglingFullScreen ? nil : CAMediaTimingFunction(name: .linear)

    Logger.log("Refreshing title bar & OSC layout. EachStartDuration: \(startingAnimationDuration), EachEndDuration: \(endingAnimationDuration)", level: .verbose, subsystem: player.subsystem)

    // Starting animations:

    // Set initial var
    transition.animationTasks.append(UIAnimation.zeroDurationTask{ [self] in
      controlBarFloating.isDragging = false
      /// Some methods where reference `currentLayout` get called as a side effect of the transition animations.
      /// To avoid possible bugs as a result, let's update this at the very beginning.
      currentLayout = futureLayout
    })

    // StartingAnimation 1: show fadeable views from current layout
    for fadeAnimation in buildAnimationToShowFadeableViews(restartFadeTimer: false, duration: startingAnimationDuration) {
      transition.animationTasks.append(fadeAnimation)
    }

    // StartingAnimation 2: Fade out views which no longer will be shown but aren't enclosed in a panel.
    transition.animationTasks.append(UIAnimation.Task(duration: startingAnimationDuration, { [self] in
      fadeOutOldViews(transition)
    }))

    if !transition.isTogglingToFullScreen {  // Avoid bounciness and possible unwanted video scaling animation (not needed for ->FS anyway)
      // StartingAnimation 3: Minimize panels which are no longer needed.
      transition.animationTasks.append(UIAnimation.Task(duration: startingAnimationDuration, timingFunction: panelTimingFunction, { [self] in
        closeOldPanels(transition)
      }))
    }

    // Ending animations:

    // Not animated: Update constraints. Should have no visible changes.
    transition.animationTasks.append(UIAnimation.zeroDurationTask{ [self] in
      updateHiddenViewsAndConstraints(transition)
    })

    // EndingAnimation: Open new panels and fade in new views
    transition.animationTasks.append(UIAnimation.Task(duration: endingAnimationDuration, timingFunction: panelTimingFunction, { [self] in
      if let extraTaskFunc = extraTaskFunc {
        extraTaskFunc()
      }

      openNewPanels(transition)
      fadeInNewViews(transition)
    }))

    // After animations all finish, start fade timer
    transition.animationTasks.append(UIAnimation.zeroDurationTask{ [self] in
      // Update blending mode:
      updatePanelBlendingModes(to: futureLayout)
      /// This should go in `fadeInNewViews()`, but for some reason putting it here fixes a bug where the document icon won't fade out
      apply(visibility: futureLayout.titleIconAndText, titleTextField, documentIconButton)

      animationState = .shown
      resetFadeTimer()
    })

    return transition
  }

  private func fadeOutOldViews(_ transition: LayoutTransition) {
    animationState = .willHide
    let futureLayout = transition.toLayout
    Logger.log("FadeOutOldViews", level: .verbose, subsystem: player.subsystem)

    // Title bar & title bar accessories:

    // Hide all title bar items if top panel placement is changing
    if futureLayout.titleIconAndText == .hidden || transition.isTopPanelPlacementChanging {
      apply(visibility: .hidden, documentIconButton, titleTextField)
    }

    if futureLayout.trafficLightButtons == .hidden || transition.isTopPanelPlacementChanging {
      /// Workaround for Apple bug (as of MacOS 13.3.1) where setting `alphaValue=0` on the "minimize" button will
      /// cause `window.performMiniaturize()` to be ignored. So to hide these, use `isHidden=true` + `alphaValue=1` instead.
      for button in trafficLightButtons {
        button.isHidden = true
      }
    }

    if transition.isTopPanelPlacementChanging || futureLayout.titlebarAccessoryViewControllers == .hidden {
      // Hide all title bar accessories (if needed):
      leadingTitleBarAccessoryView.alphaValue = 0
      fadeableViews.remove(leadingTitleBarAccessoryView)
      trailingTitleBarAccessoryView.alphaValue = 0
      fadeableViews.remove(trailingTitleBarAccessoryView)
    } else {
      /// We may have gotten here in response to one of these buttons' visibility being toggled in the prefs,
      /// so we need to allow for showing/hiding these individually.
      /// Setting `.isHidden = true` for these icons visibly messes up their layout.
      /// So just set alpha value for now, and hide later in `updateHiddenViewsAndConstraints()`
      if futureLayout.leadingSidebarToggleButton == .hidden {
        leadingSidebarToggleButton.alphaValue = 0
        fadeableViews.remove(leadingSidebarToggleButton)
      }
      if futureLayout.trailingSidebarToggleButton == .hidden {
        trailingSidebarToggleButton.alphaValue = 0
        fadeableViews.remove(trailingSidebarToggleButton)
      }
      if futureLayout.pinToTopButton == .hidden {
        pinToTopButton.alphaValue = 0
        fadeableViews.remove(pinToTopButton)
      }
    }

    // Change blending modes
    if transition.isTogglingFullScreen {
      /// Need to use `.withinWindow` during animation or else panel tint can change in odd ways
      topPanelView.blendingMode = .withinWindow
      controlBarBottom.blendingMode = .withinWindow
      leadingSidebarView.blendingMode = .withinWindow
      trailingSidebarView.blendingMode = .withinWindow
    }
  }

  private func closeOldPanels(_ transition: LayoutTransition) {
    guard let window = window else { return }
    let futureLayout = transition.toLayout
    Logger.log("CloseOldPanels: title_H=\(futureLayout.titleBarHeight), topOSC_H=\(futureLayout.topOSCHeight)", level: .verbose, subsystem: player.subsystem)

    if futureLayout.titleBarHeight == 0 {
      titleBarHeightConstraint.animateToConstant(0)
    }
    if futureLayout.topOSCHeight == 0 {
      topOSCHeightConstraint.animateToConstant(0)
    }
    if futureLayout.osdMinOffsetFromTop == 0 {
      osdMinOffsetFromTopConstraint.animateToConstant(0)
    }

    // Update heights of top & bottom panels:

    let windowFrame = window.frame
    var windowYDelta: CGFloat = 0
    var windowHeightDelta: CGFloat = 0

    var needsTopPanelHeightUpdate = false
    var newTopPanelHeight: CGFloat = 0
    if !transition.isInitialLayout && transition.isTopPanelPlacementChanging {
      needsTopPanelHeightUpdate = true
      // close completely. will animate reopening if needed later
      newTopPanelHeight = 0
    } else if futureLayout.topPanelHeight < transition.fromLayout.topPanelHeight {
      needsTopPanelHeightUpdate = true
      newTopPanelHeight = futureLayout.topPanelHeight
    }

    if needsTopPanelHeightUpdate {
      // By default, when the window size changes, the system will add or subtract space from the bottom of the window.
      // Override this behavior to expand/contract upwards instead.
      if transition.fromLayout.topPanelPlacement == .outsideVideo {
        windowHeightDelta -= videoContainerTopOffsetFromContentViewTopConstraint.constant
      }
      if transition.toLayout.topPanelPlacement == .outsideVideo {
        windowHeightDelta += newTopPanelHeight
      }

      updateTopPanelHeight(to: newTopPanelHeight, transition: transition)
    }

    var needsBottomPanelHeightUpdate = false
    var newBottomPanelHeight: CGFloat = 0
    if !transition.isInitialLayout && transition.isBottomPanelPlacementChanging {
      needsBottomPanelHeightUpdate = true
      // close completely. will animate reopening if needed later
      newBottomPanelHeight = 0
    } else if futureLayout.bottomOSCHeight < transition.fromLayout.bottomOSCHeight {
      needsBottomPanelHeightUpdate = true
      newBottomPanelHeight = futureLayout.bottomOSCHeight
    }

    if needsBottomPanelHeightUpdate {
      /// Because we are calling `setFrame()` to update the top panel, we also need to take the bottom panel into
      /// account. Otherwise the system may choose to move the window in an unwanted arbitrary direction.
      /// We want the bottom panel, if "outside" the video, to expand/collapse on the bottom side.
      if transition.fromLayout.bottomPanelPlacement == .outsideVideo {
        windowHeightDelta -= videoContainerBottomOffsetFromContentViewBottomConstraint.constant
        windowYDelta -= videoContainerBottomOffsetFromContentViewBottomConstraint.constant
      }
      if transition.toLayout.bottomPanelPlacement == .outsideVideo {
        windowHeightDelta += newBottomPanelHeight
        windowYDelta += newBottomPanelHeight
      }

      updateBottomPanelHeight(to: newBottomPanelHeight, transition: transition)
    }

    // Update sidebar vertical alignments to match:
    if futureLayout.topPanelHeight < transition.fromLayout.topPanelHeight {
      refreshSidebarVerticalConstraints(layout: futureLayout)
    }

    // Do not do this when first opening the window though, because it will cause the window location restore to be incorrect.
    // Also do not apply when toggling fullscreen because it is not relevant and will cause glitches in the animation.
    if !transition.isInitialLayout && !transition.isTogglingFullScreen && !futureLayout.isFullScreen {
      let newWindowSize = CGSize(width: windowFrame.width, height: windowFrame.height + windowHeightDelta)
      let newOrigin = CGPoint(x: windowFrame.origin.x, y: windowFrame.origin.y - windowYDelta)
      let newWindowFrame = NSRect(origin: newOrigin, size: newWindowSize)
      window.setFrame(newWindowFrame, display: true, animate: true)
    }

    if transition.fromLayout.hasFloatingOSC && !futureLayout.hasFloatingOSC {
      // Hide floating OSC
      apply(visibility: futureLayout.controlBarFloating, to: controlBarFloating)
    }

    window.contentView?.layoutSubtreeIfNeeded()
  }

  private func updateHiddenViewsAndConstraints(_ transition: LayoutTransition) {
    guard let window = window else { return }
    let futureLayout = transition.toLayout
    Logger.log("UpdateHiddenViewsAndConstraints", level: .verbose, subsystem: player.subsystem)

    applyHiddenOnly(visibility: futureLayout.leadingSidebarToggleButton, to: leadingSidebarToggleButton)
    applyHiddenOnly(visibility: futureLayout.trailingSidebarToggleButton, to: trailingSidebarToggleButton)
    applyHiddenOnly(visibility: futureLayout.pinToTopButton, to: pinToTopButton)

    updateSpacingForTitleBarAccessories(futureLayout)

    if futureLayout.titleIconAndText == .hidden || transition.isTopPanelPlacementChanging {
      /// Note: MUST use `titleVisibility` to guarantee that `documentIcon` & `titleTextField` are shown/hidden consistently.
      /// Setting `isHidden=true` on `titleTextField` and `documentIcon` do not animate and do not always work.
      /// We can use `alphaValue=0` to fade out in `fadeOutOldViews()`, but `titleVisibility` is needed to remove them.
      window.titleVisibility = .hidden
    }

    /// These should all be either 0 height or unchanged from `transition.fromLayout`
    apply(visibility: futureLayout.controlBarBottom, to: controlBarBottom)
    apply(visibility: futureLayout.topPanelView, to: topPanelView)

    // Remove subviews from OSC
    for view in [fragVolumeView, fragToolbarView, fragPlaybackControlButtonsView, fragPositionSliderView] {
      view?.removeFromSuperview()
    }

    if let setupControlBarInternalViews = futureLayout.setupControlBarInternalViews {
      Logger.log("Setting up control bar: \(futureLayout.oscPosition)", level: .verbose, subsystem: player.subsystem)
      setupControlBarInternalViews()
    }

    if transition.isTopPanelPlacementChanging {
      updateTopPanelPlacement(placement: futureLayout.topPanelPlacement)
    }

    if transition.isBottomPanelPlacementChanging {
      updateBottomPanelPlacement(placement: futureLayout.bottomPanelPlacement)
    }

    // So that panels toggling between "inside" and "outside" don't change until they need to (different strategy than fullscreen)
    if !transition.isTogglingFullScreen {
      updatePanelBlendingModes(to: futureLayout)
    }

    window.contentView?.layoutSubtreeIfNeeded()
  }

  private func openNewPanels(_ transition: LayoutTransition) {
    guard let window = window else { return }
    let futureLayout = transition.toLayout
    Logger.log("OpenNewPanels. TitleHeight: \(futureLayout.titleBarHeight), TopOSC: \(futureLayout.topOSCHeight)", level: .verbose, subsystem: player.subsystem)

    // Update heights to their final values:
    topOSCHeightConstraint.animateToConstant(futureLayout.topOSCHeight)
    titleBarHeightConstraint.animateToConstant(futureLayout.titleBarHeight)
    osdMinOffsetFromTopConstraint.animateToConstant(futureLayout.osdMinOffsetFromTop)

    // Update heights of top & bottom panels:

    let windowFrame = window.frame
    var windowYDelta: CGFloat = 0
    var windowHeightDelta: CGFloat = 0

    if transition.fromLayout.topPanelPlacement == .outsideVideo {
      windowHeightDelta -= videoContainerTopOffsetFromContentViewTopConstraint.constant
    }
    if transition.toLayout.topPanelPlacement == .outsideVideo {
      windowHeightDelta += futureLayout.topPanelHeight
    }
    updateTopPanelHeight(to: futureLayout.topPanelHeight, transition: transition)

    if transition.fromLayout.bottomPanelPlacement == .outsideVideo {
      windowHeightDelta -= videoContainerBottomOffsetFromContentViewBottomConstraint.constant
      windowYDelta -= videoContainerBottomOffsetFromContentViewBottomConstraint.constant
    }
    if transition.toLayout.bottomPanelPlacement == .outsideVideo {
      windowHeightDelta += futureLayout.bottomOSCHeight
      windowYDelta += futureLayout.bottomOSCHeight
    }
    updateBottomPanelHeight(to: futureLayout.bottomOSCHeight, transition: transition)

    if !transition.isInitialLayout && !transition.isTogglingFullScreen && !futureLayout.isFullScreen {
      let newWindowSize = CGSize(width: windowFrame.width, height: windowFrame.height + windowHeightDelta)
      let newOrigin = CGPoint(x: windowFrame.origin.x, y: windowFrame.origin.y - windowYDelta)
      let newWindowFrame = NSRect(origin: newOrigin, size: newWindowSize)
      window.setFrame(newWindowFrame, display: true, animate: true)
    }

    // Update sidebar vertical alignments
    refreshSidebarVerticalConstraints(layout: futureLayout)

    controlBarBottom.layoutSubtreeIfNeeded()
    window.contentView?.layoutSubtreeIfNeeded()
  }

  private func fadeInNewViews(_ transition: LayoutTransition) {
    guard let window = window else { return }
    let futureLayout = transition.toLayout
    Logger.log("FadeInNewViews", level: .verbose, subsystem: player.subsystem)

    if futureLayout.titleIconAndText.isShowable {
      window.titleVisibility = .visible
    }

    applyShowableOnly(visibility: futureLayout.controlBarFloating, to: controlBarFloating)

    if futureLayout.isFullScreen {
      if Preference.bool(for: .displayTimeAndBatteryInFullScreen) {
        apply(visibility: .showFadeable, to: additionalInfoView)
      }
    } else {
      /// Special case for `trafficLightButtons` due to quirks. Do not use `fadeableViews`. ALways set `alphaValue = 1`.
      for button in trafficLightButtons {
        button.alphaValue = 1
      }

      if futureLayout.trafficLightButtons != .hidden {
        for button in trafficLightButtons {
          button.isHidden = false
        }
      }
    }

    applyShowableOnly(visibility: futureLayout.leadingSidebarToggleButton, to: leadingSidebarToggleButton)
    applyShowableOnly(visibility: futureLayout.trailingSidebarToggleButton, to: trailingSidebarToggleButton)
    applyShowableOnly(visibility: futureLayout.pinToTopButton, to: pinToTopButton)

    // Add back title bar accessories (if needed):
    applyShowableOnly(visibility: futureLayout.titlebarAccessoryViewControllers, to: leadingTitleBarAccessoryView)
    applyShowableOnly(visibility: futureLayout.titlebarAccessoryViewControllers, to: trailingTitleBarAccessoryView)
  }

  private func addTitleBarAccessoryViews() {
    guard let window = window else { return }
    if window.styleMask.contains(.titled) && window.titlebarAccessoryViewControllers.isEmpty {
      window.addTitlebarAccessoryViewController(leadingTitlebarAccesoryViewController)
      window.addTitlebarAccessoryViewController(trailingTitlebarAccesoryViewController)
    }
  }

  private func updatePanelBlendingModes(to futureLayout: LayoutPlan) {
    // Fullscreen + "behindWindow" doesn't blend properly and looks ugly
    if futureLayout.topPanelPlacement == .insideVideo || futureLayout.isFullScreen {
      topPanelView.blendingMode = .withinWindow
    } else {
      topPanelView.blendingMode = .behindWindow
    }

    // Fullscreen + "behindWindow" doesn't blend properly and looks ugly
    if futureLayout.bottomPanelPlacement == .insideVideo || futureLayout.isFullScreen {
      controlBarBottom.blendingMode = .withinWindow
    } else {
      controlBarBottom.blendingMode = .behindWindow
    }

    updateSidebarBlendingMode(leadingSidebar.locationID, layout: futureLayout)
    updateSidebarBlendingMode(trailingSidebar.locationID, layout: futureLayout)
  }

  /// Make sure this is called AFTER `mainWindow.setupTitleBarAndOSC()` has updated its variables
  func refreshSidebarVerticalConstraints(layout futureLayout: LayoutPlan? = nil) {
    let layout = futureLayout ?? currentLayout
    let downshift: CGFloat
    var tabHeight: CGFloat
    if player.isInMiniPlayer || (!layout.isFullScreen && layout.topPanelPlacement == Preference.PanelPlacement.outsideVideo) {
      downshift = defaultDownshift
      tabHeight = defaultTabHeight
      Logger.log("MainWindow: using default downshift (\(downshift)) and tab height (\(tabHeight))",
                 level: .verbose, subsystem: player.subsystem)
    } else {
      // Downshift: try to match title bar height
      if layout.isFullScreen || layout.topPanelPlacement == Preference.PanelPlacement.outsideVideo {
        downshift = defaultDownshift
      } else {
        // Need to adjust if has title bar
        downshift = reducedTitleBarHeight
      }

      tabHeight = layout.topOSCHeight
      // Put some safeguards in place:
      if tabHeight <= 16 || tabHeight > 70 {
        tabHeight = defaultTabHeight
      }
    }

    Logger.log("Sidebar downshift: \(downshift), TabHeight: \(tabHeight) (fullScreen: \(layout.isFullScreen), topPanel: \(layout.topPanelPlacement))",
               level: .verbose, subsystem: player.subsystem)
    quickSettingView.setVerticalConstraints(downshift: downshift, tabHeight: tabHeight)
    playlistView.setVerticalConstraints(downshift: downshift, tabHeight: tabHeight)
  }
  
  func updateSpacingForTitleBarAccessories(_ layout: LayoutPlan? = nil) {
    let layout = layout ?? self.currentLayout

    updateSpacingForLeadingTitleBarAccessory(layout)
    updateSpacingForTrailingTitleBarAccessory(layout)

    leadingTitleBarAccessoryView.layoutSubtreeIfNeeded()
    trailingTitleBarAccessoryView.layoutSubtreeIfNeeded()
  }

  // Updates visibility of buttons on the left side of the title bar. Also when the left sidebar is visible,
  // sets the horizontal space needed to push the title bar right, so that it doesn't overlap onto the left sidebar.
  private func updateSpacingForLeadingTitleBarAccessory(_ layout: LayoutPlan) {
    var trailingSpace: CGFloat = 8  // Add standard space before title text by default

    let sidebarButtonSpace: CGFloat = layout.leadingSidebarToggleButton.isShowable ? leadingSidebarToggleButton.frame.width : 0

    let isSpaceNeededForSidebar = layout.topPanelPlacement == .insideVideo && (leadingSidebar.animationState == .willShow
                                                                               || leadingSidebar.animationState == .shown)
    if isSpaceNeededForSidebar {
      // Subtract space taken by the 3 standard buttons + other visible buttons
      trailingSpace = max(0, leadingSidebar.currentWidth - trafficLightButtonsWidth - sidebarButtonSpace)
    }
    leadingTitleBarTrailingSpaceConstraint.animateToConstant(trailingSpace)
  }

  // Updates visibility of buttons on the right side of the title bar. Also when the right sidebar is visible,
  // sets the horizontal space needed to push the title bar left, so that it doesn't overlap onto the right sidebar.
  private func updateSpacingForTrailingTitleBarAccessory(_ layout: LayoutPlan) {
    var leadingSpace: CGFloat = 0
    var spaceForButtons: CGFloat = 0

    if layout.trailingSidebarToggleButton.isShowable {
      spaceForButtons += trailingSidebarToggleButton.frame.width
    }
    if layout.pinToTopButton.isShowable {
      spaceForButtons += pinToTopButton.frame.width
    }

    let isSpaceNeededForSidebar = layout.topPanelPlacement == .insideVideo && (trailingSidebar.animationState == .willShow
                                                                               || trailingSidebar.animationState == .shown)
    if isSpaceNeededForSidebar {
      leadingSpace = max(0, trailingSidebar.currentWidth - spaceForButtons)
    }
    trailingTitleBarLeadingSpaceConstraint.animateToConstant(leadingSpace)

    // Add padding to the side for buttons
    let isAnyButtonVisible = layout.trailingSidebarToggleButton.isShowable || layout.pinToTopButton.isShowable
    let buttonMargin: CGFloat = isAnyButtonVisible ? 8 : 0
    trailingTitleBarTrailingSpaceConstraint.animateToConstant(buttonMargin)
  }

  // This method should only make a layout plan. It should not alter the current layout.
  private func buildFutureLayoutPlan(from layoutSpec: LayoutSpec) -> LayoutPlan {
    let window = window!

    let futureLayout = LayoutPlan(spec: layoutSpec)

    // Title bar & title bar accessories:

    if futureLayout.isFullScreen {
      futureLayout.titleIconAndText = .showAlways
      futureLayout.trafficLightButtons = .showAlways
    } else {
      let visibleState: Visibility = futureLayout.topPanelPlacement == .insideVideo ? .showFadeable : .showAlways

      futureLayout.topPanelView = visibleState
      futureLayout.trafficLightButtons = visibleState
      futureLayout.titleIconAndText = visibleState
      futureLayout.titleBarHeight = StandardTitleBarHeight  // may be overridden by OSC layout

      if futureLayout.topPanelPlacement == .insideVideo {
        futureLayout.osdMinOffsetFromTop = StandardTitleBarHeight + 8
      }

      futureLayout.titlebarAccessoryViewControllers = visibleState

      // LeadingSidebar toggle button
      let hasLeadingSidebar = !leadingSidebar.tabGroups.isEmpty
      if hasLeadingSidebar && Preference.bool(for: .showLeadingSidebarToggleButton) {
        futureLayout.leadingSidebarToggleButton = visibleState
      }
      // TrailingSidebar toggle button
      let hasTrailingSidebar = !trailingSidebar.tabGroups.isEmpty
      if hasTrailingSidebar && Preference.bool(for: .showTrailingSidebarToggleButton) {
        futureLayout.trailingSidebarToggleButton = visibleState
      }

      // "On Top" (mpv) AKA "Pin to Top" (OS)
      futureLayout.pinToTopButton = futureLayout.computePinToTopButtonVisibility(isOnTop: isOntop)
    }

    // OSC:

    if futureLayout.enableOSC {
      // add fragment views
      switch futureLayout.oscPosition {
      case .floating:
        futureLayout.controlBarFloating = .showFadeable  // floating is always fadeable

        futureLayout.setupControlBarInternalViews = { [self] in
          currentControlBar = controlBarFloating

          oscFloatingPlayButtonsContainerView.addView(fragPlaybackControlButtonsView, in: .center)
          // There sweems to be a race condition when adding to these StackViews.
          // Sometimes it still contains the old view, and then trying to add again will cause a crash.
          // Must check if it already contains the view before adding.
          if !oscFloatingUpperView.views(in: .leading).contains(fragVolumeView) {
            oscFloatingUpperView.addView(fragVolumeView, in: .leading)
          }
          let toolbarView = rebuildToolbar(iconSize: oscFloatingToolbarButtonIconSize, iconPadding: oscFloatingToolbarButtonIconPadding)
          oscFloatingUpperView.addView(toolbarView, in: .trailing)
          fragToolbarView = toolbarView

          oscFloatingUpperView.setVisibilityPriority(.detachEarly, for: fragVolumeView)
          oscFloatingUpperView.setVisibilityPriority(.detachEarlier, for: toolbarView)
          oscFloatingUpperView.setClippingResistancePriority(.defaultLow, for: .horizontal)

          oscFloatingLowerView.addSubview(fragPositionSliderView)
          Utility.quickConstraints(["H:|[v]|", "V:|[v]|"], ["v": fragPositionSliderView])
          // center control bar
          let cph = Preference.float(for: .controlBarPositionHorizontal)
          let cpv = Preference.float(for: .controlBarPositionVertical)
          controlBarFloating.xConstraint.constant = window.frame.width * CGFloat(cph)
          controlBarFloating.yConstraint.constant = window.frame.height * CGFloat(cpv)

          playbackButtonsSquareWidthConstraint.constant = oscFloatingPlayBtnsSize
          playbackButtonsHorizontalPaddingConstraint.constant = oscFloatingPlayBtnsHPad
        }
      case .top:
        if !futureLayout.isFullScreen {
          futureLayout.titleBarHeight = reducedTitleBarHeight
        }

        let visibility: Visibility = futureLayout.topPanelPlacement == .insideVideo ? .showFadeable : .showAlways
        futureLayout.topPanelView = visibility
        futureLayout.topOSCHeight = oscBarHeight

        futureLayout.setupControlBarInternalViews = { [self] in
          currentControlBar = controlBarTop
          addControlBarViews(to: oscTopMainView,
                             playBtnSize: oscBarPlaybackIconSize, playBtnSpacing: oscBarPlaybackIconSpacing)
        }

      case .bottom:
        futureLayout.bottomOSCHeight = oscBarHeight
        futureLayout.controlBarBottom = (futureLayout.bottomPanelPlacement == .insideVideo) ? .showFadeable : .showAlways

        futureLayout.setupControlBarInternalViews = { [self] in
          currentControlBar = controlBarBottom
          addControlBarViews(to: oscBottomMainView,
                             playBtnSize: oscBarPlaybackIconSize, playBtnSpacing: oscBarPlaybackIconSpacing)
        }
      }
    } else {  // No OSC
      currentControlBar = nil
    }

    return futureLayout
  }

  private func addControlBarViews(to containerView: NSStackView, playBtnSize: CGFloat, playBtnSpacing: CGFloat,
                                  toolbarIconSize: CGFloat? = nil, toolbarIconSpacing: CGFloat? = nil) {
    let toolbarView = rebuildToolbar(iconSize: toolbarIconSize, iconPadding: toolbarIconSpacing)
    containerView.addView(fragPlaybackControlButtonsView, in: .leading)
    containerView.addView(fragPositionSliderView, in: .leading)
    containerView.addView(fragVolumeView, in: .leading)
    containerView.addView(toolbarView, in: .leading)
    fragToolbarView = toolbarView

    containerView.setClippingResistancePriority(.defaultLow, for: .horizontal)
    containerView.setVisibilityPriority(.mustHold, for: fragPositionSliderView)
    containerView.setVisibilityPriority(.detachEarly, for: fragVolumeView)
    containerView.setVisibilityPriority(.detachEarlier, for: toolbarView)

    playbackButtonsSquareWidthConstraint.constant = playBtnSize
    playbackButtonsHorizontalPaddingConstraint.constant = playBtnSpacing
  }

  // MARK: - Key events

  @discardableResult
  override func handleKeyBinding(_ keyBinding: KeyMapping) -> Bool {
    let success = super.handleKeyBinding(keyBinding)
    // TODO: replace this with a key binding interceptor
    if success && keyBinding.action.first == MPVCommand.screenshot.rawValue {
      player.sendOSD(.screenshot)
    }
    return success
  }

  // MARK: - Mouse / Trackpad events

  override func pressureChange(with event: NSEvent) {
    if isCurrentPressInSecondStage == false && event.stage == 2 {
      performMouseAction(Preference.enum(for: .forceTouchAction))
      isCurrentPressInSecondStage = true
    } else if event.stage == 1 {
      isCurrentPressInSecondStage = false
    }
  }

  /// Workaround for issue #4183, Cursor remains visible after resuming playback with the touchpad using secondary click
  ///
  /// When IINA hides the OSC it also calls the macOS AppKit method `NSCursor.setHiddenUntilMouseMoves` to hide the
  /// cursor. In macOS Catalina that method works as documented and keeps the cursor hidden until the mouse moves. Starting with
  /// macOS Big Sur the cursor becomes visible if mouse buttons are clicked without moving the mouse. To workaround this defect
  /// call this method again to keep the cursor hidden when the OSC is not visible.
  ///
  /// This erroneous behavior has been reported to Apple as: "Regression in NSCursor.setHiddenUntilMouseMoves"
  /// Feedback number FB11963121
  private func workaroundCursorDefect() {
    guard #available(macOS 11, *) else { return }
    NSCursor.setHiddenUntilMouseMoves(true)
  }

  override func mouseDown(with event: NSEvent) {
    if Logger.enabled && Logger.Level.preferred >= .verbose {
      Logger.log("MainWindow mouseDown @ \(event.locationInWindow)", level: .verbose, subsystem: player.subsystem)
    }
    workaroundCursorDefect()
    // do nothing if it's related to floating OSC
    guard !controlBarFloating.isDragging else { return }
    // record current mouse pos
    mousePosRelatedToWindow = event.locationInWindow
    // Start resize if applicable
    startResizingSidebar(with: event)
  }

  override func mouseDragged(with event: NSEvent) {
    if resizeSidebar(with: event) {
      return
    } else if !fsState.isFullscreen {
      guard !controlBarFloating.isDragging else { return }

      if let mousePosRelatedToWindow = mousePosRelatedToWindow {
        if !isDragging {
          /// Require that the user must drag the cursor at least a small distance for it to start a "drag" (`isDragging==true`)
          /// The user's action will only be counted as a click if `isDragging==false` when `mouseUp` is called.
          /// (Apple's trackpad in particular is very sensitive and tends to call `mouseDragged()` if there is even the slightest
          /// roll of the finger during a click, and the distance of the "drag" may be less than `minimumInitialDragDistance`)
          if mousePosRelatedToWindow.distance(to: event.locationInWindow) <= Constants.Distance.mainWindowMinInitialDragThreshold {
            return
          }
          if Logger.enabled && Logger.Level.preferred >= .verbose {
            Logger.log("MainWindow mouseDrag: minimum dragging distance was met", level: .verbose, subsystem: player.subsystem)
          }
          isDragging = true
        }
        window?.performDrag(with: event)
      }
    }
  }

  override func mouseUp(with event: NSEvent) {
    if Logger.enabled && Logger.Level.preferred >= .verbose {
      Logger.log("MainWindow mouseUp @ \(event.locationInWindow), isDragging: \(isDragging), clickCount: \(event.clickCount)",
                 level: .verbose, subsystem: player.subsystem)
    }
    workaroundCursorDefect()
    mousePosRelatedToWindow = nil
    if isDragging {
      // if it's a mouseup after dragging window
      isDragging = false
    } else if finishResizingSidebar(with: event) {
      return
    } else {
      // if it's a mouseup after clicking

      /// Single click. Note that `event.clickCount` will be 0 if there is at least one call to `mouseDragged()`,
      /// but we will only count it as a drag if `isDragging==true`
      if event.clickCount <= 1 && !isMouseEvent(event, inAnyOf: [leadingSidebarView, trailingSidebarView, subPopoverView]) {
        if hideSidebarsOnClick() {
          return
        }
      }
      if event.clickCount == 2 && isMouseEvent(event, inAnyOf: [titleBarView]) {
        let userDefault = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
        if userDefault == "Minimize" {
          window?.performMiniaturize(nil)
        } else if userDefault == "Maximize" {
          window?.performZoom(nil)
        }
        return
      }

      super.mouseUp(with: event)
    }
  }

  override func otherMouseDown(with event: NSEvent) {
    workaroundCursorDefect()
    super.otherMouseDown(with: event)
  }

  override func otherMouseUp(with event: NSEvent) {
    workaroundCursorDefect()
    super.otherMouseUp(with: event)
  }

  /// Workaround for issue #4183, Cursor remains visible after resuming playback with the touchpad using secondary click
  ///
  /// AppKit contains special handling for [rightMouseDown](https://developer.apple.com/documentation/appkit/nsview/event_handling/1806802-rightmousedown) having to do with contextual menus.
  /// Even though the documentation indicates the event will be passed up the responder chain, the event is not being received by the
  /// window controller. We are having to catch the event in the view. Because of that we do not call the super method and instead
  /// return to the view.`
  override func rightMouseDown(with event: NSEvent) {
    workaroundCursorDefect()
  }

  override func rightMouseUp(with event: NSEvent) {
    workaroundCursorDefect()
    super.rightMouseUp(with: event)
  }

  override internal func performMouseAction(_ action: Preference.MouseClickAction) {
    Logger.log("Performing mouseAction: \(action)", level: .verbose, subsystem: player.subsystem)
    super.performMouseAction(action)
    switch action {
    case .fullscreen:
      toggleWindowFullScreen()
    case .hideOSC:
      hideFadeableViews()
    case .togglePIP:
      if #available(macOS 10.12, *) {
        menuTogglePIP(.dummy)
      }
    default:
      break
    }
  }

  override func scrollWheel(with event: NSEvent) {
    guard !isInInteractiveMode else { return }
    guard !isMouseEvent(event, inAnyOf: [leadingSidebarView, trailingSidebarView, titleBarView, subPopoverView]) else { return }

    if isMouseEvent(event, inAnyOf: [fragPositionSliderView]) && playSlider.isEnabled {
      seekOverride = true
    } else if isMouseEvent(event, inAnyOf: [fragVolumeView]) && volumeSlider.isEnabled {
      volumeOverride = true
    } else {
      guard !isMouseEvent(event, inAnyOf: [currentControlBar]) else { return }
    }

    super.scrollWheel(with: event)

    seekOverride = false
    volumeOverride = false
  }

  override func mouseEntered(with event: NSEvent) {
    guard !isInInteractiveMode else { return }
    guard let obj = event.trackingArea?.userInfo?["obj"] as? Int else {
      Logger.log("No data for tracking area", level: .warning)
      return
    }
    mouseExitEnterCount += 1
    if obj == 0 {
      // main window
      isMouseInWindow = true
      showFadeableViews(duration: 0)
    } else if obj == 1 {
      if controlBarFloating.isDragging { return }
      // slider
      isMouseInSlider = true
      timePreviewWhenSeek.isHidden = false
      thumbnailPeekView.isHidden = !player.info.thumbnailsReady

      let mousePos = playSlider.convert(event.locationInWindow, from: nil)
      updateTimeLabel(mousePos.x, originalPos: event.locationInWindow)
    }
  }

  override func mouseExited(with event: NSEvent) {
    guard !isInInteractiveMode else { return }
    guard let obj = event.trackingArea?.userInfo?["obj"] as? Int else {
      Logger.log("No data for tracking area", level: .warning)
      return
    }
    mouseExitEnterCount += 1
    if obj == 0 {
      // main window
      isMouseInWindow = false
      if controlBarFloating.isDragging { return }
      if Preference.bool(for: .hideFadeableViewsWhenOutsideWindow) {
        hideFadeableViews()
      } else {
        // Closes loophole in case cursor hovered over OSC before exiting (in which case timer was destroyed)
        resetFadeTimer()
      }
    } else if obj == 1 {
      // slider
      isMouseInSlider = false
      timePreviewWhenSeek.isHidden = true
      let mousePos = playSlider.convert(event.locationInWindow, from: nil)
      updateTimeLabel(mousePos.x, originalPos: event.locationInWindow)
      thumbnailPeekView.isHidden = true
    }
  }

  override func mouseMoved(with event: NSEvent) {
    guard !isInInteractiveMode else { return }

    /// Set or unset the cursor to `resizeLeftRight` if able to resize the sidebar
    if isMousePosWithinLeadingSidebarResizeRect(mousePositionInWindow: event.locationInWindow) ||
        isMousePosWithinTrailingSidebarResizeRect(mousePositionInWindow: event.locationInWindow) {
      if sidebarResizeCursor == nil {
        let newCursor = NSCursor.resizeLeftRight
        newCursor.push()
        sidebarResizeCursor = newCursor
      }
    } else {
      if let currentCursor = sidebarResizeCursor {
        currentCursor.pop()
        sidebarResizeCursor = nil
      }
    }

    let mousePos = playSlider.convert(event.locationInWindow, from: nil)
    if isMouseInSlider {
      updateTimeLabel(mousePos.x, originalPos: event.locationInWindow)
    }

    if isMouseInWindow {
      // Check whether mouse is in OSC
      let shouldRestartFadeTimer = !isMouseEvent(event, inAnyOf: [currentControlBar, titleBarView])
      showFadeableViews(thenRestartFadeTimer: shouldRestartFadeTimer, duration: 0)
    }
  }

  @objc func handleMagnifyGesture(recognizer: NSMagnificationGestureRecognizer) {
    guard pinchAction != .none else { return }
    guard !isInInteractiveMode, let window = window else { return }

    switch pinchAction {
    case .none:
      return
    case .fullscreen:
      // enter/exit fullscreen
      if recognizer.state == .began {
        let isEnlarge = recognizer.magnification > 0
        if isEnlarge != fsState.isFullscreen {
          recognizer.state = .recognized
          self.toggleWindowFullScreen()
        }
      }
    case .windowSize:
      if fsState.isFullscreen { return }

      // adjust window size
      switch recognizer.state {
      case .began:
        // FIXME: confirm reset on video size change due to track change
        windowFrameAtMagnificationBegin = window.frame
        videoContainerFrameAtMagnificationBegin = videoContainerView.frame
        scaleVideoFromPinchGesture(to: recognizer.magnification)
      case .changed:
        scaleVideoFromPinchGesture(to: recognizer.magnification)
      case .ended:
        scaleVideoFromPinchGesture(to: recognizer.magnification)
        updateWindowParametersForMPV()
      case .cancelled, .failed:
        scaleVideoFromPinchGesture(to: 1.0)
        break
      default:
        return
      }

    }
  }

  @objc func handleRotationGesture(recognizer: NSRotationGestureRecognizer) {
    rotationHandler.handleRotationGesture(recognizer: recognizer)
  }

  // MARK: - Window delegate: Open / Close

  func windowWillOpen() {
    Logger.log("WindowWillOpen", level: .verbose, subsystem: player.subsystem)
    isClosing = false
    guard let window = self.window, let cv = window.contentView else { return }
    // Must workaround an AppKit defect in some versions of macOS. This defect is known to exist in
    // Catalina and Big Sur. The problem was not reproducible in early versions of Monterey. It
    // reappeared in Ventura. The status of other versions of macOS is unknown, however the
    // workaround should be safe to apply in any version of macOS. The problem was reported in
    // issues #4229, #3159, #3097 and #3253. The titles of open windows shown in the "Window" menu
    // are automatically managed by the AppKit framework. To improve performance PlayerCore caches
    // and reuses player instances along with their windows. This technique is valid and recommended
    // by Apple. But in some versions of macOS, if a window is reused the framework will display the
    // title first used for the window in the "Window" menu even after IINA has updated the title of
    // the window. This problem can also be seen when right-clicking or control-clicking the IINA
    // icon in the dock. As a workaround reset the window's title to "Window" before it is reused.
    // This is the default title AppKit assigns to a window when it is first created. Surprising and
    // rather disturbing this works as a workaround, but it does.
    window.title = "Window"

    let currentScreen = window.selectDefaultScreen()
    NSScreen.screens.enumerated().forEach { (screenIndex, screen) in
      let currentString = (screen == currentScreen) ? " (current)" : ""
      NSScreen.log("Screen\(screenIndex)\(currentString)" , screen)
    }

    let useAnimation = !AccessibilityPreferences.motionReductionEnabled
    if shouldApplyInitialWindowSize, let windowFrame = windowFrameFromGeometry(newSize: AppData.sizeWhenNoVideo, screen: currentScreen) {
      Logger.log("WindowWillOpen using initial geometry; setFrame to: \(windowFrame)", level: .verbose, subsystem: player.subsystem)
      window.setFrame(windowFrame, display: false, animate: useAnimation)
    }

    resetCollectionBehavior()
    // update buffer indicator view
    updateBufferIndicatorView()

    // start tracking mouse event
    if cv.trackingAreas.isEmpty {
      cv.addTrackingArea(NSTrackingArea(rect: cv.bounds,
                                        options: [.activeAlways, .enabledDuringMouseDrag, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
                                        owner: self, userInfo: ["obj": 0]))
    }
    if playSlider.trackingAreas.isEmpty {
      playSlider.addTrackingArea(NSTrackingArea(rect: playSlider.bounds,
                                                options: [.activeAlways, .enabledDuringMouseDrag, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
                                                owner: self, userInfo: ["obj": 1]))
    }
    // Track the thumbs on the progress bar representing the A-B loop points and treat them as part
    // of the slider.
    if playSlider.abLoopA.trackingAreas.count <= 1 {
      playSlider.abLoopA.addTrackingArea(NSTrackingArea(rect: playSlider.abLoopA.bounds, options:  [.activeAlways, .enabledDuringMouseDrag, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved], owner: self, userInfo: ["obj": 1]))
    }
    if playSlider.abLoopB.trackingAreas.count <= 1 {
      playSlider.abLoopB.addTrackingArea(NSTrackingArea(rect: playSlider.abLoopB.bounds, options: [.activeAlways, .enabledDuringMouseDrag, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved], owner: self, userInfo: ["obj": 1]))
    }

    // truncate middle for title
    if let attrTitle = titleTextField?.attributedStringValue.mutableCopy() as? NSMutableAttributedString, attrTitle.length > 0 {
      let p = attrTitle.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as! NSMutableParagraphStyle
      p.lineBreakMode = .byTruncatingMiddle
      attrTitle.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: attrTitle.length))
    }
    updateTitle()  // Need to call this here, or else when opening directly to fullscreen, window title is just "Window"

    addVideoViewToWindow()
    window.setIsVisible(true)
    player.initVideo()
    videoView.videoLayer.draw(forced: true)

    // Set layout from prefs. Do not animate:
    transitionToInitialLayout()
  }

  func windowWillClose(_ notification: Notification) {
    Logger.log("Window closing", subsystem: player.subsystem)

    isClosing = true
    shouldApplyInitialWindowSize = true
    // Close PIP
    if pipStatus == .inPIP {
      if #available(macOS 10.12, *) {
        exitPIP()
      }
    }
    // stop playing
    if case .fullscreen(legacy: true, priorWindowedFrame: _) = fsState {
      restoreDockSettings()
    }
    player.stop()
    // stop tracking mouse event
    guard let w = self.window, let cv = w.contentView else { return }
    cv.trackingAreas.forEach(cv.removeTrackingArea)
    playSlider.trackingAreas.forEach(playSlider.removeTrackingArea)

    // TODO: save playback state here
    
    player.events.emit(.windowWillClose)
  }

  // MARK: - Window delegate: Full screen

  func customWindowsToEnterFullScreen(for window: NSWindow) -> [NSWindow]? {
    return [window]
  }

  func customWindowsToExitFullScreen(for window: NSWindow) -> [NSWindow]? {
    return [window]
  }

  private func resetViewsForFullScreenTransition() {
    // When playback is paused the display link is stopped in order to avoid wasting energy on
    // needless processing. It must be running while transitioning to/from full screen mode.
    videoView.displayActive()

    if isInInteractiveMode {
      exitInteractiveMode(immediately: true)
    }

    thumbnailPeekView.isHidden = true
    timePreviewWhenSeek.isHidden = true
    isMouseInSlider = false
  }

  func windowWillEnterFullScreen(_ notification: Notification) {
  }

  func window(_ window: NSWindow, startCustomAnimationToEnterFullScreenOn screen: NSScreen, withDuration duration: TimeInterval) {
    animateEntryIntoFullScreen(withDuration: duration, isLegacy: false)
  }

  // Animation: Enter FullScreen
  private func animateEntryIntoFullScreen(withDuration duration: TimeInterval, isLegacy: Bool) {
    guard let window = window,
          let screen = window.screen else { return }
    Logger.log("Animating entry into \(isLegacy ? "legacy " : "")full screen, duration: \(duration)",
               level: .verbose, subsystem: player.subsystem)

    let priorWindowedFrame = window.frame

    var animationTasks: [UIAnimation.Task] = []

    animationTasks.append(UIAnimation.zeroDurationTask { [self] in
      fsState.startAnimatingToFullScreen(legacy: isLegacy, priorWindowedFrame: priorWindowedFrame)
      Logger.log("Entering fullscreen, priorWindowedFrame := \(priorWindowedFrame)", level: .verbose)

      // Hide traffic light buttons & title during the animation:
      hideBuiltInTitleBarItems()

      // Set the appearance to match the theme so the title bar matches the theme
      let iinaTheme = Preference.enum(for: .themeMaterial) as Preference.Theme
      if #available(macOS 10.14, *) {
        window.appearance = NSAppearance(iinaTheme: iinaTheme)
      } else {
        switch(iinaTheme) {
        case .dark, .ultraDark: window.appearance = NSAppearance(named: .vibrantDark)
        default: window.appearance = NSAppearance(named: .vibrantLight)
        }
      }

      setWindowFloatingOnTop(false, updateOnTopStatus: false)

      if isLegacy {
        // Legacy fullscreen cannot handle transition while playing and will result in a black flash or jittering.
        // This will briefly freeze the video output, which is slightly better
        videoView.videoLayer.suspend()

        // stylemask
        if #available(macOS 10.16, *) {
          window.styleMask.remove(.titled)
        } else {
          window.styleMask.insert(.fullScreen)
        }
      }
      // Let mpv decide the correct render region in full screen
      player.mpv.setFlag(MPVOption.Window.keepaspect, true)
    })

    resetViewsForFullScreenTransition()
    constrainVideoViewForFullScreen()

    // May be in interactive mode, with some panels hidden. Honor existing layout but change value of isFullScreen
    let fullscreenLayout = currentLayout.spec.clone(fullScreen: true)
    let transition = buildLayoutTransition(to: fullscreenLayout, totalStartingDuration: 0, totalEndingDuration: duration, extraTaskFunc: { [self] in
      if isLegacy {
        // set window frame and in some cases content view frame
        setWindowFrameForLegacyFullScreen()
      } else {
        Logger.log("Window entering full screen; setFrame to: \(screen.visibleFrame)", level: .verbose)
        window.setFrame(screen.frameWithoutCameraHousing, display: true, animate: !AccessibilityPreferences.motionReductionEnabled)
      }
    })
    animationTasks.append(contentsOf: transition.animationTasks)

    // Make sure this doesn't happen until after animation finishes
    animationTasks.append(UIAnimation.zeroDurationTask { [self] in
      if isLegacy {
        window.styleMask.insert(.borderless)
        window.styleMask.remove(.resizable)

        // auto hide menubar and dock
        NSApp.presentationOptions.insert(.autoHideMenuBar)
        NSApp.presentationOptions.insert(.autoHideDock)

        (window as! MainWindow).forceKeyAndMain = true
        window.level = .floating
      }

      /// Special case: need to wait until now to call `trafficLightButtons.isHidden = false` due to their quirks
      for button in trafficLightButtons {
        button.isHidden = false
      }

      videoView.needsLayout = true
      videoView.layoutSubtreeIfNeeded()
      if isLegacy {
        videoView.videoLayer.resume()
      }

      if Preference.bool(for: .blackOutMonitor) {
        blackOutOtherMonitors()
      }

      if player.info.isPaused {
        if Preference.bool(for: .playWhenEnteringFullScreen) {
          player.resume()
        } else {
          // When playback is paused the display link is stopped in order to avoid wasting energy on
          // needless processing. It must be running while transitioning to full screen mode. Now that
          // the transition has completed it can be stopped.
          videoView.displayIdle()
        }
      }

      if #available(macOS 10.12.2, *) {
        player.touchBarSupport.toggleTouchBarEsc(enteringFullScr: true)
      }

      updateWindowParametersForMPV()

      // Exit PIP if necessary
      if pipStatus == .inPIP,
         #available(macOS 10.12, *) {
        exitPIP()
      }

      fsState.finishAnimating()
      player.events.emit(.windowFullscreenChanged, data: true)
    })

    animationQueue.run(animationTasks)
  }

  func window(_ window: NSWindow, startCustomAnimationToExitFullScreenWithDuration duration: TimeInterval) {
    if !AccessibilityPreferences.motionReductionEnabled {  /// see note in `windowDidExitFullScreen()`
      animateExitFromFullScreen(withDuration: duration, isLegacy: false)
    }
  }

  /// Workaround for Apple quirk. When exiting fullscreen, MacOS uses a relatively slow animation to open the Dock and fade in other windows.
  /// It appears we cannot call `setFrame()` (or more precisely, we must make sure any `setFrame()` animation does not end) until after this
  /// animation completes, or the window size will be incorrectly set to the same size of the screen.
  /// There does not appear to be any similar problem when entering fullscreen.
  func windowDidExitFullScreen(_ notification: Notification) {
    if AccessibilityPreferences.motionReductionEnabled {
      animateExitFromFullScreen(withDuration: UIAnimation.FullScreenTransitionDuration, isLegacy: false)
    }
  }

  private func hideBuiltInTitleBarItems() {
    apply(visibility: .hidden, documentIconButton, titleTextField)
    for button in trafficLightButtons {
      /// Special case for fullscreen transition due to quirks of `trafficLightButtons`.
      /// In most cases it's best to avoid setting `alphaValue = 0` for these because doing so will disable their menu items,
      /// but should be ok for brief animations
      for button in trafficLightButtons {
        button.alphaValue = 0
      }
      button.alphaValue = 0
      button.isHidden = false
    }
    window?.titleVisibility = .hidden
  }

  // Animation: Exit FullScreen
  private func animateExitFromFullScreen(withDuration duration: TimeInterval, isLegacy: Bool) {
    guard let window = window else { return }
    Logger.log("Animating exit from \(isLegacy ? "legacy " : "")full screen, duration: \(duration)",
               level: .verbose, subsystem: player.subsystem)

    // If a window is closed while in full screen mode (control-w pressed) AppKit will still call
    // this method. Because windows are tied to player cores and cores are cached and reused some
    // processing must be performed to leave the window in a consistent state for reuse. However
    // the windowWillClose method will have initiated unloading of the file being played. That
    // operation is processed asynchronously by mpv. If the window is being closed due to IINA
    // quitting then mpv could be in the process of shutting down. Must not access mpv while it is
    // asynchronously processing stop and quit commands.
    guard !isClosing else { return }

    guard let priorFrame = fsState.priorWindowedFrame else { return }

    var animationTasks: [UIAnimation.Task] = []

    // Before animating the transition:
    animationTasks.append(UIAnimation.zeroDurationTask { [self] in
      resetViewsForFullScreenTransition()

      apply(visibility: .hidden, to: additionalInfoView)

      // Hide traffic light buttons & title during the animation:
      hideBuiltInTitleBarItems()

      fsState.startAnimatingToWindow()

      if isLegacy {
        videoView.videoLayer.suspend()
      }
      player.mpv.setFlag(MPVOption.Window.keepaspect, false)
    })

    // May be in interactive mode, with some panels hidden (overriding stored preferences).
    // Honor existing layout but change value of isFullScreen:
    let windowedLayout = currentLayout.spec.clone(fullScreen: false)

    /// Split the duration between `openNewPanels` animation and `fadeInNewViews` animation
    let transition = buildLayoutTransition(to: windowedLayout, totalStartingDuration: 0, totalEndingDuration: duration, extraTaskFunc: { [self] in
      Logger.log("Window exiting \(isLegacy ? "legacy " : "")full screen; setting priorWindowedFrame: \(priorFrame)",
                 level: .verbose, subsystem: player.subsystem)
      window.setFrame(priorFrame, display: true, animate: !AccessibilityPreferences.motionReductionEnabled)
    })

    animationTasks.append(contentsOf: transition.animationTasks)

    // Make sure this doesn't happen until after animation finishes
    animationTasks.append(UIAnimation.zeroDurationTask { [self] in
      if isLegacy {
        // reset stylemask at the end
        window.styleMask.remove(.borderless)
        window.styleMask.insert(.resizable)
        if #available(macOS 10.16, *) {
          window.styleMask.insert(.titled)
          (window as! MainWindow).forceKeyAndMain = false
          window.level = .normal
        } else {
          window.styleMask.remove(.fullScreen)
        }

        restoreDockSettings()

        // Title bar accessories get removed by legacy fullscreen. Add them back:
        addTitleBarAccessoryViews()
      }

      constrainVideoViewForWindowedMode()

      if Preference.bool(for: .blackOutMonitor) {
        removeBlackWindows()
      }

      fsState.finishAnimating()

      if player.info.isPaused {
        // When playback is paused the display link is stopped in order to avoid wasting energy on
        // needless processing. It must be running while transitioning from full screen mode. Now that
        // the transition has completed it can be stopped.
        videoView.displayIdle()
      }

      if #available(macOS 10.12.2, *) {
        player.touchBarSupport.toggleTouchBarEsc(enteringFullScr: false)
      }

      // Must not access mpv while it is asynchronously processing stop and quit commands.
      // See comments in resetViewsForFullScreenTransition for details.
      guard !isClosing else { return }

      videoView.needsLayout = true
      videoView.layoutSubtreeIfNeeded()
      if isLegacy {
        videoView.videoLayer.resume()
      }

      if Preference.bool(for: .pauseWhenLeavingFullScreen) && player.info.isPlaying {
        player.pause()
      }

      // restore ontop status
      if player.info.isPlaying {
        setWindowFloatingOnTop(isOntop, updateOnTopStatus: false)
      }

      resetCollectionBehavior()
      updateWindowParametersForMPV()

      player.events.emit(.windowFullscreenChanged, data: false)
    })

    animationQueue.run(animationTasks)
  }

  func toggleWindowFullScreen() {
    guard let window = self.window else { fatalError("make sure the window exists before animating") }

    switch fsState {
    case .windowed:
      guard !player.isInMiniPlayer else { return }
      if Preference.bool(for: .useLegacyFullScreen) {
        animateEntryIntoFullScreen(withDuration: UIAnimation.FullScreenTransitionDuration, isLegacy: true)
      } else {
        window.toggleFullScreen(self)
      }
    case let .fullscreen(legacy, _):
      if legacy {
        animateExitFromFullScreen(withDuration: UIAnimation.FullScreenTransitionDuration, isLegacy: true)
      } else {
        window.toggleFullScreen(self)
      }
    default:
      return
    }
  }

  private func restoreDockSettings() {
    NSApp.presentationOptions.remove(.autoHideMenuBar)
    NSApp.presentationOptions.remove(.autoHideDock)
  }

  /// Set the window frame and if needed the content view frame to appropriately use the full screen.
  ///
  /// For screens that contain a camera housing the content view will be adjusted to not use that area of the screen.
  private func setWindowFrameForLegacyFullScreen() {
    guard let window = self.window else { return }
    let screen = window.screen ?? NSScreen.main!
    let newWindowFrame = screen.frame

    Logger.log("Window entering legacy full screen; setFrame to: \(newWindowFrame)",
               level: .verbose, subsystem: player.subsystem)
    window.setFrame(newWindowFrame, display: true, animate: !AccessibilityPreferences.motionReductionEnabled)

    if let unusableHeight = screen.cameraHousingHeight {
      // This screen contains an embedded camera. Shorten the height of the window's content view's
      // frame to avoid having part of the window obscured by the camera housing.
      let view = window.contentView!
      view.setFrameSize(NSMakeSize(view.frame.width, screen.frame.height - unusableHeight))
    }
  }

  // MARK: - Window delegate: Resize

  func windowWillResize(_ window: NSWindow, to requestedSize: NSSize) -> NSSize {
    // This method can be called as a side effect of the animation. If so, ignore.
    guard fsState == .windowed else { return requestedSize }
    Logger.log("WindowWillResize: requestedSize: \(requestedSize)", level: .verbose, subsystem: player.subsystem)

    if denyNextWindowResize {
      let currentSize = window.frame.size
      Logger.log("WindowWillResize: denying this resize; will stay at \(currentSize)",
                 level: .verbose, subsystem: player.subsystem)
      denyNextWindowResize = false
      return currentSize
    }

    if requestedSize.height <= minSize.height || requestedSize.width <= minSize.width {
      Logger.log("WindowWillResize: requestedSize too small; changing to min \(minSize)", level: .verbose, subsystem: player.subsystem)
      let newVideoSize = videoContainerView.frame.size.shrink(toSize: minSize)
      return computeWindowFrameForVideoResize(toVideoSize: newVideoSize).size
    }

    return requestedSize
  }

  func windowDidResize(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }
    // Remember, this method can be called as a side effect of an animation
//    Logger.log("WindowDidResize: \(window.frame)", level: .verbose, subsystem: player.subsystem)

    UIAnimation.disableAnimation {
      if isInInteractiveMode {
        // interactive mode
        cropSettingsView?.cropBoxView.resized(with: videoView.frame)
      } else if currentLayout.oscPosition == .floating {
        // Update floating control bar position
        updateFloatingOSCAfterWindowDidResize()
      } else {
        // May need to update title bar OSC
        updateSpacingForTitleBarAccessories()
      }
    }

    player.events.emit(.windowResized, data: window.frame)
  }

  private func updateFloatingOSCAfterWindowDidResize() {
    guard let window = window, currentLayout.oscPosition == .floating else { return }
    let cph = Preference.float(for: .controlBarPositionHorizontal)
    let cpv = Preference.float(for: .controlBarPositionVertical)

    let windowWidth = window.frame.width
    let margin: CGFloat = 10
    let minWindowWidth: CGFloat = 480 // 460 + 20 margin
    var xPos: CGFloat

    if windowWidth < minWindowWidth {
      // osc is compressed
      xPos = windowWidth / 2
    } else {
      // osc has full width
      let oscHalfWidth: CGFloat = 230
      xPos = windowWidth * CGFloat(cph)
      if xPos - oscHalfWidth < margin {
        xPos = oscHalfWidth + margin
      } else if xPos + oscHalfWidth + margin > windowWidth {
        xPos = windowWidth - oscHalfWidth - margin
      }
    }

    let windowHeight = window.frame.height
    var yPos = windowHeight * CGFloat(cpv)
    let oscHeight: CGFloat = 67
    let yMargin: CGFloat = 25

    if yPos < 0 {
      yPos = 0
    } else if yPos + oscHeight + yMargin > windowHeight {
      yPos = windowHeight - oscHeight - yMargin
    }

    controlBarFloating.xConstraint.constant = xPos
    controlBarFloating.yConstraint.constant = yPos

    // Detach the views in oscFloatingUpperView manually on macOS 11 only; as it will cause freeze
    if isMacOS11 {
      guard let maxWidth = [fragVolumeView, fragToolbarView].compactMap({ $0?.frame.width }).max() else {
        return
      }

      // window - 10 - controlBarFloating
      // controlBarFloating - 12 - oscFloatingUpperView
      let margin: CGFloat = (10 + 12) * 2
      let hide = (window.frame.width
                  - oscFloatingPlayButtonsContainerView.frame.width
                  - maxWidth*2
                  - margin) < 0

      let views = oscFloatingUpperView.views
      if hide {
        if views.contains(fragVolumeView) {
          oscFloatingUpperView.removeView(fragVolumeView)
        }
        if let fragToolbarView = fragToolbarView, views.contains(fragToolbarView) {
          oscFloatingUpperView.removeView(fragToolbarView)
        }
      } else {
        if !views.contains(fragVolumeView) {
          oscFloatingUpperView.addView(fragVolumeView, in: .leading)
        }
        if let fragToolbarView = fragToolbarView, !views.contains(fragToolbarView) {
          oscFloatingUpperView.addView(fragToolbarView, in: .trailing)
        }
      }
    }
  }

  // resize framebuffer in videoView after resizing.
  func windowDidEndLiveResize(_ notification: Notification) {
    // Must not access mpv while it is asynchronously processing stop and quit commands.
    // See comments in windowWillExitFullScreen for details.
    guard !isClosing else { return }

    // This method can be called as a side effect of the animation. If so, ignore.
    guard fsState == .windowed else { return }

    updateWindowParametersForMPV()
  }

  func windowDidChangeBackingProperties(_ notification: Notification) {
    Logger.log("WindowDidChangeBackingProperties()", level: .verbose, subsystem: player.subsystem)
    if let oldScale = (notification.userInfo?[NSWindow.oldScaleFactorUserInfoKey] as? NSNumber)?.doubleValue,
       let window = window, oldScale != Double(window.backingScaleFactor) {
      Logger.log("WindowDidChangeBackingProperties: scale factor changed from \(oldScale) to \(Double(window.backingScaleFactor))",
                 level: .verbose, subsystem: player.subsystem)
      // FIXME: more needs to be changed than just this
      videoView.videoLayer.contentsScale = window.backingScaleFactor
      denyNextWindowResize = true
    }
  }

  
  override func windowDidChangeScreen(_ notification: Notification) {
    super.windowDidChangeScreen(notification)

    player.events.emit(.windowScreenChanged)
  }

  func windowDidMove(_ notification: Notification) {
    guard let window = window else { return }
    player.events.emit(.windowMoved, data: window.frame)
  }

  // MARK: - Window delegate: Activeness status

  func windowDidBecomeKey(_ notification: Notification) {
    window!.makeFirstResponder(window!)
    if Preference.bool(for: .pauseWhenInactive) && isPausedDueToInactive {
      player.resume()
      isPausedDueToInactive = false
    }
  }

  func windowDidResignKey(_ notification: Notification) {
    // keyWindow is nil: The whole app is inactive
    // keyWindow is another MainWindow: Switched to another video window
    if NSApp.keyWindow == nil ||
      (NSApp.keyWindow?.windowController is MainWindowController ||
        (NSApp.keyWindow?.windowController is MiniPlayerWindowController && NSApp.keyWindow?.windowController != player.miniPlayer)) {
      if Preference.bool(for: .pauseWhenInactive), player.info.isPlaying {
        player.pause()
        isPausedDueToInactive = true
      }
    }
  }

  override func windowDidBecomeMain(_ notification: Notification) {
    super.windowDidBecomeMain(notification)

    if fsState.isFullscreen && Preference.bool(for: .blackOutMonitor) {
      blackOutOtherMonitors()
    }
    player.events.emit(.windowMainStatusChanged, data: true)
  }

  override func windowDidResignMain(_ notification: Notification) {
    super.windowDidResignMain(notification)
    if Preference.bool(for: .blackOutMonitor) {
      removeBlackWindows()
    }
    player.events.emit(.windowMainStatusChanged, data: false)
  }

  func windowWillMiniaturize(_ notification: Notification) {
    if Preference.bool(for: .pauseWhenMinimized), player.info.isPlaying {
      isPausedDueToMiniaturization = true
      player.pause()
    }
  }

  func windowDidMiniaturize(_ notification: Notification) {
    if Preference.bool(for: .togglePipByMinimizingWindow) && !isWindowMiniaturizedDueToPip {
      if #available(macOS 10.12, *) {
        enterPIP()
      }
    }
    player.events.emit(.windowMiniaturized)
  }

  func windowDidDeminiaturize(_ notification: Notification) {
    Logger.log("windowDidDeminiaturize()", level: .verbose, subsystem: player.subsystem)
    if Preference.bool(for: .pauseWhenMinimized) && isPausedDueToMiniaturization {
      player.resume()
      isPausedDueToMiniaturization = false
    }
    if Preference.bool(for: .togglePipByMinimizingWindow) && !isWindowMiniaturizedDueToPip {
      if #available(macOS 10.12, *) {
        exitPIP()
      }
    }
    player.events.emit(.windowDeminiaturized)
  }

  // MARK: - UI: Show / Hide Fadeable Views

  // Shows fadeableViews and titlebar via fade
  private func showFadeableViews(thenRestartFadeTimer restartFadeTimer: Bool = true, duration: CGFloat = UIAnimation.DefaultDuration) {
    let animationTasks: [UIAnimation.Task] = buildAnimationToShowFadeableViews(restartFadeTimer: restartFadeTimer, duration: duration)
    animationQueue.run(animationTasks)
  }

  private func buildAnimationToShowFadeableViews(restartFadeTimer: Bool = true, duration: CGFloat = UIAnimation.DefaultDuration) -> [UIAnimation.Task] {
    var animationTasks: [UIAnimation.Task] = []

    guard !player.disableUI && !isInInteractiveMode else {
      return animationTasks
    }

    guard animationState == .hidden else {
      if restartFadeTimer {
        resetFadeTimer()
      } else {
        destroyFadeTimer()
      }
      return animationTasks
    }

    let currentLayout = self.currentLayout

    animationTasks.append(UIAnimation.Task(duration: duration, { [self] in
      Logger.log("Showing fadeable views", level: .verbose, subsystem: player.subsystem)
      animationState = .willShow
      // The OSC was not updated while it was hidden to avoid wasting energy. Update it now.
      player.syncUITime()
      if !player.info.isPaused {
        player.createSyncUITimer()
      }
      destroyFadeTimer()

      for v in fadeableViews {
        v.animator().alphaValue = 1
      }
    }))

    // Not animated, but needs to wait until after fade is done
    animationTasks.append(UIAnimation.zeroDurationTask { [self] in
      // if no interrupt then hide animation
      if animationState == .willShow {
        animationState = .shown
        for v in fadeableViews {
          v.isHidden = false
        }
        if restartFadeTimer {
          resetFadeTimer()
        }
        /// Special case for `trafficLightButtons` due to Apple quirk
        if currentLayout.trafficLightButtons == .showFadeable {
          for button in trafficLightButtons {
            button.isHidden = false
          }
        }
        /// Special case for title icon and text due to Apple quirk
        if currentLayout.titleIconAndText == .showFadeable {
          window?.titleVisibility = .visible
        }
      }
    })
    return animationTasks
  }

  @objc func hideFadeableViewsAndCursor() {
    // don't hide UI when dragging control bar
    if controlBarFloating.isDragging { return }
    if hideFadeableViews() {
      NSCursor.setHiddenUntilMouseMoves(true)
    }
  }

  @discardableResult
  private func hideFadeableViews() -> Bool {
    guard pipStatus == .notInPIP && animationState == .shown else {
      return false
    }

    var animationTasks: [UIAnimation.Task] = []

    animationTasks.append(UIAnimation.Task{ [self] in
      // Don't hide overlays when in PIP or when they are not actually shown
      Logger.log("Hiding fadeable views", level: .verbose, subsystem: player.subsystem)

      // Follow energy efficiency best practices and stop the timer that updates the OSC while it is
      // hidden. However the timer can't be stopped if the mini player is being used as it always
      // displays the the OSC or the timer is also updating the information being displayed in the
      // touch bar. Does this host have a touch bar? Is the touch bar configured to show app controls?
      // Is the touch bar awake? Is the host being operated in closed clamshell mode? This is the kind
      // of information needed to avoid running the timer and updating controls that are not visible.
      // Unfortunately in the documentation for NSTouchBar Apple indicates "There’s no need, and no
      // API, for your app to know whether or not there’s a Touch Bar available". So this code keys
      // off whether AppKit has requested that a NSTouchBar object be created. This avoids running the
      // timer on Macs that do not have a touch bar. It also may avoid running the timer when a
      // MacBook with a touch bar is being operated in closed clameshell mode.
      if !player.isInMiniPlayer && !player.needsTouchBar && !currentLayout.hasPermanentOSC {
        player.invalidateTimer()
      }

      destroyFadeTimer()
      animationState = .willHide

      for v in fadeableViews {
        v.animator().alphaValue = 0
      }
      /// Quirk 1: special handling for `trafficLightButtons`
      if currentLayout.trafficLightButtons == .showFadeable {
        for button in trafficLightButtons {
          button.alphaValue = 0
        }
      }
      /// Quirk 2: MUST set `titleVisibility` to guarantee that `documentIcon` & `titleTextField` are shown/hidden consistently.
      /// Setting `isHidden=true` on `titleTextField` and `documentIcon` do not animate and do not always work.
      /// We can use `alphaValue=0` to fade out in `fadeOutOldViews()`, but `titleVisibility` is needed to remove them.
      if currentLayout.titleIconAndText == .showFadeable {
        window?.titleVisibility = .hidden
      }
    })

    animationTasks.append(UIAnimation.zeroDurationTask { [self] in
      // if no interrupt then hide animation
      guard animationState == .willHide else { return }

      animationState = .hidden
      for v in fadeableViews {
        v.isHidden = true
      }
      /// Quirk 1: need to set `alphaValue` back to `1` so that each button's corresponding menu items still work
      if currentLayout.trafficLightButtons == .showFadeable {
        for button in trafficLightButtons {
          button.isHidden = true
          button.alphaValue = 1
        }
      }
    })

    animationQueue.run(animationTasks)
    return true
  }

  // MARK: - UI: Show / Hide Fadeable Views Timer

  private func resetFadeTimer() {
    // If timer exists, destroy first
    destroyFadeTimer()

    // Create new timer.
    // Timer and animation APIs require Double, but we must support legacy prefs, which store as Float
    var timeout = Double(Preference.float(for: .controlBarAutoHideTimeout))
    if timeout < UIAnimation.DefaultDuration {
      timeout = UIAnimation.DefaultDuration
    }
    hideFadeableViewsTimer = Timer.scheduledTimer(timeInterval: TimeInterval(timeout), target: self, selector: #selector(self.hideFadeableViewsAndCursor), userInfo: nil, repeats: false)
  }

  private func destroyFadeTimer() {
    if let hideFadeableViewsTimer = hideFadeableViewsTimer {
      hideFadeableViewsTimer.invalidate()
      self.hideFadeableViewsTimer = nil
    }
  }

  // MARK: - UI: Title

  @objc
  override func updateTitle() {
    // Workaround for AppKit quirk: need to have title visible while changing title, or else document icon button can go missing.
    var tasks = buildAnimationToShowFadeableViews()

    tasks.append(UIAnimation.zeroDurationTask{ [self] in
      if player.info.isNetworkResource {
        window?.title = player.getMediaTitle()
      } else {
        window?.representedURL = player.info.currentURL
        // Workaround for issue #3543, IINA crashes reporting:
        // NSInvalidArgumentException [NSNextStepFrame _displayName]: unrecognized selector
        // When running on an M1 under Big Sur and using legacy full screen.
        //
        // Changes in Big Sur broke the legacy full screen feature. The MainWindowController method
        // legacyAnimateToFullscreen had to be changed to get this feature working again. Under Big
        // Sur that method now calls "window.styleMask.remove(.titled)". Removing titled from the
        // style mask causes the AppKit method NSWindow.setTitleWithRepresentedFilename to trigger the
        // exception listed above. This appears to be a defect in the Cocoa framework. The window's
        // title can still be set directly without triggering the exception. The problem seems to be
        // isolated to the setTitleWithRepresentedFilename method, possibly only when running on an
        // Apple Silicon based Mac. Based on the Apple documentation setTitleWithRepresentedFilename
        // appears to be a convenience method. As a workaround for the issue directly set the window
        // title.
        //
        // This problem has been reported to Apple as:
        // "setTitleWithRepresentedFilename throws NSInvalidArgumentException: NSNextStepFrame _displayName"
        // Feedback number FB9789129
        if Preference.bool(for: .useLegacyFullScreen), #available(macOS 11, *) {
          window?.title = player.info.currentURL?.lastPathComponent ?? ""
        } else {
          window?.setTitleWithRepresentedFilename(player.info.currentURL?.path ?? "")
        }
      }
    })

    animationQueue.run(tasks)
  }

  // MARK: - UI: OSD

  private func updateOSDPosition() {
    guard let contentView = window?.contentView else { return }
//    contentView.removeConstraint(additionalInfoToOSDSpaceConstraint)
    contentView.removeConstraint(leadingSidebarToOSDSpaceConstraint)
    contentView.removeConstraint(trailingSidebarToOSDSpaceConstraint)
    let osdPosition: Preference.OSDPosition = Preference.enum(for: .osdPosition)
    switch osdPosition {
    case .topLeft:
      // OSD on left, AdditionalInfo on right
      leadingSidebarToOSDSpaceConstraint = leadingSidebarView.trailingAnchor.constraint(equalTo: osdVisualEffectView.leadingAnchor, constant: -8.0)
      trailingSidebarToOSDSpaceConstraint = trailingSidebarView.leadingAnchor.constraint(equalTo: additionalInfoView.trailingAnchor, constant: 8.0)
    case .topRight:
      // AdditionalInfo on left, OSD on right
      leadingSidebarToOSDSpaceConstraint = leadingSidebarView.trailingAnchor.constraint(equalTo: additionalInfoView.leadingAnchor, constant: -8.0)
      trailingSidebarToOSDSpaceConstraint = trailingSidebarView.leadingAnchor.constraint(equalTo: osdVisualEffectView.trailingAnchor, constant: 8.0)
    }

    leadingSidebarToOSDSpaceConstraint.isActive = true
    trailingSidebarToOSDSpaceConstraint.isActive = true
    contentView.layoutSubtreeIfNeeded()
  }

  // Do not call displayOSD directly. Call PlayerCore.sendOSD instead.
  func displayOSD(_ message: OSDMessage, autoHide: Bool = true, forcedTimeout: Double? = nil, accessoryView: NSView? = nil, context: Any? = nil) {
    guard player.displayOSD && !isShowingPersistentOSD && !isInInteractiveMode else { return }

    if hideOSDTimer != nil {
      hideOSDTimer!.invalidate()
      hideOSDTimer = nil
    }
    osdAnimationState = .shown

    let (osdString, osdType) = message.message()

    let osdTextSize = Preference.float(for: .osdTextSize)
    osdLabel.font = NSFont.monospacedDigitSystemFont(ofSize: CGFloat(osdTextSize), weight: .regular)
    osdAccessoryText.font = NSFont.monospacedDigitSystemFont(ofSize: CGFloat(osdTextSize * 0.5).clamped(to: 11...25), weight: .regular)
    osdLabel.stringValue = osdString

    switch osdType {
    case .normal:
      osdStackView.setVisibilityPriority(.notVisible, for: osdAccessoryText)
      osdStackView.setVisibilityPriority(.notVisible, for: osdAccessoryProgress)
    case .withProgress(let value):
      osdStackView.setVisibilityPriority(.notVisible, for: osdAccessoryText)
      osdStackView.setVisibilityPriority(.mustHold, for: osdAccessoryProgress)
      osdAccessoryProgress.doubleValue = value
    case .withText(let text):
      // data for mustache redering
      let osdData: [String: String] = [
        "duration": player.info.videoDuration?.stringRepresentation ?? Constants.String.videoTimePlaceholder,
        "position": player.info.videoPosition?.stringRepresentation ?? Constants.String.videoTimePlaceholder,
        "currChapter": (player.mpv.getInt(MPVProperty.chapter) + 1).description,
        "chapterCount": player.info.chapters.count.description
      ]

      osdStackView.setVisibilityPriority(.mustHold, for: osdAccessoryText)
      osdStackView.setVisibilityPriority(.notVisible, for: osdAccessoryProgress)
      osdAccessoryText.stringValue = try! (try! Template(string: text)).render(osdData)
    }

    apply(visibility: .showAlways, to: osdVisualEffectView)
    osdVisualEffectView.layoutSubtreeIfNeeded()
    if autoHide {
      let timeout: Double
      if let forcedTimeout = forcedTimeout {
        timeout = forcedTimeout
      } else {
        // Timer and animation APIs require Double, but we must support legacy prefs, which store as Float
        let configuredTimeout = Double(Preference.float(for: .osdAutoHideTimeout))
        timeout = configuredTimeout <= UIAnimation.OSDAnimationDuration ? UIAnimation.OSDAnimationDuration : configuredTimeout
      }
      hideOSDTimer = Timer.scheduledTimer(timeInterval: TimeInterval(timeout), target: self, selector: #selector(self.hideOSD), userInfo: nil, repeats: false)
    }

    osdStackView.views(in: .bottom).forEach {
      osdStackView.removeView($0)
    }
    if let accessoryView = accessoryView {
      isShowingPersistentOSD = true
      if context != nil {
        osdContext = context
      }

      if #available(macOS 10.14, *) {} else {
        accessoryView.appearance = NSAppearance(named: .vibrantDark)
      }
      let heightConstraint = NSLayoutConstraint(item: accessoryView, attribute: .height, relatedBy: .greaterThanOrEqual, toItem: nil, attribute: .notAnAttribute, multiplier: 1, constant: 300)
      heightConstraint.priority = .defaultLow
      heightConstraint.isActive = true

      osdStackView.addView(accessoryView, in: .bottom)
      Utility.quickConstraints(["H:|-0-[v(>=240)]-0-|"], ["v": accessoryView])

      accessoryView.wantsLayer = true
      accessoryView.layer?.opacity = 0

      UIAnimation.runAsync(UIAnimation.Task(duration: UIAnimation.OSDAnimationDuration, { [self] in
        osdVisualEffectView.layoutSubtreeIfNeeded()
      }), then: {
        accessoryView.layer?.opacity = 1
      })
    }

  }

  @objc
  func hideOSD() {
    osdAnimationState = .willHide
    isShowingPersistentOSD = false
    osdContext = nil

    UIAnimation.runAsync(UIAnimation.Task(duration: UIAnimation.OSDAnimationDuration, { [self] in
      osdVisualEffectView.alphaValue = 0
    }), then: {
      if self.osdAnimationState == .willHide {
        self.osdAnimationState = .hidden
        self.osdVisualEffectView.isHidden = true
        self.osdStackView.views(in: .bottom).forEach { self.osdStackView.removeView($0) }
      }
    })
  }

  func updateAdditionalInfo() {
    additionalInfoLabel.stringValue = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
    additionalInfoTitle.stringValue = window?.representedURL?.lastPathComponent ?? window?.title ?? ""
    if let capacity = PowerSource.getList().filter({ $0.type == "InternalBattery" }).first?.currentCapacity {
      additionalInfoBattery.stringValue = "\(capacity)%"
      additionalInfoStackView.setVisibilityPriority(.mustHold, for: additionalInfoBatteryView)
    } else {
      additionalInfoStackView.setVisibilityPriority(.notVisible, for: additionalInfoBatteryView)
    }
  }

  // MARK: - UI: Interactive mode


  func enterInteractiveMode(_ mode: InteractiveMode, selectWholeVideoByDefault: Bool = false) {
    if #available(macOS 10.14, *) {
      window?.backgroundColor = .windowBackgroundColor
    } else {
      window?.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 1)
    }

    let (ow, oh) = player.originalVideoSize
    guard ow != 0 && oh != 0 else {
      Utility.showAlert("no_video_track")
      return
    }

    // TODO: use key interceptor to support ESC and ENTER keys for interactive mode

    /// Start by hiding OSC and/or "outside" panels, which aren't needed and might mess up the layout.
    /// We can do this by creating a `LayoutSpec`, then using it to build a `LayoutTransition` and executing its animation.
    let interactiveModeLayout = LayoutSpec(isFullScreen: currentLayout.isFullScreen,
                                           topPanelPlacement: .insideVideo,
                                           bottomPanelPlacement: currentLayout.bottomPanelPlacement,
                                           enableOSC: false,
                                           oscPosition: currentLayout.oscPosition)

    let transition = buildLayoutTransition(to: interactiveModeLayout, totalEndingDuration: 0)
    var animationTasks: [UIAnimation.Task] = transition.animationTasks

    // Now animate into Interactive Mode:
    animationTasks.append(UIAnimation.Task(duration: UIAnimation.CropAnimationDuration,
                                              timingFunction: CAMediaTimingFunction(name: .easeIn), { [self] in
      guard let window = self.window else { return }

      hideFadeableViews()
      hideOSD()

      isPausedPriorToInteractiveMode = player.info.isPaused
      player.pause()

      let cropController = mode.viewController()
      cropController.mainWindow = self
      bottomView.isHidden = false
      bottomView.addSubview(cropController.view)
      Utility.quickConstraints(["H:|[v]|", "V:|[v]|"], ["v": cropController.view])

      isInInteractiveMode = true
      let origVideoSize = NSSize(width: ow, height: oh)
      // VideoView's top bezel must be at least as large as the title bar so that dragging the top of crop doesn't drag the window too
      // the max region that the video view can occupy
      let newVideoViewBounds = NSRect(x: StandardTitleBarHeight,
                                      y: InteractiveModeBottomViewHeight + StandardTitleBarHeight,
                                      width: window.frame.width - StandardTitleBarHeight - StandardTitleBarHeight,
                                      height: window.frame.height - InteractiveModeBottomViewHeight - StandardTitleBarHeight - StandardTitleBarHeight)
      let newVideoViewSize = origVideoSize.shrink(toSize: newVideoViewBounds.size)
      let newVideoViewFrame = newVideoViewBounds.centeredResize(to: newVideoViewSize)

      bottomPanelBottomConstraint.animateToConstant(0)
      constrainVideoViewForWindowedMode(
        top: window.frame.height - newVideoViewFrame.maxY,
        right: newVideoViewFrame.maxX - window.frame.width,
        bottom: -newVideoViewFrame.minY,
        left: newVideoViewFrame.minX
      )

      // add crop setting view
      videoContainerView.addSubview(cropController.cropBoxView)
      cropController.cropBoxView.selectedRect = selectWholeVideoByDefault ? NSRect(origin: .zero, size: origVideoSize) : .zero
      cropController.cropBoxView.actualSize = origVideoSize
      cropController.cropBoxView.resized(with: newVideoViewFrame)
      cropController.cropBoxView.isHidden = true
      Utility.quickConstraints(["H:|[v]|", "V:|[v]|"], ["v": cropController.cropBoxView])

      self.cropSettingsView = cropController
    }))

    animationTasks.append(UIAnimation.zeroDurationTask { [self] in
      guard let cropController = cropSettingsView else { return }
      // show crop settings view
      cropController.cropBoxView.isHidden = false
      videoContainerView.layer?.shadowColor = .black
      videoContainerView.layer?.shadowOpacity = 1
      videoContainerView.layer?.shadowOffset = .zero
      videoContainerView.layer?.shadowRadius = 3

      cropController.cropBoxView.resized(with: videoView.frame)
      cropController.cropBoxView.layoutSubtreeIfNeeded()
    })

    animationQueue.run(animationTasks)
  }

  func exitInteractiveMode(immediately: Bool = false, then doAfter: @escaping () -> Void = {}) {
    guard let cropController = cropSettingsView else { return }
    // if exit without animation
    let duration: CGFloat = immediately ? 0 : UIAnimation.CropAnimationDuration
    cropController.cropBoxView.isHidden = true

    var animationTasks: [UIAnimation.Task] = []

    animationTasks.append(UIAnimation.Task(duration: duration, timingFunction: CAMediaTimingFunction(name: .easeIn), { [self] in
      // Restore prev constraints:
      bottomPanelBottomConstraint.animateToConstant(-InteractiveModeBottomViewHeight)
      constrainVideoViewForWindowedMode()
    }))

    animationTasks.append(UIAnimation.zeroDurationTask { [self] in
      cropController.cropBoxView.removeFromSuperview()
      self.hideAllSidebars(animate: false)
      self.bottomView.subviews.removeAll()
      self.bottomView.isHidden = true
      self.showFadeableViews(duration: 0)
      window?.backgroundColor = .black

      if !isPausedPriorToInteractiveMode {
        player.resume()
      }
      isInInteractiveMode = false
      self.cropSettingsView = nil
    })

    let transition = buildLayoutTransition(to: LayoutSpec.fromPreferences(isFullScreen: currentLayout.isFullScreen),
                                           totalStartingDuration: duration * 0.5, totalEndingDuration: duration * 0.5)

    animationTasks.append(contentsOf: transition.animationTasks)

    animationQueue.run(animationTasks, then: doAfter)
  }

  /// Determine if the thumbnail preview can be shown above the progress bar in the on screen controller..
  ///
  /// Normally the OSC's thumbnail preview is shown above the time preview. This is the preferred location. However the
  /// thumbnail preview extends beyond the frame of the OSC. If the OSC is near the top of the window this could result
  /// in the thumbnail extending outside of the window resulting in clipping. This method checks if there is room for the
  /// thumbnail to fully fit in the window. Otherwise the thumbnail must be displayed below the OSC's progress bar.
  /// - Parameters:
  ///   - timePreviewYPos: The y-coordinate of the time preview `TextField`.
  ///   - thumbnailHeight: The height of the thumbnail.
  /// - Returns: `true` if the thumbnail can be shown above the slider, `false` otherwise.
  private func canShowThumbnailAbove(timePreviewYPos: Double, thumbnailHeight: Double) -> Bool {
    switch currentLayout.oscPosition {
    case .top:
      return false
    case .bottom:
      return true
    case .floating:
      // The layout preference for the on screen controller is set to the default floating layout.
      // Must ensure the top of the thumbnail will be below the top of the window.
      let topOfThumbnail = timePreviewYPos + timePreviewWhenSeek.frame.height + thumbnailHeight
      // Normally the height of the usable area of the window can be obtained from the content
      // layout. But when the legacy full screen preference is enabled the layout height may be
      // larger than the content view if the display contains a camera housing. Use the lower of
      // the two heights.
      let windowContentHeight = min(window!.contentLayoutRect.height, window!.contentView!.frame.height)
      return topOfThumbnail <= windowContentHeight
    }
  }

  /** Display time label when mouse over slider */
  private func updateTimeLabel(_ mouseXPos: CGFloat, originalPos: NSPoint) {
    timePreviewWhenSeekHorizontalCenterConstraint.constant = mouseXPos

    guard let duration = player.info.videoDuration else { return }
    let percentage = max(0, Double((mouseXPos - 3) / (playSlider.frame.width - 6)))
    let previewTime = duration * percentage
    guard timePreviewWhenSeek.stringValue != previewTime.stringRepresentation else { return }

    Logger.log("Updating seek time indicator to: \(previewTime.stringRepresentation)", level: .verbose, subsystem: player.subsystem)
    timePreviewWhenSeek.stringValue = previewTime.stringRepresentation

    if player.info.thumbnailsReady, let image = player.info.getThumbnail(forSecond: previewTime.second)?.image,
        let totalRotation = player.info.totalRotation {
      let imageToDisplay = image.rotate(totalRotation)
      thumbnailPeekView.imageView.image = imageToDisplay
      thumbnailPeekView.isHidden = false

      let thumbLength = imageToDisplay.size.width
      let thumbHeight = imageToDisplay.size.height
      thumbnailPeekView.frame.size = imageToDisplay.size
      Logger.log("Displaying thumbnail: \(thumbLength) W x \(thumbHeight) H", level: .verbose, subsystem: player.subsystem)
      let timePreviewOriginY = timePreviewWhenSeek.superview!.convert(timePreviewWhenSeek.frame.origin, to: nil).y
      let showAbove = canShowThumbnailAbove(timePreviewYPos: timePreviewOriginY, thumbnailHeight: thumbHeight)
      let thumbOriginY: CGFloat
      if showAbove {
        // Show thumbnail above seek time, which is above slider
        thumbOriginY = timePreviewOriginY + timePreviewWhenSeek.frame.height
      } else {
        // Show thumbnail below slider
        let sliderFrameInWindow = playSlider.superview!.convert(playSlider.frame.origin, to: nil)
        thumbOriginY = sliderFrameInWindow.y - thumbHeight
      }
      thumbnailPeekView.frame.origin = NSPoint(x: round(originalPos.x - thumbnailPeekView.frame.width / 2), y: thumbOriginY)
    } else {
      thumbnailPeekView.isHidden = true
    }
  }

  func updateBufferIndicatorView() {
    guard loaded else { return }

    if player.info.isNetworkResource {
      bufferIndicatorView.isHidden = false
      bufferSpin.startAnimation(nil)
      bufferProgressLabel.stringValue = NSLocalizedString("main.opening_stream", comment:"Opening stream…")
      bufferDetailLabel.stringValue = ""
    } else {
      bufferIndicatorView.isHidden = true
    }
  }

  // MARK: - UI: Window size / aspect

  /** Calculate the window frame from a parsed struct of mpv's `geometry` option. */
  func windowFrameFromGeometry(newSize: NSSize? = nil, screen: NSScreen? = nil) -> NSRect? {
    guard let geometry = cachedGeometry ?? player.getGeometry(), let screenFrame = (screen ?? window?.screen)?.visibleFrame else {
      Logger.log("WindowFrameFromGeometry: returning nil", level: .verbose, subsystem: player.subsystem)
      return nil
    }
    Logger.log("WindowFrameFromGeometry: using \(geometry), screenFrame: \(screenFrame)", level: .verbose, subsystem: player.subsystem)

    cachedGeometry = geometry
    var winFrame = window!.frame
    if let ns = newSize {
      winFrame.size.width = ns.width
      winFrame.size.height = ns.height
    }
    let winAspect = winFrame.size.aspect
    var widthOrHeightIsSet = false
    // w and h can't take effect at same time
    if let strw = geometry.w, strw != "0" {
      var w: CGFloat
      if strw.hasSuffix("%") {
        w = CGFloat(Double(String(strw.dropLast()))! * 0.01 * Double(screenFrame.width))
      } else {
        w = CGFloat(Int(strw)!)
      }
      w = max(minSize.width, w)
      winFrame.size.width = w
      winFrame.size.height = w / winAspect
      widthOrHeightIsSet = true
    } else if let strh = geometry.h, strh != "0" {
      var h: CGFloat
      if strh.hasSuffix("%") {
        h = CGFloat(Double(String(strh.dropLast()))! * 0.01 * Double(screenFrame.height))
      } else {
        h = CGFloat(Int(strh)!)
      }
      h = max(minSize.height, h)
      winFrame.size.height = h
      winFrame.size.width = h * winAspect
      widthOrHeightIsSet = true
    }
    // x, origin is window center
    if let strx = geometry.x, let xSign = geometry.xSign {
      let x: CGFloat
      if strx.hasSuffix("%") {
        x = CGFloat(Double(String(strx.dropLast()))! * 0.01 * Double(screenFrame.width)) - winFrame.width / 2
      } else {
        x = CGFloat(Int(strx)!)
      }
      winFrame.origin.x = xSign == "+" ? x : screenFrame.width - x
      // if xSign equals "-", need set right border as origin
      if (xSign == "-") {
        winFrame.origin.x -= winFrame.width
      }
    }
    // y
    if let stry = geometry.y, let ySign = geometry.ySign {
      let y: CGFloat
      if stry.hasSuffix("%") {
        y = CGFloat(Double(String(stry.dropLast()))! * 0.01 * Double(screenFrame.height)) - winFrame.height / 2
      } else {
        y = CGFloat(Int(stry)!)
      }
      winFrame.origin.y = ySign == "+" ? y : screenFrame.height - y
      if (ySign == "-") {
        winFrame.origin.y -= winFrame.height
      }
    }
    // if x and y are not specified
    if geometry.x == nil && geometry.y == nil && widthOrHeightIsSet {
      winFrame.origin.x = (screenFrame.width - winFrame.width) / 2
      winFrame.origin.y = (screenFrame.height - winFrame.height) / 2
    }
    // if the screen has offset
    winFrame.origin.x += screenFrame.origin.x
    winFrame.origin.y += screenFrame.origin.y

    Logger.log("WindowFrameFromGeometry: result: \(winFrame)", level: .verbose, subsystem: player.subsystem)
    return winFrame
  }

  /** Set window size when info available, or video size changed. Called in response to receiving 'video-reconfig' msg  */
  func adjustFrameAfterVideoReconfig() {
    guard let window = window else { return }

    let vsfd = player.videoSizeForDisplay
    let videoNativeSize = NSSize(width: vsfd.0, height: vsfd.1)

    // set aspect ratio
    videoView.updateAspectRatioConstraint(w: videoNativeSize.width, h: videoNativeSize.height)
    if #available(macOS 10.12, *) {
      pip.aspectRatio = videoNativeSize
    }

    // Scale only the video. Panels outside the video do not change size
    let oldVideoSize = videoView.frame.size
    let outsidePanelsWidth = window.frame.width - oldVideoSize.width
    let outsidePanelsHeight = window.frame.height - oldVideoSize.height

    let screenRect = bestScreen.visibleFrame
    let maxVideoSize = NSSize(width: screenRect.width - outsidePanelsWidth,
                              height: screenRect.height - outsidePanelsHeight)

    let windowFrame = fsState.priorWindowedFrame ?? window.frame  // FIXME: need to save more information
    var newVideoSize: NSSize
    var newWindowFrame: NSRect

    if shouldResizeWindowAfterVideoReconfig() {
      let resizeRatio = (Preference.enum(for: .resizeWindowOption) as Preference.ResizeWindowOption).ratio

      Logger.log("Starting resizeWindow calculations. OriginalVideoSize: \(videoNativeSize)", level: .verbose)

      // get videoSize on screen
      newVideoSize = videoNativeSize
      if Preference.bool(for: .usePhysicalResolution) {
        newVideoSize = window.convertFromBacking(
          NSMakeRect(window.frame.origin.x, window.frame.origin.y, videoNativeSize.width, videoNativeSize.height)).size
        Logger.log("Converted to physical resolution, result: \(newVideoSize)", level: .verbose)
      }

      if player.info.justStartedFile {
        if resizeRatio < 0 {
          newVideoSize = newVideoSize.shrink(toSize: maxVideoSize)
          Logger.log("Shrinking videoSize to fit in maxVideoSize: \(maxVideoSize), result: \(newVideoSize)", level: .verbose)
        } else {
          newVideoSize = newVideoSize.multiply(CGFloat(resizeRatio))
        }
        Logger.log("Applied resizeRatio: (\(resizeRatio)), result: \(newVideoSize)", level: .verbose)
      }

      // check screen size
      newVideoSize = newVideoSize.satisfyMaxSizeWithSameAspectRatio(maxVideoSize)
      Logger.log("Constrained max size to maxVideoSize: \(maxVideoSize), result: \(newVideoSize)", level: .verbose)
      // guard min size
      // must be slightly larger than the min size, or it will crash when the min size is auto saved as window frame size.
      newVideoSize = newVideoSize.satisfyMinSizeWithSameAspectRatio(minSize)
      Logger.log("Constrained min size: \(minSize). Final result for videoSize: \(newVideoSize)", level: .verbose)
      // check if have geometry set (initial window position/size)
      if shouldApplyInitialWindowSize, let wfg = windowFrameFromGeometry(newSize: newVideoSize) {
        Logger.log("Applied initial window geometry; resulting windowFrame: \(wfg)", level: .verbose)
        newWindowFrame = wfg
      } else {
        let newWindowSize = NSSize(width: newVideoSize.width + outsidePanelsWidth,
                                   height: newVideoSize.height + outsidePanelsHeight)
        if player.info.justStartedFile, resizeRatio < 0 {
          newWindowFrame = screenRect.centeredResize(to: newWindowSize)
          Logger.log("Did a centered resize using screen rect \(screenRect); resulting windowFrame: \(newWindowFrame)", level: .verbose)
        } else {
          newWindowFrame = windowFrame.centeredResize(to: newWindowSize)
          Logger.log("Did a centered resize using prior frame \(windowFrame); resulting windowFrame: \(newWindowFrame)", level: .verbose)
        }
      }

    } else {
      // FIXME: this gets messed up by vertical videos. Investigate organizing per aspect ratio
      // user is navigating in playlist. retain same window width.
      let newVideoWidth = oldVideoSize.width
      let newVideoHeight = newVideoWidth / videoNativeSize.aspect
      newVideoSize = NSSize(width: newVideoWidth, height: newVideoHeight)
      Logger.log("Using same width, with new height (\(newVideoHeight)) -> newVideoSize: \(newVideoSize)", level: .verbose)
      newWindowFrame = computeWindowFrameForVideoResize(toVideoSize: newVideoSize)
    }

    // FIXME: examine this
    // maybe not a good position, consider putting these at playback-restart
    player.info.justOpenedFile = false
    player.info.justStartedFile = false
    shouldApplyInitialWindowSize = false

    if fsState.isFullscreen {
      Logger.log("AdjustFrameAfterVideoReconfig: Window is in fullscreen; setting priorWindowedFrame to: \(newWindowFrame)", level: .verbose)
      fsState.priorWindowedFrame = newWindowFrame
    } else {
      Logger.log("AdjustFrameAfterVideoReconfig: Updating videoSize from: \(oldVideoSize) to: \(newVideoSize); newWindowFrame: \(newWindowFrame)",
                 level: .verbose, subsystem: player.subsystem)
      window.setFrame(newWindowFrame, display: true, animate: true)
      updateWindowParametersForMPV(withSize: newVideoSize)
    }

    // UI and slider
    updatePlayTime(withDuration: true, andProgressBar: true)
    player.events.emit(.windowSizeAdjusted, data: newWindowFrame)
  }

  private func shouldResizeWindowAfterVideoReconfig() -> Bool {
    if player.info.justStartedFile {
      // resize option applies
      let resizeTiming = Preference.enum(for: .resizeWindowTiming) as Preference.ResizeWindowTiming
      switch resizeTiming {
      case .always:
        return true
      case .onlyWhenOpen:
        return player.info.justOpenedFile
      case .never:
        return false
      }
    }
    // video size changed during playback
    return true
  }

  func updateWindowParametersForMPV(withSize videoSize: CGSize? = nil) {
    if let videoWidth = player.info.videoWidth {
      let videoScale = Double((videoSize ?? videoView.frame.size).width) / Double(videoWidth)
      let prevVideoScale = player.info.cachedWindowScale
      if videoScale != prevVideoScale {
        Logger.log("Updating mpv windowScale from: \(player.info.cachedWindowScale) to: \(videoScale)")
        player.info.cachedWindowScale = videoScale
        player.mpv.setDouble(MPVProperty.windowScale, videoScale)
      }
    }
  }

  func setWindowScale(_ scale: CGFloat) {
    guard fsState == .windowed else { return }

    let (videoWidth, videoHeight) = player.videoSizeForDisplay
    let videoDesiredSize = CGSize(width: CGFloat(videoWidth) * scale, height: CGFloat(videoHeight) * scale)

    // FIXME: "Use physical resolution" never worked properly
//    let logicalFrame = NSRect(x: window.frame.origin.x,
//                              y: window.frame.origin.y,
//                              width: CGFloat(videoWidth),
//                              height: CGFloat(videoHeight))
//    var finalSize = (Preference.bool(for: .usePhysicalResolution) ? window.convertFromBacking(logicalFrame) : logicalFrame).size

    Logger.log("Setting window scale to \(scale)x -> desiredVideoSize: \(videoDesiredSize)")
    resizeVideo(toVideoSize: videoDesiredSize)
  }

  private func scaleVideoFromPinchGesture(to magnification: CGFloat) {
    // avoid zero and negative numbers because they will cause problems
    let scale = max(0.0001, magnification + 1.0)

    let origVideoSize = videoContainerFrameAtMagnificationBegin.size
    let newVideoSize = NSSize(width: origVideoSize.width * scale,
                              height: origVideoSize.height * scale);

    resizeVideo(toVideoSize: newVideoSize,
               fromVideoSize: videoContainerFrameAtMagnificationBegin.size,
               fromWindowFrame: windowFrameAtMagnificationBegin,
               animate: false)
  }

  /**
   ┌───────────────────────────────────────────┐
   │ `windowFrame`      ▲                      │
   │                    │`topPanelHeight`      │
   │                    ▼                      │
   │                ┌───────┐                  │
   │◄──────────────►│ Video │◄────────────────►│
   │`leftPanelWidth`│ Frame │`rightPanelWidth `│
   │                └───────┘                  │
   │                  ▲                        │
   │                  │ `bottomPanelHeight`    │
   │                  ▼                        │
   └───────────────────────────────────────────┘
   */
  struct ScalableWindowFrame {
    let windowFrame: NSRect

    // Outside panels
    let topPanelHeight: CGFloat
    let rightPanelWidth: CGFloat
    let bottomPanelHeight: CGFloat
    let leftPanelWidth: CGFloat

    var videoSize: NSSize {
      assert(topPanelHeight >= 0, "Expected topPanelHeight > 0, found \(topPanelHeight)")
      assert(rightPanelWidth >= 0, "Expected rightPanelWidth > 0, found \(rightPanelWidth)")
      assert(bottomPanelHeight >= 0, "Expected bottomPanelHeight > 0, found \(bottomPanelHeight)")
      assert(leftPanelWidth >= 0, "Expected leftPanelWidth > 0, found \(leftPanelWidth)")
      assert(rightPanelWidth >= 0, "Expected rightPanelWidth > 0, found \(rightPanelWidth)")
      return NSSize(width: windowFrame.width - rightPanelWidth - leftPanelWidth,
                    height: windowFrame.height - topPanelHeight - bottomPanelHeight)
    }

    var outsidePanelsTotalSize: NSSize {
      return NSSize(width: rightPanelWidth + leftPanelWidth, height: topPanelHeight + bottomPanelHeight)
    }

    var minVideoSize: NSSize {
      return PlayerCore.minVideoSize
    }

    func clone(windowFrame: NSRect? = nil,
               topPanelHeight: CGFloat? = nil, rightPanelWidth: CGFloat? = nil,
               bottomPanelHeight: CGFloat? = nil, leftPanelWidth: CGFloat? = nil) -> ScalableWindowFrame {

      return ScalableWindowFrame(windowFrame: windowFrame ?? self.windowFrame,
                                 topPanelHeight: topPanelHeight ?? self.topPanelHeight,
                                 rightPanelWidth: rightPanelWidth ?? self.rightPanelWidth,
                                 bottomPanelHeight: bottomPanelHeight ?? self.bottomPanelHeight,
                                 leftPanelWidth: leftPanelWidth ?? self.leftPanelWidth)
    }

    private func computeMaxVideoSize(in containerSize: NSSize) -> NSSize {
      // Resize only the video. Panels outside the video do not change size.
      // To do this, subtract the "outside" panels from the container frame
      let outsidePanelsSize = self.outsidePanelsTotalSize
      return NSSize(width: containerSize.width - outsidePanelsSize.width,
                    height: containerSize.height - outsidePanelsSize.height)
    }

    func constrainWithin(_ containerFrame: NSRect) -> ScalableWindowFrame {
      return scale(desiredVideoSize: self.videoSize, constrainedWithin: containerFrame)
    }

    func scale(desiredVideoSize: NSSize, constrainedWithin containerFrame: NSRect) -> ScalableWindowFrame {
      var newVideoSize = desiredVideoSize

      /// Clamp video between max and min video sizes, maintaining its aspect ratio.
      /// (`desiredVideoSize` is assumed to be correct aspect ratio of the video.)

      // Max
      let maxVideoSize = computeMaxVideoSize(in: containerFrame.size)
      if newVideoSize.height > maxVideoSize.height {
        newVideoSize = newVideoSize.satisfyMaxSizeWithSameAspectRatio(maxVideoSize)
      }
      if newVideoSize.width > maxVideoSize.width {
        newVideoSize = newVideoSize.satisfyMaxSizeWithSameAspectRatio(maxVideoSize)
      }

      // Min
      if newVideoSize.height < minVideoSize.height {
        newVideoSize = newVideoSize.satisfyMinSizeWithSameAspectRatio(minVideoSize)
      }
      if newVideoSize.width < minVideoSize.width {
        newVideoSize = newVideoSize.satisfyMinSizeWithSameAspectRatio(minVideoSize)
      }

      newVideoSize = NSSize(width: newVideoSize.width, height: newVideoSize.height)

      let outsidePanelsSize = self.outsidePanelsTotalSize
      let newWindowSize = NSSize(width: round(newVideoSize.width + outsidePanelsSize.width),
                                 height: round(newVideoSize.height + outsidePanelsSize.height))

      // Round the results to prevent excessive window drift due to small imprecisions in calculation
      let deltaX = round((newVideoSize.width - videoSize.width) / 2)
      let deltaY = round((newVideoSize.height - videoSize.height) / 2)
      let newWindowOrigin = NSPoint(x: windowFrame.origin.x - deltaX,
                                    y: windowFrame.origin.y - deltaY)

      // Move window if needed to make sure the window is not offscreen
      let newWindowFrame = NSRect(origin: newWindowOrigin, size: newWindowSize).constrain(in: containerFrame)
      return self.clone(windowFrame: newWindowFrame)
    }

    func resizeOutsidePanels(newTopHeight: CGFloat? = nil, newRightWidth: CGFloat? = nil, newBottomHeight: CGFloat? = nil, newLeftWidth: CGFloat? = nil) -> ScalableWindowFrame {

      var ΔW: CGFloat = 0
      var ΔH: CGFloat = 0
      var ΔX: CGFloat = 0
      var ΔY: CGFloat = 0
      if let newTopHeight = newTopHeight {
        let ΔTop = abs(newTopHeight) - self.topPanelHeight
        ΔH += ΔTop
      }
      if let newRightWidth = newRightWidth {
        let ΔRight = abs(newRightWidth) - self.rightPanelWidth
        ΔW += ΔRight
      }
      if let newBottomHeight = newBottomHeight {
        let ΔBottom = abs(newBottomHeight) - self.bottomPanelHeight
        ΔH += ΔBottom
        ΔY -= ΔBottom
      }
      if let newLeftWidth = newLeftWidth {
        let ΔLeft = abs(newLeftWidth) - self.leftPanelWidth
        ΔW += ΔLeft
        ΔX -= ΔLeft
      }
      let newWindowFrame = CGRect(x: windowFrame.origin.x + ΔX,
                                  y: windowFrame.origin.y + ΔY,
                                  width: windowFrame.width + ΔW,
                                  height: windowFrame.height + ΔH)
      return ScalableWindowFrame(windowFrame: newWindowFrame,
                                 topPanelHeight: newTopHeight ?? self.topPanelHeight,
                                 rightPanelWidth: newRightWidth ?? self.rightPanelWidth,
                                 bottomPanelHeight: newBottomHeight ?? self.bottomPanelHeight,
                                 leftPanelWidth: newLeftWidth ?? self.leftPanelWidth)
    }
  }

  /**
   Resizes and repositions the window, attempting to match `desiredVideoSize`, but the actual resulting
   video size will be scaled if needed so it is`>= minSize` and `<= bestScreen.visibleFrame`.
   The window's position will also be updated to maintain its current center if possible, but also to
   ensure it is placed entirely inside `bestScreen.visibleFrame`. The aspect ratio of `desiredVideoSize`
   does not need to match the aspect ratio of `fromVideoSize`.
   • If `fromVideoSize` is not provided, it will default to `videoView.frame.size`.
   • If `fromWindowFrame` is not provided, it will default to `window.frame`
   */
  func resizeVideo(toVideoSize desiredVideoSize: CGSize,
                   fromVideoSize: CGSize? = nil, fromWindowFrame: CGRect? = nil,
                   animate: Bool = true) {
    guard !isInInteractiveMode, let window = window else { return }
    let newWindowFrame = computeWindowFrameForVideoResize(toVideoSize: desiredVideoSize,
                                                          fromVideoSize: fromVideoSize, fromWindowFrame: fromWindowFrame)
    window.setFrame(newWindowFrame, display: true, animate: animate)
  }
  

  /// Same as `resizeVideo()`, but does not call `window.setFrame()`.
  private func computeWindowFrameForVideoResize(toVideoSize desiredVideoSize: CGSize,
                                                fromVideoSize oldVideoSize: CGSize? = nil,
                                                fromWindowFrame oldWindowFrame: CGRect? = nil) -> NSRect {

    let oldScaleFrame = buildScalableFrame(fromVideoSize: oldVideoSize ?? self.videoContainerView.frame.size,
                                           fromWindowFrame: oldWindowFrame ?? self.window!.frame)
    let newScaleFrame = oldScaleFrame.scale(desiredVideoSize: desiredVideoSize, constrainedWithin: bestScreen.visibleFrame)

    if Logger.isEnabled(.verbose) {
      let actualScale = String(format: "%.2f", newScaleFrame.videoSize.width / CGFloat(player.videoSizeForDisplay.0))
      Logger.log("Resizing video from \(oldScaleFrame.videoSize) to \(newScaleFrame.videoSize) (\(actualScale)x scale), newWindowFrame: \(newScaleFrame.windowFrame)",
                 level: .verbose, subsystem: player.subsystem)
    }
    return newScaleFrame.windowFrame
  }

  func buildScalableFrame(fromVideoSize videoSize: CGSize, fromWindowFrame windowFrame: CGRect) -> ScalableWindowFrame {
    /// `ScalableWindowFrame` wants to know space used by each outside panel individually.
    /// We can't get that detail from the video size alone; we can only get their sum. But we don't really care because
    /// we are just adjusting the center of the video anyway. Divide width and height by 2 to get the same result.
    let halfOutsideWidth = abs(windowFrame.width - videoSize.width) / 2
    let halfOutsideHeight = abs(windowFrame.height - videoSize.height) / 2

    return ScalableWindowFrame(windowFrame: windowFrame,
                               topPanelHeight: halfOutsideHeight, rightPanelWidth: halfOutsideWidth,
                               bottomPanelHeight: halfOutsideHeight, leftPanelWidth: halfOutsideWidth)
  }

  func buildScalableFrame() -> ScalableWindowFrame {
    let windowFrame = window!.frame
    let videoFrame = videoContainerView.frame

    let leftPanelWidth = videoContainerView.frame.origin.x
    let bottomPanelHeight = videoContainerView.frame.origin.y
    let rightPanelWidth = windowFrame.width - videoFrame.width - leftPanelWidth
    let topPanelHeight = windowFrame.height - videoFrame.height - bottomPanelHeight

    return ScalableWindowFrame(windowFrame: windowFrame,
                               topPanelHeight: topPanelHeight, rightPanelWidth: rightPanelWidth,
                               bottomPanelHeight: bottomPanelHeight, leftPanelWidth: leftPanelWidth)
  }

  // MARK: - UI: Others

  private func blackOutOtherMonitors() {
    let screens = NSScreen.screens.filter { $0 != window?.screen }

    blackWindows = []

    for screen in screens {
      var screenRect = screen.frame
      screenRect.origin = CGPoint(x: 0, y: 0)
      let blackWindow = NSWindow(contentRect: screenRect, styleMask: [], backing: .buffered, defer: false, screen: screen)
      blackWindow.backgroundColor = .black
      blackWindow.level = .iinaBlackScreen

      blackWindows.append(blackWindow)
      blackWindow.makeKeyAndOrderFront(nil)
    }
    Logger.log("Added black windows for \(screens.count); total is now: \(blackWindows.count)", level: .verbose)
  }

  private func removeBlackWindows() {
    for window in blackWindows {
      window.orderOut(self)
    }
    blackWindows = []
    Logger.log("Removed all black windows", level: .verbose)
  }

  override func setWindowFloatingOnTop(_ onTop: Bool, updateOnTopStatus: Bool = true) {
    guard !fsState.isFullscreen else { return }
    super.setWindowFloatingOnTop(onTop, updateOnTopStatus: updateOnTopStatus)

    resetCollectionBehavior()
  }

  // MARK: - Sync UI with playback

  override func updatePlayButtonState(_ state: NSControl.StateValue) {
    super.updatePlayButtonState(state)
    if state == .off {
      speedValueIndex = AppData.availableSpeedValues.count / 2
      leftArrowLabel.isHidden = true
      rightArrowLabel.isHidden = true
    }
  }

  func updateNetworkState() {
    let needShowIndicator = player.info.pausedForCache || player.info.isSeeking

    if needShowIndicator {
      let usedStr = FloatingPointByteCountFormatter.string(fromByteCount: player.info.cacheUsed, prefixedBy: .ki)
      let speedStr = FloatingPointByteCountFormatter.string(fromByteCount: player.info.cacheSpeed)
      let bufferingState = player.info.bufferingState
      bufferIndicatorView.isHidden = false
      bufferProgressLabel.stringValue = String(format: NSLocalizedString("main.buffering_indicator", comment:"Buffering... %d%%"), bufferingState)
      bufferDetailLabel.stringValue = "\(usedStr)B (\(speedStr)/s)"
    } else {
      bufferIndicatorView.isHidden = true
    }
  }

  private func updateArrowButtonImages() {
    switch arrowBtnFunction {
    case .playlist:
      leftArrowButton.image = #imageLiteral(resourceName: "nextl")
      rightArrowButton.image = #imageLiteral(resourceName: "nextr")
    case .speed, .seek:
      leftArrowButton.image = #imageLiteral(resourceName: "speedl")
      rightArrowButton.image = #imageLiteral(resourceName: "speed")
    }
  }

  // MARK: - IBActions

  @IBAction override func playButtonAction(_ sender: NSButton) {
    super.playButtonAction(sender)
    if (player.info.isPaused) {
      // speed is already reset by playerCore
      speedValueIndex = AppData.availableSpeedValues.count / 2
      leftArrowLabel.isHidden = true
      rightArrowLabel.isHidden = true
      // set speed to 0 if is fastforwarding
      if isFastforwarding {
        player.setSpeed(1)
        isFastforwarding = false
      }
    }
  }

  @IBAction override func muteButtonAction(_ sender: NSButton) {
    super.muteButtonAction(sender)
    player.sendOSD(player.info.isMuted ? .mute : .unMute)
  }

  @IBAction func leftArrowButtonAction(_ sender: NSButton) {
    if arrowBtnFunction == .speed {
      let speeds = AppData.availableSpeedValues.count
      // If fast forwarding change speed to 1x
      if speedValueIndex > speeds / 2 {
        speedValueIndex = speeds / 2
      }

      if sender.intValue == 0 { // Released
        if maxPressure == 1 &&
          (speedValueIndex < speeds / 2 - 1 ||
          Date().timeIntervalSince(lastClick) < minimumPressDuration) { // Single click ended, 2x speed
          speedValueIndex = oldIndex - 1
        } else { // Force Touch or long press ended
          speedValueIndex = speeds / 2
        }
        maxPressure = 0
      } else {
        if sender.intValue == 1 && maxPressure == 0 { // First press
          oldIndex = speedValueIndex
          speedValueIndex -= 1
          lastClick = Date()
        } else { // Force Touch
          speedValueIndex = max(oldIndex - Int(sender.intValue), 0)
        }
        maxPressure = max(maxPressure, sender.intValue)
      }
      arrowButtonAction(left: true)
    } else {
      // trigger action only when released button
      if sender.intValue == 0 {
        arrowButtonAction(left: true)
      }
    }
  }

  @IBAction func rightArrowButtonAction(_ sender: NSButton) {
    if arrowBtnFunction == .speed {
      let speeds = AppData.availableSpeedValues.count
      // If rewinding change speed to 1x
      if speedValueIndex < speeds / 2 {
        speedValueIndex = speeds / 2
      }

      if sender.intValue == 0 { // Released
        if maxPressure == 1 &&
          (speedValueIndex > speeds / 2 + 1 ||
          Date().timeIntervalSince(lastClick) < minimumPressDuration) { // Single click ended
          speedValueIndex = oldIndex + 1
        } else { // Force Touch or long press ended
          speedValueIndex = speeds / 2
        }
        maxPressure = 0
      } else {
        if sender.intValue == 1 && maxPressure == 0 { // First press
          oldIndex = speedValueIndex
          speedValueIndex += 1
          lastClick = Date()
        } else { // Force Touch
          speedValueIndex = min(oldIndex + Int(sender.intValue), speeds - 1)
        }
        maxPressure = max(maxPressure, sender.intValue)
      }
      arrowButtonAction(left: false)
    } else {
      // trigger action only when released button
      if sender.intValue == 0 {
        arrowButtonAction(left: false)
      }
    }
  }

  /** handle action of either left or right arrow button */
  func arrowButtonAction(left: Bool) {
    switch arrowBtnFunction {
    case .speed:
      isFastforwarding = true
      let speedValue = AppData.availableSpeedValues[speedValueIndex]
      player.setSpeed(speedValue)
      if speedValueIndex == 5 {
        leftArrowLabel.isHidden = true
        rightArrowLabel.isHidden = true
      } else if speedValueIndex < 5 {
        leftArrowLabel.isHidden = false
        rightArrowLabel.isHidden = true
        leftArrowLabel.stringValue = String(format: "%.2fx", speedValue)
      } else if speedValueIndex > 5 {
        leftArrowLabel.isHidden = true
        rightArrowLabel.isHidden = false
        rightArrowLabel.stringValue = String(format: "%.0fx", speedValue)
      }
      // if is paused
      if playButton.state == .off {
        updatePlayButtonState(.on)
        player.resume()
      }

    case .playlist:
      player.mpv.command(left ? .playlistPrev : .playlistNext, checkError: false)

    case .seek:
      player.seek(relativeSecond: left ? -10 : 10, option: .relative)

    }
  }

  @IBAction func toggleOnTop(_ sender: NSButton) {
    setWindowFloatingOnTop(!isOntop)
  }

  /** When slider changes */
  @IBAction override func playSliderChanges(_ sender: NSSlider) {
    guard !player.info.fileLoading else { return }
    super.playSliderChanges(sender)

    // update position of time label
    timePreviewWhenSeekHorizontalCenterConstraint.constant = sender.knobPointPosition() - playSlider.frame.origin.x

    // update text of time label
    let percentage = 100 * sender.doubleValue / sender.maxValue
    let seekTime = player.info.videoDuration! * percentage * 0.01
    Logger.log("PlaySliderChanged: setting seek time label to \(seekTime.stringRepresentation.quoted)")
    timePreviewWhenSeek.stringValue = seekTime.stringRepresentation
  }

  @objc func toolBarButtonAction(_ sender: NSButton) {
    guard let buttonType = Preference.ToolBarButton(rawValue: sender.tag) else { return }
    switch buttonType {
    case .fullScreen:
      toggleWindowFullScreen()
    case .musicMode:
      player.switchToMiniPlayer()
    case .pip:
      if #available(macOS 10.12, *) {
        if pipStatus == .inPIP {
          exitPIP()
        } else if pipStatus == .notInPIP {
          enterPIP()
        }
      }
    case .playlist:
      showSidebar(forTabGroup: .playlist)
    case .settings:
      showSidebar(forTabGroup: .settings)
    case .subTrack:
      quickSettingView.showSubChooseMenu(forView: sender, showLoadedSubs: true)
    }
  }

  // MARK: - Utility

  internal override func handleIINACommand(_ cmd: IINACommand) {
    super.handleIINACommand(cmd)
    switch cmd {
    case .togglePIP:
      if #available(macOS 10.12, *) {
        menuTogglePIP(.dummy)
      }
    case .videoPanel:
      menuShowVideoQuickSettings(.dummy)
    case .audioPanel:
      menuShowAudioQuickSettings(.dummy)
    case .subPanel:
      menuShowSubQuickSettings(.dummy)
    case .playlistPanel:
      menuShowPlaylistPanel(.dummy)
    case .chapterPanel:
      menuShowChaptersPanel(.dummy)
    case .toggleMusicMode:
      menuSwitchToMiniPlayer(.dummy)
    case .deleteCurrentFileHard:
      menuDeleteCurrentFileHard(.dummy)
    case .biggerWindow:
      let item = NSMenuItem()
      item.tag = 11
      menuChangeWindowSize(item)
    case .smallerWindow:
      let item = NSMenuItem()
      item.tag = 10
      menuChangeWindowSize(item)
    case .fitToScreen:
      let item = NSMenuItem()
      item.tag = 3
      menuChangeWindowSize(item)
    default:
      break
    }
  }

  private func resetCollectionBehavior() {
    guard !fsState.isFullscreen else { return }
    if Preference.bool(for: .useLegacyFullScreen) {
      window?.collectionBehavior = [.managed, .fullScreenAuxiliary]
    } else {
      window?.collectionBehavior = [.managed, .fullScreenPrimary]
    }
  }

}

// MARK: - Picture in Picture

@available(macOS 10.12, *)
extension MainWindowController: PIPViewControllerDelegate {

  func enterPIP() {
    guard pipStatus != .inPIP else { return }
    pipStatus = .inPIP
    showFadeableViews()

    pipVideo = NSViewController()
    pipVideo.view = videoView
    pip.playing = player.info.isPlaying
    pip.title = window?.title

    pip.presentAsPicture(inPicture: pipVideo)
    pipOverlayView.isHidden = false

    if let window = self.window {
      let windowShouldDoNothing = window.styleMask.contains(.fullScreen) || window.isMiniaturized
      let pipBehavior = windowShouldDoNothing ? .doNothing : Preference.enum(for: .windowBehaviorWhenPip) as Preference.WindowBehaviorWhenPip
      switch pipBehavior {
      case .doNothing:
        break
      case .hide:
        isWindowHidden = true
        window.orderOut(self)
        break
      case .minimize:
        isWindowMiniaturizedDueToPip = true
        window.miniaturize(self)
        break
      }
      if Preference.bool(for: .pauseWhenPip) {
        player.pause()
      }
    }

    player.events.emit(.pipChanged, data: true)
  }

  func exitPIP() {
    guard pipStatus == .inPIP else { return }
    if pipShouldClose(pip) {
      // Prod Swift to pick the dismiss(_ viewController: NSViewController)
      // overload over dismiss(_ sender: Any?). A change in the way implicitly
      // unwrapped optionals are handled in Swift means that the wrong method
      // is chosen in this case. See https://bugs.swift.org/browse/SR-8956.
      pip.dismiss(pipVideo!)
    }
    player.events.emit(.pipChanged, data: false)
  }

  func doneExitingPIP() {
    if isWindowHidden {
      window?.makeKeyAndOrderFront(self)
    }

    pipStatus = .notInPIP

    addVideoViewToWindow()

    // Similarly, we need to run a redraw here as well. We check to make sure we
    // are paused, because this causes a janky animation in either case but as
    // it's not necessary while the video is playing and significantly more
    // noticeable, we only redraw if we are paused.
    let currentTrackIsAlbumArt = player.info.currentTrack(.video)?.isAlbumart ?? false
    if player.info.isPaused || currentTrackIsAlbumArt {
      videoView.videoLayer.draw(forced: true)
    }

    resetFadeTimer()

    isWindowMiniaturizedDueToPip = false
    isWindowHidden = false
  }

  func prepareForPIPClosure(_ pip: PIPViewController) {
    guard pipStatus == .inPIP else { return }
    guard let window = window else { return }
    // This is called right before we're about to close the PIP
    pipStatus = .intermediate

    // Hide the overlay view preemptively, to prevent any issues where it does
    // not hide in time and ends up covering the video view (which will be added
    // to the window under everything else, including the overlay).
    pipOverlayView.isHidden = true

    // Set frame to animate back to
    if fsState.isFullscreen {
      let newVideoSize = videoView.frame.size.shrink(toSize: window.frame.size)
      pip.replacementRect = newVideoSize.centeredRect(in: .init(origin: .zero, size: window.frame.size))
    } else {
      pip.replacementRect = window.contentView?.frame ?? .zero
    }
    pip.replacementWindow = window

    // Bring the window to the front and deminiaturize it
    NSApp.activate(ignoringOtherApps: true)
    window.deminiaturize(pip)
  }

  func pipWillClose(_ pip: PIPViewController) {
    prepareForPIPClosure(pip)
  }

  func pipShouldClose(_ pip: PIPViewController) -> Bool {
    prepareForPIPClosure(pip)
    return true
  }

  func pipDidClose(_ pip: PIPViewController) {
    doneExitingPIP()
  }

  func pipActionPlay(_ pip: PIPViewController) {
    player.resume()
  }

  func pipActionPause(_ pip: PIPViewController) {
    player.pause()
  }

  func pipActionStop(_ pip: PIPViewController) {
    // Stopping PIP pauses playback
    player.pause()
  }
}
