//
//  PlayerWindowController.swift
//  iina
//
//  Created by lhc on 8/7/16.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa
import Mustache
import WebKit

// MARK: - Constants

fileprivate let InteractiveModeBottomViewHeight: CGFloat = 60

// MARK: - Constants

class PlayerWindowController: NSWindowController, NSWindowDelegate {
  unowned var player: PlayerCore
  unowned var log: Logger.Subsystem {
    return player.log
  }

  override var windowNibName: NSNib.Name {
    return NSNib.Name("PlayerWindowController")
  }

  var videoView: VideoView {
    return player.videoView
  }

  var loaded = false

  @objc let monospacedFont: NSFont = {
    let fontSize = NSFont.systemFontSize(for: .small)
    return NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
  }()

  /**
   `NSWindow` doesn't provide title bar height directly, but we can derive it by asking `NSWindow` for
   the dimensions of a prototypical window with titlebar, then subtracting the height of its `contentView`.
   Note that we can't use this trick to get it from our window instance directly, because our window has the
   `fullSizeContentView` style and so its `frameRect` does not include any extra space for its title bar.
   */
  static let standardTitleBarHeight: CGFloat = {
    // Probably doesn't matter what dimensions we pick for the dummy contentRect, but to be safe let's make them nonzero.
    let dummyContentRect = NSRect(x: 0, y: 0, width: 10, height: 10)
    let dummyFrameRect = NSWindow.frameRect(forContentRect: dummyContentRect, styleMask: .titled)
    let titleBarHeight = dummyFrameRect.height - dummyContentRect.height
    return titleBarHeight
  }()

  static let reducedTitleBarHeight: CGFloat = {
    if let heightOfCloseButton = NSWindow.standardWindowButton(.closeButton, for: .titled)?.frame.height {
      // add 2 because button's bounds seems to be a bit larger than its visible size
      return standardTitleBarHeight - ((standardTitleBarHeight - heightOfCloseButton) / 2 + 2)
    }
    Logger.log("reducedTitleBarHeight may be incorrect (could not get close button)", level: .error)
    return standardTitleBarHeight
  }()

  // MARK: - Objects, Views

  var bestScreen: NSScreen {
    window?.screen ?? NSScreen.main!
  }

  /** For blacking out other screens. */
  var cachedScreenIDs = Set<UInt32>()
  var blackWindows: [NSWindow] = []

  /** The quick setting sidebar (video, audio, subtitles). */
  lazy var quickSettingView: QuickSettingViewController = {
    let quickSettingView = QuickSettingViewController()
    quickSettingView.windowController = self
    return quickSettingView
  }()

  /** The playlist and chapter sidebar. */
  lazy var playlistView: PlaylistViewController = {
    let playlistView = PlaylistViewController()
    playlistView.windowController = self
    return playlistView
  }()

  lazy var miniPlayer: MiniPlayerController = {
    let controller = MiniPlayerController()
    controller.windowController = self
    return controller
  }()

  /** The control view for interactive mode. */
  var cropSettingsView: CropBoxViewController?

  // For legacy windowed mode
  // TODO: not used. Decide whether to use this, or delete
  var fakeLeadingTitleBarView: NSStackView? = nil

  // For Rotate gesture:
  let rotationHandler = VideoRotationHandler()

  // For Pinch To Magnify gesture:
  let magnificationHandler = VideoMagnificationHandler()

  let animationQueue = CocoaAnimation.SerialQueue()

  // MARK: - Status

  var isAnimating: Bool {
    return animationQueue.isRunning
  }

  var isOntop: Bool = false {
    didSet {
      player.mpv.setFlag(MPVOption.Window.ontop, isOntop)
      updatePinToTopButton()
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

  var isClosing = false
  var shouldApplyInitialWindowSize = true
  var isWindowMiniaturizedDueToPip = false

  var denyNextWindowResize = false

  var isPausedDueToInactive: Bool = false
  var isPausedDueToMiniaturization: Bool = false
  var isPausedPriorToInteractiveMode: Bool = false

  // - Mouse

  var mousePosRelatedToWindow: CGPoint?
  var isDragging: Bool = false
  var isLiveResizingWidth = false

  // might use another obj to handle slider?
  var isMouseInWindow: Bool = false
  var isMouseInSlider: Bool = false

  var isFastforwarding: Bool = false

  // - Left and right arrow buttons

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

  /// - Sidebars: See file `Sidebars.swift`

  /// For resize of `playlist` tab group
  var leadingSidebarIsResizing = false
  var trailingSidebarIsResizing = false

  // Is non-nil if within the activation rect of one of the sidebars
  var sidebarResizeCursor: NSCursor? = nil

  // - Fadeable Views

  /** Views that will show/hide when cursor moving in/out the window. */
  var fadeableViews = Set<NSView>()
  /** Similar to `fadeableViews`, but may fade in differently depending on configuration of top bar. */
  var fadeableViewsTopBar = Set<NSView>()
  var fadeableViewsAnimationState: UIAnimationState = .shown
  var fadeableTopBarAnimationState: UIAnimationState = .shown
  /** For auto hiding UI after a timeout. */
  var hideFadeableViewsTimer: Timer?

  // - OSD

  /** Whether current osd needs user interaction to be dismissed */
  var isShowingPersistentOSD = false
  var osdContext: Any?
  private var osdLastMessage: OSDMessage? = nil
  var osdAnimationState: UIAnimationState = .hidden
  var hideOSDTimer: Timer?

  // - Window Layout State

  // TODO: move to LayoutState
  var pipStatus = PIPStatus.notInPIP
  var isInInteractiveMode: Bool = false

  lazy var currentLayout: LayoutState = {
    return LayoutState(spec: LayoutSpec.defaultLayout())
  }()

  // The most up-to-date aspect ratio of the video (width/height)
  var videoAspectRatio: CGFloat = CGFloat(AppData.widthWhenNoVideo) / CGFloat(AppData.heightWhenNoVideo) {
    didSet {
      log.verbose("Updated videoAspectRatio: \(videoAspectRatio)")
    }
  }

  // Used to assign an incrementing unique ID to each geometry update animation request, so that frequent requests don't
  // build up and result in weird freezes or short episodes of "wandering window"
  var geoUpdateRequestCount: Int = 0

  lazy var windowedModeGeometry: PlayerWindowGeometry = {
    return buildWindowGeometryFromCurrentFrame(using: currentLayout)
  }() {
    didSet {
      log.verbose("Updated windowedModeGeometry: \(windowedModeGeometry.windowFrame)")
    }
  }

  lazy var musicModeGeometry: MusicModeGeometry = {
    return miniPlayer.buildMusicModeGeometryFromPrefs()
  }(){
    didSet {
      log.verbose("Updated \(musicModeGeometry)")
    }
  }

  // MARK: - Enums

  // Window state

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

  // MARK: - Observed user defaults

  // Cached user default values
  private lazy var arrowBtnFunction: Preference.ArrowButtonAction = Preference.enum(for: .arrowButtonAction)
  lazy var displayTimeAndBatteryInFullScreen: Bool = Preference.bool(for: .displayTimeAndBatteryInFullScreen)
  // Cached user defaults values
  internal lazy var followGlobalSeekTypeWhenAdjustSlider: Bool = Preference.bool(for: .followGlobalSeekTypeWhenAdjustSlider)
  internal lazy var useExactSeek: Preference.SeekOption = Preference.enum(for: .useExactSeek)
  internal lazy var relativeSeekAmount: Int = Preference.integer(for: .relativeSeekAmount)
  internal lazy var volumeScrollAmount: Int = Preference.integer(for: .volumeScrollAmount)
  internal lazy var singleClickAction: Preference.MouseClickAction = Preference.enum(for: .singleClickAction)
  internal lazy var doubleClickAction: Preference.MouseClickAction = Preference.enum(for: .doubleClickAction)
  internal lazy var horizontalScrollAction: Preference.ScrollAction = Preference.enum(for: .horizontalScrollAction)
  internal lazy var verticalScrollAction: Preference.ScrollAction = Preference.enum(for: .verticalScrollAction)

  static let playerWindowPrefKeys: [Preference.Key] = [
    .themeMaterial,
    .showRemainingTime,
    .alwaysFloatOnTop,
    .maxVolume,
    .useExactSeek,
    .relativeSeekAmount,
    .volumeScrollAmount,
    .singleClickAction,
    .doubleClickAction,
    .horizontalScrollAction,
    .verticalScrollAction,
    .playlistShowMetadata,
    .playlistShowMetadataInMusicMode,
    .autoSwitchToMusicMode,
    .osdPosition,
    .enableOSC,
    .oscPosition,
    .topBarPlacement,
    .bottomBarPlacement,
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
    .blackOutMonitor,
    .useLegacyFullScreen,
    .displayTimeAndBatteryInFullScreen,
    .alwaysShowOnTopIcon,
    .leadingSidebarPlacement,
    .trailingSidebarPlacement,
    .settingsTabGroupLocation,
    .playlistTabGroupLocation,
    .showLeadingSidebarToggleButton,
    .showTrailingSidebarToggleButton,
    .useLegacyWindowedMode,
    .allowEmptySpaceAroundVideo,
  ]

  override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
    guard let keyPath = keyPath, let change = change else { return }

    switch keyPath {
    case PK.themeMaterial.rawValue:
      if let newValue = change[.newKey] as? Int {
        setMaterial(Preference.Theme(rawValue: newValue))
      }
    case PK.showRemainingTime.rawValue:
      if let newValue = change[.newKey] as? Bool {
        rightLabel.mode = newValue ? .remaining : .duration
        if player.isInMiniPlayer {
          player.windowController.miniPlayer.rightLabel.mode = newValue ? .remaining : .duration
        }
      }
    case PK.alwaysFloatOnTop.rawValue:
      if let newValue = change[.newKey] as? Bool {
        if player.info.isPlaying {
          setWindowFloatingOnTop(newValue)
        }
      }
    case PK.maxVolume.rawValue:
      if let newValue = change[.newKey] as? Int {
        volumeSlider.maxValue = Double(newValue)
        if player.mpv.getDouble(MPVOption.Audio.volume) > Double(newValue) {
          player.mpv.setDouble(MPVOption.Audio.volume, Double(newValue))
        }
      }
    case PK.useExactSeek.rawValue:
      if let newValue = change[.newKey] as? Int {
        useExactSeek = Preference.SeekOption(rawValue: newValue)!
      }
    case PK.relativeSeekAmount.rawValue:
      if let newValue = change[.newKey] as? Int {
        relativeSeekAmount = newValue.clamped(to: 1...5)
      }
    case PK.volumeScrollAmount.rawValue:
      if let newValue = change[.newKey] as? Int {
        volumeScrollAmount = newValue.clamped(to: 1...4)
      }
    case PK.singleClickAction.rawValue:
      if let newValue = change[.newKey] as? Int {
        singleClickAction = Preference.MouseClickAction(rawValue: newValue)!
      }
    case PK.doubleClickAction.rawValue:
      if let newValue = change[.newKey] as? Int {
        doubleClickAction = Preference.MouseClickAction(rawValue: newValue)!
      }
    case PK.playlistShowMetadata.rawValue, PK.playlistShowMetadataInMusicMode.rawValue:
      if player.isPlaylistVisible {
        player.windowController.playlistView.playlistTableView.reloadData()
      }
    case PK.autoSwitchToMusicMode.rawValue:
      player.overrideAutoMusicMode = false
      
    case PK.enableOSC.rawValue,
      PK.oscPosition.rawValue,
      PK.topBarPlacement.rawValue,
      PK.bottomBarPlacement.rawValue,
      PK.oscBarHeight.rawValue,
      PK.oscBarPlaybackIconSize.rawValue,
      PK.oscBarPlaybackIconSpacing.rawValue,
      PK.showLeadingSidebarToggleButton.rawValue,
      PK.showTrailingSidebarToggleButton.rawValue,
      PK.oscBarToolbarIconSize.rawValue,
      PK.oscBarToolbarIconSpacing.rawValue,
      PK.controlBarToolbarButtons.rawValue:

      updateTitleBarAndOSC()
    case PK.useLegacyWindowedMode.rawValue:
      updateTitleBarAndOSC()
    case PK.allowEmptySpaceAroundVideo.rawValue:
      if let isAllowed = change[.newKey] as? Bool, !isAllowed {
        log.debug("Pref \(keyPath.quoted) changed to \(isAllowed): resizing window to remove any black space")
        resizeVideoContainer()
      }
    case PK.thumbnailLength.rawValue:
      if let newValue = change[.newKey] as? Int {
        DispatchQueue.main.asyncAfter(deadline: .now() + AppData.thumbnailRegenerationDelay) { [self] in
          if newValue == Preference.integer(for: .thumbnailLength) && newValue != player.info.thumbnailLength {
            log.debug("Pref \(keyPath.quoted) changed to \(newValue)px: requesting thumbs regen")
            player.reloadThumbnails()
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
    case PK.blackOutMonitor.rawValue:
      if let newValue = change[.newKey] as? Bool {
        if isFullScreen {
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
    case PK.leadingSidebarPlacement.rawValue, PK.trailingSidebarPlacement.rawValue:
      updateSidebarPlacements()
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
      animationQueue.run(CocoaAnimation.zeroDurationTask {
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

  // - Top bar (title bar and/or top OSC) constraints
  @IBOutlet weak var videoContainerTopOffsetFromTopBarBottomConstraint: NSLayoutConstraint!
  @IBOutlet weak var videoContainerTopOffsetFromTopBarTopConstraint: NSLayoutConstraint!
  @IBOutlet weak var videoContainerTopOffsetFromContentViewTopConstraint: NSLayoutConstraint!
  // Needs to be changed to align with either sidepanel or left of screen:
  @IBOutlet weak var topBarLeadingSpaceConstraint: NSLayoutConstraint!
  // Needs to be changed to align with either sidepanel or right of screen:
  @IBOutlet weak var topBarTrailingSpaceConstraint: NSLayoutConstraint!

  // - Bottom OSC constraints
  @IBOutlet weak var videoContainerBottomOffsetFromBottomBarTopConstraint: NSLayoutConstraint!
  @IBOutlet weak var videoContainerBottomOffsetFromBottomBarBottomConstraint: NSLayoutConstraint!
  @IBOutlet weak var videoContainerBottomOffsetFromContentViewBottomConstraint: NSLayoutConstraint!
  // Needs to be changed to align with either sidepanel or left of screen:
  @IBOutlet weak var bottomBarLeadingSpaceConstraint: NSLayoutConstraint!
  // Needs to be changed to align with either sidepanel or right of screen:
  @IBOutlet weak var bottomBarTrailingSpaceConstraint: NSLayoutConstraint!

  // - Leading sidebar constraints
  @IBOutlet weak var videoContainerLeadingOffsetFromContentViewLeadingConstraint: NSLayoutConstraint!
  @IBOutlet weak var videoContainerLeadingOffsetFromLeadingSidebarLeadingConstraint: NSLayoutConstraint!
  @IBOutlet weak var videoContainerLeadingOffsetFromLeadingSidebarTrailingConstraint: NSLayoutConstraint!

  @IBOutlet weak var videoContainerLeadingToLeadingSidebarCropTrailingConstraint: NSLayoutConstraint!

  // - Trailing sidebar constraints
  @IBOutlet weak var videoContainerTrailingOffsetFromContentViewTrailingConstraint: NSLayoutConstraint!
  @IBOutlet weak var videoContainerTrailingOffsetFromTrailingSidebarLeadingConstraint: NSLayoutConstraint!
  @IBOutlet weak var videoContainerTrailingOffsetFromTrailingSidebarTrailingConstraint: NSLayoutConstraint!

  @IBOutlet weak var videoContainerTrailingToTrailingSidebarCropLeadingConstraint: NSLayoutConstraint!

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

  // The OSD should always be below the top bar + 8. But if top bar/title bar is transparent, we need this constraint
  @IBOutlet weak var osdMinOffsetFromTopConstraint: NSLayoutConstraint!

  @IBOutlet weak var bottomBarBottomConstraint: NSLayoutConstraint!
  // Sets the size of the spacer view in the top overlay which reserves space for a title bar:
  @IBOutlet weak var titleBarHeightConstraint: NSLayoutConstraint!
  /// Size of each side of the 3 square playback buttons ⏪⏯️⏩ (`leftArrowButton`, Play/Pause, `rightArrowButton`):
  @IBOutlet weak var playbackButtonsSquareWidthConstraint: NSLayoutConstraint!
  /// Space added to the left and right of *each* of the 3 square playback buttons:
  @IBOutlet weak var playbackButtonsHorizontalPaddingConstraint: NSLayoutConstraint!
  @IBOutlet weak var topOSCHeightConstraint: NSLayoutConstraint!

  @IBOutlet weak var timePreviewWhenSeekHorizontalCenterConstraint: NSLayoutConstraint!

  // - Outlets: Views

  // MiniPlayer buttons
  @IBOutlet weak var closeButtonView: NSView!
  // Mini island containing window buttons which hover over album art / video:
  @IBOutlet weak var closeButtonBackgroundViewVE: NSVisualEffectView!
  // Mini island containing window buttons which appear next to controls (when video not visible):
  @IBOutlet weak var closeButtonBackgroundViewBox: NSBox!
  @IBOutlet weak var closeButtonVE: NSButton!
  @IBOutlet weak var backButtonVE: NSButton!
  @IBOutlet weak var closeButtonBox: NSButton!
  @IBOutlet weak var backButtonBox: NSButton!

  @IBOutlet var leadingTitleBarAccessoryView: NSView!
  @IBOutlet var trailingTitleBarAccessoryView: NSView!
  /** "Pin to Top" button in title bar, if configured to  be shown */
  @IBOutlet weak var pinToTopButton: NSButton!
  @IBOutlet weak var leadingSidebarToggleButton: NSButton!
  @IBOutlet weak var trailingSidebarToggleButton: NSButton!

  /** Panel at top of window. May be `insideVideo` or `outsideVideo`. May contain `titleBarView` and/or `controlBarTop`
   depending on configuration. */
  @IBOutlet weak var topBarView: NSVisualEffectView!
  /** Bottom border of `topBarView`. */
  @IBOutlet weak var topBarBottomBorder: NSBox!
  /** Reserves space for the title bar components. Does not contain any child views. */
  @IBOutlet weak var titleBarView: NSView!
  /** Control bar at top of window, if configured. */
  @IBOutlet weak var controlBarTop: NSView!

  @IBOutlet weak var controlBarFloating: ControlBarView!

  /** Control bar at bottom of window, if configured. May be `insideVideo` or `outsideVideo`. */
  @IBOutlet weak var bottomBarView: NSVisualEffectView!
  /** Top border of `bottomBarView`. */
  @IBOutlet weak var bottomBarTopBorder: NSBox!

  @IBOutlet weak var timePreviewWhenSeek: NSTextField!
  @IBOutlet weak var thumbnailPeekView: ThumbnailPeekView!
  @IBOutlet weak var leftArrowButton: NSButton!
  @IBOutlet weak var rightArrowButton: NSButton!

  @IBOutlet weak var leadingSidebarView: NSVisualEffectView!
  @IBOutlet weak var leadingSidebarTrailingBorder: NSBox!  // shown if leading sidebar is "outside"
  @IBOutlet weak var trailingSidebarView: NSVisualEffectView!
  @IBOutlet weak var trailingSidebarLeadingBorder: NSBox!  // shown if trailing sidebar is "outside"
  /** For interactive mode */
  @IBOutlet weak var bottomView: NSView!
  @IBOutlet weak var bufferIndicatorView: NSVisualEffectView!
  @IBOutlet weak var bufferProgressLabel: NSTextField!
  @IBOutlet weak var bufferSpin: NSProgressIndicator!
  @IBOutlet weak var bufferDetailLabel: NSTextField!
  @IBOutlet weak var additionalInfoView: NSVisualEffectView!
  @IBOutlet weak var additionalInfoLabel: NSTextField!
  @IBOutlet weak var additionalInfoStackView: NSStackView!
  @IBOutlet weak var additionalInfoTitle: NSTextField!
  @IBOutlet weak var additionalInfoBatteryView: NSView!
  @IBOutlet weak var additionalInfoBattery: NSTextField!

  @IBOutlet weak var oscFloatingPlayButtonsContainerView: NSStackView!
  @IBOutlet weak var oscFloatingUpperView: NSStackView!
  @IBOutlet weak var oscFloatingLowerView: NSStackView!
  @IBOutlet var oscBottomMainView: NSStackView!
  @IBOutlet weak var oscTopMainView: NSStackView!

  var fragToolbarView: NSStackView? = nil
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
  let defaultAlbumArtView = NSView()

  @IBOutlet weak var volumeSlider: NSSlider!
  @IBOutlet weak var muteButton: NSButton!
  @IBOutlet weak var playButton: NSButton!
  @IBOutlet weak var playSlider: PlaySlider!
  @IBOutlet weak var rightLabel: DurationDisplayTextField!
  @IBOutlet weak var leftLabel: DurationDisplayTextField!

  /** Differentiate between single clicks and double clicks. */
  internal var singleClickTimer: Timer?
  internal var mouseExitEnterCount = 0

  // Scroll direction

  /** The direction of current scrolling event. */
  enum ScrollDirection {
    case horizontal
    case vertical
  }

  internal var scrollDirection: ScrollDirection?

  /** We need to pause the video when a user starts seeking by scrolling.
   This property records whether the video is paused initially so we can
   recover the status when scrolling finished. */
  private var wasPlayingBeforeSeeking = false

  /** Subclasses should set these value to true if the mouse is in some
   special views (e.g. volume slider, play slider) before calling
   `super.scrollWheel()` and set them back to false after calling
   `super.scrollWheel()`.*/
  internal var seekOverride = false
  internal var volumeOverride = false

  var mouseActionDisabledViews: [NSView?] {[leadingSidebarView, trailingSidebarView, currentControlBar, titleBarView, oscTopMainView, subPopoverView]}

  var isFullScreen: Bool {
    return currentLayout.isFullScreen
  }

  var standardWindowButtons: [NSButton] {
    get {
      return ([.closeButton, .miniaturizeButton, .zoomButton, .documentIconButton] as [NSWindow.ButtonType]).compactMap {
        window?.standardWindowButton($0)
      }
    }
  }

  var documentIconButton: NSButton? {
    get {
      window?.standardWindowButton(.documentIconButton)
    }
  }

  var trafficLightButtons: [NSButton] {
    get {
      if let window = window, window.styleMask.contains(.titled) {
        return ([.closeButton, .miniaturizeButton, .zoomButton] as [NSWindow.ButtonType]).compactMap {
          window.standardWindowButton($0)
        }
      } else {
        if let stackView = fakeLeadingTitleBarView {
          return stackView.subviews as! [NSButton]
        }
      }
      return []
    }
  }

  // Width of the 3 traffic light buttons
  lazy var trafficLightButtonsWidth: CGFloat = {
    var maxX: CGFloat = 0
    for buttonType in [NSWindow.ButtonType.closeButton, NSWindow.ButtonType.miniaturizeButton, NSWindow.ButtonType.zoomButton] {
      if let button = window!.standardWindowButton(buttonType) {
        maxX = max(maxX, button.frame.origin.x + button.frame.width)
      }
    }
    return maxX
  }()

  /** Get the `NSTextField` of widow's title. */
  var titleTextField: NSTextField? {
    get {
      return window?.standardWindowButton(.closeButton)?.superview?.subviews.compactMap({ $0 as? NSTextField }).first
    }
  }

  var leadingTitlebarAccesoryViewController: NSTitlebarAccessoryViewController?
  var trailingTitlebarAccesoryViewController: NSTitlebarAccessoryViewController?

  /** Current OSC view. May be top, bottom, or floating depneding on user pref. */
  var currentControlBar: NSView?

  lazy var pluginOverlayViewContainer: NSView! = {
    guard let window = window, let cv = window.contentView else { return nil }
    let view = NSView(frame: .zero)
    view.translatesAutoresizingMaskIntoConstraints = false
    cv.addSubview(view, positioned: .below, relativeTo: bufferIndicatorView)
    Utility.quickConstraints(["H:|[v]|", "V:|[v]|"], ["v": view])
    return view
  }()

  lazy var subPopoverView = playlistView.subPopover?.contentViewController?.view

  private var oscFloatingLeadingTrailingConstraint: [NSLayoutConstraint]?

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

  init(playerCore: PlayerCore) {
    self.player = playerCore
    super.init(window: nil)
    log.verbose("PlayerWindowController init")
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func windowDidLoad() {
    log.verbose("PlayerWindow windowDidLoad starting")
    super.windowDidLoad()
    loaded = true

    guard let window = window else { return }
    guard let cv = window.contentView else { return }

    window.initialFirstResponder = nil
    window.titlebarAppearsTransparent = true

    setMaterial(Preference.enum(for: .themeMaterial))

    leftLabel.mode = .current
    rightLabel.mode = Preference.bool(for: .showRemainingTime) ? .remaining : .duration

    updateVolumeUI()

    // size
    window.minSize = AppData.minVideoSize

    // need to deal with control bar, so we handle it manually
    window.isMovableByWindowBackground  = false

    // set background color to black
    window.backgroundColor = .black
//    window.backgroundColor = .clear

    /// Set `videoContainerView`'s background to black so that when `allowEmptySpaceAroundVideo`
    /// pref is enabled, sidebars do not bleed through during their open/close animations.
    videoContainerView.wantsLayer = true
    videoContainerView.layer?.backgroundColor = .black

    // Titlebar accessories

    // Update this here to reduce animation jitter on older versions of MacOS:
    videoContainerTopOffsetFromTopBarTopConstraint.constant = PlayerWindowController.standardTitleBarHeight

    addTitleBarAccessoryViews()

    // osc views
    oscFloatingPlayButtonsContainerView.addView(fragPlaybackControlButtonsView, in: .center)

    updateArrowButtonImages()

    // video view

    // gesture recognizers
    rotationHandler.windowControllerController = self
    magnificationHandler.windowController = self
    cv.addGestureRecognizer(magnificationHandler.magnificationGestureRecognizer)
    cv.addGestureRecognizer(rotationHandler.rotationGestureRecognizer)

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

    // default album art
    defaultAlbumArtView.translatesAutoresizingMaskIntoConstraints = false
    defaultAlbumArtView.wantsLayer = true
    defaultAlbumArtView.alphaValue = 1
    defaultAlbumArtView.isHidden = true
    defaultAlbumArtView.layer?.contents = #imageLiteral(resourceName: "default-album-art")
    videoContainerView.addSubview(defaultAlbumArtView)
    defaultAlbumArtView.addConstraintsToFillSuperview()

    // init quick setting view now
    let _ = quickSettingView

    // other initialization
    osdAccessoryProgress.usesThreadedAnimation = false
    if #available(macOS 10.14, *) {
      topBarBottomBorder.fillColor = NSColor(named: .titleBarBorder)!
    }
    cachedScreenIDs.removeAll()
    for screen in NSScreen.screens {
      cachedScreenIDs.insert(screen.displayId)
    }
    // Do not make visual effects views opaque when window is not in focus
    for view in [topBarView, osdVisualEffectView, bottomBarView, controlBarFloating,
                 leadingSidebarView, trailingSidebarView, osdVisualEffectView, pipOverlayView, bufferIndicatorView] {
      view?.state = .active
    }

    let roundedCornerRadius: CGFloat = CGFloat(Preference.float(for: .roundedCornerRadius))

    // buffer indicator view
    if roundedCornerRadius > 0.0 {
      bufferIndicatorView.roundCorners(withRadius: roundedCornerRadius)
      osdVisualEffectView.roundCorners(withRadius: roundedCornerRadius)
      additionalInfoView.roundCorners(withRadius: roundedCornerRadius)
    }
    
    if player.disableUI { hideFadeableViews() }

    // add notification observers

    addObserver(to: .default, forName: .iinaMediaTitleChanged, object: player) { [unowned self] _ in
      self.updateTitle()
    }

    addObserver(to: .default, forName: .iinaFileLoaded, object: player) { [unowned self] _ in
      self.updateTitle()
    }

    if #available(macOS 10.15, *) {
      addObserver(to: .default, forName: NSScreen.colorSpaceDidChangeNotification, object: nil) { [unowned self] noti in
        player.refreshEdrMode()
      }
    }

    /// The `iinaFileLoaded` event is useful here because it is posted after `fileLoaded`.
    /// This ensures that `info.vid` will have been updated with the current audio track selection, or `0` if none selected.
    /// Before `fileLoaded` it may be `0` (indicating no selection) as the track info is still being processed, which is misleading.
    addObserver(to: .default, forName: .iinaFileLoaded, object: player) { [self] note in
      log.verbose("Got iinaFileLoaded notification")

      thumbnailPeekView.isHidden = true
      timePreviewWhenSeek.isHidden = true

      quickSettingView.reload()

      refreshDefaultAlbumArtVisibility()
    }

    // FIXME: this is triggered while file is loading. Need to tighten up state logic before uncommenting
//    addObserver(to: .default, forName: .iinaVIDChanged, object: player) { [self] note in
//      guard !player.info.fileLoading && player.info.fileLoaded else { return }
//      log.verbose("Got iinaVIDChanged notification")
//      refreshDefaultAlbumArtVisibility()
//    }

    // This observer handles when the user connected a new screen or removed a screen, or shows/hides the Dock.
    addObserver(to: .default, forName: NSApplication.didChangeScreenParametersNotification) { [unowned self] _ in

      // FIXME: this also handles the case where Dock was shown/hidden! Need to update window sizes accordingly

      var screenIDs = Set<UInt32>()
      for screen in NSScreen.screens {
        screenIDs.insert(screen.displayId)
      }
      log.verbose("Got NSApplicationDidChangeScreenParametersNotification; screenIDs was: \(self.cachedScreenIDs), is now: \(screenIDs)")
      if isFullScreen && Preference.bool(for: .blackOutMonitor) && screenIDs != self.cachedScreenIDs {
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
      if currentLayout.isLegacyFullScreen {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in
          animationQueue.run(CocoaAnimation.Task({ [self] in
            let newGeo = windowedModeGeometry.clone(windowFrame: bestScreen.frame)
            setWindowFrameForLegacyFullScreen(using: newGeo)
          }))
        }
      }
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

    NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [unowned self] _ in
      if Preference.bool(for: .pauseWhenGoesToSleep) {
        self.player.pause()
      }
    }

    PlayerWindowController.playerWindowPrefKeys.forEach { key in
      UserDefaults.standard.addObserver(self, forKeyPath: key.rawValue, options: .new, context: nil)
    }

    log.verbose("PlayerWindow windowDidLoad done")
    player.events.emit(.windowLoaded)
  }

  deinit {
    ObjcUtils.silenced {
      for key in PlayerWindowController.playerWindowPrefKeys {
        UserDefaults.standard.removeObserver(self, forKeyPath: key.rawValue)
      }
    }
  }

  internal func addObserver(to notificationCenter: NotificationCenter, forName name: Notification.Name, object: Any? = nil, using block: @escaping (Notification) -> Void) {
    notificationCenter.addObserver(forName: name, object: object, queue: .main, using: block)
  }

  // default album art
  func refreshDefaultAlbumArtVisibility() {
    guard loaded else { return }

    let vid = player.info.vid
    let showDefaultArt: Bool
    // if received video size before switching to music mode, hide default album art
    if vid == 0 {
      guard defaultAlbumArtView.isHidden else { return }
      log.verbose("Showing defaultAlbumArt because vid = 0")
      showDefaultArt = true
    } else {
      guard !defaultAlbumArtView.isHidden else { return }
      log.verbose("Hiding defaultAlbumArt because vid != 0")
      showDefaultArt = false
    }

    defaultAlbumArtView.isHidden = !showDefaultArt
    let newAspectRatio = showDefaultArt ? 1 : videoAspectRatio

    switch currentLayout.spec.mode {
    case .musicMode:
      let newGeo = musicModeGeometry.clone(videoAspectRatio: newAspectRatio)
      applyMusicModeGeometry(newGeo)
    case .windowed:
      let vidCon = player.info.getUserPreferredVideoContainerSize(forAspectRatio: newAspectRatio) ?? windowedModeGeometry.videoContainerSize
      let newGeo = windowedModeGeometry.clone(videoAspectRatio: newAspectRatio).scaleVideoContainer(desiredSize: vidCon, constrainedWithin: bestScreen.visibleFrame)
      // FIXME: need to request aspectRatio from video - mpv will not provide it if paused
      applyWindowGeometry(newGeo)
    case .fullScreen:
      // TODO: legacy FS?
      break
    }
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
    player.log.verbose("Adding videoView to videoContainerView")
    /// Make sure `defaultAlbumArtView` stays above `videoView`
    videoContainerView.addSubview(videoView, positioned: .below, relativeTo: defaultAlbumArtView)
    videoView.translatesAutoresizingMaskIntoConstraints = false
    // add constraints
    videoView.constrainForNormalLayout()
  }

  /** Set material for OSC and title bar */
  func setMaterial(_ theme: Preference.Theme?) {
    guard let window = window, let theme = theme else { return }

    if #available(macOS 10.14, *) {
      window.appearance = NSAppearance(iinaTheme: theme)
      // See overridden functions for 10.14-
      return
    }

    let (appearance, material) = Utility.getAppearanceAndMaterial(from: theme)
    let isDarkTheme = appearance?.isDark ?? true
    (playSlider.cell as? PlaySliderCell)?.isInDarkTheme = isDarkTheme

    for view in [topBarView, controlBarFloating, bottomBarView,
                 osdVisualEffectView, pipOverlayView, additionalInfoView, bufferIndicatorView] {
      view?.material = material
      view?.appearance = appearance
    }

    for sidebar in [leadingSidebarView, trailingSidebarView] {
      sidebar?.material = .dark
      sidebar?.appearance = NSAppearance(named: .vibrantDark)
    }

    if player.isInMiniPlayer {
      _ = miniPlayer.view  // load XIB if not loaded to prevent unboxing nils

      for view in [miniPlayer.backgroundView, closeButtonBackgroundViewVE, miniPlayer.playlistWrapperView] {
        view?.appearance = appearance
        view?.material = material
      }
    }

    window.appearance = appearance
  }

  func updateTitleBarAndOSC() {
    animationQueue.runZeroDuration { [self] in
      guard !isInInteractiveMode else {
        log.verbose("Skipping layout refresh due to interactive mode")
        return
      }
      let oldLayout = currentLayout
      let outputLayoutSpec = LayoutSpec.fromPreferences(andSpec: oldLayout.spec)
      let transition = buildLayoutTransition(named: "UpdateTitleBar&OSC", from: oldLayout, to: outputLayoutSpec)
      animationQueue.run(transition.animationTasks)
    }
  }

  // MARK: - Key events

  @discardableResult
  func handleKeyBinding(_ keyBinding: KeyMapping) -> Bool {
    if keyBinding.isIINACommand {
      if let menuItem = keyBinding.menuItem, let action = menuItem.action {
        // - Menu item (e.g. custom video filter)
        // If a menu item's key equivalent doesn't have any modifiers, the player window will get the key event instead of the main menu.
        Logger.log("Executing action for menuItem \(menuItem.title.quoted)", level: .verbose, subsystem: player.subsystem)
        NSApp.sendAction(action, to: self, from: menuItem)
        return true
      }

      // - IINA command
      if let iinaCommand = IINACommand(rawValue: keyBinding.rawAction) {
        handleIINACommand(iinaCommand)
        return true
      } else {
        Logger.log("Unrecognized IINA command: \(keyBinding.rawAction.quoted)", level: .error, subsystem: player.subsystem)
        return false
      }
    } else {
      // - mpv command

      if let menuItem = keyBinding.menuItem, let action = menuItem.action {
        // Contains an action selector. Call it instead of sending raw mpv command
        NSApplication.shared.sendAction(action, to: menuItem.target, from: menuItem)
        return true
      }

      let returnValue: Int32
      // execute the command
      switch keyBinding.action.first! {
        // TODO: replace this with a key binding interceptor
      case MPVCommand.abLoop.rawValue:
        returnValue = abLoop()
      case MPVCommand.screenshot.rawValue:
        returnValue = player.mpv.command(rawString: keyBinding.rawAction)
        if returnValue == 0 {
          player.sendOSD(.screenshot)
        }
      default:
        returnValue = player.mpv.command(rawString: keyBinding.rawAction)
      }

      let success = returnValue == 0

      if success {
        if keyBinding.action.first == MPVCommand.screenshot.rawValue {
          player.sendOSD(.screenshot)
        }

      } else {
        Logger.log("Return value \(returnValue) when executing key command \(keyBinding.rawAction.quoted)",
                   level: .error, subsystem: player.subsystem)
      }
      return success
    }
  }

  override func keyDown(with event: NSEvent) {
    let keyCode = KeyCodeHelper.mpvKeyCode(from: event)
    let normalizedKeyCode = KeyCodeHelper.normalizeMpv(keyCode)

    PluginInputManager.handle(
      input: normalizedKeyCode, event: .keyDown, player: player,
      arguments: keyEventArgs(event), handler: { [self] in
        if let keyBinding = player.bindingController.matchActiveKeyBinding(endingWith: event) {

          guard !keyBinding.isIgnored else {
            // if "ignore", just swallow the event. Do not forward; do not beep
            log.verbose("Binding is ignored for key: \(keyCode.quoted)")
            return true
          }

          // beep if cmd failed
          return handleKeyBinding(keyBinding)
        }
        return false
      }, defaultHandler: {
        // invalid key
        super.keyDown(with: event)
      })
  }

  override func keyUp(with event: NSEvent) {
    let keyCode = KeyCodeHelper.mpvKeyCode(from: event)
    let normalizedKeyCode = KeyCodeHelper.normalizeMpv(keyCode)

    PluginInputManager.handle(
      input: normalizedKeyCode, event: .keyUp, player: player,
      arguments: keyEventArgs(event)
    )
  }

  // MARK: - Mouse / Trackpad events

  /// This method is provided soly for invoking plugin input handlers.
  func informPluginMouseDragged(with event: NSEvent) {
    PluginInputManager.handle(
      input: PluginInputManager.Input.mouse, event: .mouseDrag, player: player,
      arguments: mouseEventArgs(event)
    )
  }

  fileprivate func mouseEventArgs(_ event: NSEvent) -> [[String: Any]] {
    return [[
      "x": event.locationInWindow.x,
      "y": event.locationInWindow.y,
      "clickCount": event.clickCount,
      "pressure": event.pressure
    ] as [String : Any]]
  }

  fileprivate func keyEventArgs(_ event: NSEvent) -> [[String: Any]] {
    return [[
      "x": event.locationInWindow.x,
      "y": event.locationInWindow.y,
      "isRepeat": event.isARepeat
    ] as [String : Any]]
  }

  func isMouseEvent(_ event: NSEvent, inAnyOf views: [NSView?]) -> Bool {
    return views.filter { $0 != nil }.reduce(false, { (result, view) in
      return result || view!.isMousePoint(view!.convert(event.locationInWindow, from: nil), in: view!.bounds)
    })
  }

  /**
   Being called to perform single click action after timeout.

   - SeeAlso:
   mouseUp(with:)
   */
  @objc internal func performMouseActionLater(_ timer: Timer) {
    guard let action = timer.userInfo as? Preference.MouseClickAction else { return }
    if mouseExitEnterCount >= 2 && action == .hideOSC {
      /// the counter being greater than or equal to 2 means that the mouse re-entered the window
      /// `showFadeableViews()` must be called due to the movement in the window, thus `hideOSC` action should be cancelled
      return
    }
    performMouseAction(action)
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
    guard #available(macOS 11, *) else { return }
    NSCursor.setHiddenUntilMouseMoves(true)
  }

  override func mouseDown(with event: NSEvent) {
    if Logger.enabled && Logger.Level.preferred >= .verbose {
      log.verbose("PlayerWindow mouseDown @ \(event.locationInWindow)")
    }
    workaroundCursorDefect()
    // do nothing if it's related to floating OSC
    guard !controlBarFloating.isDragging else { return }
    // record current mouse pos
    mousePosRelatedToWindow = event.locationInWindow
    // Start resize if applicable
    let wasHandled = startResizingSidebar(with: event)
    if !wasHandled {
      PluginInputManager.handle(
        input: PluginInputManager.Input.mouse, event: .mouseDown,
        player: player, arguments: mouseEventArgs(event)
      )
      // we don't call super here because before adding the plugin system,
      // PlayerWindowController didn't call super at all
    }
  }

  override func mouseDragged(with event: NSEvent) {
    let didResizeSidebar = resizeSidebar(with: event) != nil
    guard !didResizeSidebar else {
      return
    }

    if !isFullScreen && !controlBarFloating.isDragging {
      if let mousePosRelatedToWindow = mousePosRelatedToWindow {
        if !isDragging {
          /// Require that the user must drag the cursor at least a small distance for it to start a "drag" (`isDragging==true`)
          /// The user's action will only be counted as a click if `isDragging==false` when `mouseUp` is called.
          /// (Apple's trackpad in particular is very sensitive and tends to call `mouseDragged()` if there is even the slightest
          /// roll of the finger during a click, and the distance of the "drag" may be less than `minimumInitialDragDistance`)
          if mousePosRelatedToWindow.distance(to: event.locationInWindow) <= Constants.Distance.windowControllerMinInitialDragThreshold {
            return
          }
          if Logger.enabled && Logger.Level.preferred >= .verbose {
            log.verbose("PlayerWindow mouseDrag: minimum dragging distance was met")
          }
          isDragging = true
        }
        window?.performDrag(with: event)
        informPluginMouseDragged(with: event)
      }
    }
  }

  override func mouseUp(with event: NSEvent) {
    if Logger.enabled && Logger.Level.preferred >= .verbose {
      log.verbose("PlayerWindow mouseUp @ \(event.locationInWindow), dragging: \(isDragging.yn), clickCount: \(event.clickCount)")
    }
    workaroundCursorDefect()
    mousePosRelatedToWindow = nil
    if isDragging {
      // if it's a mouseup after dragging window
      isDragging = false
    } else if finishResizingSidebar(with: event) {
      updateCachedGeometry()
      player.saveState()
      return
    } else {
      // if it's a mouseup after clicking

      /// Single click. Note that `event.clickCount` will be 0 if there is at least one call to `mouseDragged()`,
      /// but we will only count it as a drag if `isDragging==true`
      if event.clickCount <= 1 && !isMouseEvent(event, inAnyOf: [leadingSidebarView, trailingSidebarView, subPopoverView,
                                                                 topBarView, bottomBarView]) {
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

      guard !isMouseEvent(event, inAnyOf: mouseActionDisabledViews) else {
        player.log.verbose("Click occurred in a disabled view; ignoring")
        return
      }
      PluginInputManager.handle(
        input: PluginInputManager.Input.mouse, event: .mouseUp, player: player,
        arguments: mouseEventArgs(event), defaultHandler: { [self] in
          // default handler
          if event.clickCount == 1 {
            if doubleClickAction == .none {
              performMouseAction(singleClickAction)
            } else {
              singleClickTimer = Timer.scheduledTimer(timeInterval: NSEvent.doubleClickInterval, target: self, selector: #selector(performMouseActionLater), userInfo: singleClickAction, repeats: false)
              mouseExitEnterCount = 0
            }
          } else if event.clickCount == 2 {
            if let timer = singleClickTimer {
              timer.invalidate()
              singleClickTimer = nil
            }
            performMouseAction(doubleClickAction)
          }
        })
    }
  }

  override func otherMouseDown(with event: NSEvent) {
    workaroundCursorDefect()
    super.otherMouseDown(with: event)
  }

  override func otherMouseUp(with event: NSEvent) {
    workaroundCursorDefect()
    Logger.log("PlayerWindow otherMouseUp!", level: .verbose, subsystem: player.subsystem)
    guard !isMouseEvent(event, inAnyOf: mouseActionDisabledViews) else { return }

    PluginInputManager.handle(
      input: PluginInputManager.Input.otherMouse, event: .mouseUp, player: player,
      arguments: mouseEventArgs(event), defaultHandler: {
        if event.type == .otherMouseUp {
          self.performMouseAction(Preference.enum(for: .middleClickAction))
        } else {
          super.otherMouseUp(with: event)
        }
      })
  }

  /// Workaround for issue #4183, Cursor remains visible after resuming playback with the touchpad using secondary click
  ///
  /// AppKit contains special handling for [rightMouseDown](https://developer.apple.com/documentation/appkit/nsview/event_handling/1806802-rightmousedown) having to do with contextual menus.
  /// Even though the documentation indicates the event will be passed up the responder chain, the event is not being received by the
  /// window controller. We are having to catch the event in the view. Because of that we do not call the super method and instead
  /// return to the view.`
  override func rightMouseDown(with event: NSEvent) {
    workaroundCursorDefect()
    PluginInputManager.handle(
      input: PluginInputManager.Input.rightMouse, event: .mouseDown,
      player: player, arguments: mouseEventArgs(event)
    )
  }

  override func rightMouseUp(with event: NSEvent) {
    log.verbose("PlayerWindow rightMouseUp!")
    workaroundCursorDefect()
    guard !isMouseEvent(event, inAnyOf: mouseActionDisabledViews) else { return }

    PluginInputManager.handle(
      input: PluginInputManager.Input.rightMouse, event: .mouseUp, player: player,
      arguments: mouseEventArgs(event), defaultHandler: {
        self.performMouseAction(Preference.enum(for: .rightClickAction))
      })
  }

  func performMouseAction(_ action: Preference.MouseClickAction) {
    log.verbose("Performing mouseAction: \(action)")
    switch action {
    case .pause:
      player.togglePause()
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
    } else if volumeSlider.isEnabled && (player.isInMiniPlayer && isMouseEvent(event, inAnyOf: [miniPlayer.volumeSliderView])
                                         || isMouseEvent(event, inAnyOf: [fragVolumeView])) {
      volumeOverride = true
    } else {
      guard !isMouseEvent(event, inAnyOf: [currentControlBar]) else { return }
    }

    let isMouse = event.phase.isEmpty
    let isTrackpadBegan = event.phase.contains(.began)
    let isTrackpadEnd = event.phase.contains(.ended)

    // determine direction

    if isMouse || isTrackpadBegan {
      if event.scrollingDeltaX != 0 {
        scrollDirection = .horizontal
      } else if event.scrollingDeltaY != 0 {
        scrollDirection = .vertical
      }
    } else if isTrackpadEnd {
      scrollDirection = nil
    }

    let scrollAction: Preference.ScrollAction
    if seekOverride {
      scrollAction = .seek
    } else if volumeOverride {
      scrollAction = .volume
    } else {
      scrollAction = scrollDirection == .horizontal ? horizontalScrollAction : verticalScrollAction
      // show volume popover when volume seek begins and hide on end
      if scrollAction == .volume && player.isInMiniPlayer {
        player.windowController.miniPlayer.handleVolumePopover(isTrackpadBegan, isTrackpadEnd, isMouse)
      }
    }

    // pause video when seek begins

    if scrollAction == .seek && isTrackpadBegan {
      // record pause status
      if player.info.isPlaying {
        player.pause()
        wasPlayingBeforeSeeking = true
      }
    }

    if isTrackpadEnd && wasPlayingBeforeSeeking {
      // only resume playback when it was playing before seeking
      if wasPlayingBeforeSeeking {
        player.resume()
      }
      wasPlayingBeforeSeeking = false
    }

    // handle the delta value

    let isPrecise = event.hasPreciseScrollingDeltas
    let isNatural = event.isDirectionInvertedFromDevice

    var deltaX = isPrecise ? Double(event.scrollingDeltaX) : event.scrollingDeltaX.unifiedDouble
    var deltaY = isPrecise ? Double(event.scrollingDeltaY) : event.scrollingDeltaY.unifiedDouble * 2

    if isNatural {
      deltaY = -deltaY
    } else {
      deltaX = -deltaX
    }

    let delta = scrollDirection == .horizontal ? deltaX : deltaY

    // perform action

    switch scrollAction {
    case .seek:
      let seekAmount = (isMouse ? AppData.seekAmountMapMouse : AppData.seekAmountMap)[relativeSeekAmount] * delta
      player.seek(relativeSecond: seekAmount, option: useExactSeek)
    case .volume:
      // don't use precised delta for mouse
      let newVolume = player.info.volume + (isMouse ? delta : AppData.volumeMap[volumeScrollAmount] * delta)
      player.setVolume(newVolume)
      if player.isInMiniPlayer {
        player.windowController.miniPlayer.volumeSlider.doubleValue = newVolume
      } else {
        volumeSlider.doubleValue = newVolume
      }
    default:
      break
    }

    seekOverride = false
    volumeOverride = false
  }

  override func mouseEntered(with event: NSEvent) {
    guard !isInInteractiveMode else { return }
    guard let obj = event.trackingArea?.userInfo?["obj"] as? Int else {
      log.warn("No data for tracking area")
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
      updateTimeLabelAndThumbnail(mousePos.x, originalPos: event.locationInWindow)
    }
  }

  override func mouseExited(with event: NSEvent) {
    guard !isInInteractiveMode else { return }
    guard let obj = event.trackingArea?.userInfo?["obj"] as? Int else {
      log.warn("No data for tracking area")
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
      let mousePos = playSlider.convert(event.locationInWindow, from: nil)
      updateTimeLabelAndThumbnail(mousePos.x, originalPos: event.locationInWindow)
      timePreviewWhenSeek.isHidden = true
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
      updateTimeLabelAndThumbnail(mousePos.x, originalPos: event.locationInWindow)
    } else {
      // Just to be sure
      timePreviewWhenSeek.isHidden = true
      thumbnailPeekView.isHidden = true
    }

    if isMouseInWindow {
      let isPrefEnabled = Preference.enum(for: .showTopBarTrigger) == Preference.ShowTopBarTrigger.topBarHover
      let forceShowTopBar = isPrefEnabled && isMouseInTopBarArea(event) && fadeableTopBarAnimationState == .hidden
      // Check whether mouse is in OSC
      let shouldRestartFadeTimer = !isMouseEvent(event, inAnyOf: [currentControlBar, titleBarView])
      showFadeableViews(thenRestartFadeTimer: shouldRestartFadeTimer, duration: 0, forceShowTopBar: forceShowTopBar)
    }
  }

  // assumes mouse is in window
  private func isMouseInTopBarArea(_ event: NSEvent) -> Bool {
    if isMouseEvent(event, inAnyOf: [bottomBarView]) {
      return false
    }
    guard let window = window, let contentView = window.contentView else { return false }
    let heightThreshold = contentView.frame.height - currentLayout.topBarHeight
    return event.locationInWindow.y >= heightThreshold
  }

  @objc func handleMagnifyGesture(recognizer: NSMagnificationGestureRecognizer) {
    magnificationHandler.handleMagnifyGesture(recognizer: recognizer)
  }

  @objc func handleRotationGesture(recognizer: NSRotationGestureRecognizer) {
    rotationHandler.handleRotationGesture(recognizer: recognizer)
  }

  // MARK: - Window delegate: Open / Close

  func openWindow() {
    guard let window = self.window, let cv = window.contentView else { return }
    isClosing = false

    log.verbose("PlayerWindow openWindow starting")

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
      let currentString = (screen == currentScreen) ? "✅" : " "
      screen.log("\(currentString)Screen\(screenIndex): ")
    }

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

    resetCollectionBehavior()
    updateBufferIndicatorView()
    updateOSDPosition()

    // FIXME: find way to delay until after fileLoaded. We don't know the video dimensions yet!
    log.verbose("Showing Player Window")
    window.setIsVisible(true)
    addVideoViewToWindow()
    log.verbose("Hiding defaultAlbumArt for window open")
    defaultAlbumArtView.isHidden = true

    player.initVideo()
    videoView.videoLayer.draw(forced: true)
    videoView.startDisplayLink()

    // Restore layout from last launch or configure from prefs. Do not animate, but run inside animationQueue
    animationQueue.run(CocoaAnimation.Task({ [self] in
      setInitialWindowLayout()
    }))

    log.verbose("PlayerWindow openWindow done")
  }

  func windowWillClose(_ notification: Notification) {
    log.verbose("Window will close")

    isClosing = true
    // Close PIP
    if pipStatus == .inPIP {
      if #available(macOS 10.12, *) {
        exitPIP()
      }
    }
    if currentLayout.isLegacyFullScreen {
      restoreDockSettings()
    }
    // stop playing
    // This will save state if configured to do so
    player.stop()
    // stop tracking mouse event
    guard let w = self.window, let cv = w.contentView else { return }
    cv.trackingAreas.forEach(cv.removeTrackingArea)
    playSlider.trackingAreas.forEach(playSlider.removeTrackingArea)

    // Reset state flags
    shouldApplyInitialWindowSize = true
    player.overrideAutoMusicMode = false

    player.events.emit(.windowWillClose)
  }

  func restoreDockSettings() {
    NSApp.presentationOptions.remove(.autoHideMenuBar)
    NSApp.presentationOptions.remove(.autoHideDock)
  }

  // MARK: - Window delegate: Full screen

  func customWindowsToEnterFullScreen(for window: NSWindow) -> [NSWindow]? {
    return [window]
  }

  func customWindowsToExitFullScreen(for window: NSWindow) -> [NSWindow]? {
    return [window]
  }

  func windowWillEnterFullScreen(_ notification: Notification) {
  }

  func window(_ window: NSWindow, startCustomAnimationToEnterFullScreenOn screen: NSScreen, withDuration duration: TimeInterval) {
    animateEntryIntoFullScreen(withDuration: duration, isLegacy: false)
  }

  // Animation: Enter FullScreen
  private func animateEntryIntoFullScreen(withDuration duration: TimeInterval, isLegacy: Bool) {
    log.verbose("Animating entry into \(isLegacy ? "legacy " : "")full screen, duration: \(duration)")
    let oldLayout = currentLayout

    // May be in interactive mode, with some panels hidden. Honor existing layout but change value of isFullScreen
    let fullscreenLayout = oldLayout.spec.clone(mode: .fullScreen, isLegacyStyle: isLegacy)
    let transition = buildLayoutTransition(named: "Enter\(isLegacy ? "Legacy" : "")FullScreen", from: oldLayout, to: fullscreenLayout, totalStartingDuration: 0, totalEndingDuration: duration)
    animationQueue.run(transition.animationTasks)
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
      animateExitFromFullScreen(withDuration: CocoaAnimation.FullScreenTransitionDuration, isLegacy: false)
    }
  }

  // Animation: Exit FullScreen
  private func animateExitFromFullScreen(withDuration duration: TimeInterval, isLegacy: Bool) {
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

    let oldLayout = currentLayout

    // May be in interactive mode, with some panels hidden (overriding stored preferences).
    // Honor existing layout but change value of isFullScreen:
    let windowedLayout = oldLayout.spec.clone(mode: .windowed, isLegacyStyle: Preference.bool(for: .useLegacyWindowedMode))

    /// Split the duration between `openNewPanels` animation and `fadeInNewViews` animation
    let transition = buildLayoutTransition(named: "Exit\(isLegacy ? "Legacy" : "")FullScreen", from: oldLayout, to: windowedLayout, totalStartingDuration: 0, totalEndingDuration: duration)

    animationQueue.run(transition.animationTasks)
  }

  func toggleWindowFullScreen() {
    log.verbose("ToggleWindowFullScreen() entered")
    let layout = currentLayout

    switch layout.spec.mode {
    case .windowed:
      enterFullScreen()
    case .fullScreen:
      exitFullScreen(legacy: layout.spec.isLegacyStyle)
    default:
      return
    }
  }

  func enterFullScreen(legacy: Bool? = nil) {
    guard let window = self.window else { fatalError("make sure the window exists before animating") }
    let isLegacy: Bool = legacy ?? Preference.bool(for: .useLegacyFullScreen)
    log.verbose("EnterFullScreen called (legacy: \(isLegacy.yn))")
    guard !currentLayout.isFullScreen else { return }

    if isLegacy {
      animateEntryIntoFullScreen(withDuration: CocoaAnimation.FullScreenTransitionDuration, isLegacy: true)
    } else {
      window.toggleFullScreen(self)
    }
  }

  func exitFullScreen(legacy: Bool) {
    guard let window = self.window else { fatalError("make sure the window exists before animating") }
    log.verbose("ExitFullScreen called (legacy: \(legacy.yn))")
    guard currentLayout.isFullScreen else { return }

    if legacy {
      animateExitFromFullScreen(withDuration: CocoaAnimation.FullScreenTransitionDuration, isLegacy: true)
    } else {
      window.toggleFullScreen(self)
    }
  }

  // MARK: - Window Delegate: window move, screen changes

  func windowDidChangeBackingProperties(_ notification: Notification) {
    log.verbose("WindowDidChangeBackingProperties()")
    if let oldScale = (notification.userInfo?[NSWindow.oldScaleFactorUserInfoKey] as? NSNumber)?.doubleValue,
       let window = window, oldScale != Double(window.backingScaleFactor) {
      log.verbose("WindowDidChangeBackingProperties: scale factor changed from \(oldScale) to \(Double(window.backingScaleFactor))")

      videoView.videoLayer.contentsScale = window.backingScaleFactor

      // Do not allow MacOS to change the window size:
      denyNextWindowResize = true
    }
  }

  func windowDidChangeScreen(_ notification: Notification) {
    guard let window = window else { return }
    log.verbose("WindowDidChangeScreen, frame=\(window.frame)")
    videoView.updateDisplayLink()
    player.events.emit(.windowScreenChanged)

    if currentLayout.isLegacyFullScreen {
      /// Need to recompute legacy FS's window size so it exactly fills the new screen.
      /// But looks like the OS will try to reposition the window on its own and can't be stopped...
      /// Just wait until after it does its thing before calling `setFrame()`.
      // TODO: in the future, keep strict track of window size & position, and call
      /// `setFrame()` in `windowDidMove()` to preserve correctness
      if currentLayout.isLegacyFullScreen {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in
          animationQueue.run(CocoaAnimation.Task({ [self] in
            let newGeo = windowedModeGeometry.clone(windowFrame: bestScreen.frame)
            setWindowFrameForLegacyFullScreen(using: newGeo)
          }))
        }
      }
      return
    }
  }

  func windowWillMove(_ notification: Notification) {
    guard let window = window else { return }
    log.verbose("WindowWillMove, frame=\(window.frame)")
  }

  func windowDidMove(_ notification: Notification) {
    guard !isAnimating else { return }
    guard let window = window else { return }
    log.verbose("WindowDidMove, frame=\(window.frame)")
    updateCachedGeometry()
    player.saveState()
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
    // keyWindow is another PlayerWindow: Switched to another video window
    if NSApp.keyWindow == nil || (NSApp.keyWindow?.windowController is PlayerWindowController) {
      if Preference.bool(for: .pauseWhenInactive), player.info.isPlaying {
        player.pause()
        isPausedDueToInactive = true
      }
    }
  }

  func windowDidBecomeMain(_ notification: Notification) {
    log.verbose("Window became main: \(player.subsystem.rawValue)")

    PlayerCore.lastActive = player
    if #available(macOS 10.13, *), RemoteCommandController.useSystemMediaControl {
      NowPlayingInfoManager.updateInfo(withTitle: true)
    }
    (NSApp.delegate as? AppDelegate)?.menuController?.updatePluginMenu()

    if isFullScreen && Preference.bool(for: .blackOutMonitor) {
      blackOutOtherMonitors()
    }
    player.events.emit(.windowMainStatusChanged, data: true)
    NotificationCenter.default.post(name: .iinaPlayerWindowChanged, object: true)
  }

  func windowDidResignMain(_ notification: Notification) {
    log.verbose("Window is no longer main: \(player.subsystem.rawValue)")

    if Preference.bool(for: .blackOutMonitor) {
      removeBlackWindows()
    }
    player.events.emit(.windowMainStatusChanged, data: false)
    NotificationCenter.default.post(name: .iinaPlayerWindowChanged, object: false)
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
    updateCachedGeometry()
    player.saveState()
    player.events.emit(.windowMiniaturized)
  }

  func windowDidDeminiaturize(_ notification: Notification) {
    log.verbose("Window did deminiaturize")
    if Preference.bool(for: .pauseWhenMinimized) && isPausedDueToMiniaturization {
      player.resume()
      isPausedDueToMiniaturization = false
    }
    if Preference.bool(for: .togglePipByMinimizingWindow) && !isWindowMiniaturizedDueToPip {
      if #available(macOS 10.12, *) {
        exitPIP()
      }
    }
    updateCachedGeometry()
    player.saveState()
    player.events.emit(.windowDeminiaturized)
  }

  // MARK: - UI: Show / Hide Fadeable Views

  func isUITimerNeeded() -> Bool {
    log.verbose("Checking if UITimer needed. hasPermanentOSC: \(currentLayout.hasPermanentOSC), fadeableViews: \(fadeableViewsAnimationState), topBar: \(fadeableTopBarAnimationState), OSD: \(osdAnimationState)")

    if currentLayout.hasPermanentOSC {
      return true
    }
    let showingFadeableViews = fadeableViewsAnimationState == .shown || fadeableViewsAnimationState == .willShow
    let showingFadeableTopBar = fadeableTopBarAnimationState == .shown || fadeableViewsAnimationState == .willShow
    let showingOSD = osdAnimationState == .shown || osdAnimationState == .willShow
    return showingFadeableViews || showingFadeableTopBar || showingOSD
  }

  // Shows fadeableViews and titlebar via fade
  func showFadeableViews(thenRestartFadeTimer restartFadeTimer: Bool = true, duration: CGFloat = CocoaAnimation.DefaultDuration,
                                 forceShowTopBar: Bool = false) {
    let animationTasks: [CocoaAnimation.Task] = buildAnimationToShowFadeableViews(restartFadeTimer: restartFadeTimer, duration: duration,
                                                                               forceShowTopBar: forceShowTopBar)
    animationQueue.run(animationTasks)
  }

  func buildAnimationToShowFadeableViews(restartFadeTimer: Bool = true, duration: CGFloat = CocoaAnimation.DefaultDuration,
                                         forceShowTopBar: Bool = false) -> [CocoaAnimation.Task] {
    var animationTasks: [CocoaAnimation.Task] = []

    let showTopBar = forceShowTopBar || Preference.enum(for: .showTopBarTrigger) == Preference.ShowTopBarTrigger.windowHover

    guard !player.disableUI && !isInInteractiveMode else {
      return animationTasks
    }

    guard showTopBar || fadeableViewsAnimationState == .hidden else {
      if restartFadeTimer {
        resetFadeTimer()
      } else {
        destroyFadeTimer()
      }
      return animationTasks
    }

    let currentLayout = self.currentLayout

    animationTasks.append(CocoaAnimation.Task(duration: duration, { [self] in
      log.verbose("Showing fadeable views")
      fadeableViewsAnimationState = .willShow
      player.refreshSyncUITimer()
      destroyFadeTimer()

      for v in fadeableViews {
        v.animator().alphaValue = 1
      }

      if showTopBar {
        fadeableTopBarAnimationState = .willShow
        for v in fadeableViewsTopBar {
          v.animator().alphaValue = 1
        }
      }
    }))

    // Not animated, but needs to wait until after fade is done
    animationTasks.append(CocoaAnimation.zeroDurationTask { [self] in
      // if no interrupt then hide animation
      if fadeableViewsAnimationState == .willShow {
        fadeableViewsAnimationState = .shown
        for v in fadeableViews {
          v.isHidden = false
        }

        if restartFadeTimer {
          resetFadeTimer()
        }
      }

      if showTopBar && fadeableTopBarAnimationState == .willShow {
        fadeableTopBarAnimationState = .shown
        for v in fadeableViewsTopBar {
          v.isHidden = false
        }
        /// Special case for `trafficLightButtons` due to AppKit quirk
        if currentLayout.trafficLightButtons == .showFadeableTopBar {
          for button in trafficLightButtons {
            button.isHidden = false
          }
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
    guard pipStatus == .notInPIP && fadeableViewsAnimationState == .shown else {
      return false
    }

    var animationTasks: [CocoaAnimation.Task] = []

    animationTasks.append(CocoaAnimation.Task{ [self] in
      // Don't hide overlays when in PIP or when they are not actually shown
      log.verbose("Hiding fadeable views")

      destroyFadeTimer()
      fadeableViewsAnimationState = .willHide
      fadeableTopBarAnimationState = .willHide
      player.refreshSyncUITimer()

      for v in fadeableViews {
        v.animator().alphaValue = 0
      }
      for v in fadeableViewsTopBar {
        v.animator().alphaValue = 0
      }
      /// Quirk 1: special handling for `trafficLightButtons`
      if currentLayout.trafficLightButtons == .showFadeableTopBar {
        for button in trafficLightButtons {
          button.alphaValue = 0
        }
      }
    })

    animationTasks.append(CocoaAnimation.zeroDurationTask { [self] in
      // if no interrupt then hide animation
      guard fadeableViewsAnimationState == .willHide else { return }

      fadeableViewsAnimationState = .hidden
      fadeableTopBarAnimationState = .hidden
      for v in fadeableViews {
        v.isHidden = true
      }
      for v in fadeableViewsTopBar {
        v.isHidden = true
      }
      /// Quirk 1: need to set `alphaValue` back to `1` so that each button's corresponding menu items still work
      if currentLayout.trafficLightButtons == .showFadeableTopBar {
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

  func resetFadeTimer() {
    // If timer exists, destroy first
    destroyFadeTimer()

    // Create new timer.
    // Timer and animation APIs require Double, but we must support legacy prefs, which store as Float
    var timeout = Double(Preference.float(for: .controlBarAutoHideTimeout))
    if timeout < CocoaAnimation.DefaultDuration {
      timeout = CocoaAnimation.DefaultDuration
    }
    hideFadeableViewsTimer = Timer.scheduledTimer(timeInterval: TimeInterval(timeout), target: self, selector: #selector(self.hideFadeableViewsAndCursor), userInfo: nil, repeats: false)
    hideFadeableViewsTimer?.tolerance = 0.1
  }

  private func destroyFadeTimer() {
    if let hideFadeableViewsTimer = hideFadeableViewsTimer {
      hideFadeableViewsTimer.invalidate()
      self.hideFadeableViewsTimer = nil
    }
  }

  func updatePlayTime(withDuration duration: Bool) {
    // IINA listens for changes to mpv properties such as chapter that can occur during file loading
    // resulting in this function being called before mpv has set its position and duration
    // properties. Confirm the window and file have been loaded.
    guard loaded, player.info.fileLoaded else { return }
    // The mpv documentation for the duration property indicates mpv is not always able to determine
    // the video duration in which case the property is not available.
    guard let duration = player.info.videoDuration else {
      Logger.log("Video duration not available", subsystem: player.subsystem)
      return
    }
    guard let pos = player.info.videoPosition else {
      Logger.log("Video position not available", subsystem: player.subsystem)
      return
    }

    if osdAnimationState == .shown, let osdLastMessage = self.osdLastMessage {
      let message: OSDMessage?
      switch osdLastMessage {
      case .pause, .resume:
        message = osdLastMessage
      case .seek(_, _):
        message = .seek(videoPosition: player.info.videoPosition, videoDuration: player.info.videoDuration)
      default:
        message = nil
      }

      if let message = message {
        setOSDViews(fromMessage: message)
      }
    }

    let percentage = (pos.second / duration.second) * 100
    if player.isInMiniPlayer {
      // Music mode
      _ = player.windowController.miniPlayer.view // make sure it is loaded
      player.windowController.miniPlayer.playSlider.doubleValue = percentage
      [player.windowController.miniPlayer.leftLabel, player.windowController.miniPlayer.rightLabel].forEach { $0.updateText(with: duration, given: pos) }
    } else {
      // Normal player
      [leftLabel, rightLabel].forEach { $0.updateText(with: duration, given: pos) }
      playSlider.doubleValue = percentage
    }
    // Touch bar
    if #available(macOS 10.12.2, *) {
      player.touchBarSupport.touchBarPlaySlider?.setDoubleValueSafely(percentage)
      player.touchBarSupport.touchBarPosLabels.forEach { $0.updateText(with: duration, given: pos) }
    }
  }

  // MARK: - UI: Title

  @objc
  func updateTitle() {
    if player.isInMiniPlayer {
      let (mediaTitle, mediaAlbum, mediaArtist) = player.getMusicMetadata()
      window?.title = mediaTitle
      _ = miniPlayer.view
      miniPlayer.updateTitle(mediaTitle: mediaTitle, mediaAlbum: mediaAlbum, mediaArtist: mediaArtist)
    } else if player.info.isNetworkResource {
      window?.title = player.getMediaTitle()
    } else {
      window?.representedURL = player.info.currentURL
      // Workaround for issue #3543, IINA crashes reporting:
      // NSInvalidArgumentException [NSNextStepFrame _displayName]: unrecognized selector
      // When running on an M1 under Big Sur and using legacy full screen.
      //
      // Changes in Big Sur broke the legacy full screen feature. The PlayerWindowController method
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

  // MARK: - UI: OSD

  private func updateOSDPosition() {
    guard let contentView = window?.contentView else { return }
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

  private func setOSDViews(fromMessage message: OSDMessage) {
    osdLastMessage = message

    let (osdString, osdType) = message.message()
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
      osdStackView.setVisibilityPriority(.mustHold, for: osdAccessoryText)
      osdStackView.setVisibilityPriority(.notVisible, for: osdAccessoryProgress)

      // data for mustache redering
      let osdData: [String: String] = [
        "duration": player.info.videoDuration?.stringRepresentation ?? Constants.String.videoTimePlaceholder,
        "position": player.info.videoPosition?.stringRepresentation ?? Constants.String.videoTimePlaceholder,
        "currChapter": (player.mpv.getInt(MPVProperty.chapter) + 1).description,
        "chapterCount": player.info.chapters.count.description
      ]
      osdAccessoryText.stringValue = try! (try! Template(string: text)).render(osdData)
    }
  }

  // Do not call displayOSD directly. Call PlayerCore.sendOSD instead.
  func displayOSD(_ message: OSDMessage, autoHide: Bool = true, forcedTimeout: Double? = nil, accessoryView: NSView? = nil, context: Any? = nil) {
    guard player.enableOSD && !isShowingPersistentOSD && !isInInteractiveMode else { return }

    if let hideOSDTimer = self.hideOSDTimer {
      hideOSDTimer.invalidate()
      self.hideOSDTimer = nil
    }
    if osdAnimationState != .shown {
      osdAnimationState = .shown  /// set this before calling `refreshSyncUITimer()`
      player.refreshSyncUITimer()
    } else {
      osdAnimationState = .shown
    }
    let osdTextSize = Preference.float(for: .osdTextSize)
    osdLabel.font = NSFont.monospacedDigitSystemFont(ofSize: CGFloat(osdTextSize), weight: .regular)
    osdAccessoryText.font = NSFont.monospacedDigitSystemFont(ofSize: CGFloat(osdTextSize * 0.5).clamped(to: 11...25), weight: .regular)

    setOSDViews(fromMessage: message)

    osdVisualEffectView.alphaValue = 1
    osdVisualEffectView.isHidden = false
    fadeableViews.remove(osdVisualEffectView)

    osdVisualEffectView.layoutSubtreeIfNeeded()
    if autoHide {
      let timeout: Double
      if let forcedTimeout = forcedTimeout {
        timeout = forcedTimeout
      } else {
        // Timer and animation APIs require Double, but we must support legacy prefs, which store as Float
        let configuredTimeout = Double(Preference.float(for: .osdAutoHideTimeout))
        timeout = configuredTimeout <= CocoaAnimation.OSDAnimationDuration ? CocoaAnimation.OSDAnimationDuration : configuredTimeout
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

      accessoryView.wantsLayer = true
      accessoryView.layer?.opacity = 0

      CocoaAnimation.runAsync(CocoaAnimation.Task(duration: CocoaAnimation.OSDAnimationDuration, { [self] in
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
    if let hideOSDTimer = self.hideOSDTimer {
      hideOSDTimer.invalidate()
      self.hideOSDTimer = nil
    }

    player.refreshSyncUITimer()

    CocoaAnimation.runAsync(CocoaAnimation.Task(duration: CocoaAnimation.OSDAnimationDuration, { [self] in
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
    guard isFullScreen && displayTimeAndBatteryInFullScreen && !additionalInfoView.isHidden else {
      return
    }

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
    guard let origVideoSize = player.videoBaseDisplaySize, origVideoSize.width != 0 && origVideoSize.height != 0 else {
      Utility.showAlert("no_video_track")
      return
    }
    guard let window = self.window else { return }

    if #available(macOS 10.14, *) {
      videoContainerView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    } else {
      videoContainerView.layer?.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 1).cgColor
    }

    // TODO: use key interceptor to support ESC and ENTER keys for interactive mode

    /// Start by hiding OSC and/or "outside" panels, which aren't needed and might mess up the layout.
    /// We can do this by creating a `LayoutSpec`, then using it to build a `LayoutTransition` and executing its animation.
    let oldLayout = currentLayout
    let interactiveModeLayout = oldLayout.spec.clone(leadingSidebar: oldLayout.leadingSidebar.clone(visibility: .hide),
                                                     trailingSidebar: oldLayout.trailingSidebar.clone(visibility: .hide),
                                                     mode: oldLayout.spec.mode,
                                                     topBarPlacement: .insideVideo,
                                                     enableOSC: false)
    let transition = buildLayoutTransition(named: "EnterInteractiveMode", from: oldLayout, to: interactiveModeLayout, totalEndingDuration: 0)
    var animationTasks: [CocoaAnimation.Task] = transition.animationTasks

    // Now animate into Interactive Mode:
    animationTasks.append(CocoaAnimation.Task(duration: CocoaAnimation.CropAnimationDuration, timing: .easeIn, { [self] in

      hideFadeableViews()
      hideOSD()

      isPausedPriorToInteractiveMode = player.info.isPaused
      player.pause()

      let cropController = mode.viewController()
      cropController.windowController = self
      bottomView.isHidden = false
      bottomView.addSubview(cropController.view)
      Utility.quickConstraints(["H:|[v]|", "V:|[v]|"], ["v": cropController.view])

      isInInteractiveMode = true
      let titleBarHeight = PlayerWindowController.standardTitleBarHeight
      // VideoView's top bezel must be at least as large as the title bar so that dragging the top of crop doesn't drag the window too
      // the max region that the video view can occupy
      let newVideoViewBounds = NSRect(x: titleBarHeight,
                                      y: InteractiveModeBottomViewHeight + titleBarHeight,
                                      width: window.frame.width - titleBarHeight - titleBarHeight,
                                      height: window.frame.height - InteractiveModeBottomViewHeight - titleBarHeight - titleBarHeight)
      let newVideoViewSize = origVideoSize.shrink(toSize: newVideoViewBounds.size)
      let newVideoViewFrame = newVideoViewBounds.centeredResize(to: newVideoViewSize)

      bottomBarBottomConstraint.animateToConstant(0)
      videoView.constrainLayoutToEqualsOffsetOnly(
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

    animationTasks.append(CocoaAnimation.zeroDurationTask { [self] in
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

    log.verbose("Entering interactive mode")
    animationQueue.run(animationTasks)
  }

  func exitInteractiveMode(immediately: Bool = false, then doAfter: @escaping () -> Void = {}) {
    guard let cropController = cropSettingsView else { return }
    let oldLayout = currentLayout
    // if exit without animation
    let duration: CGFloat = immediately ? 0 : CocoaAnimation.CropAnimationDuration
    cropController.cropBoxView.isHidden = true

    var animationTasks: [CocoaAnimation.Task] = []

    animationTasks.append(CocoaAnimation.Task(duration: duration, timing: .easeIn, { [self] in
      // Restore prev constraints:
      bottomBarBottomConstraint.animateToConstant(-InteractiveModeBottomViewHeight)
      videoView.constrainForNormalLayout()
    }))

    animationTasks.append(CocoaAnimation.zeroDurationTask { [self] in
      cropController.cropBoxView.removeFromSuperview()
      self.bottomView.subviews.removeAll()
      self.bottomView.isHidden = true
      self.showFadeableViews(duration: 0)
      videoContainerView.layer?.backgroundColor = .black

      if !isPausedPriorToInteractiveMode {
        player.resume()
      }
      isInInteractiveMode = false
      self.cropSettingsView = nil
    })

    let transition = buildLayoutTransition(named: "ExitInteractiveMode", from: oldLayout, to: LayoutSpec.fromPreferences(andSpec: oldLayout.spec),
                                           totalStartingDuration: duration * 0.5, totalEndingDuration: duration * 0.5)

    animationTasks.append(contentsOf: transition.animationTasks)

    log.verbose("Exiting interactive mode")
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
  private func updateTimeLabelAndThumbnail(_ mouseXPos: CGFloat, originalPos: NSPoint) {
    timePreviewWhenSeekHorizontalCenterConstraint.constant = mouseXPos

    guard let duration = player.info.videoDuration else { return }
    let percentage = max(0, Double((mouseXPos - 3) / (playSlider.frame.width - 6)))
    let previewTime = duration * percentage
    guard timePreviewWhenSeek.stringValue != previewTime.stringRepresentation else { return }

//    Logger.log("Updating seek time indicator to: \(previewTime.stringRepresentation)", level: .verbose, subsystem: player.subsystem)
    timePreviewWhenSeek.stringValue = previewTime.stringRepresentation

    if player.info.thumbnailsReady, let image = player.info.getThumbnail(forSecond: previewTime.second)?.image,
        let totalRotation = player.info.totalRotation {

      let thumbWidth = image.size.width
      var thumbHeight = image.size.height
      let rawAspect = thumbWidth / thumbHeight

      if let dwidth = player.info.videoDisplayWidth, let dheight = player.info.videoDisplayHeight,
         player.info.thumbnailWidth > 0 {
        // The aspect ratio of some videos is different at display time. May need to resize these videos
        // once the actual aspect ratio is known. (Should they be resized before being stored on disk? Doing so
        // would increase the file size without improving the quality, whereas resizing on the fly seems fast enough).
        let dAspect = Double(dwidth) / Double(dheight)
        if rawAspect != dAspect {
          thumbHeight = CGFloat((Double(thumbWidth) / dAspect).rounded())
        }
      }

      let imageToDisplay = image.rotate(totalRotation).resized(newWidth: thumbWidth, newHeight: thumbHeight)
      let thumbnailSize = imageToDisplay.size

      thumbnailPeekView.imageView.image = imageToDisplay

      if videoView.frame.height < thumbnailSize.height {
        thumbnailPeekView.frame.size = thumbnailSize.shrink(toSize: videoView.frame.size)
      } else {
        thumbnailPeekView.frame.size = thumbnailSize
      }
      log.verbose("Displaying thumbnail: \(thumbnailSize.width) W x \(thumbnailSize.height) H")
      thumbnailPeekView.isHidden = false
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

  func updateWindowParametersForMPV(withSize videoSize: CGSize? = nil) {
    guard let videoWidth = player.videoBaseDisplaySize?.width, videoWidth > 0 else {
      log.debug("Skipping send to mpv windowScale; could not get width from videoBaseDisplaySize")
      return
    }

    log.verbose("Sending mpv windowScale\(videoSize == nil ? "" : " given videoSize \(videoSize!)")")
    // this is also a good place to save state, if applicable

    let videoScale = Double((videoSize ?? windowedModeGeometry.videoSize).width) / Double(videoWidth)
    let prevVideoScale = player.info.cachedWindowScale
    if videoScale != prevVideoScale {
      log.verbose("Sending mpv windowScale: \(player.info.cachedWindowScale) → \(videoScale)")
      player.info.cachedWindowScale = videoScale
      player.mpv.setDouble(MPVProperty.windowScale, videoScale)
    }
  }

  // MARK: - UI: Others

  @discardableResult
  func abLoop() -> Int32 {
    let returnValue = player.abLoop()
    if returnValue == 0 {
      syncPlaySliderABLoop()
    }
    return returnValue
  }

  func syncPlaySliderABLoop() {
    let a = player.abLoopA
    let b = player.abLoopB
    if let slider = player.isInMiniPlayer ? player.windowController.playSlider : playSlider {
      slider.abLoopA.isHidden = a == 0
      slider.abLoopA.doubleValue = secondsToPercent(a)
      slider.abLoopB.isHidden = b == 0
      slider.abLoopB.doubleValue = secondsToPercent(b)
      slider.needsDisplay = true
    }
  }

  /// Returns the percent of the total duration of the video the given position in seconds represents.
  ///
  /// The percentage returned must be considered an estimate that could change. The duration of the video is obtained from the
  /// [mpv](https://mpv.io/manual/stable/) `duration` property. The documentation for this property cautions that mpv
  /// is not always able to determine the duration and when it does return a duration it may be an estimate. If the duration is unknown
  /// this method will fallback to using the current playback position, if that is known. Otherwise this method will return zero.
  /// - Parameter seconds: Position in the video as seconds from start.
  /// - Returns: The percent of the video the given position represents.
  private func secondsToPercent(_ seconds: Double) -> Double {
    if let duration = player.info.videoDuration?.second {
      return duration == 0 ? 0 : seconds / duration * 100
    } else if let position = player.info.videoPosition?.second {
      return position == 0 ? 0 : seconds / position * 100
    } else {
      return 0
    }
  }

  func updateVolumeUI() {
    guard loaded else { return }
    if let volumeSlider = player.isInMiniPlayer ? player.windowController.miniPlayer.volumeSlider : volumeSlider {
      volumeSlider.maxValue = Double(Preference.integer(for: .maxVolume))
      volumeSlider.doubleValue = player.info.volume
    }
    if let muteButton = player.isInMiniPlayer ? player.windowController.miniPlayer.muteButton : muteButton {
      muteButton.state = player.info.isMuted ? .on : .off
    }
    if player.isInMiniPlayer {
      miniPlayer.updateVolumeUI()
    }
  }

  func enterMusicMode() {
    animationQueue.runZeroDuration { [self] in
      /// Start by hiding OSC and/or "outside" panels, which aren't needed and might mess up the layout.
      /// We can do this by creating a `LayoutSpec`, then using it to build a `LayoutTransition` and executing its animation.
      let oldLayout = currentLayout
      let miniPlayerLayout = oldLayout.spec.clone(mode: .musicMode)
      buildLayoutTransition(named: "EnterMusicMode", from: oldLayout, to: miniPlayerLayout, thenRun: true)
    }
  }

  func exitMusicMode() {
    animationQueue.runZeroDuration { [self] in
      /// Start by hiding OSC and/or "outside" panels, which aren't needed and might mess up the layout.
      /// We can do this by creating a `LayoutSpec`, then using it to build a `LayoutTransition` and executing its animation.
      let miniPlayerLayout = currentLayout
      
      let newSpec = miniPlayerLayout.spec.clone(mode: .windowed)
      let windowedLayout = LayoutSpec.fromPreferences(andSpec: newSpec)
      buildLayoutTransition(named: "ExitMusicMode", from: miniPlayerLayout, to: windowedLayout, thenRun: true)
    }
  }

  func blackOutOtherMonitors() {
    let screens = NSScreen.screens.filter { $0 != window?.screen }

    blackWindows = []

    for screen in screens {
      var screenRect = screen.frame
      screenRect.origin = CGPoint(x: 0, y: 0)
      let blackWindow = NSWindow(contentRect: screenRect, styleMask: [], backing: .buffered, defer: false, screen: screen)
      blackWindow.backgroundColor = .black
      blackWindow.level = .iinaBlackScreen

      blackWindows.append(blackWindow)
      blackWindow.orderFront(nil)
    }
    log.verbose("Added black windows for \(screens.count); total is now: \(blackWindows.count)")
  }

  func removeBlackWindows() {
    for window in blackWindows {
      window.orderOut(self)
    }
    blackWindows = []
    log.verbose("Removed all black windows")
  }

  func setWindowFloatingOnTop(_ onTop: Bool, updateOnTopStatus: Bool = true) {
    guard !isFullScreen else { return }
    guard let window = window else { return }
    window.level = onTop ? .iinaFloating : .normal
    if (updateOnTopStatus) {
      self.isOntop = onTop
    }
    resetCollectionBehavior()
  }

  // MARK: - Sync UI with playback

  func updatePlayButtonState(_ state: NSControl.StateValue) {
    guard loaded else { return }
    if let playButton = player.isInMiniPlayer ? player.windowController.miniPlayer.playButton : playButton {
      playButton.state = state
    }

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

  func updateMusicModeButtonsVisibility() {
    closeButtonBackgroundViewVE.isHidden = !player.isInMiniPlayer || !miniPlayer.isVideoVisible
    closeButtonBackgroundViewBox.isHidden = !player.isInMiniPlayer || miniPlayer.isVideoVisible
  }

  // MARK: - IBActions

  @objc func menuSwitchToMiniPlayer(_ sender: NSMenuItem) {
    if player.isInMiniPlayer {
      player.exitMusicMode()
    } else {
      player.enterMusicMode()
    }
  }

  @IBAction func volumeSliderChanges(_ sender: NSSlider) {
    let value = sender.doubleValue
    if Preference.double(for: .maxVolume) > 100, value > 100 && value < 101 {
      NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
    }
    player.setVolume(value)
  }

  @IBAction func backBtnAction(_ sender: NSButton) {
    player.exitMusicMode()
  }

  @IBAction func playButtonAction(_ sender: NSButton) {
    player.info.isPaused ? player.resume() : player.pause()
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

  @IBAction func muteButtonAction(_ sender: NSButton) {
    player.toggleMute()
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
           Date().timeIntervalSince(lastClick) < AppData.minimumPressDuration) { // Single click ended, 2x speed
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
           Date().timeIntervalSince(lastClick) < AppData.minimumPressDuration) { // Single click ended
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
  @IBAction func playSliderChanges(_ sender: NSSlider) {
    guard !player.info.fileLoading else { return }

    let percentage = 100 * sender.doubleValue / sender.maxValue
    player.seek(percent: percentage, forceExact: !followGlobalSeekTypeWhenAdjustSlider)

    // update position of time label
    timePreviewWhenSeekHorizontalCenterConstraint.constant = sender.knobPointPosition() - playSlider.frame.origin.x

    // update text of time label
    let seekTime = player.info.videoDuration! * percentage * 0.01
    log.debug("PlaySliderChanged: setting seek time label to \(seekTime.stringRepresentation.quoted)")
    timePreviewWhenSeek.stringValue = seekTime.stringRepresentation
  }

  @objc func toolBarButtonAction(_ sender: NSButton) {
    guard let buttonType = Preference.ToolBarButton(rawValue: sender.tag) else { return }
    switch buttonType {
    case .fullScreen:
      toggleWindowFullScreen()
    case .musicMode:
      player.enterMusicMode()
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

  func handleIINACommand(_ cmd: IINACommand) {
    let appDelegate = (NSApp.delegate! as! AppDelegate)
    switch cmd {
    case .openFile:
      appDelegate.openFile(self)
    case .openURL:
      appDelegate.openURL(self)
    case .flip:
      menuToggleFlip(.dummy)
    case .mirror:
      menuToggleMirror(.dummy)
    case .saveCurrentPlaylist:
      menuSavePlaylist(.dummy)
    case .deleteCurrentFile:
      menuDeleteCurrentFile(.dummy)
    case .findOnlineSubs:
      menuFindOnlineSub(.dummy)
    case .saveDownloadedSub:
      saveDownloadedSub(.dummy)
    case .toggleMusicMode:
      menuSwitchToMiniPlayer(.dummy)
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
    }
  }

  func resetCollectionBehavior() {
    guard !isFullScreen else { return }
    if Preference.bool(for: .useLegacyFullScreen) {
      window?.collectionBehavior = [.managed, .fullScreenAuxiliary]
    } else {
      window?.collectionBehavior = [.managed, .fullScreenPrimary]
    }
  }

}

// MARK: - Picture in Picture

@available(macOS 10.12, *)
extension PlayerWindowController: PIPViewControllerDelegate {

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
      showWindow(self)
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
    if isFullScreen {
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
