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

fileprivate let SettingsWidth: CGFloat = 360
fileprivate let PlaylistMinWidth: CGFloat = 240
fileprivate let PlaylistMaxWidth: CGFloat = 500

fileprivate let InteractiveModeBottomViewHeight: CGFloat = 60

fileprivate let UIAnimationDuration = 0.25
fileprivate let OSDAnimationDuration = 0.5
fileprivate let SidebarAnimationDuration = 0.2
fileprivate let CropAnimationDuration = 0.2

// How close the cursor has to be horizontally to the edge of the sidebar in order to trigger its resize:
fileprivate let sidebarResizeActivationRadius = 4.0

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
  let playbackButtonSize: CGFloat = 24

  /** Scale of spacing around & between playback buttons (for floating OSC):
   (1) 1x margin above and below buttons,
   (2) 2x margin to left and right of button group,
   (3) 4x spacing betwen buttons
   */
  let playbackButtonMarginForFloatingOSC: CGFloat = 4
  /** Scale of spacing around & between playback buttons (for top / bottom OSCs) */
  let playbackButtonMarginForFullWidthOSC: CGFloat = 6

  /** Adjust vertical offset of sidebars so that when a sidebar is open while "top" OSC is shown,
   the horizontal line under the sidebar tab buttons aligns with bottom of the OSC. */
  lazy var sidebarSeparatorOffsetFromTop: CGFloat = fullWidthOSCPreferredHeight + reducedTitleBarHeight

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
  var hideControlTimer: Timer?
  var hideOSDTimer: Timer?

  /** For blacking out other screens. */
  var screens: [NSScreen] = []
  var cachedScreenCount = 0
  var blackWindows: [NSWindow] = []

  // Current rotation of videoView
  private var cgCurrentRotationDegrees: CGFloat = 0

  // MARK: - Status

  override var isOntop: Bool {
    didSet {
      updateOnTopIcon()
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
  private var isResizingLeftSidebar: Bool = false
  private var isResizingRightSidebar: Bool = false

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
  var fadeableViews: [NSView] = []

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

  // Sidebar

  /** Type of the view embedded in sidebar. */
  enum SidebarTabGroup: String {
    case settings
    case playlist

    func width() -> CGFloat {
      switch self {
      case .settings:
        return SettingsWidth
      case .playlist:
        return CGFloat(Preference.integer(for: .playlistWidth)).clamped(to: PlaylistMinWidth...PlaylistMaxWidth)
      }
    }
  }

  enum SidebarTab: Equatable {
    case playlist
    case chapters

    case video
    case audio
    case sub
    case plugin(id: String)

    var group: SidebarTabGroup {
      switch self {
        case .playlist, .chapters:
          return .playlist
        case .video, .audio, .sub, .plugin(id: _):
          return .settings
      }
    }

    init?(name: String) {
      switch name {
        case "playlist":
          self = .playlist
        case "chapters":
          self = .chapters
        case "video":
          self = .video
        case "audio":
          self = .audio
        case "sub":
          self = .sub
        default:
          if name.hasPrefix("plugin:") {
            self = .plugin(id: String(name.dropFirst(7)))
          } else {
            return nil
          }
      }
    }

    var name: String {
      switch self {
        case .playlist: return "playlist"
        case .chapters: return "chapters"
        case .video: return "video"
        case .audio: return "audio"
        case .sub: return "sub"
        case .plugin(let id): return "plugin:\(id)"
      }
    }
  }

  private class Sidebar {
    let id: Preference.SidebarID

    init(_ id: Preference.SidebarID) {
      self.id = id
    }

    // user configured:
    var layoutStyle: Preference.SidebarLayoutStyle = Preference.SidebarLayoutStyle.defaultValue
    var tabGroups: Set<SidebarTabGroup> = Set()

    // state:

    var animationState: UIAnimationState = .hidden

    // nil means none/hidden:
    var visibleTab: SidebarTab? = nil

    var visibleTabGroup: SidebarTabGroup? {
      return visibleTab?.group
    }

    var isVisible: Bool {
      return visibleTab != nil
    }
  }

  private var leftSidebar = Sidebar(.left)
  private var rightSidebar = Sidebar(.right)
  private lazy var sidebarsByID: [Preference.SidebarID: Sidebar] = [ .left: self.leftSidebar, .right: self.rightSidebar]

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
  private lazy var titleBarLayout: Preference.TitleBarLayout = Preference.enum(for: .titleBarLayout)
  private lazy var enableOSC: Bool = Preference.bool(for: .enableOSC)
  private lazy var oscPosition: Preference.OSCPosition = Preference.enum(for: .oscPosition)
  private lazy var arrowBtnFunction: Preference.ArrowButtonAction = Preference.enum(for: .arrowButtonAction)
  private lazy var pinchAction: Preference.PinchAction = Preference.enum(for: .pinchAction)
  private lazy var rotateAction: Preference.RotateAction = Preference.enum(for: .rotateAction)
  lazy var displayTimeAndBatteryInFullScreen: Bool = Preference.bool(for: .displayTimeAndBatteryInFullScreen)

  private static let mainWindowPrefKeys: [Preference.Key] = PlayerWindowController.playerWindowPrefKeys + [
    .titleBarLayout,
    .enableOSC,
    .oscPosition,
    .enableThumbnailPreview,
    .enableThumbnailForRemoteFiles,
    .thumbnailLength,
    .showChapterPos,
    .arrowButtonAction,
    .pinchAction,
    .rotateAction,
    .blackOutMonitor,
    .useLegacyFullScreen,
    .displayTimeAndBatteryInFullScreen,
    .controlBarToolbarButtons,
    .alwaysShowOnTopIcon,
    .leftSidebarLayoutStyle,
    .rightSidebarLayoutStyle,
    .settingsParentSidebarID,
    .playlistParentSidebarID,
  ]

  override var observedPrefKeys: [Preference.Key] {
    MainWindowController.mainWindowPrefKeys
  }

  override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
    guard let keyPath = keyPath, let change = change else { return }
    super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)

    switch keyPath {
    case PK.enableOSC.rawValue, PK.oscPosition.rawValue, PK.titleBarLayout.rawValue:
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
    case PK.rotateAction.rawValue:
      if let newValue = change[.newKey] as? Int {
        rotateAction = Preference.RotateAction(rawValue: newValue)!
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
      updateOnTopIcon()
    case PK.leftSidebarLayoutStyle.rawValue:
      // TODO
      break
    case PK.rightSidebarLayoutStyle.rawValue:
      // TODO
      break
    case PK.settingsParentSidebarID.rawValue:
      if let newRawValue = change[.newKey] as? Int, let newID = Preference.SidebarID(rawValue: newRawValue) {
        self.moveSidebarIfNeeded(forTabGroup: .settings, toNewSidebarID: newID)
      }
    case PK.playlistParentSidebarID.rawValue:
      if let newRawValue = change[.newKey] as? Int, let newID = Preference.SidebarID(rawValue: newRawValue) {
        self.moveSidebarIfNeeded(forTabGroup: .playlist, toNewSidebarID: newID)
      }
    default:
      return
    }
  }

  // MARK: - Outlets

  var standardWindowButtons: [NSButton] {
    get {
      return ([.closeButton, .miniaturizeButton, .zoomButton, .documentIconButton] as [NSWindow.ButtonType]).compactMap {
        window?.standardWindowButton($0)
      }
    }
  }

  var trafficLightButtonsWidth: CGFloat = 0.0

  /** Get the `NSTextField` of widow's title. */
  var titleTextField: NSTextField? {
    get {
      return window?.standardWindowButton(.closeButton)?.superview?.subviews.compactMap({ $0 as? NSTextField }).first
    }
  }

  var leftTitlebarAccesoryViewController: NSTitlebarAccessoryViewController!
  var rightTitlebarAccesoryViewController: NSTitlebarAccessoryViewController!
  @IBOutlet var leftTitleBarAccessoryView: NSView!
  @IBOutlet var rightTitleBarAccessoryView: NSView!

  /** Current OSC view. May be top, bottom, or floating depneding on user pref. */
  var currentControlBar: NSView?

  @IBOutlet weak var leftTitleBarLeadingSpaceConstraint: NSLayoutConstraint!
  @IBOutlet weak var rightTitleBarTrailingSpaceConstraint: NSLayoutConstraint!
  @IBOutlet weak var videoAspectRatioConstraint: NSLayoutConstraint!

  @IBOutlet weak var leftSidebarLeadingConstraint: NSLayoutConstraint!
  @IBOutlet weak var rightSidebarTrailingConstraint: NSLayoutConstraint!
  @IBOutlet weak var leftSidebarWidthConstraint: NSLayoutConstraint!
  @IBOutlet weak var rightSidebarWidthConstraint: NSLayoutConstraint!
  @IBOutlet weak var bottomBarBottomConstraint: NSLayoutConstraint!
  // Sets the size of the spacer view in the top overlay which reserves space for a title bar:
  @IBOutlet weak var titleBarOverlayHeightConstraint: NSLayoutConstraint!
  // Size of each side of the square 3 playback buttons ⏪⏯️⏩ (Left Arrow, Play/Pause, Right Arrow):
  @IBOutlet weak var playbackButtonSizeConstraint: NSLayoutConstraint!
  @IBOutlet weak var playbackButtonMarginSizeConstraint: NSLayoutConstraint!
  @IBOutlet weak var topOSCPreferredHeightConstraint: NSLayoutConstraint!
  @IBOutlet weak var bottomOSCPreferredHeightConstraint: NSLayoutConstraint!

  /** Top-of-video overlay, may contain `titleBarOverlayView` and/or top OSC if configured. */
  @IBOutlet weak var topOverlayView: NSVisualEffectView!
  /** Border below `titleBarOverlayView`, or top OSC if configured. */
  @IBOutlet weak var topOverlayBottomBorder: NSBox!
  /** Reserves space for the title bar components. Does not contain any child views. */
  @IBOutlet weak var titleBarOverlayView: NSView!
  /** "Pin to Top" button in titlebar, if configured to  be shown */
  @IBOutlet weak var pinToTopButton: NSButton!

  @IBOutlet weak var controlBarTop: NSView!
  @IBOutlet weak var controlBarFloating: ControlBarView!
  @IBOutlet weak var controlBarBottom: NSVisualEffectView!
  @IBOutlet weak var timePreviewWhenSeek: NSTextField!
  @IBOutlet weak var leftArrowButton: NSButton!
  @IBOutlet weak var rightArrowButton: NSButton!
  @IBOutlet weak var settingsButton: NSButton!
  @IBOutlet weak var playlistButton: NSButton!
  @IBOutlet weak var leftSidebarView: NSVisualEffectView!
  @IBOutlet weak var rightSidebarView: NSVisualEffectView!
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

  override var mouseActionDisabledViews: [NSView?] {[leftSidebarView, rightSidebarView, currentControlBar, titleBarOverlayView, oscTopMainView, subPopoverView]}

  // MARK: - PIP

  lazy var _pip: PIPViewController = {
    let pip = PIPViewController()
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

    leftSidebar.layoutStyle = Preference.enum(for: .leftSidebarLayoutStyle)
    rightSidebar.layoutStyle = Preference.enum(for: .rightSidebarLayoutStyle)

    let settingsSidebarID: Preference.SidebarID = Preference.enum(for: .settingsParentSidebarID)
    setSidebar(id: settingsSidebarID, forTabGroup: .settings)

    let playlistSidebarID: Preference.SidebarID = Preference.enum(for: .playlistParentSidebarID)
    setSidebar(id: playlistSidebarID, forTabGroup: .playlist)
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
    topOverlayView.layerContentsRedrawPolicy = .onSetNeedsDisplay

    // Titlebar accessories

    trafficLightButtonsWidth = calculateWidthOfTrafficLightButtons()

    leftTitlebarAccesoryViewController = NSTitlebarAccessoryViewController()
    leftTitlebarAccesoryViewController.view = leftTitleBarAccessoryView
    leftTitlebarAccesoryViewController.layoutAttribute = .left
    window.addTitlebarAccessoryViewController(leftTitlebarAccesoryViewController)
    leftTitleBarAccessoryView.translatesAutoresizingMaskIntoConstraints = false

    rightTitlebarAccesoryViewController = NSTitlebarAccessoryViewController()
    rightTitlebarAccesoryViewController.view = rightTitleBarAccessoryView
    rightTitlebarAccesoryViewController.layoutAttribute = .right
    window.addTitlebarAccessoryViewController(rightTitlebarAccesoryViewController)
    rightTitleBarAccessoryView.translatesAutoresizingMaskIntoConstraints = false
    let buttonSizeConstraint = pinToTopButton.heightAnchor.constraint(equalToConstant: StandardTitleBarHeight)
    buttonSizeConstraint.isActive = true
    pinToTopButton.addConstraint(buttonSizeConstraint)
    updateOnTopIcon()

    // FIXME: do not do this here
    // size
    window.minSize = minSize
    if let wf = windowFrameFromGeometry() {
      window.setFrame(wf, display: false)
    }

    updateVideoAspectRatioConstraint(w: AppData.sizeWhenNoVideo.width, h: AppData.sizeWhenNoVideo.height)
    window.aspectRatio = AppData.sizeWhenNoVideo

    // sidebar views
    leftSidebarView.isHidden = true
    rightSidebarView.isHidden = true

    // osc views
    fragControlView.addView(fragControlViewLeftView, in: .center)
    fragControlView.addView(fragControlViewMiddleView, in: .center)
    fragControlView.addView(fragControlViewRightView, in: .center)

    updateArrowButtonImage()

    // fade-able views
    fadeableViews.append(contentsOf: standardWindowButtons as [NSView])
    fadeableViews.append(topOverlayView)
    fadeableViews.append(rightTitleBarAccessoryView)

    playbackButtonSizeConstraint.constant = playbackButtonSize

    setupTitleBarAndOSC()
    let buttons = (Preference.array(for: .controlBarToolbarButtons) as? [Int] ?? []).compactMap(Preference.ToolBarButton.init(rawValue:))
    setupOSCToolbarButtons(buttons)

    // video view
    guard let cv = window.contentView else { return }
    cv.autoresizesSubviews = false
    addVideoViewToWindow()
    window.setIsVisible(true)

    // gesture recognizer
    cv.addGestureRecognizer(magnificationGestureRecognizer)
    cv.addGestureRecognizer(NSRotationGestureRecognizer(target: self, action: #selector(MainWindowController.handleRotationGesture(recognizer:))))

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

    // init quick setting view now
    let _ = quickSettingView

    // buffer indicator view
    bufferIndicatorView.roundCorners(withRadius: 10)
    updateBufferIndicatorView()

    // thumbnail peek view
    thumbnailPeekView.isHidden = true

    // other initialization
    osdAccessoryProgress.usesThreadedAnimation = false
    if #available(macOS 10.14, *) {
      topOverlayBottomBorder.fillColor = NSColor(named: .titleBarBorder)!
    }
    cachedScreenCount = NSScreen.screens.count
    // Do not make visual effects views opaque when window is not in focus
    for view in [topOverlayView, osdVisualEffectView, controlBarBottom, controlBarFloating,
                 leftSidebarView, rightSidebarView, osdVisualEffectView, pipOverlayView, bufferIndicatorView] {
      view?.state = .active
    }
    // hide other views
    osdVisualEffectView.isHidden = true
    osdVisualEffectView.roundCorners(withRadius: 10)
    additionalInfoView.roundCorners(withRadius: 10)
    leftArrowLabel.isHidden = true
    rightArrowLabel.isHidden = true
    timePreviewWhenSeek.isHidden = true
    bottomView.isHidden = true
    pipOverlayView.isHidden = true
    
    if player.disableUI { hideUI() }

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

  private func updateVideoAspectRatioConstraint(w width: CGFloat, h height: CGFloat) {
    videoContainerView.removeConstraint(videoAspectRatioConstraint)
    videoAspectRatioConstraint = videoContainerView.heightAnchor.constraint(equalTo: videoContainerView.widthAnchor, multiplier: height / width)
    videoAspectRatioConstraint.isActive = true
    videoContainerView.addConstraint(videoAspectRatioConstraint)
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

    for view in [topOverlayView, controlBarFloating, controlBarBottom,
                 osdVisualEffectView, pipOverlayView, additionalInfoView, bufferIndicatorView] {
      view?.material = material
      view?.appearance = appearance
    }

    for sidebar in [leftSidebarView, rightSidebarView] {
      sidebar?.material = .dark
      sidebar?.appearance = NSAppearance(named: .vibrantDark)
    }

    window.appearance = appearance
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
    guard let cv = window?.contentView else { return }
    videoContainerView.addSubview(videoView, positioned: .above, relativeTo: nil)
    videoView.translatesAutoresizingMaskIntoConstraints = false
    // add constraints
    ([.top, .bottom, .left, .right] as [NSLayoutConstraint.Attribute]).forEach { attr in
      videoViewConstraints[attr] = NSLayoutConstraint(item: videoView, attribute: attr, relatedBy: .equal, toItem: cv, attribute: attr, multiplier: 1, constant: 0)
      videoViewConstraints[attr]!.isActive = true
    }
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

  private func setupTitleBarAndOSC() {
    let oscPositionNew: Preference.OSCPosition = Preference.enum(for: .oscPosition)
//    let oscEnabledNew = Preference.bool(for: .enableOSC)
//    let titleBarLayoutNew: Preference.TitleBarLayout = Preference.enum(for: .titleBarLayout)

    let isSwitchingToTop = oscPositionNew == .insideTop
    let isSwitchingFromTop = oscPosition == .insideTop
    let isFloating = oscPositionNew == .floating

    if let cb = currentControlBar {
      // remove current osc view from fadeable views
      fadeableViews = fadeableViews.filter { $0 != cb }
    }

    // reset
    ([controlBarFloating, controlBarBottom, controlBarTop] as [NSView]).forEach { $0.isHidden = true }

    controlBarFloating.isDragging = false

    // detach all fragment views
    [oscFloatingTopView, oscTopMainView, oscBottomMainView].forEach { stackView in
      stackView!.views.forEach {
        stackView!.removeView($0)
      }
    }
    [fragSliderView, fragControlView, fragToolbarView, fragVolumeView].forEach {
        $0!.removeFromSuperview()
    }

    let isInFullScreen = fsState.isFullscreen

    if isSwitchingToTop {
      topOSCPreferredHeightConstraint.constant = fullWidthOSCPreferredHeight
      bottomOSCPreferredHeightConstraint.constant = 0
      if isInFullScreen {
        topOverlayView.isHidden = false
        addBackTopOverlayViewToFadeableViews()
        titleBarOverlayHeightConstraint.constant = 0
      } else {
        titleBarOverlayHeightConstraint.constant = reducedTitleBarHeight
      }
    } else {
      titleBarOverlayHeightConstraint.constant = StandardTitleBarHeight
      topOSCPreferredHeightConstraint.constant = 0
      bottomOSCPreferredHeightConstraint.constant = fullWidthOSCPreferredHeight
    }

    if isSwitchingFromTop {
      if isInFullScreen {
        topOverlayView.isHidden = true
        removeTopOverlayViewFromFadeableViews()
      }
    }

    oscPosition = oscPositionNew

    // add fragment views
    switch oscPositionNew {
    case .floating:
      currentControlBar = controlBarFloating
      fadeableViews.append(controlBarFloating)
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
      controlBarFloating.xConstraint.constant = window!.frame.width * CGFloat(cph)
      controlBarFloating.yConstraint.constant = window!.frame.height * CGFloat(cpv)
    case .insideTop:
      currentControlBar = controlBarTop
      controlBarTop.isHidden = false
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
    case .insideBottom:
      currentControlBar = controlBarBottom
      fadeableViews.append(controlBarBottom)
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
      case .outsideBottom:
        // TODO!
        break
    }

    showUI()

    if isFloating {
      playbackButtonMarginSizeConstraint.constant = playbackButtonMarginForFloatingOSC
      oscFloatingLeadingTrailingConstraint = NSLayoutConstraint.constraints(withVisualFormat: "H:|-(>=10)-[v]-(>=10)-|",
                                                                            options: [], metrics: nil, views: ["v": controlBarFloating as Any])
      NSLayoutConstraint.activate(oscFloatingLeadingTrailingConstraint!)
    } else {
      playbackButtonMarginSizeConstraint.constant = playbackButtonMarginForFullWidthOSC
      if let constraints = oscFloatingLeadingTrailingConstraint {
        controlBarFloating.superview?.removeConstraints(constraints)
        oscFloatingLeadingTrailingConstraint = nil
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
    if Logger.isEnabled(.verbose) {
      Logger.log("MainWindow mouseDown \(event.locationInWindow)", level: .verbose, subsystem: player.subsystem)
    }
    workaroundCursorDefect()
    // do nothing if it's related to floating OSC
    guard !controlBarFloating.isDragging else { return }
    // record current mouse pos
    mousePosRelatedToWindow = event.locationInWindow
    // playlist resizing
    if leftSidebar.visibleTab == .playlist {
      let sf = leftSidebarView.frame
      let dragRectCenterX: CGFloat
      switch leftSidebar.layoutStyle {
        case .insideVideo:
          dragRectCenterX = sf.origin.x + sf.width
        case .outsideVideo:
          dragRectCenterX = sf.origin.x
      }

      let activationRect = NSMakeRect(dragRectCenterX - sidebarResizeActivationRadius, sf.origin.y, 2 * sidebarResizeActivationRadius, sf.height)
      if NSPointInRect(mousePosRelatedToWindow!, activationRect) {
        Logger.log("User started resize of left sidebar", level: .verbose)
        isResizingLeftSidebar = true
      }
    } else if rightSidebar.visibleTab == .playlist {
      let sf = rightSidebarView.frame
      let dragRectCenterX: CGFloat
      switch leftSidebar.layoutStyle {
        case .insideVideo:
          dragRectCenterX = sf.origin.x
        case .outsideVideo:
          dragRectCenterX = sf.origin.x + sf.width
      }

      let activationRect = NSMakeRect(dragRectCenterX - sidebarResizeActivationRadius, sf.origin.y, 2 * sidebarResizeActivationRadius, sf.height)
      if NSPointInRect(mousePosRelatedToWindow!, activationRect) {
        Logger.log("User started resize of right sidebar", level: .verbose)
        isResizingRightSidebar = true
      }
    }
  }

  override func mouseDragged(with event: NSEvent) {
    if isResizingLeftSidebar {
      let currentLocation = event.locationInWindow
      let newWidth: CGFloat
      switch leftSidebar.layoutStyle {
        case .insideVideo:
          newWidth = currentLocation.x + 2
        case .outsideVideo:
          newWidth = leftSidebarView.frame.width + currentLocation.x + 2
      }
      let newPlaylistWidth = newWidth.clamped(to: PlaylistMinWidth...PlaylistMaxWidth)
      leftSidebarWidthConstraint.constant = newPlaylistWidth
      updateLeftTitleBarLeadingSpace(toWidth: newPlaylistWidth)
    } else if isResizingRightSidebar {
      let currentLocation = event.locationInWindow
      // resize sidebar
      let newWidth: CGFloat
      switch rightSidebar.layoutStyle {
        case .insideVideo:
          newWidth = window!.frame.width - currentLocation.x - 2
        case .outsideVideo:
          newWidth = window!.frame.width - currentLocation.x + rightSidebarView.frame.width - 2
      }
      let newPlaylistWidth = newWidth.clamped(to: PlaylistMinWidth...PlaylistMaxWidth)
      rightSidebarWidthConstraint.constant = newPlaylistWidth
      updateRightTitleBarTrailingSpace(toWidth: newPlaylistWidth)
    } else if !fsState.isFullscreen {
      guard !controlBarFloating.isDragging else { return }

      if let mousePosRelatedToWindow = mousePosRelatedToWindow {
        if !isDragging {
          // Require that the user must drag the cursor at least a small distance for it to start a "drag" (`isDragging==true`)
          // The user's action will only be counted as a click if `isDragging==false` when `mouseUp` is called.
          // (Apple's trackpad in particular is very sensitive and tends to call `mouseDragged()` if there is even the slightest
          // roll of the finger during a click, and the distance of the "drag" may be less than 1 pixel)
          if mousePosRelatedToWindow.isWithinRadius(radius: Constants.Distance.mainWindowMinInitialDragThreshold,
                                                    ofPoint: event.locationInWindow) {
            return
          }
          if Logger.enabled && Logger.Level.preferred >= .verbose {
            Logger.log("MainWindow mouseDrag: minimum dragging distance was met!", level: .verbose, subsystem: player.subsystem)
          }
          isDragging = true
        }
        if isDragging {
          window?.performDrag(with: event)
        }
      }
    }
  }

  override func mouseUp(with event: NSEvent) {
    if Logger.isEnabled(.verbose) {
      Logger.log("MainWindow mouseUp. isDragging: \(isDragging), isResizingRightSidebar: \(isResizingRightSidebar), clickCount: \(event.clickCount)",
                 level: .verbose, subsystem: player.subsystem)
    }

    workaroundCursorDefect()
    mousePosRelatedToWindow = nil
    if isDragging {
      // if it's a mouseup after dragging window
      isDragging = false
    } else if isResizingLeftSidebar {
      // if it's a mouseup after resizing sidebar
      isResizingLeftSidebar = false
      Logger.log("New width of left sidebar playlist is \(leftSidebarWidthConstraint.constant)", level: .verbose)
      Preference.set(Int(leftSidebarWidthConstraint.constant), for: .playlistWidth)
    } else if isResizingRightSidebar {
      // if it's a mouseup after resizing sidebar
      isResizingRightSidebar = false
      Logger.log("New width of right sidebar playlist is \(rightSidebarWidthConstraint.constant)", level: .verbose)
      Preference.set(Int(rightSidebarWidthConstraint.constant), for: .playlistWidth)
    } else {
      // if it's a mouseup after clicking

      // Single click. Note that `event.clickCount` will be 0 if there is at least one call to `mouseDragged()`,
      // but we will only count it as a drag if `isDragging==true`
      if event.clickCount <= 1 && !isMouseEvent(event, inAnyOf: [leftSidebarView, rightSidebarView, subPopoverView]) {
        hideSidebars()
        return
      }

      if event.clickCount == 2 && isMouseEvent(event, inAnyOf: [titleBarOverlayView]) {
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
      hideUI()
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
    guard !isMouseEvent(event, inAnyOf: [leftSidebarView, rightSidebarView, titleBarOverlayView, subPopoverView]) else { return }

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
      showUI()
      updateTimer()
    } else if obj == 1 {
      // slider
      if controlBarFloating.isDragging { return }
      isMouseInSlider = true
      if !controlBarFloating.isDragging {
        timePreviewWhenSeek.isHidden = false
        thumbnailPeekView.isHidden = !player.info.thumbnailsReady
      }
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
      destroyTimer()
      hideUI()
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
      showUI()
    }
    // check whether mouse is in osc
    if isMouseEvent(event, inAnyOf: [currentControlBar, titleBarOverlayView]) {
      destroyTimer()
    } else {
      updateTimer()
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

  private func degToRad(_ degrees: CGFloat) -> CGFloat {
    return degrees * CGFloat.pi / 180
  }

  // Returns the total degrees in the given rotation which are due to complete 360° rotations
  private func completeCircleDegrees(of rotationDegrees: CGFloat) -> CGFloat{
    CGFloat(Int(rotationDegrees / 360) * 360)
  }

  // Reduces the given rotation to one which is a positive number between 0 and 360 degrees and has the same resulting orientation.
  private func normalizeRotation(_ rotationDegrees: Int) -> Int {
    // Take out all full rotations so we end up with number between -360 and 360
    let simplifiedRotation = rotationDegrees %% 360
    // Remove direction and return a number from 0..<360
    return simplifiedRotation < 0 ? simplifiedRotation + 360 : simplifiedRotation
  }

  // Find which 90° rotation the given rotation is closest to (within 45° of it).
  private func findClosestQuarterRotation(_ mpvNormalizedRotationDegrees: Int) -> Int {
    assert(mpvNormalizedRotationDegrees >= 0 && mpvNormalizedRotationDegrees < 360)
    for quarterCircleRotation in AppData.rotations {
      if mpvNormalizedRotationDegrees < quarterCircleRotation + 45 {
        return quarterCircleRotation
      }
    }
    return AppData.rotations[0]
  }

  // Side effect: sets `cgCurrentRotationDegrees` to `toDegrees` before returning
  func rotateVideoView(toDegrees: CGFloat, animate: Bool = true) {
    let fromDegrees = cgCurrentRotationDegrees
    let toRadians = degToRad(toDegrees)

    // Animation is enabled by default for this view.
    // We only want to animate some rotations and not others, and never want to animate
    // position change. So put these in an explicitly disabled transaction block:
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    // Rotate about center point. Also need to change position because.
    let centerPoint = CGPointMake(NSMidX(videoView.frame), NSMidY(videoView.frame))
    videoView.layer?.position = centerPoint
    videoView.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
    CATransaction.commit()

    if animate {
      Logger.log("Animating rotation from \(fromDegrees)° to \(toDegrees)°")

      CATransaction.begin()
      // This will show an animation but doesn't change its permanent state.
      // Still need the rotation call down below to do that.
      let rotateAnimation = CABasicAnimation(keyPath: "transform")
      rotateAnimation.valueFunction = CAValueFunction(name: .rotateZ)
      rotateAnimation.fromValue = degToRad(fromDegrees)
      rotateAnimation.toValue = toRadians
      rotateAnimation.duration = 0.2
      videoView.layer?.add(rotateAnimation, forKey: "transform")
      CATransaction.commit()
    }

    // This block updates the view's permanent position, but won't animate.
    // Need to call this even if running the animation above, or else layer will revert to its prev appearance after
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    videoView.layer?.transform = CATransform3DMakeRotation(toRadians, 0, 0, 1)
    CATransaction.commit()

    cgCurrentRotationDegrees = toDegrees
  }

  private func findNearestCGQuarterRotation(forCGRotation cgRotationInDegrees: CGFloat, equalToMpvRotation mpvQuarterRotation: Int) -> CGFloat {
    let cgCompleteCirclesTotalDegrees = completeCircleDegrees(of: cgRotationInDegrees)
    let cgClosestQuarterRotation = CGFloat(normalizeRotation(-mpvQuarterRotation))
    let cgLessThanWholeRotation = cgRotationInDegrees - cgCompleteCirclesTotalDegrees
    let cgSnapToDegrees: CGFloat
    if cgLessThanWholeRotation > 0 {
      // positive direction:
      cgSnapToDegrees = cgCompleteCirclesTotalDegrees + cgClosestQuarterRotation
    } else {
      // negative direction:
      cgSnapToDegrees = cgCompleteCirclesTotalDegrees + (cgClosestQuarterRotation - 360)
    }
    Logger.log("mpvQuarterRotation: \(mpvQuarterRotation) cgCompleteCirclesTotalDegrees: \(cgCompleteCirclesTotalDegrees)° cgLessThanWholeRotation: \(cgLessThanWholeRotation); cgClosestQuarterRotation: \(cgClosestQuarterRotation)° -> cgSnapToDegrees: \(cgSnapToDegrees)°")
    return cgSnapToDegrees
  }

  @objc func handleRotationGesture(recognizer: NSRotationGestureRecognizer) {
    guard rotateAction == .rotateVideoByQuarters else { return }

    switch recognizer.state {
      case .began, .changed:
        let cgNewRotationDegrees = recognizer.rotationInDegrees
        rotateVideoView(toDegrees: cgNewRotationDegrees, animate: false)
        break
      case .failed, .cancelled:
        rotateVideoView(toDegrees: 0, animate: false)
        break
      case .ended:
        // mpv and CoreGraphics rotate in opposite directions
        let mpvNormalizedRotationDegrees = normalizeRotation(Int(-recognizer.rotationInDegrees))
        let mpvClosestQuarterRotation = findClosestQuarterRotation(mpvNormalizedRotationDegrees)
        guard mpvClosestQuarterRotation != 0 else {
          // Zero degree rotation: no change.
          // Don't "unwind" if more than 360° rotated; just take shortest partial circle back to origin
          cgCurrentRotationDegrees -= completeCircleDegrees(of: cgCurrentRotationDegrees)
          Logger.log("Rotation gesture of \(recognizer.rotationInDegrees)° will not change video rotation. Snapping back from: \(cgCurrentRotationDegrees)°")
          rotateVideoView(toDegrees: 0, animate: !AccessibilityPreferences.motionReductionEnabled)
          return
        }

        // Snap to one of the 4 quarter circle rotations
        let mpvNewRotation = (player.info.userRotation + mpvClosestQuarterRotation) %% 360
        Logger.log("User's gesture of \(recognizer.rotationInDegrees)° is equivalent to mpv \(mpvNormalizedRotationDegrees)°, which is closest to \(mpvClosestQuarterRotation)°. Adding it to current mpv rotation (\(player.info.userRotation)°) → new rotation will be \(mpvNewRotation)°")
        // Need to convert snap-to location back to CG, to feed to animation
        let cgSnapToDegrees = findNearestCGQuarterRotation(forCGRotation: recognizer.rotationInDegrees,
                                                           equalToMpvRotation: mpvClosestQuarterRotation)
        rotateVideoView(toDegrees: cgSnapToDegrees, animate: !AccessibilityPreferences.motionReductionEnabled)
        player.setVideoRotate(mpvNewRotation)

      default:
        return
    }
  }

  // MARK: - Window delegate: Open / Close

  func windowWillOpen() {
    Logger.log("WindowWillOpen", level: .verbose, subsystem: player.subsystem)
    isClosing = false

    if #available(macOS 12, *) {
      // Apparently Apple fixed AppKit for Monterey so the workaround below is only needed for
      // previous versions of macOS. Support for #unavailable is coming in Swift 5.6. The version of
      // Xcode being used at the time of this writing supports Swift 5.5.
    } else {
      // Must workaround an AppKit defect in earlier versions of macOS. This defect is known to
      // exist in Catalina and Big Sur. The problem was not reproducible in Monterey. The status of
      // other versions of macOS is unknown, however the workaround should be safe to apply in any
      // version of macOS. The problem was reported in issues #3159, #3097 and #3253. The titles of
      // open windows shown in the "Window" menu are automatically managed by the AppKit framework.
      // To improve performance PlayerCore caches and reuses player instances along with their
      // windows. This technique is valid and recommended by Apple. But in older versions of macOS,
      // if a window is reused the framework will display the title first used for the window in the
      // "Window" menu even after IINA has updated the title of the window. This problem can also be
      // seen when right-clicking or control-clicking the IINA icon in the dock. As a workaround
      // reset the window's title to "Window" before it is reused. This is the default title AppKit
      // assigns to a window when it is first created. Surprising and rather disturbing this works
      // as a workaround, but it does.
      window!.title = "Window"
    }

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

    window!.makeMain()
    window!.makeKeyAndOrderFront(nil)
    resetCollectionBehavior()
    // update buffer indicator view
    updateBufferIndicatorView()
    // start tracking mouse event
    guard let w = self.window, let cv = w.contentView else { return }
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

    // update timer
    updateTimer()
    // truncate middle for title
    if let attrTitle = titleTextField?.attributedStringValue.mutableCopy() as? NSMutableAttributedString, attrTitle.length > 0 {
      let p = attrTitle.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as! NSMutableParagraphStyle
      p.lineBreakMode = .byTruncatingMiddle
      attrTitle.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: attrTitle.length))
    }
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

    // TODO: save window position & state here
    
    player.events.emit(.windowWillClose)
  }

  // MARK: - Window delegate: Full screen

  func customWindowsToEnterFullScreen(for window: NSWindow) -> [NSWindow]? {
    return [window]
  }

  func customWindowsToExitFullScreen(for window: NSWindow) -> [NSWindow]? {
    return [window]
  }

  func window(_ window: NSWindow, startCustomAnimationToEnterFullScreenOn screen: NSScreen, withDuration duration: TimeInterval) {
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = AccessibilityPreferences.adjustedDuration(duration)
      window.animator().setFrame(screen.frame, display: true, animate: !AccessibilityPreferences.motionReductionEnabled)
    }, completionHandler: nil)

  }

  func window(_ window: NSWindow, startCustomAnimationToExitFullScreenWithDuration duration: TimeInterval) {
    if NSMenu.menuBarVisible() {
      NSMenu.setMenuBarVisible(false)
    }
    let priorWindowedFrame = fsState.priorWindowedFrame!

    NSAnimationContext.runAnimationGroup({ context in
      context.duration = AccessibilityPreferences.adjustedDuration(duration)
      window.animator().setFrame(priorWindowedFrame, display: true, animate: !AccessibilityPreferences.motionReductionEnabled)
    }, completionHandler: nil)

    NSMenu.setMenuBarVisible(true)
  }

  func windowWillEnterFullScreen(_ notification: Notification) {
    if isInInteractiveMode {
      exitInteractiveMode(immediately: true)
    }

    // Set the appearance to match the theme so the titlebar matches the theme
    let iinaTheme = Preference.enum(for: .themeMaterial) as Preference.Theme
    if #available(macOS 10.14, *) {
      window?.appearance = NSAppearance(iinaTheme: iinaTheme)
    } else {
      switch(iinaTheme) {
      case .dark, .ultraDark: window!.appearance = NSAppearance(named: .vibrantDark)
      default: window!.appearance = NSAppearance(named: .vibrantLight)
      }
    }

    if oscPosition == .insideTop {
      // need top overlay for OSC, but hide title bar
      topOverlayView.isHidden = false
    } else {
      // stop animation and hide topOverlayView
      removeTopOverlayViewFromFadeableViews()
      topOverlayView.isHidden = true
    }
    titleBarOverlayHeightConstraint.constant = 0
    standardWindowButtons.forEach { $0.alphaValue = 0 }
    titleTextField?.alphaValue = 0

    if let accessories = window?.titlebarAccessoryViewControllers, !accessories.isEmpty {
      for index in (0 ..< accessories.count).reversed() {
        window!.removeTitlebarAccessoryViewController(at: index)
      }
    }
    setWindowFloatingOnTop(false, updateOnTopStatus: false)

    thumbnailPeekView.isHidden = true
    timePreviewWhenSeek.isHidden = true
    isMouseInSlider = false

    let isLegacyFullScreen = notification.name == .iinaLegacyFullScreen
    fsState.startAnimatingToFullScreen(legacy: isLegacyFullScreen, priorWindowedFrame: window!.frame)

    videoView.videoLayer.suspend()
    // Let mpv decide the correct render region in full screen
    player.mpv.setFlag(MPVOption.Window.keepaspect, true)
  }

  func windowDidEnterFullScreen(_ notification: Notification) {
    fsState.finishAnimating()

    titleTextField?.alphaValue = 1
    removeStandardButtonsFromFadeableViews()

    videoViewConstraints.values.forEach { $0.constant = 0 }
    videoView.needsLayout = true
    videoView.layoutSubtreeIfNeeded()
    videoView.videoLayer.resume()

    if Preference.bool(for: .blackOutMonitor) {
      blackOutOtherMonitors()
    }

    if Preference.bool(for: .displayTimeAndBatteryInFullScreen) {
      fadeableViews.append(additionalInfoView)
    }

    if Preference.bool(for: .playWhenEnteringFullScreen) && player.info.isPaused {
      player.resume()
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
    Logger.log("Exiting fullscreen", subsystem: player.subsystem)
    if isInInteractiveMode {
      exitInteractiveMode(immediately: true)
    }

    if oscPosition == .insideTop {
      titleBarOverlayHeightConstraint.constant = reducedTitleBarHeight
    } else {
      titleBarOverlayHeightConstraint.constant = StandardTitleBarHeight
    }

    thumbnailPeekView.isHidden = true
    timePreviewWhenSeek.isHidden = true
    additionalInfoView.isHidden = true
    isMouseInSlider = false

    if let index = fadeableViews.firstIndex(of: additionalInfoView) {
      fadeableViews.remove(at: index)
    }

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

  func windowDidExitFullScreen(_ notification: Notification) {
    if AccessibilityPreferences.motionReductionEnabled {
      // When animation is not used exiting full screen does not restore the previous size of the
      // window. Restore it now.
      window!.setFrame(fsState.priorWindowedFrame!, display: true, animate: false)
    }
    addBackTopOverlayViewToFadeableViews()
    addBackStandardButtonsToFadeableViews()
    topOverlayView.isHidden = false
    fsState.finishAnimating()

    if Preference.bool(for: .blackOutMonitor) {
      removeBlackWindows()
    }

    if #available(macOS 10.12.2, *) {
      player.touchBarSupport.toggleTouchBarEsc(enteringFullScr: false)
    }

    window!.addTitlebarAccessoryViewController(leftTitlebarAccesoryViewController)
    window!.addTitlebarAccessoryViewController(rightTitlebarAccesoryViewController)

    // Must not access mpv while it is asynchronously processing stop and quit commands.
    // See comments in windowWillExitFullScreen for details.
    guard !isClosing else { return }
    showUI()
    updateTimer()

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

    // interactive mode
    if isInInteractiveMode {
      cropSettingsView?.cropBoxView.resized(with: videoView.frame)
    }

    // TODO: pull out this logic & do OSC resize when panel opens!
    // update control bar position
    if oscPosition == .floating {
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
    }
    
    // Detach the views in oscFloatingTopView manually on macOS 11 only; as it will cause freeze
    if isMacOS11 && oscPosition == .floating {
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

    player.events.emit(.windowResized, data: window.frame)
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

  @objc func hideUIAndCursor() {
    // don't hide UI when dragging control bar
    if controlBarFloating.isDragging { return }
    hideUI()
    NSCursor.setHiddenUntilMouseMoves(true)
  }

  private func hideUI() {
    // Don't hide UI when in PIP
    guard pipStatus == .notInPIP || animationState == .hidden else {
      return
    }

    // Follow energy efficiency best practices and stop the timer that updates the OSC.
    player.invalidateTimer()
    animationState = .willHide
    NSAnimationContext.runAnimationGroup({ (context) in
      context.duration = AccessibilityPreferences.adjustedDuration(UIAnimationDuration)
      fadeableViews.forEach { (v) in
        v.animator().alphaValue = 0
      }
      if !self.fsState.isFullscreen {
        titleTextField?.animator().alphaValue = 0
      }
    }) {
      // if no interrupt then hide animation
      if self.animationState == .willHide {
        self.fadeableViews.forEach { (v) in
          if let btn = v as? NSButton, self.standardWindowButtons.contains(btn) {
            v.alphaValue = 1e-100
          } else {
            v.isHidden = true
          }
        }
        self.animationState = .hidden
      }
    }
  }

  private func showUI() {
    if player.disableUI { return }
    animationState = .willShow
    // The OSC was not updated while it was hidden to avoid wasting energy. Update it now.
    player.syncUITime()
    player.createSyncUITimer()
    NSAnimationContext.runAnimationGroup({ (context) in
      context.duration = AccessibilityPreferences.adjustedDuration(UIAnimationDuration)
      fadeableViews.forEach { (v) in
        v.animator().alphaValue = 1
      }
      if !fsState.isFullscreen {
        titleTextField?.animator().alphaValue = 1
      }
    }) {
      // if no interrupt then hide animation
      if self.animationState == .willShow {
        self.animationState = .shown
        for v in self.fadeableViews {
          v.isHidden = false
        }
        self.standardWindowButtons.forEach { $0.isEnabled = true }
      }
    }
  }

  // MARK: - UI: Show / Hide Timer

  private func updateTimer() {
    destroyTimer()
    createTimer()
  }

  private func destroyTimer() {
    // if timer exist, destroy first
    if hideControlTimer != nil {
      hideControlTimer!.invalidate()
      hideControlTimer = nil
    }
  }

  private func createTimer() {
    // create new timer
    let timeout = Preference.float(for: .controlBarAutoHideTimeout)
    hideControlTimer = Timer.scheduledTimer(timeInterval: TimeInterval(timeout), target: self, selector: #selector(self.hideUIAndCursor), userInfo: nil, repeats: false)
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
    addDocIconToFadeableViews()
  }

  func updateOnTopIcon() {
    pinToTopButton.isHidden = Preference.bool(for: .alwaysShowOnTopIcon) ? false : !isOntop
    pinToTopButton.state = isOntop ? .on : .off

    updateRightTitleBarTrailingSpace(toWidth: rightSidebar.isVisible ? rightSidebarWidthConstraint.constant : 0)
  }

  private func updateLeftTitleBarLeadingSpace(toWidth newWidth: CGFloat, animate: Bool = false) {
    // Subtract space taken by the 3 standard buttons
    let width = max(0, newWidth - trafficLightButtonsWidth)
    Logger.log("Setting left title bar space to: \(width)")
    if animate {
      leftTitleBarLeadingSpaceConstraint.animator().constant = width
    } else {
      leftTitleBarLeadingSpaceConstraint.constant = width
    }
  }

  // Sets the horizontal space needed to push the titlebar & "on top" button leftward, so that they don't overlap on the right sidebar
  private func updateRightTitleBarTrailingSpace(toWidth newWidth: CGFloat, animate: Bool = false) {
    Logger.log("Setting right title bar space to: \(newWidth)")
    if animate {
      rightTitleBarTrailingSpaceConstraint.animator().constant = newWidth
    } else {
      rightTitleBarTrailingSpaceConstraint.constant = newWidth
    }
  }

  // MARK: - UI: OSD

  // Do not call displayOSD directly, call PlayerCore.sendOSD instead.
  func displayOSD(_ message: OSDMessage, autoHide: Bool = true, forcedTimeout: Float? = nil, accessoryView: NSView? = nil, context: Any? = nil) {
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

    osdVisualEffectView.alphaValue = 1
    osdVisualEffectView.isHidden = false
    osdVisualEffectView.layoutSubtreeIfNeeded()

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

      // enlarge window if too small
      let winFrame = window!.frame
      var newFrame = winFrame
      if (winFrame.height < 300) {
        newFrame = winFrame.centeredResize(to: winFrame.size.satisfyMinSizeWithSameAspectRatio(NSSize(width: 500, height: 300)))
      }

      accessoryView.wantsLayer = true
      accessoryView.layer?.opacity = 0

      NSAnimationContext.runAnimationGroup({ context in
        context.duration = 0.3
        context.allowsImplicitAnimation = true
        window!.setFrame(newFrame, display: true)
        osdVisualEffectView.layoutSubtreeIfNeeded()
      }, completionHandler: {
        accessoryView.layer?.opacity = 1
      })
    }

    if autoHide {
      let timeout = forcedTimeout ?? Preference.float(for: .osdAutoHideTimeout)
      hideOSDTimer = Timer.scheduledTimer(timeInterval: TimeInterval(timeout), target: self, selector: #selector(self.hideOSD), userInfo: nil, repeats: false)
    }
  }

  @objc
  func hideOSD() {
    NSAnimationContext.runAnimationGroup({ (context) in
      self.osdAnimationState = .willHide
      context.duration = OSDAnimationDuration
      osdVisualEffectView.animator().alphaValue = 0
    }) {
      if self.osdAnimationState == .willHide {
        self.osdAnimationState = .hidden
        self.osdStackView.views(in: .bottom).forEach { self.osdStackView.removeView($0) }
      }
    }
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

  // MARK: - UI: Side bar

  // For JavascriptAPICore:
  func isShowingSettingsSidebar() -> Bool {
    return leftSidebar.visibleTabGroup == .settings || rightSidebar.visibleTabGroup == .settings
  }

  func isShowing(sidebarTab tab: SidebarTab) -> Bool {
    return leftSidebar.visibleTab == tab || rightSidebar.visibleTab == tab
  }

  private func setSidebar(id sidebarID: Preference.SidebarID, forTabGroup tabGroup: SidebarTabGroup) {
    let addToSidebar: Sidebar
    let removeFromSidebar: Sidebar
    if sidebarID == leftSidebar.id {
      addToSidebar = leftSidebar
      removeFromSidebar = rightSidebar
    } else {
      addToSidebar = rightSidebar
      removeFromSidebar = leftSidebar
    }
    addToSidebar.tabGroups.insert(tabGroup)
    removeFromSidebar.tabGroups.remove(tabGroup)
  }

  private func getConfiguredSidebar(forTabGroup tabGroup: SidebarTabGroup) -> Sidebar? {
    for sidebar in [leftSidebar, rightSidebar] {
      if sidebar.tabGroups.contains(tabGroup) {
        return sidebar
      }
    }
    Logger.log("No sidebar found for tab group \(tabGroup.rawValue.quoted)!", level: .error)
    return nil
  }

  // If location of tab group changed to another sidebar (in user prefs), check if it is showing, and if so, hide it & show it on the other side
  private func moveSidebarIfNeeded(forTabGroup tabGroup: SidebarTabGroup, toNewSidebarID newID: Preference.SidebarID) {
    guard let currentID = getConfiguredSidebar(forTabGroup: tabGroup)?.id else { return }
    guard currentID != newID else { return }

    if let prevSidebar = sidebarsByID[currentID], prevSidebar.visibleTabGroup == tabGroup, let curentVisibleTab = prevSidebar.visibleTab {
      changeVisibility(forTab: curentVisibleTab, to: false, then: {
        self.setSidebar(id: newID, forTabGroup: .settings)
        self.changeVisibility(forTab: curentVisibleTab, to: true)
      })
    }
  }

  func showSidebar(forTabGroup tabGroup: SidebarTabGroup, force: Bool = false, hideIfAlreadyShown: Bool = true) {
    Logger.log("ShowSidebar for tabGroup: \(tabGroup.rawValue.quoted), force: \(force), hideIfAlreadyShown: \(hideIfAlreadyShown)")
    switch tabGroup {
      case .playlist:
        if let tab = SidebarTab(name: playlistView.currentTab.rawValue) {
          showSidebar(tab: tab, force: force, hideIfAlreadyShown: hideIfAlreadyShown)
        }
      case .settings:
        if let tab = SidebarTab(name: quickSettingView.currentTab.name) {
          showSidebar(tab: tab, force: force, hideIfAlreadyShown: hideIfAlreadyShown)
        }
    }
  }

  func showSidebar(tab: SidebarTab, force: Bool = false, hideIfAlreadyShown: Bool = true) {
    Logger.log("ShowSidebar for tab: \(tab.name.quoted), force: \(force), hideIfAlreadyShown: \(hideIfAlreadyShown)")
    if !force && (leftSidebar.animationState.isInTransition || rightSidebar.animationState.isInTransition) {
      return  // do not interrput other actions while it is animating
    }

    guard let destinationSidebar = getConfiguredSidebar(forTabGroup: tab.group) else { return }

    if destinationSidebar.visibleTab == tab && hideIfAlreadyShown {
      changeVisibility(forTab: tab, to: false)
      return
    }

    // This will change the sidebar to the displayed tab group if needed:
    changeVisibility(forTab: tab, to: true)
  }

  // hides both sidebars (if visible)
  func hideSidebars(animate: Bool = true, then: (() -> Void)? = nil) {
    Logger.log("Hiding all sidebars", level: .verbose)
    // Need to make sure that completionHandler (1) runs at all, and (2) runs after animations
    var completionHandler: (() -> Void)? = then
    if let visibleTab = leftSidebar.visibleTab {
      changeVisibility(forTab: visibleTab, to: false, then: completionHandler)
      completionHandler = nil
    }
    if let visibleTab = rightSidebar.visibleTab {
      changeVisibility(forTab: visibleTab, to: false, then: completionHandler)
      completionHandler = nil
    }
    if let completionHandler = completionHandler {
      completionHandler()
    }
  }

  private func changeVisibility(forTab tab: SidebarTab, to show: Bool, animate: Bool = true, then: (() -> Void)? = nil) {
    guard !isInInteractiveMode else { return }
    Logger.log("Changing visibility of sidebar for tab \(tab.name.quoted) to: \(show)", level: .verbose)

    let group = tab.group
    let viewController = (group == .playlist) ? playlistView : quickSettingView
    guard let sidebar = getConfiguredSidebar(forTabGroup: group) else { return }
    let currentWidth = group.width()

    if sidebar.isVisible == show {
      if !sidebar.isVisible || sidebar.visibleTab == tab {
        // Nothing to do
        if let thenDo = then {
          thenDo()
        }
        return
      }

      if sidebar.visibleTabGroup != group {
        // If tab is open but with wrong tab group, hide it, then change it, then show again
        changeVisibility(forTab: tab, to: false, then: {
          self.changeVisibility(forTab: tab, to: true)
        })
        return
      }
    }

    let sidebarView: NSVisualEffectView
    let widthConstraint: NSLayoutConstraint
    let edgeConstraint: NSLayoutConstraint
    switch sidebar.id {
      case .left:
        sidebarView = leftSidebarView
        widthConstraint = leftSidebarWidthConstraint
        edgeConstraint = leftSidebarLeadingConstraint
      case .right:
        sidebarView = rightSidebarView
        widthConstraint = rightSidebarWidthConstraint
        edgeConstraint = rightSidebarTrailingConstraint
    }

    sidebar.animationState = show ? .willShow : .willHide

    if show {
      // Make it the active tab in its parent tab group (can do this whether or not it's shown):
      switch tab.group {
        case .playlist:
          guard let tabType = PlaylistViewController.TabViewType(name: tab.name) else {
            Logger.log("Cannot switch to tab \(tab.name.quoted): could not convert to PlaylistView tab!", level: .error)
            return
          }
          self.playlistView.pleaseSwitchToTab(tabType)
        case .settings:
          guard let tabType = QuickSettingViewController.TabViewType(name: tab.name) else {
            Logger.log("Cannot switch to tab \(tab.name.quoted): could not convert to QuickSettingView tab!", level: .error)
            return
          }
          self.quickSettingView.pleaseSwitchToTab(tabType)
      }

      // adjust sidebar width before showing in case it's not up to date
      widthConstraint.constant = currentWidth
      sidebarView.isHidden = false

      // add view and constraints
      let view = viewController.view
      sidebarView.addSubview(view)
      let constraintsH = NSLayoutConstraint.constraints(withVisualFormat: "H:|[v]|", options: [], metrics: nil, views: ["v": view])
      let constraintsV = NSLayoutConstraint.constraints(withVisualFormat: "V:|[v]|", options: [], metrics: nil, views: ["v": view])
      NSLayoutConstraint.activate(constraintsH)
      NSLayoutConstraint.activate(constraintsV)
    }

    NSAnimationContext.runAnimationGroup({ context in
      context.duration = animate ? AccessibilityPreferences.adjustedDuration(SidebarAnimationDuration) : 0
      context.timingFunction = CAMediaTimingFunction(name: .easeIn)
      if sidebar.id == .right {
        updateRightTitleBarTrailingSpace(toWidth: show ? currentWidth : 0, animate: animate)
      } else if sidebar.id == .left {
        updateLeftTitleBarLeadingSpace(toWidth: show ? currentWidth : 0, animate: animate)
      }
      edgeConstraint.animator().constant = (show ? 0 : -currentWidth)
    }, completionHandler: {
      if show {
        sidebar.animationState = .shown
        sidebar.visibleTab = tab
      } else {
        sidebar.visibleTab = nil
        sidebarView.subviews.removeAll()
        sidebarView.isHidden = true
        sidebar.animationState = .hidden
      }
      Logger.log("Sidebar animation state is now: \(sidebar.animationState)")
      if let thenDo = then {
        thenDo()
      }
    })
  }

  private func setConstraintsForVideoView(_ constraints: [NSLayoutConstraint.Attribute: CGFloat], animate: Bool = false) {
    for (attr, value) in constraints {
      if let constraint = videoViewConstraints[attr] {
        if animate {
          constraint.animator().constant = value
        } else {
          constraint.constant = value
        }
      }
    }
  }

  // MARK: - UI: "Fadeable" views

  private func removeStandardButtonsFromFadeableViews() {
    fadeableViews = fadeableViews.filter { view in
      !standardWindowButtons.contains {
        $0 == view
      }
    }
    for view in standardWindowButtons {
      view.alphaValue = 1
      view.isHidden = false
    }
  }

  private func removeTopOverlayViewFromFadeableViews() {
    if let index = (self.fadeableViews.firstIndex { $0 === topOverlayView }) {
      self.fadeableViews.remove(at: index)
    }
  }

  private func addBackStandardButtonsToFadeableViews() {
    fadeableViews.append(contentsOf: standardWindowButtons as [NSView])
  }

  private func addBackTopOverlayViewToFadeableViews() {
    fadeableViews.append(topOverlayView)
  }

  // Sometimes the doc icon may not be available, eg. when opened an online video.
  // We should try to add it every time when window title changed.
  private func addDocIconToFadeableViews() {
    if let docIcon = window?.standardWindowButton(.documentIconButton), !fadeableViews.contains(docIcon) {
      fadeableViews.append(docIcon)
    }
  }

  // MARK: - UI: Interactive mode

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
    hideUI()

    if fsState.isFullscreen {
      let aspect: NSSize
      if window.aspectRatio == .zero {
        let dsize = player.videoSizeForDisplay
        aspect = NSSize(width: dsize.0, height: dsize.1)
      } else {
        aspect = window.aspectRatio
      }
      let frame = aspect.shrink(toSize: window.frame.size).centeredRect(in: window.frame)
      setConstraintsForVideoView([
        .left: frame.minX,
        .right: window.frame.width - frame.maxX,  // `frame.x` should also work
        .bottom: -frame.minY,
        .top: window.frame.height - frame.maxY  // `frame.y` should also work
      ])
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
    NSAnimationContext.runAnimationGroup({ (context) in
      context.duration = CropAnimationDuration
      context.timingFunction = CAMediaTimingFunction(name: .easeIn)
      bottomBarBottomConstraint.animator().constant = 0
      setConstraintsForVideoView(newConstants, animate: true)
    }) {
      self.cropSettingsView?.cropBoxView.isHidden = false
      self.videoView.layer?.shadowColor = .black
      self.videoView.layer?.shadowOpacity = 1
      self.videoView.layer?.shadowOffset = .zero
      self.videoView.layer?.shadowRadius = 3
    }
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
      bottomBarBottomConstraint.constant = -InteractiveModeBottomViewHeight
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
    NSAnimationContext.runAnimationGroup({ (context) in
      context.duration = CropAnimationDuration
      context.timingFunction = CAMediaTimingFunction(name: .easeIn)
      bottomBarBottomConstraint.animator().constant = -InteractiveModeBottomViewHeight
      ([.top, .bottom, .left, .right] as [NSLayoutConstraint.Attribute]).forEach { attr in
        videoViewConstraints[attr]!.animator().constant = 0
      }
    }) {
      self.cropSettingsView?.cropBoxView.removeFromSuperview()
      self.hideSidebars(animate: false)
      self.bottomView.subviews.removeAll()
      self.bottomView.isHidden = true
      self.showUI()
      then()
    }
  }

  // TODO: fix typo: 'timnePreviewYPos'
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
    guard oscPosition != .insideBottom else { return true }
    guard oscPosition != .insideTop else { return false }
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
    standardWindowButtons.forEach { $0.isEnabled = true }
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

  // TODO: fix typo
  @IBAction func ontopButtonnAction(_ sender: NSButton) {
    setWindowFloatingOnTop(!isOntop)
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
    showUI()

    pipVideo = NSViewController()
    pipVideo.view = videoView
    pip.playing = player.info.isPlaying
    pip.title = window?.title

    pip.presentAsPicture(inPicture: pipVideo)
    pipOverlayView.isHidden = false

    // If the video is paused, it will end up in a weird state due to the
    // animation. By forcing a redraw it will keep its paused image throughout.
    // (At least) in 10.15, presentAsPictureInPicture: behaves asynchronously.
    // Therefore we should wait until the view is moved to the PIP superview.
    let currentTrackIsAlbumArt = player.info.currentTrack(.video)?.isAlbumart ?? false
    if player.info.isPaused || currentTrackIsAlbumArt {
      // It takes two `layout` before finishing entering PIP (tested on macOS 12, but
      // could be earlier). Force redraw for the first two `layout`s.
      videoView.pendingRedrawsAfterEnteringPIP = 2
    }

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

    updateTimer()

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

protocol SidebarTabGroupViewController {
  var downShift: CGFloat { get set }
}
