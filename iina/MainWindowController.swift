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

fileprivate let InteractiveModeBottomViewHeight: CGFloat = 60

fileprivate extension NSStackView.VisibilityPriority {
  static let detachEarly = NSStackView.VisibilityPriority(rawValue: 850)
  static let detachEarlier = NSStackView.VisibilityPriority(rawValue: 800)
  static let detachEarliest = NSStackView.VisibilityPriority(rawValue: 750)
}

class MainWindowController: PlayerWindowController {

  override var windowNibName: NSNib.Name {
    return NSNib.Name("MainWindowController")
  }

  @objc let monospacedFont: NSFont = {
    let fontSize = NSFont.systemFontSize(for: .small)
    return NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
  }()

  // MARK: - Constants

  /** Minimum window size. */
  let minSize = NSMakeSize(285, 120)

  /** For Force Touch. */
  let minimumPressDuration: TimeInterval = 0.5

  lazy var reducedTitleBarHeight: CGFloat = {
    if let heightOfCloseButton = window?.standardWindowButton(.closeButton)?.frame.height {
      // add 2 because button's bounds seems to be a bit larger than its visible size
      return StandardTitleBarHeight - ((StandardTitleBarHeight - heightOfCloseButton) / 2 + 2)
    }
    Logger.log("reducedTitleBarHeight may be incorrect (could not get close button)", level: .error)
    return StandardTitleBarHeight
  }()

  // Preferred height for "full-width" OSCs (i.e. top and bottom, not floating)
  let fullWidthOSCPreferredHeight: CGFloat = 44

  // Size of playback button icon (W = H):
  let playButtonSizeForFullOSC: CGFloat = 24
  let playButtonSizeForFloatingOSC: CGFloat = 24
  let playButtonSizeForTitleBarOSC: CGFloat = 18

  /** Scale of spacing around & between playback buttons (for floating OSC):
   (1) 1x margin above and below buttons,
   (2) 2x margin to left and right of button group,
   (3) 4x spacing betwen buttons
   */
  let playbackButtonMarginForFloatingOSC: CGFloat = 4
  /** Scale of spacing around & between playback buttons (for top / bottom OSCs) */
  let playbackButtonMarginForFullWidthOSC: CGFloat = 6
  let playbackButtonMarginForTitleBarOSC: CGFloat = 3

  // MARK: - Objects, Views

  override var videoView: VideoView {
    return _videoView
  }

  lazy private var _videoView: VideoView = VideoView(frame: window!.contentView!.bounds, player: player)

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

  private lazy var magnificationGestureRecognizer: NSMagnificationGestureRecognizer = {
    return NSMagnificationGestureRecognizer(target: self, action: #selector(MainWindowController.handleMagnifyGesture(recognizer:)))
  }()

  /** For auto hiding UI after a timeout. */
  var hideFadeableViewsTimer: Timer?
  var hideOSDTimer: Timer?

  /** For blacking out other screens. */
  var screens: [NSScreen] = []
  var cachedScreenCount = 0
  var blackWindows: [NSWindow] = []

  // Current rotation of videoView: see MainWindowRotationGesture
  let rotationHandler = VideoRotationHandler()

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
  var isWindowHidden: Bool = false
  var isWindowMiniaturizedDueToPip = false

  // might use another obj to handle slider?
  var isMouseInWindow: Bool = false
  var isMouseInSlider: Bool = false

  var isFastforwarding: Bool = false

  var isPausedDueToInactive: Bool = false
  var isPausedDueToMiniaturization: Bool = false
  var isPausedPriorToInteractiveMode: Bool = false

  var lastMagnification: CGFloat = 0.0

  /** Views that will show/hide when cursor moving in/out the window. */
  var fadeableViews = Set<NSView>()

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

  // MARK: - Observed user defaults

  // Cached user default values
  private lazy var titleBarStyle: Preference.TitleBarStyle = Preference.enum(for: .titleBarStyle)
  private lazy var topPanelPlacement: Preference.PanelPlacement = Preference.enum(for: .topPanelPlacement)
  private lazy var bottomPanelPlacement: Preference.PanelPlacement = Preference.enum(for: .bottomPanelPlacement)
  private lazy var enableOSC: Bool = Preference.bool(for: .enableOSC)
  private lazy var oscPosition: Preference.OSCPosition = Preference.enum(for: .oscPosition)
  private lazy var arrowBtnFunction: Preference.ArrowButtonAction = Preference.enum(for: .arrowButtonAction)
  private lazy var pinchAction: Preference.PinchAction = Preference.enum(for: .pinchAction)
  lazy var displayTimeAndBatteryInFullScreen: Bool = Preference.bool(for: .displayTimeAndBatteryInFullScreen)

  private static let mainWindowPrefKeys: [Preference.Key] = PlayerWindowController.playerWindowPrefKeys + [
    .osdPosition,
    .titleBarStyle,
    .enableOSC,
    .oscPosition,
    .topPanelPlacement,
    .bottomPanelPlacement,
    .enableThumbnailPreview,
    .enableThumbnailForRemoteFiles,
    .thumbnailLength,
    .showChapterPos,
    .arrowButtonAction,
    .pinchAction,
    .blackOutMonitor,
    .useLegacyFullScreen,
    .displayTimeAndBatteryInFullScreen,
    .controlBarToolbarButtons,
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
      PK.titleBarStyle.rawValue,
      PK.topPanelPlacement.rawValue,
      PK.bottomPanelPlacement.rawValue,
      PK.showLeadingSidebarToggleButton.rawValue,
      PK.showTrailingSidebarToggleButton.rawValue:

      setupTitleBarAndOSC()
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
        updateArrowButtonImage()
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
    case PK.controlBarToolbarButtons.rawValue:
      if let newValue = change[.newKey] as? [Int] {
        setupOSCToolbarButtons(newValue.compactMap(Preference.ToolBarButton.init(rawValue:)))
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
      UIAnimation.run { _ in
        self.updateOSDPosition()
      }
    default:
      return
    }
  }

  // MARK: - Outlets

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

  private var trafficLightButtonsWidth: CGFloat = 0.0

  /** Get the `NSTextField` of widow's title. */
  private var titleTextField: NSTextField? {
    get {
      return window?.standardWindowButton(.closeButton)?.superview?.subviews.compactMap({ $0 as? NSTextField }).first
    }
  }

  private var leadingTitlebarAccesoryViewController: NSTitlebarAccessoryViewController!
  private var trailingTitlebarAccesoryViewController: NSTitlebarAccessoryViewController!
  @IBOutlet var leadingTitleBarAccessoryView: NSView!
  @IBOutlet var trailingTitleBarAccessoryView: NSView!

  /** Current OSC view. May be top, bottom, or floating depneding on user pref. */
  private var currentControlBar: NSView?

  // Spacers in left title bar accessory view:
  @IBOutlet weak var leadingTitleBarLeadingSpaceConstraint: NSLayoutConstraint!
  @IBOutlet weak var leadingTitleBarTrailingSpaceConstraint: NSLayoutConstraint!

  // Spacers in right title bar accessory view:
  @IBOutlet weak var trailingTitleBarLeadingSpaceConstraint: NSLayoutConstraint!
  @IBOutlet weak var trailingTitleBarTrailingSpaceConstraint: NSLayoutConstraint!

  // Needs to be changed to align with either sidepanel or left of screen:
  @IBOutlet weak var topPanelLeadingSpaceConstraint: NSLayoutConstraint!
  // Needs to be changed to align with either sidepanel or right of screen:
  @IBOutlet weak var topPanelTrailingSpaceConstraint: NSLayoutConstraint!

  // Needs to be changed to align with either sidepanel or left of screen:
  @IBOutlet weak var bottomPanelLeadingSpaceConstraint: NSLayoutConstraint!
  // Needs to be changed to align with either sidepanel or right of screen:
  @IBOutlet weak var bottomPanelTrailingSpaceConstraint: NSLayoutConstraint!

  @IBOutlet weak var videoAspectRatioConstraint: NSLayoutConstraint!
  @IBOutlet weak var videoContainerTopConstraint: NSLayoutConstraint!
  @IBOutlet weak var videoContainerBottomConstraint: NSLayoutConstraint!
  @IBOutlet weak var windowContentViewLeadingConstraint: NSLayoutConstraint!
  @IBOutlet weak var windowContentViewTrailingConstraint: NSLayoutConstraint!

  /** ┌──────────────────────┐
      │ A ┌────┐ B  ┌────┐ C │  A: leadingSidebarToOSDSpaceConstraint
      │◄─►│    │◄──►│    │◄─►│  B: additionalInfoToOSDSpaceConstraint
      │   └────┘    └────┘   │  C: trailingSidebarToOSDSpaceConstraint
      └──────────────────────┘
   */
  @IBOutlet weak var leadingSidebarToOSDSpaceConstraint: NSLayoutConstraint!
  @IBOutlet weak var additionalInfoToOSDSpaceConstraint: NSLayoutConstraint!
  @IBOutlet weak var trailingSidebarToOSDSpaceConstraint: NSLayoutConstraint!

  @IBOutlet weak var videoContainerLeadingToLeadingSidebarConstraint: NSLayoutConstraint!
  @IBOutlet weak var leadingSidebarWidthConstraint: NSLayoutConstraint!
  @IBOutlet weak var videoContainerTrailingToTrailingSidebarConstraint: NSLayoutConstraint!
  @IBOutlet weak var trailingSidebarWidthConstraint: NSLayoutConstraint!
  @IBOutlet weak var oscTitleBarWidthConstraint: NSLayoutConstraint!

  @IBOutlet weak var bottomPanelBottomConstraint: NSLayoutConstraint!
  // Sets the size of the spacer view in the top overlay which reserves space for a title bar:
  @IBOutlet weak var titleBarHeightConstraint: NSLayoutConstraint!
  // Size of each side of the square 3 playback buttons ⏪⏯️⏩ (Left Arrow, Play/Pause, Right Arrow):
  @IBOutlet weak var playbackButtonSizeConstraint: NSLayoutConstraint!
  @IBOutlet weak var playbackButtonMarginSizeConstraint: NSLayoutConstraint!
  @IBOutlet weak var topOSCPreferredHeightConstraint: NSLayoutConstraint!
  @IBOutlet weak var bottomOSCPreferredHeightConstraint: NSLayoutConstraint!

  /** Top-of-video overlay, may contain `titleBarView` and/or top OSC if configured. */
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

  @IBOutlet weak var oscFloatingTopView: NSStackView!
  @IBOutlet weak var oscFloatingBottomView: NSView!
  @IBOutlet weak var oscBottomMainView: NSStackView!
  @IBOutlet weak var oscTopMainView: NSStackView!
  @IBOutlet weak var oscTitleBarMainView: NSStackView!

  @IBOutlet weak var fragControlView: NSStackView!
  @IBOutlet weak var fragToolbarView: NSStackView!
  @IBOutlet weak var fragVolumeView: NSView!
  @IBOutlet weak var fragSliderView: NSView!
  @IBOutlet weak var fragControlViewMiddleView: NSView!
  @IBOutlet weak var fragControlViewLeftView: NSView!
  @IBOutlet weak var fragControlViewRightView: NSView!

  @IBOutlet weak var leftArrowLabel: NSTextField!
  @IBOutlet weak var rightArrowLabel: NSTextField!

  @IBOutlet weak var osdVisualEffectView: NSVisualEffectView!
  @IBOutlet weak var osdStackView: NSStackView!
  @IBOutlet weak var osdLabel: NSTextField!
  @IBOutlet weak var osdAccessoryText: NSTextField!
  @IBOutlet weak var osdAccessoryProgress: NSProgressIndicator!

  @IBOutlet weak var pipOverlayView: NSVisualEffectView!
  @IBOutlet weak var videoContainerView: NSView!

  lazy var pluginOverlayViewContainer: NSView! = {
    guard let window = window, let cv = window.contentView else { return nil }
    let view = NSView(frame: .zero)
    view.translatesAutoresizingMaskIntoConstraints = false
    cv.addSubview(view, positioned: .below, relativeTo: bufferIndicatorView)
    Utility.quickConstraints(["H:|[v]|", "V:|[v]|"], ["v": view])
    return view
  }()

  lazy var subPopoverView = playlistView.subPopover?.contentViewController?.view

  var videoViewConstraints: [NSLayoutConstraint.Attribute: NSLayoutConstraint] = [:]
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

    window.styleMask.insert(.fullSizeContentView)

    // need to deal with control bar, so we handle it manually
    // w.isMovableByWindowBackground  = true

    // set background color to black
    window.backgroundColor = .black

    // TODO: why?
    topPanelView.layerContentsRedrawPolicy = .onSetNeedsDisplay

    // Sidebars
    leadingSidebarView.isHidden = true
    trailingSidebarView.isHidden = true

    leadingSidebar.placement = Preference.enum(for: .leadingSidebarPlacement)
    trailingSidebar.placement = Preference.enum(for: .trailingSidebarPlacement)

    let settingsSidebarLocation: Preference.SidebarLocation = Preference.enum(for: .settingsTabGroupLocation)
    sidebarsByID[settingsSidebarLocation]?.tabGroups.insert(.settings)

    let playlistSidebarLocation: Preference.SidebarLocation = Preference.enum(for: .playlistTabGroupLocation)
    sidebarsByID[playlistSidebarLocation]?.tabGroups.insert(.playlist)

    // Titlebar accessories

    trafficLightButtonsWidth = calculateWidthOfTrafficLightButtons()

    leadingTitlebarAccesoryViewController = NSTitlebarAccessoryViewController()
    leadingTitlebarAccesoryViewController.view = leadingTitleBarAccessoryView
    leadingTitlebarAccesoryViewController.layoutAttribute = .leading
    window.addTitlebarAccessoryViewController(leadingTitlebarAccesoryViewController)
    leadingTitleBarAccessoryView.translatesAutoresizingMaskIntoConstraints = false
    let constraint = leadingTitleBarAccessoryView.heightAnchor.constraint(equalTo: leadingTitleBarAccessoryView.superview!.heightAnchor)
    constraint.isActive = true

    trailingTitlebarAccesoryViewController = NSTitlebarAccessoryViewController()
    trailingTitlebarAccesoryViewController.view = trailingTitleBarAccessoryView
    trailingTitlebarAccesoryViewController.layoutAttribute = .trailing
    window.addTitlebarAccessoryViewController(trailingTitlebarAccesoryViewController)
    trailingTitleBarAccessoryView.translatesAutoresizingMaskIntoConstraints = false

    // Now that we know the height of the title bar, we can set these:
    for titleBarButton in [leadingSidebarToggleButton, trailingSidebarToggleButton, pinToTopButton] {
      guard let titleBarButton = titleBarButton else { continue }
      let buttonSizeConstraint = titleBarButton.heightAnchor.constraint(equalToConstant: StandardTitleBarHeight)
      buttonSizeConstraint.isActive = true
      titleBarButton.addConstraint(buttonSizeConstraint)
    }

    // FIXME: do not do this here
    // size
    window.minSize = minSize
    if let wf = windowFrameFromGeometry() {
      window.setFrame(wf, display: false)
    }

    updateVideoAspectRatioConstraint(w: AppData.sizeWhenNoVideo.width, h: AppData.sizeWhenNoVideo.height)
    window.aspectRatio = AppData.sizeWhenNoVideo

    // osc views
    fragControlView.addView(fragControlViewLeftView, in: .center)
    fragControlView.addView(fragControlViewMiddleView, in: .center)
    fragControlView.addView(fragControlViewRightView, in: .center)

    updateArrowButtonImage()

    // video view
    guard let cv = window.contentView else { return }
    cv.autoresizesSubviews = false
    addVideoViewToWindow()
    window.setIsVisible(true)

    rotationHandler.mainWindowController = self

    // gesture recognizers
    cv.addGestureRecognizer(magnificationGestureRecognizer)
    cv.addGestureRecognizer(NSRotationGestureRecognizer(target: self, action: #selector(rotationHandler.handleRotationGesture(recognizer:))))

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

    player.initVideo()

    let roundedCornerRadius: CGFloat = CGFloat(Preference.float(for: .roundedCornerRadius))

    // init quick setting view now
    let _ = quickSettingView

    // thumbnail peek view
    thumbnailPeekView.isHidden = true

    // other initialization
    osdAccessoryProgress.usesThreadedAnimation = false
    if #available(macOS 10.14, *) {
      topPanelBottomBorder.fillColor = NSColor(named: .titleBarBorder)!
    }
    cachedScreenCount = NSScreen.screens.count
    // Do not make visual effects views opaque when window is not in focus
    for view in [topPanelView, osdVisualEffectView, controlBarBottom, controlBarFloating,
                 leadingSidebarView, trailingSidebarView, osdVisualEffectView, pipOverlayView, bufferIndicatorView] {
      view?.state = .active
    }
    // hide other views
    osdVisualEffectView.isHidden = true
    leftArrowLabel.isHidden = true
    rightArrowLabel.isHidden = true
    timePreviewWhenSeek.isHidden = true
    bottomView.isHidden = true
    pipOverlayView.isHidden = true

    setupTitleBarAndOSC()
    let buttons = (Preference.array(for: .controlBarToolbarButtons) as? [Int] ?? []).compactMap(Preference.ToolBarButton.init(rawValue:))
    setupOSCToolbarButtons(buttons)

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
      // This observer handles a situation that the user connected a new screen or removed a screen

      // FIXME: this also handles the case where existing screen was resized, including if the Dock was shown/hidden!
      // Need to update window sizes accordingly

      // FIXME: Change to use displayIDs as VideoView does. Scren count alone should not be relied upon
      let screenCount = NSScreen.screens.count
      Logger.log("Got \(NSApplication.didChangeScreenParametersNotification.rawValue.quoted); screen count was: \(self.cachedScreenCount), is now: \(screenCount)", subsystem: player.subsystem)
      if self.fsState.isFullscreen && Preference.bool(for: .blackOutMonitor) && self.cachedScreenCount != screenCount {
        self.removeBlackWindows()
        self.blackOutOtherMonitors()
      }
      // Update the cached value
      self.cachedScreenCount = screenCount
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
      guard let strongSelf = self else { return }
      let seconds = strongSelf.percentToSeconds(strongSelf.playSlider.abLoopA.doubleValue)
      strongSelf.player.abLoopA = seconds
      strongSelf.player.sendOSD(.abLoopUpdate(.aSet, VideoTime(seconds).stringRepresentation))
    }
    addObserver(to: .default, forName: .iinaPlaySliderLoopKnobChanged, object: playSlider.abLoopB) { [weak self] _ in
      guard let strongSelf = self else { return }
      let seconds = strongSelf.percentToSeconds(strongSelf.playSlider.abLoopB.doubleValue)
      strongSelf.player.abLoopB = seconds
      strongSelf.player.sendOSD(.abLoopUpdate(.bSet, VideoTime(seconds).stringRepresentation))
    }

    player.events.emit(.windowLoaded)
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

  // - MARK: Controllers & Title Bar

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
  private func updateTopPanelPlacement() {
    guard let window = window, let windowContentView = window.contentView else { return }
    windowContentView.removeConstraint(videoContainerTopConstraint)
    windowContentView.removeConstraint(topPanelLeadingSpaceConstraint)
    windowContentView.removeConstraint(topPanelTrailingSpaceConstraint)

    if Preference.enum(for: .topPanelPlacement) == Preference.PanelPlacement.outsideVideo {
      videoContainerTopConstraint = videoContainerView.topAnchor.constraint(equalTo: topPanelView.bottomAnchor, constant: 0)
      topPanelView.blendingMode = .behindWindow

      // Align left & right sides with window (sidebars go below top panel)
      topPanelLeadingSpaceConstraint = topPanelView.leadingAnchor.constraint(equalTo: windowContentView.leadingAnchor, constant: 0)
      topPanelTrailingSpaceConstraint = topPanelView.trailingAnchor.constraint(equalTo: windowContentView.trailingAnchor, constant: 0)
    } else {
      // Inside video or not shown
      videoContainerTopConstraint = videoContainerView.topAnchor.constraint(equalTo: topPanelView.topAnchor, constant: 0)
      topPanelView.blendingMode = .withinWindow

      // Align left & right sides with sidebars (top panel will squeeze to make space for sidebars)
      topPanelLeadingSpaceConstraint = topPanelView.leadingAnchor.constraint(equalTo: leadingSidebarView.trailingAnchor, constant: 0)
      topPanelTrailingSpaceConstraint = topPanelView.trailingAnchor.constraint(equalTo: trailingSidebarView.leadingAnchor, constant: 0)
    }
    videoContainerTopConstraint.isActive = true
    topPanelLeadingSpaceConstraint.isActive = true
    topPanelTrailingSpaceConstraint.isActive = true
  }

  private func updateBottomPanelPlacement() {
    guard let window = window, let windowContentView = window.contentView else { return }
    windowContentView.removeConstraint(videoContainerBottomConstraint)
    windowContentView.removeConstraint(bottomPanelLeadingSpaceConstraint)
    windowContentView.removeConstraint(bottomPanelTrailingSpaceConstraint)

    if Preference.enum(for: .bottomPanelPlacement) == Preference.PanelPlacement.outsideVideo {
      videoContainerBottomConstraint = videoContainerView.bottomAnchor.constraint(equalTo: controlBarBottom.topAnchor, constant: 0)
      controlBarBottom.blendingMode = .behindWindow
      controlBarBottomTopBorder.isHidden = false

      // Align left & right sides with window (sidebars go below top panel)
      bottomPanelLeadingSpaceConstraint = controlBarBottom.leadingAnchor.constraint(equalTo: windowContentView.leadingAnchor, constant: 0)
      bottomPanelTrailingSpaceConstraint = controlBarBottom.trailingAnchor.constraint(equalTo: windowContentView.trailingAnchor, constant: 0)
    } else {  // Inside video
      videoContainerBottomConstraint = videoContainerView.bottomAnchor.constraint(equalTo: controlBarBottom.bottomAnchor, constant: 0)
      controlBarBottom.blendingMode = .withinWindow
      controlBarBottomTopBorder.isHidden = true

      // Align left & right sides with sidebars (top panel will squeeze to make space for sidebars)
      bottomPanelLeadingSpaceConstraint = controlBarBottom.leadingAnchor.constraint(equalTo: leadingSidebarView.trailingAnchor, constant: 0)
      bottomPanelTrailingSpaceConstraint = controlBarBottom.trailingAnchor.constraint(equalTo: trailingSidebarView.leadingAnchor, constant: 0)
    }
    videoContainerBottomConstraint.isActive = true
    bottomPanelLeadingSpaceConstraint.isActive = true
    bottomPanelTrailingSpaceConstraint.isActive = true
  }

  private func updateVideoAspectRatioConstraint(w width: CGFloat, h height: CGFloat) {
    let newMultiplier: CGFloat = height / width
    if let videoAspectRatioConstraint = videoAspectRatioConstraint {
      guard videoAspectRatioConstraint.multiplier != newMultiplier else {
        return
      }
      videoContainerView.removeConstraint(videoAspectRatioConstraint)
    }
    videoAspectRatioConstraint = videoContainerView.heightAnchor.constraint(equalTo: videoContainerView.widthAnchor, multiplier: height / width)
    videoAspectRatioConstraint.isActive = true
    videoContainerView.addConstraint(videoAspectRatioConstraint)
  }

  private func calculateWidthOfTrafficLightButtons() -> CGFloat {
    var maxX: CGFloat = 0
    for buttonType in [NSWindow.ButtonType.closeButton, NSWindow.ButtonType.miniaturizeButton, NSWindow.ButtonType.zoomButton] {
      if let button = window?.standardWindowButton(buttonType) {
        maxX = max(maxX, button.frame.origin.x + button.frame.width)
      }
    }
    return maxX
  }

  private func addVideoViewToWindow() {
    videoContainerView.addSubview(videoView)
    videoView.translatesAutoresizingMaskIntoConstraints = false
    // add constraints
    ([.top, .bottom, .left, .right] as [NSLayoutConstraint.Attribute]).forEach { attr in
      // FIXME: figure out why this 2px adjustment is necessary
      let constantAdustment: CGFloat = attr == .top || attr == .left ? -2 : 0
      videoViewConstraints[attr] = NSLayoutConstraint(item: videoView, attribute: attr, relatedBy: .equal, toItem: videoContainerView,
                                                      attribute: attr, multiplier: 1, constant: constantAdustment)
      videoViewConstraints[attr]!.isActive = true
    }
  }

  private func updatePinToTopButton(fullScreen fullScreenOverride: Bool? = nil) {
    let hasTitleBar = hasTitleBar(fullScreen: fullScreenOverride)
    pinToTopButton.isHidden = !(hasTitleBar && (Preference.bool(for: .alwaysShowOnTopIcon) || isOntop))
    pinToTopButton.state = isOntop ? .on : .off
  }

  private func setupOSCToolbarButtons(_ buttons: [Preference.ToolBarButton]) {
    var buttons = buttons
    if #available(macOS 10.12.2, *) {} else {
      buttons = buttons.filter { $0 != .pip }
    }
    fragToolbarView.views.forEach { fragToolbarView.removeView($0) }
    for buttonType in buttons {
      let button = NSButton()
      OSCToolbarButton.setStyle(of: button, buttonType: buttonType)
      button.action = #selector(self.toolBarButtonAction(_:))
      fragToolbarView.addView(button, in: .trailing)
    }
  }

  private func isTitleBarOSC(fullScreen fullScreenOverride: Bool? = nil) -> Bool {
    let isFullScreen: Bool = fullScreenOverride ?? fsState.isFullscreen
    return !isFullScreen && enableOSC && oscPosition == .top && titleBarStyle == .minimal
  }

  private func hasTitleBar(fullScreen fullScreenOverride: Bool? = nil) -> Bool {
    let isFullScreen: Bool = fullScreenOverride ?? fsState.isFullscreen
    if isFullScreen {
      return false
    }
    if topPanelPlacement == .insideVideo || (topPanelPlacement == .outsideVideo && enableOSC && oscPosition == .top) {
      return titleBarStyle != .none
    }
    return true
  }

  private func setupTitleBarAndOSC(fullScreen fullScreenOverride: Bool? = nil) {
    enableOSC = Preference.bool(for: .enableOSC)
    oscPosition = Preference.enum(for: .oscPosition)
    titleBarStyle = Preference.enum(for: .titleBarStyle)
    topPanelPlacement = Preference.enum(for: .topPanelPlacement)
    bottomPanelPlacement = Preference.enum(for: .bottomPanelPlacement)

    guard let window = window else { return }
    guard let contentView = window.contentView else { return }

    // fullScreenOverride == future full screen state, but should be used in present calculations
    let isFullScreen: Bool = fullScreenOverride ?? fsState.isFullscreen
    let hasTitleBar = hasTitleBar(fullScreen: fullScreenOverride)

    var animationBlocks: [AnimationBlock] = []

    animationBlocks.append{ [self] context in
      /// Set to 0 as default (also makes animation prettier).
      titleBarHeightConstraint.animateToConstant(0)
      topOSCPreferredHeightConstraint.animateToConstant(0)
      bottomOSCPreferredHeightConstraint.animateToConstant(0)

      // Reset view states to defaults
      controlBarFloating.isDragging = false
      hideAndRemoveFromFadeable(controlBarFloating, controlBarBottom, topPanelView, controlBarTitleBar, titleTextField)
      window.titleVisibility = .hidden  // Note: MUST use this to guarantee that documentIcon is shown/hidden consistently
      for button in standardWindowButtons {
        hideAndRemoveFromFadeable(button)
      }
      hideAndRemoveFromFadeable(leadingSidebarToggleButton, trailingSidebarToggleButton)

      // Detach all OSC fragment views
      [oscFloatingTopView, oscTopMainView, oscBottomMainView, oscTitleBarMainView].forEach { stackView in
        stackView!.views.forEach {
          stackView!.removeView($0)
        }
      }
      [fragSliderView, fragControlView, fragToolbarView, fragVolumeView].forEach {
        $0!.removeFromSuperview()
      }

      updateTopPanelPlacement()
      updateBottomPanelPlacement()

      /// NOTE: these assume `trailingSidebarView` is above `leadingSidebarView`
      /// (i.e. comes after it in the list of `contentView`'s subviews in the XIB)
      if topPanelPlacement == .insideVideo {
        // Sidebars cast shadow on top panel
        contentView.addSubview(topPanelView, positioned: .below, relativeTo: leadingSidebarView)
      } else {
        // No shadow (because top panel does not cast a shadow)
        contentView.addSubview(topPanelView, positioned: .above, relativeTo: trailingSidebarView)
      }
      if bottomPanelPlacement == .insideVideo {
        // Sidebars cast shadow on bottom OSC
        contentView.addSubview(controlBarBottom, positioned: .below, relativeTo: leadingSidebarView)
      } else {
        // No shadow (because bottom panel does not cast a shadow)
        contentView.addSubview(controlBarBottom, positioned: .above, relativeTo: trailingSidebarView)
      }

      quickSettingView.refreshVerticalConstraints()
      playlistView.refreshVerticalConstraints()

      // - Title bar:

      if hasTitleBar {
        // Add back title bar accessories (if needed):
        if window.titlebarAccessoryViewControllers.isEmpty {
          window.addTitlebarAccessoryViewController(leadingTitlebarAccesoryViewController)
          window.addTitlebarAccessoryViewController(trailingTitlebarAccesoryViewController)
        }

        titleBarHeightConstraint.animateToConstant(StandardTitleBarHeight)  // May be overridden by OSC layout

        // LeadingSidebar toggle button
        let hasLeadingSidebar = !leadingSidebar.tabGroups.isEmpty
        if hasLeadingSidebar && Preference.bool(for: .showLeadingSidebarToggleButton) {
          show(leadingSidebarToggleButton, makeFadeable: topPanelPlacement == .insideVideo)
        }
        // TrailingSidebar toggle button
        let hasTrailingSidebar = !trailingSidebar.tabGroups.isEmpty
        if hasTrailingSidebar && Preference.bool(for: .showTrailingSidebarToggleButton) {
          show(trailingSidebarToggleButton, makeFadeable: topPanelPlacement == .insideVideo)
        }

      } else {
        // Remove all title bar accessories (if needed):
        for index in (0 ..< window.titlebarAccessoryViewControllers.count).reversed() {
          window.removeTitlebarAccessoryViewController(at: index)
        }
      }

      // "On Top" (mpv) AKA "Pin to Top" (OS)
      updatePinToTopButton(fullScreen: fullScreenOverride)

      updateSpacingForTitleBarAccessories(fullScreen: isFullScreen)

      if isFullScreen {
        for button in trafficLightButtons {
          show(button)
        }

      } else {  // Not fullscreen

        if topPanelPlacement == .insideVideo || (enableOSC && oscPosition == .top) {
          let fadeable = topPanelPlacement == .insideVideo

          switch titleBarStyle {
          case .full:
            window.titleVisibility = .visible
            // Title bar is fadeable
            show(topPanelView, titleTextField, makeFadeable: fadeable)
            for button in standardWindowButtons {
              show(button, makeFadeable: fadeable)
            }

          case .minimal:
            window.titleVisibility = .hidden
            for button in trafficLightButtons {
              show(button, makeFadeable: fadeable)
            }

          case .none:
            window.titleVisibility = .hidden

          }
        } else {  // topPanelPlacement == .outsideVideo and no top OSC

          window.titleVisibility = .visible
          show(topPanelView, titleTextField)
          for button in standardWindowButtons {
            show(button)
          }
        }
      }

      // OSC:
      if enableOSC {
        // add fragment views
        switch oscPosition {
        case .floating:
          currentControlBar = controlBarFloating
          show(controlBarFloating, makeFadeable: true)   // floating is always fadeable

          fragControlView.setVisibilityPriority(.detachOnlyIfNecessary, for: fragControlViewLeftView)
          fragControlView.setVisibilityPriority(.detachOnlyIfNecessary, for: fragControlViewRightView)
          oscFloatingTopView.addView(fragVolumeView, in: .leading)
          oscFloatingTopView.addView(fragToolbarView, in: .trailing)
          oscFloatingTopView.addView(fragControlView, in: .center)

          // Setting the visibility priority to detach only will cause freeze when resizing the window
          // (and triggering the detach) in macOS 11.
          if !isMacOS11 {
            oscFloatingTopView.setVisibilityPriority(.detachOnlyIfNecessary, for: fragVolumeView)
            oscFloatingTopView.setVisibilityPriority(.detachOnlyIfNecessary, for: fragToolbarView)
            oscFloatingTopView.setClippingResistancePriority(.defaultLow, for: .horizontal)
          }
          oscFloatingBottomView.addSubview(fragSliderView)
          Utility.quickConstraints(["H:|[v]|", "V:|[v]|"], ["v": fragSliderView])
          Utility.quickConstraints(["H:|-(>=0)-[v]-(>=0)-|"], ["v": fragControlView])
          // center control bar
          let cph = Preference.float(for: .controlBarPositionHorizontal)
          let cpv = Preference.float(for: .controlBarPositionVertical)
          controlBarFloating.xConstraint.constant = window.frame.width * CGFloat(cph)
          controlBarFloating.yConstraint.constant = window.frame.height * CGFloat(cpv)

          playbackButtonSizeConstraint.constant = playButtonSizeForFloatingOSC
          playbackButtonMarginSizeConstraint.constant = playbackButtonMarginForFloatingOSC

        case .top:
          if !isFullScreen {
            switch titleBarStyle {
            case .full:
              titleBarHeightConstraint.animateToConstant(reducedTitleBarHeight)
            case .minimal:
              titleBarHeightConstraint.animateToConstant(StandardTitleBarHeight)

              // FIXME 3: prevent window drag when dragging playback position & volume sliders when titlebar hidden
              // FIXME 4: fix random disappearing views when toggling OSC top <-> bottom
              // FIXME 5: disable prefs for titlebar buttons when titlebar hidden
              // FIXME 6: find alternatives for SF Symbols sidebar.trailing & sidebar.leading
              // FIXME 7: prevent sidebars from opening if not enough space
            case .none:
              break
            }
          }

          let isTitleBarOSC = isTitleBarOSC(fullScreen: isFullScreen)
          if isTitleBarOSC {
            currentControlBar = controlBarTitleBar
            show(controlBarTitleBar, makeFadeable: topPanelPlacement == .insideVideo)
            // Use top panel to provide a visual effects background. It is otherwise unaffiliated with OSC:
            show(topPanelView, makeFadeable: topPanelPlacement == .insideVideo)

            playbackButtonSizeConstraint.constant = playButtonSizeForTitleBarOSC
            playbackButtonMarginSizeConstraint.constant = playbackButtonMarginForTitleBarOSC

            fragControlView.setVisibilityPriority(.notVisible, for: fragControlViewLeftView)
            fragControlView.setVisibilityPriority(.notVisible, for: fragControlViewRightView)
            oscTitleBarMainView.addView(fragVolumeView, in: .trailing)
            oscTitleBarMainView.addView(fragToolbarView, in: .trailing)
            oscTitleBarMainView.addView(fragControlView, in: .leading)
            oscTitleBarMainView.addView(fragSliderView, in: .leading)
            oscTitleBarMainView.setClippingResistancePriority(.defaultHigh, for: .horizontal)
            oscTitleBarMainView.setVisibilityPriority(.mustHold, for: fragSliderView)
            oscTitleBarMainView.setVisibilityPriority(.detachEarly, for: fragVolumeView)
            oscTitleBarMainView.setVisibilityPriority(.detachEarlier, for: fragToolbarView)

          } else {
            currentControlBar = controlBarTop
            show(topPanelView,   // show for transition animation or if placement == "outside"
                 makeFadeable: isFullScreen || topPanelPlacement == .insideVideo)

            fragControlView.setVisibilityPriority(.notVisible, for: fragControlViewLeftView)
            fragControlView.setVisibilityPriority(.notVisible, for: fragControlViewRightView)
            oscTopMainView.addView(fragVolumeView, in: .trailing)
            oscTopMainView.addView(fragToolbarView, in: .trailing)
            oscTopMainView.addView(fragControlView, in: .leading)
            oscTopMainView.addView(fragSliderView, in: .leading)
            oscTopMainView.setClippingResistancePriority(.defaultLow, for: .horizontal)
            oscTopMainView.setVisibilityPriority(.mustHold, for: fragSliderView)
            oscTopMainView.setVisibilityPriority(.detachEarly, for: fragVolumeView)
            oscTopMainView.setVisibilityPriority(.detachEarlier, for: fragToolbarView)

            playbackButtonSizeConstraint.constant = playButtonSizeForFullOSC
            playbackButtonMarginSizeConstraint.constant = playbackButtonMarginForFullWidthOSC
            topOSCPreferredHeightConstraint.animateToConstant(fullWidthOSCPreferredHeight)
          }

        case .bottom:
          currentControlBar = controlBarBottom
          show(controlBarBottom,   // show for transition animation or if placement == "outside"
               makeFadeable: isFullScreen || bottomPanelPlacement == .insideVideo)

          fragControlView.setVisibilityPriority(.notVisible, for: fragControlViewLeftView)
          fragControlView.setVisibilityPriority(.notVisible, for: fragControlViewRightView)
          oscBottomMainView.addView(fragVolumeView, in: .trailing)
          oscBottomMainView.addView(fragToolbarView, in: .trailing)
          oscBottomMainView.addView(fragControlView, in: .leading)
          oscBottomMainView.addView(fragSliderView, in: .leading)
          oscBottomMainView.setClippingResistancePriority(.defaultLow, for: .horizontal)
          oscBottomMainView.setVisibilityPriority(.mustHold, for: fragSliderView)
          oscBottomMainView.setVisibilityPriority(.detachEarly, for: fragVolumeView)
          oscBottomMainView.setVisibilityPriority(.detachEarlier, for: fragToolbarView)

          playbackButtonSizeConstraint.constant = playButtonSizeForFullOSC
          playbackButtonMarginSizeConstraint.constant = playbackButtonMarginForFullWidthOSC
          bottomOSCPreferredHeightConstraint.animateToConstant(fullWidthOSCPreferredHeight)
        }
      }

      window.contentView?.layoutSubtreeIfNeeded()
    }

    showFadeableViews(completionHandler: {
      UIAnimation.run(animationBlocks)
    })
  }

  private func hideAndRemoveFromFadeable(_ views: NSView?...) {
    for view in views {
      guard let view = view else { continue }
      view.alphaValue = 0
      view.isHidden = true
      fadeableViews.remove(view)
    }
  }

  private func show(_ views: NSView?..., makeFadeable: Bool = false) {
    for view in views {
      guard let view = view else { continue }
      view.alphaValue = 1
      view.isHidden = false
      if makeFadeable {
        fadeableViews.insert(view)
      }
    }
  }

  // MARK: - Mouse / Trackpad events

  @discardableResult
  override func handleKeyBinding(_ keyBinding: KeyMapping) -> Bool {
    let success = super.handleKeyBinding(keyBinding)
    // TODO: replace this with a key binding interceptor
    if success && keyBinding.action.first == MPVCommand.screenshot.rawValue {
      player.sendOSD(.screenshot)
    }
    return success
  }

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
    guard #available(macOS 11, *), animationState == .hidden || animationState == .willHide else { return }
    NSCursor.setHiddenUntilMouseMoves(true)
  }

  override func mouseDown(with event: NSEvent) {
    if Logger.enabled && Logger.Level.preferred >= .verbose {
      Logger.log("MainWindow mouseDown @ \(event.locationInWindow)", level: .verbose, subsystem: player.subsystem)
    }
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

    mousePosRelatedToWindow = nil
    if isDragging {
      // if it's a mouseup after dragging window
      isDragging = false
    } else if finishResizingSidebar() {
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

    if isMouseEvent(event, inAnyOf: [fragSliderView]) && playSlider.isEnabled {
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
      showFadeableViews()
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
    let mousePos = playSlider.convert(event.locationInWindow, from: nil)
    if isMouseInSlider {
      updateTimeLabel(mousePos.x, originalPos: event.locationInWindow)
    }
    if isMouseInWindow {
      showFadeableViews()
    }
    // Check whether mouse is in OSC
    if isMouseEvent(event, inAnyOf: [currentControlBar, titleBarView]) {
      destroyFadeTimer()
    } else {
      resetFadeTimer()
    }
  }

  @objc func handleMagnifyGesture(recognizer: NSMagnificationGestureRecognizer) {
    guard pinchAction != .none else { return }
    guard !isInInteractiveMode, let window = window, let screenFrame = NSScreen.main?.visibleFrame else { return }

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
      if recognizer.state == .began {
        // began
        lastMagnification = recognizer.magnification
      } else if recognizer.state == .changed {
        // changed
        let offset = recognizer.magnification - lastMagnification + 1.0;
        let newWidth = window.frame.width * offset
        let newHeight = newWidth / window.aspectRatio.aspect

        //Check against max & min threshold
        if newHeight < screenFrame.height && newHeight > minSize.height && newWidth > minSize.width {
          Logger.log("Magnifying window to \(recognizer.magnification)x; new size will be: \(Int(newWidth))x\(Int(newHeight))",
                     level: .verbose, subsystem: player.subsystem)
          let newSize = NSSize(width: newWidth, height: newHeight);
          updateVideoAspectRatioConstraint(w: newWidth, h: newHeight)
          window.setFrame(window.frame.centeredResize(to: newSize), display: true)
        }

        lastMagnification = recognizer.magnification
      } else if recognizer.state == .ended {
        updateWindowParametersForMPV()
      }
    }
  }

  // MARK: - Window delegate: Open / Close

  func windowWillOpen() {
    Logger.log("WindowWillOpen", level: .verbose, subsystem: player.subsystem)
    isClosing = false
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
    window!.title = "Window"

    let currentScreen = window!.selectDefaultScreen()
    NSScreen.screens.enumerated().forEach { (screenIndex, screen) in
      let currentString = (screen == currentScreen) ? " (current)" : ""
      NSScreen.log("Screen\(screenIndex)\(currentString)" , screen)
    }

    let useAnimation = !AccessibilityPreferences.motionReductionEnabled
    if shouldApplyInitialWindowSize, let windowFrame = windowFrameFromGeometry(newSize: AppData.sizeWhenNoVideo, screen: currentScreen) {
      Logger.log("WindowWillOpen using initial geometry; setting windowFrame to: \(windowFrame)", level: .verbose, subsystem: player.subsystem)
      window!.setFrame(windowFrame, display: true, animate: useAnimation)
    } else {
      let screenFrame = currentScreen.visibleFrame
      let windowFrame = AppData.sizeWhenNoVideo.centeredRect(in: screenFrame)
      Logger.log("WindowWillOpen centering in screen \(screenFrame); setting windowFrame to: \(windowFrame)", level: .verbose, subsystem: player.subsystem)
      window!.setFrame(screenFrame, display: true, animate: useAnimation)
    }

    videoView.videoLayer.draw(forced: true)
  }

  /** A method being called when window open. Pretend to be a window delegate. */
  override func windowDidOpen() {
    super.windowDidOpen()
    guard let window = self.window, let cv = window.contentView else { return }

    window.makeMain()
    window.makeKeyAndOrderFront(nil)
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
    setupTitleBarAndOSC()
    // update timer
    resetFadeTimer()
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
    Logger.log("windowWillEnterFullScreen", level: .verbose)

    resetViewsForFullScreenTransition()

    // Set the appearance to match the theme so the title bar matches the theme
    let iinaTheme = Preference.enum(for: .themeMaterial) as Preference.Theme
    if #available(macOS 10.14, *) {
      window?.appearance = NSAppearance(iinaTheme: iinaTheme)
    } else {
      switch(iinaTheme) {
      case .dark, .ultraDark: window!.appearance = NSAppearance(named: .vibrantDark)
      default: window!.appearance = NSAppearance(named: .vibrantLight)
      }
    }

    setupTitleBarAndOSC(fullScreen: true)

    setWindowFloatingOnTop(false, updateOnTopStatus: false)

    let isLegacyFullScreen = notification.name == .iinaLegacyFullScreen
    fsState.startAnimatingToFullScreen(legacy: isLegacyFullScreen, priorWindowedFrame: window!.frame)

    videoView.videoLayer.suspend()
    // Let mpv decide the correct render region in full screen
    player.mpv.setFlag(MPVOption.Window.keepaspect, true)
  }

  func window(_ window: NSWindow, startCustomAnimationToEnterFullScreenOn screen: NSScreen, withDuration duration: TimeInterval) {
    Logger.log("window startCustomAnimationToEnterFullScreenOn", level: .verbose)
    UIAnimation.run{ context in
      window.setFrame(screen.frame, display: true)
    }
  }

  func windowDidEnterFullScreen(_ notification: Notification) {
    Logger.log("windowDidEnterFullScreen", level: .verbose)
    fsState.finishAnimating()

    videoViewConstraints.values.forEach { $0.constant = 0 }
    videoView.needsLayout = true
    videoView.layoutSubtreeIfNeeded()
    videoView.videoLayer.resume()

    if Preference.bool(for: .blackOutMonitor) {
      blackOutOtherMonitors()
    }

    if Preference.bool(for: .displayTimeAndBatteryInFullScreen) {
      fadeableViews.insert(additionalInfoView)
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
    
    player.events.emit(.windowFullscreenChanged, data: true)
  }

  func windowWillExitFullScreen(_ notification: Notification) {
    Logger.log("windowWillExitFullScreen", level: .verbose)
    resetViewsForFullScreenTransition()

    additionalInfoView.isHidden = true
    fadeableViews.remove(additionalInfoView)

    fsState.startAnimatingToWindow()

    // If a window is closed while in full screen mode (control-w pressed) AppKit will still call
    // this method. Because windows are tied to player cores and cores are cached and reused some
    // processing must be performed to leave the window in a consistent state for reuse. However
    // the windowWillClose method will have initiated unloading of the file being played. That
    // operation is processed asynchronously by mpv. If the window is being closed due to IINA
    // quitting then mpv could be in the process of shutting down. Must not access mpv while it is
    // asynchronously processing stop and quit commands.
    guard !isClosing else { return }
    videoView.videoLayer.suspend()
    player.mpv.setFlag(MPVOption.Window.keepaspect, false)
  }

  func window(_ window: NSWindow, startCustomAnimationToExitFullScreenWithDuration duration: TimeInterval) {
    Logger.log("window startCustomAnimationToExitFullScreenWithDuration", level: .verbose)
    if NSMenu.menuBarVisible() {
      NSMenu.setMenuBarVisible(false)
    }

    UIAnimation.run{ [self] context in
      window.setFrame(fsState.priorWindowedFrame!, display: true)
      NSMenu.setMenuBarVisible(true)
    }
  }

  func windowDidExitFullScreen(_ notification: Notification) {
    Logger.log("windowDidExitFullScreen", level: .verbose)
    if AccessibilityPreferences.motionReductionEnabled {
      // When animation is not used exiting full screen does not restore the previous size of the
      // window. Restore it now.
      window!.setFrame(fsState.priorWindowedFrame!, display: true, animate: false)
    }
    fsState.finishAnimating()

    if Preference.bool(for: .blackOutMonitor) {
      removeBlackWindows()
    }

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
    // See comments in windowWillExitFullScreen for details.
    guard !isClosing else { return }
    setupTitleBarAndOSC(fullScreen: false)

    videoViewConstraints.values.forEach { $0.constant = 0 }
    videoView.needsLayout = true
    videoView.layoutSubtreeIfNeeded()
    videoView.videoLayer.resume()

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
  }

  func toggleWindowFullScreen() {
    guard let window = self.window else { fatalError("make sure the window exists before animating") }

    switch fsState {
    case .windowed:
      guard !player.isInMiniPlayer else { return }
      if Preference.bool(for: .useLegacyFullScreen) {
        self.legacyAnimateToFullscreen()
      } else {
        window.toggleFullScreen(self)
      }
    case let .fullscreen(legacy, oldFrame):
      if legacy {
        self.legacyAnimateToWindowed(framePriorToBeingInFullscreen: oldFrame)
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

  private func legacyAnimateToWindowed(framePriorToBeingInFullscreen: NSRect) {
    guard let window = self.window else { fatalError("make sure the window exists before animating") }

    // call delegate
    windowWillExitFullScreen(Notification(name: .iinaLegacyFullScreen))
    // stylemask
    window.styleMask.remove(.borderless)
    if #available(macOS 10.16, *) {
      window.styleMask.insert(.titled)
      (window as! MainWindow).forceKeyAndMain = false
      window.level = .normal
    } else {
      window.styleMask.remove(.fullScreen)
    }
 
    restoreDockSettings()
    // restore window frame and aspect ratio
    let videoSize = player.videoSizeForDisplay
    let aspectRatio = NSSize(width: videoSize.0, height: videoSize.1)
    let useAnimation = Preference.bool(for: .legacyFullScreenAnimation)
    if useAnimation {
      // firstly resize to a big frame with same aspect ratio for better visual experience
      let aspectFrame = aspectRatio.shrink(toSize: window.frame.size).centeredRect(in: window.frame)
      updateVideoAspectRatioConstraint(w: aspectFrame.width, h: aspectFrame.height)
      window.setFrame(aspectFrame, display: true, animate: false)
    }
    // then animate to the original frame
    window.setFrame(framePriorToBeingInFullscreen, display: true, animate: useAnimation)
    updateVideoAspectRatioConstraint(w: aspectRatio.width, h: aspectRatio.height)
    window.aspectRatio = aspectRatio
    // call delegate
    windowDidExitFullScreen(Notification(name: .iinaLegacyFullScreen))
  }

  /// Set the window frame and if needed the content view frame to appropriately use the full screen.
  ///
  /// For screens that contain a camera housing the content view will be adjusted to not use that area of the screen.
  private func setWindowFrameForLegacyFullScreen() {
    guard let window = self.window else { return }
    let screen = window.screen ?? NSScreen.main!
    window.setFrame(screen.frame, display: true, animate: !AccessibilityPreferences.motionReductionEnabled)
    guard let unusable = screen.cameraHousingHeight else { return }
    // This screen contains an embedded camera. Shorten the height of the window's content view's
    // frame to avoid having part of the window obscured by the camera housing.
    let view = window.contentView!
    view.setFrameSize(NSMakeSize(view.frame.width, screen.frame.height - unusable))
  }

  private func legacyAnimateToFullscreen() {
    guard let window = self.window else { fatalError("make sure the window exists before animating") }
    // call delegate
    windowWillEnterFullScreen(Notification(name: .iinaLegacyFullScreen))
    // stylemask
    window.styleMask.insert(.borderless)
    if #available(macOS 10.16, *) {
      window.styleMask.remove(.titled)
      (window as! MainWindow).forceKeyAndMain = true
      window.level = .floating
    } else {
      window.styleMask.insert(.fullScreen)
    }
    // cancel aspect ratio
    window.resizeIncrements = NSSize(width: 1, height: 1)
    // auto hide menubar and dock
    NSApp.presentationOptions.insert(.autoHideMenuBar)
    NSApp.presentationOptions.insert(.autoHideDock)
    // set window frame and in some cases content view frame
    setWindowFrameForLegacyFullScreen()
    // call delegate
    windowDidEnterFullScreen(Notification(name: .iinaLegacyFullScreen))
  }

  // MARK: - Window delegate: Size

  func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
    guard let window = window else { return frameSize }
//    Logger.log("WindowWillResize requested with desired size: \(frameSize)", level: .verbose, subsystem: player.subsystem)
    if frameSize.height <= minSize.height || frameSize.width <= minSize.width {
      Logger.log("WindowWillResize: requested size is too small; will change to minimum (\(minSize))", level: .verbose, subsystem: player.subsystem)
      let frameSizeNew = window.aspectRatio.grow(toSize: minSize)
      updateVideoAspectRatioConstraint(w: frameSizeNew.width, h: frameSizeNew.height)
      return frameSizeNew
    }
    updateVideoAspectRatioConstraint(w: frameSize.width, h: frameSize.height)
    return frameSize
  }

  func windowDidResize(_ notification: Notification) {
//    Logger.log("WindowDidResize: \((notification.object as! NSWindow).frame)", level: .verbose, subsystem: player.subsystem)
    guard let window = window else { return }

    UIAnimation.disableAnimation {
      // The `videoView` is not updated during full screen animation (unless using a custom one, however it could be
      // unbearably laggy under current render mechanism). Thus when entering full screen, we should keep `videoView`'s
      // aspect ratio. Otherwise, when entered full screen, there will be an awkward animation that looks like
      // `videoView` "resized" to screen size suddenly when mpv redraws the video content in correct aspect ratio.
      if case let .animating(toFullScreen, _, _) = fsState {
        let aspect: NSSize
        let targetFrame: NSRect
        if toFullScreen {
          aspect = window.aspectRatio == .zero ? window.frame.size : window.aspectRatio
          targetFrame = aspect.shrink(toSize: window.frame.size).centeredRect(in: window.contentView!.frame)
        } else {
          aspect = window.screen?.frame.size ?? NSScreen.main!.frame.size
          targetFrame = aspect.grow(toSize: window.frame.size).centeredRect(in: window.contentView!.frame)
        }

        updateVideoAspectRatioConstraint(w: targetFrame.width, h: targetFrame.height)

        setConstraintsForVideoView([
          .left: targetFrame.minX,
          .right:  targetFrame.maxX - window.frame.width,
          .bottom: -targetFrame.minY,
          .top: window.frame.height - targetFrame.maxY
        ])
      }

      if isInInteractiveMode {
        // interactive mode
        cropSettingsView?.cropBoxView.resized(with: videoView.frame)
      } else if oscPosition == .floating {
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
    guard let window = window, oscPosition == .floating else { return }
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

    // Detach the views in oscFloatingTopView manually on macOS 11 only; as it will cause freeze
    if isMacOS11 {
      guard let maxWidth = [fragVolumeView, fragToolbarView].compactMap({ $0?.frame.width }).max() else {
        return
      }

      // window - 10 - controlBarFloating
      // controlBarFloating - 12 - oscFloatingTopView
      let margin: CGFloat = (10 + 12) * 2
      let hide = (window.frame.width
                  - fragControlView.frame.width
                  - maxWidth*2
                  - margin) < 0

      let views = oscFloatingTopView.views
      if hide {
        if views.contains(fragVolumeView)
            && views.contains(fragToolbarView) {
          oscFloatingTopView.removeView(fragVolumeView)
          oscFloatingTopView.removeView(fragToolbarView)
        }
      } else {
        if !views.contains(fragVolumeView)
            && !views.contains(fragToolbarView) {
          oscFloatingTopView.addView(fragVolumeView, in: .leading)
          oscFloatingTopView.addView(fragToolbarView, in: .trailing)
        }
      }
    }
  }

  // resize framebuffer in videoView after resizing.
  func windowDidEndLiveResize(_ notification: Notification) {
    // Must not access mpv while it is asynchronously processing stop and quit commands.
    // See comments in windowWillExitFullScreen for details.
    guard !isClosing else { return }
    let newSize = window!.convertToBacking(videoView.bounds).size
    let videoSizeStr = videoView.videoSize != nil ? "\(videoView.videoSize!)" : "nil"
    Logger.log("WindowDidEndLiveResize(): videoView.videoSize: \(videoSizeStr) -> backingVideoSize: \(newSize)",
               level: .verbose, subsystem: player.subsystem)
    videoView.videoSize = newSize
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
    }
  }
  
  override func windowDidChangeScreen(_ notification: Notification) {
    super.windowDidChangeScreen(notification)

    player.events.emit(.windowScreenChanged)
  }

  // MARK: - Window delegate: Activeness status
  func windowDidMove(_ notification: Notification) {
    guard let window = window else { return }
    player.events.emit(.windowMoved, data: window.frame)
  }

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

  // MARK: - UI: Show / Hide

  @objc func hideFadeableViewsAndCursor() {
    // don't hide UI when dragging control bar
    if controlBarFloating.isDragging { return }
    hideFadeableViews()
    NSCursor.setHiddenUntilMouseMoves(true)
  }

  private func hideFadeableViews() {
    // Don't hide overlays when in PIP
    guard pipStatus == .notInPIP && animationState == .shown else {
      return
    }

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
    if !player.isInMiniPlayer && !player.needsTouchBar {
      player.invalidateTimer()
    }

    destroyFadeTimer()
    animationState = .willHide

    var animationBlocks: [AnimationBlock] = []

    animationBlocks.append{ [self] context in
      for v in fadeableViews {
        v.animator().alphaValue = 0
      }
    }

    animationBlocks.append{ [self] context in
      // if no interrupt then hide animation
      if animationState == .willHide {
        animationState = .hidden
        for v in fadeableViews {
          v.isHidden = true
        }
      }
    }

    UIAnimation.run(animationBlocks)
  }

  // Shows fadeableViews and titlebar via fade
  private func showFadeableViews(completionHandler: (() -> Void)? = nil) {
    guard !player.disableUI else { return }
    // FIXME: should be able to uncomment this. There is a race condition somewhere
//    guard animationState == .hidden else { return }

    animationState = .willShow
    // The OSC was not updated while it was hidden to avoid wasting energy. Update it now.
    player.syncUITime()
    if !player.info.isPaused {
      player.createSyncUITimer()
    }
    resetFadeTimer()

    var animationBlocks: [AnimationBlock] = []

    animationBlocks.append{ [self] context in
      for v in fadeableViews {
        v.animator().alphaValue = 1
      }
    }

    animationBlocks.append{ [self] context in
      // if no interrupt then hide animation
      if animationState == .willShow {
        animationState = .shown
        for v in fadeableViews {
          v.isHidden = false
        }
      }
    }

    if let completionHandler = completionHandler {
      animationBlocks.append{ _ in
        completionHandler()
      }
    }

    UIAnimation.run(animationBlocks)
  }

  // MARK: - UI: Show / Hide Fadeable Views Timer

  private func resetFadeTimer() {
    // If timer exists, destroy first
    destroyFadeTimer()

    // Create new timer.
    // Timer and animation APIs require Double, but we must support legacy prefs, which store as Float
    var timeout = Double(Preference.float(for: .controlBarAutoHideTimeout))
    if timeout < UIAnimation.UIAnimationDuration {
      timeout = UIAnimation.UIAnimationDuration
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
  }

  func updateSpacingForTitleBarAccessories(fullScreen fullScreenOverride: Bool? = nil) {
    guard let window = window else { return }

    let hasTitleBar = hasTitleBar(fullScreen: fullScreenOverride)
    let leadingSpaceUsed = updateSpacingForLeadingTitleBarAccessory(hasTitleBar: hasTitleBar)
    let trailingSpaceUsed = updateSpacingForTrailingTitleBarAccessory()

    if isTitleBarOSC(fullScreen: fullScreenOverride) {
      // Title bar accessories don't seem to like attaching to other views via constraints.
      // So the next best option is to programmatically update the constraint's constant any time anything changes.
      // Fortunately, this doesn't happen very often and is not a very intensive calculation.
      let availableSpace = max(0, window.frame.width - leadingSpaceUsed - trailingSpaceUsed - 8)
      oscTitleBarWidthConstraint.animateToConstant(availableSpace)
    } else {
      oscTitleBarWidthConstraint.animateToConstant(0)
    }
  }

  // Updates visibility of buttons on the left side of the title bar. Also when the left sidebar is visible,
  // sets the horizontal space needed to push the title bar right, so that it doesn't overlap onto the left sidebar.
  private func updateSpacingForLeadingTitleBarAccessory(hasTitleBar: Bool) -> CGFloat {
    var trailingSpace: CGFloat = 0

    let hasSidebarToggleButton = !leadingSidebarToggleButton.isHidden || fadeableViews.contains(leadingSidebarToggleButton)
    let sidebarButtonSpace: CGFloat = hasSidebarToggleButton ? leadingSidebarToggleButton.frame.width : 0
    let trafficLightsSpace = hasTitleBar ? 0 : trafficLightButtonsWidth

    let isSpaceNeededForSidebar = topPanelPlacement == .insideVideo
      && (leadingSidebar.animationState == .willShow || leadingSidebar.animationState == .shown)
    if isSpaceNeededForSidebar {
      // Subtract space taken by the 3 standard buttons + other visible buttons
      trailingSpace = max(0, leadingSidebarWidthConstraint.constant - trafficLightsSpace - sidebarButtonSpace)
    }
    leadingTitleBarTrailingSpaceConstraint.animateToConstant(trailingSpace)

    let totalSpaceUsed = trailingSpace + sidebarButtonSpace + trafficLightsSpace
    return totalSpaceUsed
  }

  // Updates visibility of buttons on the right side of the title bar. Also when the right sidebar is visible,
  // sets the horizontal space needed to push the title bar left, so that it doesn't overlap onto the right sidebar.
  private func updateSpacingForTrailingTitleBarAccessory() -> CGFloat {
    var leadingSpace: CGFloat = 0
    var spaceForButtons: CGFloat = 0

    if !trailingSidebarToggleButton.isHidden || fadeableViews.contains(trailingSidebarToggleButton) {
      spaceForButtons += trailingSidebarToggleButton.frame.width
    }
    if !pinToTopButton.isHidden || fadeableViews.contains(pinToTopButton) {
      spaceForButtons += pinToTopButton.frame.width
    }

    let isSpaceNeededForSidebar = topPanelPlacement == .insideVideo
      && (trailingSidebar.animationState == .willShow || trailingSidebar.animationState == .shown)
    if isSpaceNeededForSidebar {
      leadingSpace = max(0, trailingSidebarWidthConstraint.constant - spaceForButtons)
    }
    trailingTitleBarLeadingSpaceConstraint.animateToConstant(leadingSpace)

    // Add padding to the side for buttons
    let isAnyButtonVisible = !pinToTopButton.isHidden || !trailingSidebarToggleButton.isHidden
    let buttonMargin: CGFloat = isAnyButtonVisible ? 4 : 0
    trailingTitleBarTrailingSpaceConstraint.animateToConstant(buttonMargin)

    let totalSpaceUsed = leadingSpace + spaceForButtons + buttonMargin
    return totalSpaceUsed
  }

  // MARK: - UI: OSD

  func updateOSDPosition() {
    guard let contentView = window?.contentView else { return }
    contentView.removeConstraint(additionalInfoToOSDSpaceConstraint)
    contentView.removeConstraint(leadingSidebarToOSDSpaceConstraint)
    contentView.removeConstraint(trailingSidebarToOSDSpaceConstraint)
    let osdPosition: Preference.OSDPosition = Preference.enum(for: .osdPosition)
    switch osdPosition {
    case .topLeft:
      // OSD on left, AdditionalInfo on right
      leadingSidebarToOSDSpaceConstraint = leadingSidebarView.trailingAnchor.constraint(equalTo: osdVisualEffectView.leadingAnchor, constant: -8.0)
      trailingSidebarToOSDSpaceConstraint = trailingSidebarView.leadingAnchor.constraint(equalTo: additionalInfoView.trailingAnchor, constant: 8.0)
      additionalInfoToOSDSpaceConstraint = additionalInfoView.leadingAnchor.constraint(greaterThanOrEqualTo: osdVisualEffectView.trailingAnchor, constant: 8.0)
    case .topRight:
      // AdditionalInfo on left, OSD on right
      leadingSidebarToOSDSpaceConstraint = leadingSidebarView.trailingAnchor.constraint(equalTo: additionalInfoView.leadingAnchor, constant: -8.0)
      trailingSidebarToOSDSpaceConstraint = trailingSidebarView.leadingAnchor.constraint(equalTo: osdVisualEffectView.trailingAnchor, constant: 8.0)
      additionalInfoToOSDSpaceConstraint = additionalInfoView.trailingAnchor.constraint(lessThanOrEqualTo: osdVisualEffectView.leadingAnchor, constant: -8.0)
    }

    leadingSidebarToOSDSpaceConstraint.isActive = true
    trailingSidebarToOSDSpaceConstraint.isActive = true
    additionalInfoToOSDSpaceConstraint.isActive = true
    contentView.layoutSubtreeIfNeeded()
  }

  // Do not call displayOSD directly. Call PlayerCore.sendOSD instead.
  func displayOSD(_ message: OSDMessage, autoHide: Bool = true, forcedTimeout: Double? = nil, accessoryView: NSView? = nil, context: Any? = nil) {
    guard player.displayOSD && !isShowingPersistentOSD else { return }

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

    show(osdVisualEffectView)
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

      // FIXME: do not do this here
      // enlarge window if too small
      let winFrame = window!.frame
      var newFrame = winFrame
      if (winFrame.height < 300) {
        newFrame = winFrame.centeredResize(to: winFrame.size.satisfyMinSizeWithSameAspectRatio(NSSize(width: 500, height: 300)))
      }

      accessoryView.wantsLayer = true
      accessoryView.layer?.opacity = 0

      UIAnimation.run(withDuration: UIAnimation.OSDAnimationDuration, { [self] context in
        window!.setFrame(newFrame, display: true)
        osdVisualEffectView.layoutSubtreeIfNeeded()
      }, completionHandler: {
        accessoryView.layer?.opacity = 1
      })
    }

  }

  @objc
  func hideOSD() {
    UIAnimation.run(withDuration: UIAnimation.OSDAnimationDuration, { [self] context in
      self.osdAnimationState = .willHide
      osdVisualEffectView.alphaValue = 0
    }, completionHandler: {
      if self.osdAnimationState == .willHide {
        self.osdAnimationState = .hidden
        self.osdStackView.views(in: .bottom).forEach { self.osdStackView.removeView($0) }
      }
    })
    isShowingPersistentOSD = false
    osdContext = nil
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

  private func setConstraintsForVideoView(_ constraints: [NSLayoutConstraint.Attribute: CGFloat]) {
    for (attr, value) in constraints {
      if let constraint = videoViewConstraints[attr] {
        constraint.animateToConstant(value)
      }
    }
  }

  func enterInteractiveMode(_ mode: InteractiveMode, selectWholeVideoByDefault: Bool = false) {
    // prerequisites
    guard let window = window else { return }

    if #available(macOS 10.14, *) {
      window.backgroundColor = .windowBackgroundColor
    } else {
      window.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 1)
    }

    let (ow, oh) = player.originalVideoSize
    guard ow != 0 && oh != 0 else {
      Utility.showAlert("no_video_track")
      return
    }

    isPausedPriorToInteractiveMode = player.info.isPaused
    player.pause()
    isInInteractiveMode = true
    hideFadeableViews()

    if fsState.isFullscreen {
      let aspect: NSSize
      if window.aspectRatio == .zero {
        let dsize = player.videoSizeForDisplay
        aspect = NSSize(width: dsize.0, height: dsize.1)
      } else {
        aspect = window.aspectRatio
      }
      let frame = aspect.shrink(toSize: window.frame.size).centeredRect(in: window.frame)
      UIAnimation.disableAnimation {
        setConstraintsForVideoView([
          .left: frame.minX,
          .right: window.frame.width - frame.maxX,  // `frame.x` should also work
          .bottom: -frame.minY,
          .top: window.frame.height - frame.maxY  // `frame.y` should also work
        ])
      }
      videoView.needsLayout = true
      videoView.layoutSubtreeIfNeeded()
      // force rerender a frame
      videoView.videoLayer.mpvGLQueue.async {
        DispatchQueue.main.sync {
          self.videoView.videoLayer.draw()
        }
      }
    }

    let controlView = mode.viewController()
    controlView.mainWindow = self
    bottomView.isHidden = false
    bottomView.addSubview(controlView.view)
    Utility.quickConstraints(["H:|[v]|", "V:|[v]|"], ["v": controlView.view])

    let origVideoSize = NSSize(width: ow, height: oh)
    // the max region that the video view can occupy
    let newVideoViewBounds = NSRect(x: 20, y: 20 + 60, width: window.frame.width - 40, height: window.frame.height - 104)
    let newVideoViewSize = origVideoSize.shrink(toSize: newVideoViewBounds.size)
    let newVideoViewFrame = newVideoViewBounds.centeredResize(to: newVideoViewSize)

    let newConstants: [NSLayoutConstraint.Attribute: CGFloat] = [
      .left: newVideoViewFrame.minX,
      .right: newVideoViewFrame.maxX - window.frame.width,
      .bottom: -newVideoViewFrame.minY,
      .top: window.frame.height - newVideoViewFrame.maxY
    ]

    let selectedRect: NSRect = selectWholeVideoByDefault ? NSRect(origin: .zero, size: origVideoSize) : .zero

    // add crop setting view
    window.contentView!.addSubview(controlView.cropBoxView)
    controlView.cropBoxView.selectedRect = selectedRect
    controlView.cropBoxView.actualSize = origVideoSize
    controlView.cropBoxView.resized(with: newVideoViewFrame)
    controlView.cropBoxView.isHidden = true
    Utility.quickConstraints(["H:|[v]|", "V:|[v]|"], ["v": controlView.cropBoxView])

    self.cropSettingsView = controlView

    // show crop settings view
    UIAnimation.run(withDuration: UIAnimation.CropAnimationDuration, { [self] (context) in
      context.timingFunction = CAMediaTimingFunction(name: .easeIn)
      bottomPanelBottomConstraint.animateToConstant(0)
      setConstraintsForVideoView(newConstants)
    }, completionHandler: {
      self.cropSettingsView?.cropBoxView.isHidden = false
      self.videoView.layer?.shadowColor = .black
      self.videoView.layer?.shadowOpacity = 1
      self.videoView.layer?.shadowOffset = .zero
      self.videoView.layer?.shadowRadius = 3
    })
  }

  func exitInteractiveMode(immediately: Bool = false, then: @escaping () -> Void = {}) {
    window?.backgroundColor = .black

    if !isPausedPriorToInteractiveMode {
      player.resume()
    }
    isInInteractiveMode = false
    cropSettingsView?.cropBoxView.isHidden = true

    // if exit without animation
    if immediately {
      bottomPanelBottomConstraint.constant = -InteractiveModeBottomViewHeight
      ([.top, .bottom, .left, .right] as [NSLayoutConstraint.Attribute]).forEach { attr in
        videoViewConstraints[attr]!.constant = 0
      }
      self.cropSettingsView?.cropBoxView.removeFromSuperview()
      self.hideSidebars(animate: false)
      self.bottomView.subviews.removeAll()
      self.bottomView.isHidden = true
      return
    }

    // if with animation
    UIAnimation.run(withDuration: UIAnimation.CropAnimationDuration, { [self] (context) in
      context.timingFunction = CAMediaTimingFunction(name: .easeIn)
      bottomPanelBottomConstraint.animateToConstant(-InteractiveModeBottomViewHeight)
      ([.top, .bottom, .left, .right] as [NSLayoutConstraint.Attribute]).forEach { attr in
        videoViewConstraints[attr]!.animateToConstant(0)
      }
    }, completionHandler: {
      self.cropSettingsView?.cropBoxView.removeFromSuperview()
      self.hideSidebars(animate: false)
      self.bottomView.subviews.removeAll()
      self.bottomView.isHidden = true
      self.showFadeableViews()
      then()
    })
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
    switch oscPosition {
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
    let timeLabelXPos = round(mouseXPos + playSlider.frame.origin.x - timePreviewWhenSeek.frame.width / 2)
    let timeLabelYPos = playSlider.frame.origin.y + playSlider.frame.height
    timePreviewWhenSeek.frame.origin = NSPoint(x: timeLabelXPos, y: timeLabelYPos)
    let sliderFrameInWindow = playSlider.superview!.convert(playSlider.frame.origin, to: nil)
    var percentage = Double((mouseXPos - 3) / (playSlider.frame.width - 6))
    if percentage < 0 {
      percentage = 0
    }

    guard let duration = player.info.videoDuration else { return }
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
  func adjustFrameByVideoSize() {
    guard let window = window else { return }
    Logger.log("AdjustFrameByVideoSize() entered", level: .verbose)

    let (width, height) = player.videoSizeForDisplay
    if width != player.info.displayWidth || height != player.info.displayHeight {
      Logger.log("adjustFrameByVideoSize: videoSizeForDisplay (W: \(width), H: \(height)) does not match PlayerInfo (W: \(player.info.displayWidth!), H: \(player.info.displayHeight!) Rot: \(player.info.userRotation)°)", level: .error)
    }

    // set aspect ratio
    let originalVideoSize = NSSize(width: width, height: height)
    updateVideoAspectRatioConstraint(w: originalVideoSize.width, h: originalVideoSize.height)
    window.aspectRatio = originalVideoSize
    if #available(macOS 10.12, *) {
      pip.aspectRatio = originalVideoSize
    }

    let newSize = window.convertToBacking(videoView.frame).size
    Logger.log("AdjustFrameByVideoSize: videoView.frame: \(videoView.frame) -> backingVideoSize: \(newSize)", level: .verbose)
    videoView.videoSize = newSize

    var rect: NSRect
    let needResizeWindow: Bool

    let frame = fsState.priorWindowedFrame ?? window.frame

    // FIXME: this looks wrong, but what is the actual intent?
    if player.info.justStartedFile {
      // resize option applies
      let resizeTiming = Preference.enum(for: .resizeWindowTiming) as Preference.ResizeWindowTiming
      switch resizeTiming {
      case .always:
        needResizeWindow = true
      case .onlyWhenOpen:
        needResizeWindow = player.info.justOpenedFile
      case .never:
        needResizeWindow = false
      }
    } else {
      // video size changed during playback
      needResizeWindow = true
    }

    Logger.log("From videoSizeForDisplay (\(width)x\(height)), setting frameSize: \(newSize.width)x\(newSize.height); willResizeWindow: \(needResizeWindow)", level: .verbose)

    if needResizeWindow {
      let resizeRatio = (Preference.enum(for: .resizeWindowOption) as Preference.ResizeWindowOption).ratio
      // get videoSize on screen
      var videoSize = originalVideoSize
      let screenRect = window.screen?.visibleFrame

      Logger.log("Starting resizeWindow calculations. OriginalVideoSize: \(videoSize)", level: .verbose)

      if Preference.bool(for: .usePhysicalResolution) {
        videoSize = window.convertFromBacking(
          NSMakeRect(window.frame.origin.x, window.frame.origin.y, CGFloat(width), CGFloat(height))).size
        Logger.log("Converted to physical resolution, result: \(videoSize)", level: .verbose)
      }
      if player.info.justStartedFile {
        if resizeRatio < 0 {
          if let screenSize = screenRect?.size {
            videoSize = videoSize.shrink(toSize: screenSize)
            Logger.log("Shrinking videoSize to fit in screenSize: \(screenSize), result: \(videoSize)", level: .verbose)
          }
        } else {
          videoSize = videoSize.multiply(CGFloat(resizeRatio))
        }
        Logger.log("Applied resizeRatio: (\(resizeRatio)), result: \(videoSize)", level: .verbose)
      }
      // check screen size
      if let screenSize = screenRect?.size {
        videoSize = videoSize.satisfyMaxSizeWithSameAspectRatio(screenSize)
        Logger.log("Constrained max size to screenSize: \(screenSize), result: \(videoSize)", level: .verbose)
      }
      // guard min size
      // must be slightly larger than the min size, or it will crash when the min size is auto saved as window frame size.
      videoSize = videoSize.satisfyMinSizeWithSameAspectRatio(minSize)
      Logger.log("Constrained min size: \(minSize). Final result for videoSize: \(videoSize)", level: .verbose)
      // check if have geometry set (initial window position/size)
      if shouldApplyInitialWindowSize, let wfg = windowFrameFromGeometry(newSize: videoSize) {
        Logger.log("Applied initial window geometry; resulting windowFrame: \(wfg)", level: .verbose)
        rect = wfg
      } else {
        if player.info.justStartedFile, resizeRatio < 0, let screenRect = screenRect {
          rect = screenRect.centeredResize(to: videoSize)
          Logger.log("Did a centered resize using screen rect \(screenRect); resulting windowFrame: \(rect)", level: .verbose)
        } else {
          rect = frame.centeredResize(to: videoSize)
          Logger.log("Did a centered resize using prior frame \(frame); resulting windowFrame: \(rect)", level: .verbose)
        }
      }

    } else {
      // user is navigating in playlist. remain same window width.
      let newHeight = frame.width / CGFloat(width) * CGFloat(height)
      let newSize = NSSize(width: frame.width, height: newHeight).satisfyMinSizeWithSameAspectRatio(minSize)
      rect = NSRect(origin: frame.origin, size: newSize)
      Logger.log("Using same width, with new height (\(newHeight)) \(frame); resulting windowFrame: \(rect)", level: .verbose)
    }

    // maybe not a good position, consider putting these at playback-restart
    player.info.justOpenedFile = false
    player.info.justStartedFile = false
    shouldApplyInitialWindowSize = false

    if fsState.isFullscreen {
      Logger.log("Window is in fullscreen; setting priorWindowedFrame to: \(rect)", level: .verbose)
      fsState.priorWindowedFrame = rect
    } else {
      if let screenFrame = window.screen?.frame {
        rect = rect.constrain(in: screenFrame)
      }
      Logger.log("Updating windowFrame to: \(rect). animate: \(!player.disableWindowAnimation)", level: .verbose)
      if player.disableWindowAnimation {
        window.setFrame(rect, display: true, animate: false)
      } else {
        // animated `setFrame` can be inaccurate!
        window.setFrame(rect, display: true, animate: true)
//        window.setFrame(rect, display: true)
      }
      updateWindowParametersForMPV(withFrame: rect)
    }
    Logger.log("AdjustFrameByVideoSize done; resulting windowFrame: \(rect)", level: .verbose)

    // UI and slider
    updatePlayTime(withDuration: true, andProgressBar: true)
    player.events.emit(.windowSizeAdjusted, data: rect)
  }

  func updateWindowParametersForMPV(withFrame frame: NSRect? = nil) {
    guard let window = self.window else { return }
    if let videoWidth = player.info.videoWidth {
      let windowScale = Double((frame ?? window.frame).width) / Double(videoWidth)
      Logger.log("Updating mpv windowScale to: \(windowScale) (prev: \(player.info.cachedWindowScale))")
      player.info.cachedWindowScale = windowScale
      player.mpv.setDouble(MPVProperty.windowScale, windowScale)
    }
  }

  func setWindowScale(_ scale: Double) {
    guard let window = window, fsState == .windowed else { return }
    let screenFrame = (window.screen ?? NSScreen.main!).visibleFrame
    let (videoWidth, videoHeight) = player.videoSizeForDisplay
    let newFrame: NSRect
    // calculate 1x size
    let useRetinaSize = Preference.bool(for: .usePhysicalResolution)
    let logicalFrame = NSRect(x: window.frame.origin.x,
                             y: window.frame.origin.y,
                             width: CGFloat(videoWidth),
                             height: CGFloat(videoHeight))
    var finalSize = (useRetinaSize ? window.convertFromBacking(logicalFrame) : logicalFrame).size
    // calculate scaled size
    let scalef = CGFloat(scale)
    finalSize.width *= scalef
    finalSize.height *= scalef
    // set size
    if finalSize.width > screenFrame.size.width || finalSize.height > screenFrame.size.height {
      // if final size is bigger than screen
      newFrame = window.frame.centeredResize(to: window.frame.size.shrink(toSize: screenFrame.size)).constrain(in: screenFrame)
    } else {
      // otherwise, resize the window normally
      newFrame = window.frame.centeredResize(to: finalSize.satisfyMinSizeWithSameAspectRatio(minSize)).constrain(in: screenFrame)
    }
    Logger.log("Setting windowScale to: \(scale) -> newFrame: \(newFrame)")
    window.setFrame(newFrame, display: true, animate: true)
  }

  // MARK: - UI: Others

  private func blackOutOtherMonitors() {
    screens = NSScreen.screens.filter { $0 != window?.screen }

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
    // don't know why they will be disabled
//    standardWindowButtons.forEach { $0.isEnabled = true }
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

  func updateArrowButtonImage() {
    if arrowBtnFunction == .playlist {
      leftArrowButton.image = #imageLiteral(resourceName: "nextl")
      rightArrowButton.image = #imageLiteral(resourceName: "nextr")
    } else {
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

  @IBAction func leftButtonAction(_ sender: NSButton) {
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

  @IBAction func rightButtonAction(_ sender: NSButton) {
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

  /** handle action of both left and right arrow button */
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

  @IBAction func togglePinToTop(_ sender: NSButton) {
    setWindowFloatingOnTop(!isOntop)
  }

  @IBAction func toggleLeadingSidebarVisibility(_ sender: NSButton) {
    toggleVisibility(of: leadingSidebar)
  }

  @IBAction func toggleTrailingSidebarVisibility(_ sender: NSButton) {
    toggleVisibility(of: trailingSidebar)
  }

  /** When slider changes */
  @IBAction override func playSliderChanges(_ sender: NSSlider) {
    // guard let event = NSApp.currentEvent else { return }
    guard !player.info.fileLoading else { return }
    super.playSliderChanges(sender)

    // seek and update time
    let percentage = 100 * sender.doubleValue / sender.maxValue
    // label
    timePreviewWhenSeek.frame.origin = CGPoint(
      x: round(sender.knobPointPosition() - timePreviewWhenSeek.frame.width / 2),
      y: playSlider.frame.origin.y + playSlider.frame.height)
    let seekTime = player.info.videoDuration! * percentage * 0.01
    Logger.log("PlaySliderChanged: setting time indicator to: \(seekTime.stringRepresentation)")
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
