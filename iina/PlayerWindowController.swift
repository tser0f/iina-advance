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

fileprivate let thumbnailExtraOffsetX: CGFloat = 12
fileprivate let thumbnailExtraOffsetY: CGFloat = 12

// MARK: - Constants

class PlayerWindowController: NSWindowController, NSWindowDelegate {
  enum TrackingArea: Int {
    static let key: String = "area"

    case playerWindow = 0
    case playSlider
    case customTitleBar
  }

  unowned var player: PlayerCore
  unowned var log: Logger.Subsystem {
    return player.log
  }

  override var windowNibName: NSNib.Name {
    return NSNib.Name("PlayerWindowController")
  }

  @objc var videoView: VideoView {
    return player.videoView
  }

  var loaded = false
  private var thumbDisplayCounter: Int = 0

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
  var cachedScreens: [UInt32: ScreenMeta] = PlayerWindowController.buildScreenMap()
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

  var miniPlayer: MiniPlayerController!

  /** The control view for interactive mode. */
  var cropSettingsView: CropBoxViewController?

  // For legacy windowed mode
  var customTitleBar: CustomTitleBarViewController? = nil

  // For Rotate gesture:
  let rotationHandler = VideoRotationHandler()

  // For Pinch To Magnify gesture:
  let magnificationHandler = VideoMagnificationHandler()

  let animationPipeline = IINAAnimation.Pipeline()

  // MARK: - Status

  var isAnimating: Bool {
    return animationPipeline.isRunning
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
    // Also check if hidden due to PIP, or minimized
    return window.isVisible || isWindowHidden || window.isMiniaturized
  }
  private(set) var isWindowHidden: Bool = false

  var isClosing = false
  var shouldApplyInitialWindowSize = true
  var isWindowMiniturized = false
  var isWindowMiniaturizedDueToPip = false
  var isWindowPipDueToInactiveSpace = false

  var isMagnifying = false
  var denyNextWindowResize = false
  var modeToSetAfterExitingFullScreen: WindowMode? = nil

  var isPausedDueToInactive: Bool = false
  var isPausedDueToMiniaturization: Bool = false
  var isPausedPriorToInteractiveMode: Bool = false

  var floatingOscCenterRatioH = CGFloat(Preference.float(for: .controlBarPositionHorizontal))
  var floatingOSCOriginRatioV = CGFloat(Preference.float(for: .controlBarPositionVertical))

  // - Mouse

  var mousePosRelatedToWindow: CGPoint?
  var isDragging: Bool = false
  var isLiveResizingWidth = false

  // might use another obj to handle slider?
  var isMouseInWindow: Bool = false

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

  var pipStatus = PIPStatus.notInPIP

  var currentLayout: LayoutState = LayoutState(spec: LayoutSpec.defaultLayout())

  // Used to assign an incrementing unique ID to each geometry update animation request, so that frequent requests don't
  // build up and result in weird freezes or short episodes of "wandering window"
  var geoUpdateTicketCount: Int = 0

  var windowedModeGeometry: PlayerWindowGeometry! {
    didSet {
      log.verbose("Updated windowedModeGeometry to \(windowedModeGeometry!)")
      assert(!windowedModeGeometry.fitOption.isFullScreen, "windowedModeGeometry has invalid fitOption: \(windowedModeGeometry.fitOption)")
    }
  }

  var musicModeGeometry: MusicModeGeometry! {
    didSet {
      log.verbose("Updated musicModeGeometry to \(musicModeGeometry!)")
    }
  }

  // Only used when in interactive mode. Discarded after exiting interactive mode.
  var interactiveModeGeometry: InteractiveModeGeometry? = nil

  // MARK: - Enums

  // Window state

  enum PIPStatus {
    case notInPIP
    case inPIP
    case intermediate
  }

  enum InteractiveMode: Int {
    case crop = 1
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
    .hideWindowsWhenInactive,
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
    .thumbnailSizeOption,
    .thumbnailFixedLength,
    .thumbnailRawSizePercentage,
    .thumbnailDisplayedSizePercentage,
    .thumbnailBorderStyle,
    .enableThumbnailRoundedCorners,
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
    .lockViewportToVideoSize,
    .allowVideoToOverlapCameraHousing,
  ]

  override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
    guard let keyPath = keyPath, let change = change else { return }

    switch keyPath {
    case PK.themeMaterial.rawValue:
      applyThemeMaterial()
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
      PK.oscBarToolbarIconSize.rawValue,
      PK.oscBarToolbarIconSpacing.rawValue,
      PK.showLeadingSidebarToggleButton.rawValue,
      PK.showTrailingSidebarToggleButton.rawValue,
      PK.controlBarToolbarButtons.rawValue,
      PK.allowVideoToOverlapCameraHousing.rawValue,
      PK.useLegacyWindowedMode.rawValue:

      updateTitleBarAndOSC()
    case PK.lockViewportToVideoSize.rawValue:
      if let isLocked = change[.newKey] as? Bool, isLocked {
        log.debug("Pref \(keyPath.quoted) changed to \(isLocked): resizing viewport to remove any excess space")
        resizeViewport()
      }
    case PK.hideWindowsWhenInactive.rawValue:
      animationPipeline.submitZeroDuration({ [self] in
        refreshHidesOnDeactivateStatus()
      })

    case PK.thumbnailSizeOption.rawValue,
      PK.thumbnailFixedLength.rawValue,
      PK.thumbnailRawSizePercentage.rawValue:
      log.verbose("Pref \(keyPath.quoted) changed: requesting thumbs regen")
      player.reloadThumbnails()

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
      updateUseLegacyFullScreen()
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
      animationPipeline.submit(IINAAnimation.zeroDurationTask {
        self.updateOSDPosition()
      })
    default:
      return
    }
  }

  // MARK: - Outlets

  // - Outlets: Constraints

  var viewportViewHeightContraint: NSLayoutConstraint? = nil

  // Spacers in left title bar accessory view:
  @IBOutlet weak var leadingTitleBarLeadingSpaceConstraint: NSLayoutConstraint!
  @IBOutlet weak var leadingTitleBarTrailingSpaceConstraint: NSLayoutConstraint!

  // Spacers in right title bar accessory view:
  @IBOutlet weak var trailingTitleBarLeadingSpaceConstraint: NSLayoutConstraint!
  @IBOutlet weak var trailingTitleBarTrailingSpaceConstraint: NSLayoutConstraint!

  // - Top bar (title bar and/or top OSC) constraints
  @IBOutlet weak var viewportTopOffsetFromTopBarBottomConstraint: NSLayoutConstraint!
  @IBOutlet weak var viewportTopOffsetFromTopBarTopConstraint: NSLayoutConstraint!
  @IBOutlet weak var viewportTopOffsetFromContentViewTopConstraint: NSLayoutConstraint!
  // Needs to be changed to align with either sidepanel or left of screen:
  @IBOutlet weak var topBarLeadingSpaceConstraint: NSLayoutConstraint!
  // Needs to be changed to align with either sidepanel or right of screen:
  @IBOutlet weak var topBarTrailingSpaceConstraint: NSLayoutConstraint!

  // - Bottom OSC constraints
  @IBOutlet weak var viewportBottomOffsetFromBottomBarTopConstraint: NSLayoutConstraint!
  @IBOutlet weak var viewportBottomOffsetFromBottomBarBottomConstraint: NSLayoutConstraint!
  @IBOutlet var viewportBottomOffsetFromContentViewBottomConstraint: NSLayoutConstraint!
  // Needs to be changed to align with either sidepanel or left of screen:
  @IBOutlet weak var bottomBarLeadingSpaceConstraint: NSLayoutConstraint!
  // Needs to be changed to align with either sidepanel or right of screen:
  @IBOutlet weak var bottomBarTrailingSpaceConstraint: NSLayoutConstraint!

  // - Leading sidebar constraints
  @IBOutlet weak var viewportLeadingOffsetFromContentViewLeadingConstraint: NSLayoutConstraint!
  @IBOutlet weak var viewportLeadingOffsetFromLeadingSidebarLeadingConstraint: NSLayoutConstraint!
  @IBOutlet weak var viewportLeadingOffsetFromLeadingSidebarTrailingConstraint: NSLayoutConstraint!

  @IBOutlet weak var viewportLeadingToLeadingSidebarCropTrailingConstraint: NSLayoutConstraint!

  // - Trailing sidebar constraints
  @IBOutlet weak var viewportTrailingOffsetFromContentViewTrailingConstraint: NSLayoutConstraint!
  @IBOutlet weak var viewportTrailingOffsetFromTrailingSidebarLeadingConstraint: NSLayoutConstraint!
  @IBOutlet weak var viewportTrailingOffsetFromTrailingSidebarTrailingConstraint: NSLayoutConstraint!

  @IBOutlet weak var viewportTrailingToTrailingSidebarCropLeadingConstraint: NSLayoutConstraint!

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
  @IBOutlet var osdLeadingToMiniPlayerButtonsTrailingConstraint: NSLayoutConstraint!

  // Sets the size of the spacer view in the top overlay which reserves space for a title bar:
  @IBOutlet weak var titleBarHeightConstraint: NSLayoutConstraint!
  /// Size of each side of the 3 square playback buttons ⏪⏯️⏩ (`leftArrowButton`, Play/Pause, `rightArrowButton`):
  @IBOutlet weak var playbackButtonsSquareWidthConstraint: NSLayoutConstraint!
  /// Space added to the left and right of *each* of the 3 square playback buttons:
  @IBOutlet weak var playbackButtonsHorizontalPaddingConstraint: NSLayoutConstraint!
  @IBOutlet weak var topOSCHeightConstraint: NSLayoutConstraint!

  @IBOutlet weak var timePositionHoverLabelHorizontalCenterConstraint: NSLayoutConstraint!
  @IBOutlet weak var timePositionHoverLabelVerticalSpaceConstraint: NSLayoutConstraint!
  @IBOutlet weak var playSliderHeightConstraint: NSLayoutConstraint!

  // - Outlets: Views

  // MiniPlayer buttons
  @IBOutlet weak var closeButtonView: NSView!
  // Mini island containing window buttons which hover over album art / video (when video is visible):
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

  /** Panel at top of window. May be `insideViewport` or `outsideViewport`. May contain `titleBarView` and/or `controlBarTop`
   depending on configuration. */
  @IBOutlet weak var topBarView: NSVisualEffectView!
  /** Bottom border of `topBarView`. */
  @IBOutlet weak var topBarBottomBorder: NSBox!
  /** Reserves space for the title bar components. Does not contain any child views. */
  @IBOutlet weak var titleBarView: NSView!
  /** Control bar at top of window, if configured. */
  @IBOutlet weak var controlBarTop: NSView!

  @IBOutlet weak var controlBarFloating: FloatingControlBarView!

  /** Control bar at bottom of window, if configured. May be `insideViewport` or `outsideViewport`. */
  @IBOutlet weak var bottomBarView: NSVisualEffectView!
  /** Top border of `bottomBarView`. */
  @IBOutlet weak var bottomBarTopBorder: NSBox!

  @IBOutlet weak var timePositionHoverLabel: NSTextField!
  @IBOutlet weak var thumbnailPeekView: ThumbnailPeekView!
  @IBOutlet weak var leftArrowButton: NSButton!
  @IBOutlet weak var rightArrowButton: NSButton!

  @IBOutlet weak var leadingSidebarView: NSVisualEffectView!
  @IBOutlet weak var leadingSidebarTrailingBorder: NSBox!  // shown if leading sidebar is "outside"
  @IBOutlet weak var trailingSidebarView: NSVisualEffectView!
  @IBOutlet weak var trailingSidebarLeadingBorder: NSBox!  // shown if trailing sidebar is "outside"
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
  @IBOutlet weak var viewportView: ViewportView!
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

  internal var hideCursorTimer: Timer?

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

  var isInInteractiveMode: Bool {
    return currentLayout.isInteractiveMode
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
      if let window, window.styleMask.contains(.titled) {
        return ([.closeButton, .miniaturizeButton, .zoomButton] as [NSWindow.ButtonType]).compactMap {
          window.standardWindowButton($0)
        }
      }
      return customTitleBar?.trafficLightButtons ?? []
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
    
    miniPlayer = MiniPlayerController()
    miniPlayer.windowController = self

    viewportView.player = player

    // Build default window geometries from preferences and default frame
    windowedModeGeometry = buildWindowGeometryFromCurrentFrame(using: currentLayout)
    musicModeGeometry = miniPlayer.buildMusicModeGeometryFromPrefs()

    loaded = true

    guard let window = window else { return }
    guard let cv = window.contentView else { return }

    window.initialFirstResponder = nil
    window.titlebarAppearsTransparent = true

    viewportView.clipsToBounds = true
    topBarView.clipsToBounds = true
    bottomBarView.clipsToBounds = true

    applyThemeMaterial()

    leftLabel.mode = .current
    rightLabel.mode = Preference.bool(for: .showRemainingTime) ? .remaining : .duration

    updateVolumeUI()

    // size
    window.minSize = AppData.minVideoSize

    // need to deal with control bar, so we handle it manually
    window.isMovableByWindowBackground  = false

    window.backgroundColor = .black

    /// Set this to `false` to get rid of the gray pixel border around the window
//    window.isOpaque = false

    /// Set `viewportView`'s background to black so that the windows behind this one don't bleed through
    /// when `lockViewportToVideoSize` is disabled.
    viewportView.wantsLayer = true
    viewportView.layer?.backgroundColor = .black

    // Titlebar accessories

    // Update this here to reduce animation jitter on older versions of MacOS:
    viewportTopOffsetFromTopBarTopConstraint.constant = PlayerWindowController.standardTitleBarHeight

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
    viewportView.addSubview(defaultAlbumArtView)
    defaultAlbumArtView.addConstraintsToFillSuperview()

    // init quick setting view now
    let _ = quickSettingView

    // other initialization
    osdAccessoryProgress.usesThreadedAnimation = false
    if #available(macOS 10.14, *) {
      topBarBottomBorder.fillColor = NSColor(named: .titleBarBorder)!
    }

    // Do not make visual effects views opaque when window is not in focus
    for view in [topBarView, osdVisualEffectView, bottomBarView, controlBarFloating,
                 leadingSidebarView, trailingSidebarView, osdVisualEffectView, pipOverlayView, bufferIndicatorView] {
      view?.state = .active
    }

    let roundedCornerRadius: CGFloat = 6.0
    bufferIndicatorView.roundCorners(withRadius: roundedCornerRadius)
    osdVisualEffectView.roundCorners(withRadius: roundedCornerRadius)
    additionalInfoView.roundCorners(withRadius: roundedCornerRadius)
    
    if player.disableUI { hideFadeableViews() }

    // add notification observers

    NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: nil, using: { [unowned self] _ in
      // FIXME: this is not ready for production yet! Need to fix issues with freezing video
      guard Preference.bool(for: .togglePipWhenSwitchingSpaces) else { return }
      if !window.isOnActiveSpace && pipStatus == .notInPIP {
        animationPipeline.submitZeroDuration({ [self] in
          log.debug("Window is no longer in active space; entering PIP")
          enterPIP()
          isWindowPipDueToInactiveSpace = true
        })
      } else if window.isOnActiveSpace && isWindowPipDueToInactiveSpace && pipStatus == .inPIP {
        animationPipeline.submitZeroDuration({ [self] in
          log.debug("Window is in active space again; exiting PIP")
          isWindowPipDueToInactiveSpace = false
          exitPIP()
        })
      }
    })

    if #available(macOS 10.15, *) {
      addObserver(to: .default, forName: NSScreen.colorSpaceDidChangeNotification, object: nil) { [unowned self] noti in
        player.refreshEdrMode()
      }
    }

    addObserver(to: .default, forName: .iinaMediaTitleChanged, object: player) { [unowned self] _ in
      self.updateTitle()
    }

    /// The `iinaFileLoaded` event is useful here because it is posted after `fileLoaded`.
    /// This ensures that `info.vid` will have been updated with the current audio track selection, or `0` if none selected.
    /// Before `fileLoaded` it may be `0` (indicating no selection) as the track info is still being processed, which is misleading.
    addObserver(to: .default, forName: .iinaFileLoaded, object: player) { [self] note in
      log.verbose("Got iinaFileLoaded notification")

      thumbnailPeekView.isHidden = true
      timePositionHoverLabel.isHidden = true

      quickSettingView.reload()

      updateTitle()
      playlistView.scrollPlaylistToCurrentItem()

      if Preference.bool(for: .fullScreenWhenOpen) && !isFullScreen && !player.isInMiniPlayer && !player.info.isRestoring {
        log.debug("Changing to fullscreen because \(Preference.Key.fullScreenWhenOpen.rawValue) == true")
        enterFullScreen()
      }
    }

    addObserver(to: .default, forName: .iinaVIDChanged, object: player) { [self] note in
      guard !player.info.fileLoading && player.info.fileLoaded && !player.info.justStartedFile && !player.info.justOpenedFile else { return }
      log.verbose("Got iinaVIDChanged notification")
      refreshAlbumArtDisplay()
    }

    // This observer handles when the user connected a new screen or removed a screen, or shows/hides the Dock.
    NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: self.windowDidChangeScreenParameters)

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

  static func buildScreenMap() -> [UInt32 : ScreenMeta] {
    let newMap = NSScreen.screens.map{ScreenMeta.from($0)}.reduce(Dictionary<UInt32, ScreenMeta>(), {(dict, screenMeta) in
      var dict = dict
      dict[screenMeta.displayID] = screenMeta
      return dict
    })
    Logger.log("Built screen meta: \(newMap.values)", level: .verbose)
    return newMap
  }

  // Check whether to show album art, which may require changing videoView aspect ratio to 1:1.
  // Also show or hide default album art if needed.
  func refreshAlbumArtDisplay() {
    guard loaded, !isClosing, !player.isStopping, !player.isShuttingDown else { return }

    // Make sure these are up-to-date. In some cases (e.g. changing the video track while paused) mpv does not notify
    let videoParams = player.mpv.queryForVideoParams()
    player.info.videoParams = videoParams

    // Part 1: default album art

    let showDefaultArt: Bool
    // if received video size before switching to music mode, hide default album art
    if player.info.isVideoTrackSelected {
      log.verbose("Hiding defaultAlbumArt because vid != 0")
      showDefaultArt = false
    } else {
      log.verbose("Showing defaultAlbumArt because vid = 0")
      showDefaultArt = true
    }

    defaultAlbumArtView.isHidden = !showDefaultArt

    // Part 2: default audio aspect ratio

    let oldAspectRatio = player.info.videoAspectRatio
    let newAspectRatio: CGFloat
    if showDefaultArt || player.currentMediaIsAudio == .isAudio {
      newAspectRatio = 1
    } else {
      // This can also equal 1 if not found
      newAspectRatio = videoParams.videoDisplayRotatedAspect
    }

    guard newAspectRatio.stringTrunc2f != oldAspectRatio.stringTrunc2f else {
      log.verbose("No change to videoAspectRatio; no update needed")
      return
    }
    log.verbose("Updating videoAspectRatio from: \(oldAspectRatio.string2f) to: \(newAspectRatio.stringTrunc2f)")

    let layout = currentLayout
    switch layout.mode {
    case .musicMode:
      let newGeo = musicModeGeometry.clone(videoAspectRatio: newAspectRatio)
      animationPipeline.submit(IINAAnimation.Task(duration: IINAAnimation.DefaultDuration, timing: .easeInEaseOut, { [self] in
        applyMusicModeGeometry(newGeo)
      }))
    case .windowed:
      let viewportSize: NSSize
      if Preference.bool(for: .lockViewportToVideoSize),
         let intendedViewportSize = player.info.intendedViewportSize {
        viewportSize = intendedViewportSize
      } else {
        viewportSize = windowedModeGeometry.viewportSize
      }
      let newGeo = windowedModeGeometry.clone(videoAspectRatio: newAspectRatio).scaleViewport(to: viewportSize, fitOption: .keepInVisibleScreen)
      applyWindowGeometry(newGeo)
    case .fullScreen:
      player.info.videoAspectRatio = newAspectRatio
      guard let screen = window?.screen else { return }
      let fsGeo = layout.buildFullScreenGeometry(inside: screen, videoAspectRatio: newAspectRatio)
      if layout.isLegacyFullScreen {
        applyLegacyFullScreenGeometry(fsGeo)
      } else if layout.mode != .fullScreenInteractive {
        videoView.apply(fsGeo)
      }
      break
    case .fullScreenInteractive, .windowedInteractive:
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
    guard let window else { return }
    guard !viewportView.subviews.contains(videoView) else { return }
    player.log.verbose("Adding videoView to viewportView, screenScaleFactor: \(window.screenScaleFactor)")
    /// Make sure `defaultAlbumArtView` stays above `videoView`
    viewportView.addSubview(videoView, positioned: .below, relativeTo: defaultAlbumArtView)
    videoView.videoLayer.autoresizingMask = CAAutoresizingMask(rawValue: 0)
    // Screen may have changed. Refresh contentsScale
    videoView.refreshContentsScale()
    // add constraints
    videoView.translatesAutoresizingMaskIntoConstraints = false
    videoView.constrainForNormalLayout()
  }

  /** Set material for OSC and title bar */
  func applyThemeMaterial() {
    guard let window else { return }

    let theme: Preference.Theme = Preference.enum(for: .themeMaterial)
    if #available(macOS 10.14, *) {
      let newAppearance = NSAppearance(iinaTheme: theme)
      window.appearance = newAppearance

      // Change to appearance above does not take effect until this task completes. Enqueue a new task to run after this one.
      DispatchQueue.main.async { [self] in
        (newAppearance ?? window.effectiveAppearance).applyAppearanceFor {
          thumbnailPeekView.refreshColors()
        }
      }
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

  func updateUseLegacyFullScreen() {
    resetCollectionBehavior()

    let oldLayout = currentLayout
    guard oldLayout.isFullScreen else { return }
    let outputLayoutSpec = LayoutSpec.fromPreferences(fillingInFrom: oldLayout.spec)
    if oldLayout.spec.isLegacyStyle != outputLayoutSpec.isLegacyStyle {
      DispatchQueue.main.async { [self] in
        log.verbose("User toggled legacy fullscreen option while in fullscreen - transitioning to windowed mode instead")
        exitFullScreen(legacy: oldLayout.isLegacyFullScreen)
      }
    }
  }

  func updateTitleBarAndOSC() {
    animationPipeline.submitZeroDuration { [self] in
      let oldLayout = currentLayout
      let newLayoutSpec = LayoutSpec.fromPreferences(fillingInFrom: oldLayout.spec)
      buildLayoutTransition(named: "UpdateTitleBarAndOSC", from: oldLayout, to: newLayoutSpec, thenRun: true)
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

  func restartHideCursorTimer() {
    if let timer = hideCursorTimer {
      timer.invalidate()
    }
    hideCursorTimer = Timer.scheduledTimer(timeInterval: max(0, Preference.double(for: .cursorAutoHideTimeout)), target: self, selector: #selector(hideCursor), userInfo: nil, repeats: false)
  }

  @objc private func hideCursor() {
    guard !currentLayout.isInteractiveMode, !currentLayout.isMusicMode else { return }
    log.verbose("Hiding cursor")
    hideCursorTimer = nil
    NSCursor.setHiddenUntilMouseMoves(true)
  }

  override func mouseDown(with event: NSEvent) {
    if Logger.enabled && Logger.Level.preferred >= .verbose {
      log.verbose("PlayerWindow mouseDown @ \(event.locationInWindow)")
    }
    // do nothing if it's related to floating OSC
    guard !controlBarFloating.isDragging else { return }
    // record current mouse pos
    mousePosRelatedToWindow = event.locationInWindow
    // Start resize if applicable
    let wasHandled = startResizingSidebar(with: event)
    guard !wasHandled else { return }

    restartHideCursorTimer()

    PluginInputManager.handle(
      input: PluginInputManager.Input.mouse, event: .mouseDown,
      player: player, arguments: mouseEventArgs(event)
    )
    // we don't call super here because before adding the plugin system,
    // PlayerWindowController didn't call super at all
  }

  override func mouseDragged(with event: NSEvent) {
    hideCursorTimer?.invalidate()
    let didResizeSidebar = resizeSidebar(with: event)
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
    restartHideCursorTimer()
    mousePosRelatedToWindow = nil
    if isDragging {
      // if it's a mouseup after dragging window
      isDragging = false
    } else if finishResizingSidebar(with: event) {
      updateCachedGeometry()
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
        player.log.verbose("MouseUp: click occurred in a disabled view; ignoring")
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
    restartHideCursorTimer()
    super.otherMouseDown(with: event)
  }

  override func otherMouseUp(with event: NSEvent) {
    Logger.log("PlayerWindow otherMouseUp!", level: .verbose, subsystem: player.subsystem)
    restartHideCursorTimer()
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
    restartHideCursorTimer()
    PluginInputManager.handle(
      input: PluginInputManager.Input.rightMouse, event: .mouseDown,
      player: player, arguments: mouseEventArgs(event)
    )
  }

  override func rightMouseUp(with event: NSEvent) {
    log.verbose("PlayerWindow rightMouseUp!")
    restartHideCursorTimer()
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
    case .contextMenu:
      showContextMenu()
    default:
      break
    }
  }

  private func showContextMenu() {
    // TODO
  }

  override func scrollWheel(with event: NSEvent) {
    guard !isInInteractiveMode else { return }
    guard !isMouseEvent(event, inAnyOf: [leadingSidebarView, trailingSidebarView, titleBarView, subPopoverView]) else { return }
    // TODO: figure out hit test to make sure scroll doesn't happen when window is occluded

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
    guard let area = event.trackingArea?.userInfo?[TrackingArea.key] as? TrackingArea else {
      log.warn("No data for tracking area")
      return
    }
    mouseExitEnterCount += 1

    switch area {
    case .playerWindow:
      isMouseInWindow = true
      showFadeableViews(duration: 0)
    case .playSlider:
      if controlBarFloating.isDragging { return }
      refreshSeekTimeAndThumnail(from: event)
    case .customTitleBar:
      customTitleBar?.leadingTitleBarView.mouseEntered(with: event)
    }
  }

  override func mouseExited(with event: NSEvent) {
    guard !isInInteractiveMode else { return }
    guard let area = event.trackingArea?.userInfo?[TrackingArea.key] as? TrackingArea else {
      log.warn("No data for tracking area")
      return
    }
    mouseExitEnterCount += 1

    switch area {
    case .playerWindow:
      isMouseInWindow = false
      if controlBarFloating.isDragging { return }
      if !isAnimating && Preference.bool(for: .hideFadeableViewsWhenOutsideWindow) {
        hideFadeableViews()
      } else {
        // Closes loophole in case cursor hovered over OSC before exiting (in which case timer was destroyed)
        resetFadeTimer()
      }
    case .playSlider:
      refreshSeekTimeAndThumnail(from: event)
    case .customTitleBar:
      customTitleBar?.leadingTitleBarView.mouseExited(with: event)
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

    refreshSeekTimeAndThumnail(from: event)

    if isMouseInWindow {
      let isTopBarHoverEnabled = Preference.isAdvancedEnabled && Preference.enum(for: .showTopBarTrigger) == Preference.ShowTopBarTrigger.topBarHover
      let forceShowTopBar = isTopBarHoverEnabled && isMouseInTopBarArea(event) && fadeableTopBarAnimationState == .hidden
      // Check whether mouse is in OSC
      let shouldRestartFadeTimer = !isMouseEvent(event, inAnyOf: [currentControlBar, titleBarView])
      showFadeableViews(thenRestartFadeTimer: shouldRestartFadeTimer, duration: 0, forceShowTopBar: forceShowTopBar)
    }

    if isMouseInWindow || isFullScreen {
      // Always hide after timeout even if OSD fade time is longer
      restartHideCursorTimer()
    } else {
      hideCursorTimer?.invalidate()
      hideCursorTimer = nil
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

    // start tracking mouse event
    if cv.trackingAreas.isEmpty {
      cv.addTrackingArea(NSTrackingArea(rect: cv.bounds,
                                        options: [.activeAlways, .enabledDuringMouseDrag, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
                                        owner: self, userInfo: [TrackingArea.key: TrackingArea.playerWindow]))
    }
    if playSlider.trackingAreas.isEmpty {
      playSlider.addTrackingArea(NSTrackingArea(rect: playSlider.bounds,
                                                options: [.activeAlways, .enabledDuringMouseDrag, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
                                                owner: self, userInfo: [TrackingArea.key: TrackingArea.playSlider]))
    }
    // Track the thumbs on the progress bar representing the A-B loop points and treat them as part
    // of the slider.
    if playSlider.abLoopA.trackingAreas.count <= 1 {
      playSlider.abLoopA.addTrackingArea(NSTrackingArea(rect: playSlider.abLoopA.bounds, options:  [.activeAlways, .enabledDuringMouseDrag, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved], owner: self, userInfo: [TrackingArea.key: TrackingArea.playSlider]))
    }
    if playSlider.abLoopB.trackingAreas.count <= 1 {
      playSlider.abLoopB.addTrackingArea(NSTrackingArea(rect: playSlider.abLoopB.bounds, options: [.activeAlways, .enabledDuringMouseDrag, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved], owner: self, userInfo: [TrackingArea.key: TrackingArea.playSlider]))
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
    addVideoViewToWindow()

    // Restore layout from last launch or configure from prefs. Do not animate.
    setInitialWindowLayout()

    // Unfortunately, seems that window must be visible for mpv init, or it will crash...
    // TODO: find way to delay until after fileLoaded. We don't know the video dimensions yet!
    if window.isMiniaturized {
      log.verbose("De-miniturizing Player Window")
      window.deminiaturize(self)
    } else {
      log.verbose("Showing Player Window")
      window.setIsVisible(true)
    }
    log.verbose("Hiding defaultAlbumArt for window open")
    defaultAlbumArtView.isHidden = true

    player.initVideo()
    videoView.startDisplayLink()

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
    isWindowMiniturized = false
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

  func windowDidFailToEnterFullScreen(_ window: NSWindow) {
    // FIXME: handle this
    log.error("Window failed to enter full screen!")
  }

  func windowDidFailToExitFullScreen(_ window: NSWindow) {
    // FIXME: handle this
    log.error("Window failed to exit full screen!")
  }

  // Animation: Enter FullScreen
  private func animateEntryIntoFullScreen(withDuration duration: TimeInterval, isLegacy: Bool) {
    log.verbose("Animating entry into \(isLegacy ? "legacy " : "")full screen, duration: \(duration)")
    let oldLayout = currentLayout

    // May be in interactive mode, with some panels hidden. Honor existing layout but change value of isFullScreen
    let fullscreenLayout = LayoutSpec.fromPreferences(andMode: .fullScreen, isLegacyStyle: isLegacy, fillingInFrom: oldLayout.spec)

    buildLayoutTransition(named: "Enter\(isLegacy ? "Legacy" : "")FullScreen", from: oldLayout, to: fullscreenLayout, totalStartingDuration: 0, totalEndingDuration: duration, thenRun: true)
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
      animateExitFromFullScreen(withDuration: IINAAnimation.FullScreenTransitionDuration, isLegacy: false)
    } else {
      // Kludge/workaround for race condition when exiting native FS to native windowed mode
      animationPipeline.submitZeroDuration { [self] in
        updateTitle()
      }
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

    // support exiting native FS and directly into music mode
    let newMode = modeToSetAfterExitingFullScreen ?? .windowed
    modeToSetAfterExitingFullScreen = nil
    let windowedLayout = LayoutSpec.fromPreferences(andMode: newMode, fillingInFrom: oldLayout.spec)

    /// Split the duration between `openNewPanels` animation and `fadeInNewViews` animation
    let transition = buildLayoutTransition(named: "Exit\(isLegacy ? "Legacy" : "")FullScreen", from: oldLayout, to: windowedLayout, totalStartingDuration: 0, totalEndingDuration: duration)

    animationPipeline.submit(transition.animationTasks)
  }

  func toggleWindowFullScreen() {
    log.verbose("ToggleWindowFullScreen() entered")
    let layout = currentLayout

    switch layout.mode {
    case .windowed, .windowedInteractive:
      enterFullScreen()
    case .fullScreen, .fullScreenInteractive:
      exitFullScreen(legacy: layout.spec.isLegacyStyle)
    case .musicMode:
      enterFullScreen()
    }
  }

  func enterFullScreen(legacy: Bool? = nil) {
    guard let window = self.window else { fatalError("make sure the window exists before animating") }
    let isLegacy: Bool = legacy ?? Preference.bool(for: .useLegacyFullScreen)
    let isFullScreen = NSApp.presentationOptions.contains(.fullScreen)
    log.verbose("EnterFullScreen called (legacy: \(isLegacy.yn), isNativeFullScreenNow: \(isFullScreen.yn))")

    if isLegacy {
      animateEntryIntoFullScreen(withDuration: IINAAnimation.FullScreenTransitionDuration, isLegacy: true)
    } else if !isFullScreen {
      window.toggleFullScreen(self)
    }
  }

  func exitFullScreen(legacy: Bool) {
    guard let window = self.window else { fatalError("make sure the window exists before animating") }
    let isFullScreen = NSApp.presentationOptions.contains(.fullScreen)
    log.verbose("ExitFullScreen called (legacy: \(legacy.yn), isNativeFullScreenNow: \(isFullScreen.yn))")

    // If "legacy" pref was toggled while in fullscreen, still need to exit native FS
    if legacy {
      animateExitFromFullScreen(withDuration: IINAAnimation.FullScreenTransitionDuration, isLegacy: true)
    } else if isFullScreen {
      window.toggleFullScreen(self)
    }
  }

  // MARK: - Window delegate: Resize

  func windowWillStartLiveResize(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }
    guard !isAnimating, !isMagnifying else { return }
    log.verbose("LiveResize started (\(window.inLiveResize)) for window: \(window.frame)")
    isLiveResizingWidth = false
  }

  func windowWillResize(_ window: NSWindow, to requestedSize: NSSize) -> NSSize {
    let currentMode = currentLayout.mode
    log.verbose("WindowWillResize entered. RequestedSize: \(requestedSize), mode: \(currentMode)")
    videoView.videoLayer.enterAsynchronousMode()

    switch currentMode {
    case .musicMode:
      return miniPlayer.windowWillResize(window, to: requestedSize)
    case .fullScreen, .fullScreenInteractive:
      if currentLayout.isLegacyFullScreen {
        let fsGeo = currentLayout.buildFullScreenGeometry(inScreenID: windowedModeGeometry.screenID, videoAspectRatio: player.info.videoAspectRatio)
        return fsGeo.windowFrame.size
      } else {  // is native full screen
        // This method can be called as a side effect of the animation. If so, ignore.
        return requestedSize
      }
    case .windowed, .windowedInteractive:
      let newGeometry = resizeWindowedModeGeometry(to: requestedSize)
      /// Do not call `videoView.apply()` - animation looks better without it

      updateSpacingForTitleBarAccessories(windowWidth: newGeometry.windowFrame.width)

      // We know the size, but don't yet know where AppKit is actually going to put the resized window.
      // Enqueue task which will run after this method returns, so we can check once the window is in its new location.
      DispatchQueue.main.async { [self] in
        updateCachedGeometry()
      }

      return newGeometry.windowFrame.size
    }
  }

  /// Called anytime window is resized. May be called after every call to `window.setFrame()`.
  func windowDidResize(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }

    if currentLayout.isWindowed && currentLayout.oscPosition == .floating {
      // Update floating control bar position
      updateFloatingOSCAfterWindowDidResize()
    }
    guard !isAnimating, !isMagnifying else { return }

    defer {
      updateCachedGeometry()
    }

    IINAAnimation.disableAnimation {
      log.verbose("WindowDidResize live=\(window.inLiveResize.yn) mode=\(currentLayout.mode) frame=\(window.frame)")

      switch currentLayout.mode {
      case .musicMode:
        // Re-evaluate space requirements for labels. May need to start scrolling.
        // Will also update saved state
        miniPlayer.windowDidResize()
      case .windowed:
        let viewportSize = viewportView.frame.size
        let resizedGeo = windowedModeGeometry.scaleViewport(to: viewportSize)
        // Need to update this always when resizing window:
        videoView.apply(resizedGeo)

      case .windowedInteractive, .fullScreenInteractive:
        // Update interactive mode selectable box size. Origin is relative to viewport origin
        let selectableRect = NSRect(origin: CGPointZero, size: videoView.frame.size)
        cropSettingsView?.cropBoxView.resized(with: selectableRect)
      case .fullScreen:
        return
      }

      if currentLayout.isWindowed {
        updateSpacingForTitleBarAccessories(windowWidth: window.frame.width)
      }
    }

    player.events.emit(.windowResized, data: window.frame)
  }

  /// Called when done with user drag of window border.
  /// Do not use for most things! Use `windowDidResize` instead.
  func windowDidEndLiveResize(_ notification: Notification) {
    // Must not access mpv while it is asynchronously processing stop and quit commands.
    // See comments in windowWillExitFullScreen for details.
    guard !isClosing, !isAnimating, !isMagnifying else { return }

    log.verbose("WindowDidEndLiveResize mode: \(currentLayout.mode)")

    switch currentLayout.mode {
    case .windowed:
      updateCachedGeometry()
      // resize framebuffer in videoView after resizing.
      updateWindowParametersForMPV()
    case .windowedInteractive:
      updateCachedGeometry()
    case .musicMode:
      miniPlayer.windowDidEndLiveResize()
    default:
      break
    }
    player.saveState()
  }

  // MARK: - Window Delegate: window move, screen changes

  func windowDidChangeBackingProperties(_ notification: Notification) {
    if videoView.refreshContentsScale() {
      // Do not allow MacOS to change the window size:
      denyNextWindowResize = true
    }
  }

  // Note: this gets triggered by many unnecessary situations, e.g. several times each time full screen is toggled.
  func windowDidChangeScreen(_ notification: Notification) {
    guard let window = window, let screen = window.screen else { return }

    let displayId = screen.displayId
    // Legacy FS work below can be very slow. Try to avoid if possible
    guard videoView.currentDisplay != displayId else {
      log.verbose("WindowDidChangeScreen: no work needed; currentDisplayID \(displayId) is unchanged")
      return
    }

    let blackWindows = self.blackWindows
    if isFullScreen && Preference.bool(for: .blackOutMonitor) && blackWindows.compactMap({$0.screen?.displayId}).contains(displayId) {
      log.verbose("WindowDidChangeScreen: black windows contains window's displayId \(displayId); removing & regenerating black windows")
      // Window changed screen: adjust black windows accordingly
      removeBlackWindows()
      blackOutOtherMonitors()
    }

    log.verbose("WindowDidChangeScreen: screenFrame=\(screen.frame)")
    videoView.updateDisplayLink()
    player.events.emit(.windowScreenChanged)

    /// Need to recompute legacy FS's window size so it exactly fills the new screen.
    /// But looks like the OS will try to reposition the window on its own and can't be stopped...
    /// Just wait until after it does its thing before calling `setFrame()`.
    if currentLayout.isLegacyFullScreen && !player.info.isRestoring {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
        animationPipeline.submit(IINAAnimation.Task({ [self] in
          let layout = currentLayout
          guard layout.isLegacyFullScreen else { return }  // check again now that we are inside animation
          log.verbose("Updating legacy full screen window and windowedModeGeometry in response to WindowDidChangeScreen")
          let screenID = bestScreen.screenID
          let fsGeo = layout.buildFullScreenGeometry(inScreenID: screenID, videoAspectRatio: player.info.videoAspectRatio)
          applyLegacyFullScreenGeometry(fsGeo)
          windowedModeGeometry = windowedModeGeometry.clone(screenID: screenID)
          player.saveState()
        }))
      }
      return
    }
  }

  /// Can be:
  /// • A Screen was connected or disconnected
  /// • Dock visiblity was toggled
  /// • Menu bar visibility toggled
  /// • Adding or removing window style mask `.titled`
  /// • Sometimes called hundreds(!) of times while window is closing
  private func windowDidChangeScreenParameters(_ notification: Notification) {
    guard !isClosing else { return }
    let screens = PlayerWindowController.buildScreenMap()
    let screenIDs = screens.keys.sorted()
    let cachedScreenIDs = cachedScreens.keys.sorted()
    log.verbose("WindowDidChangeScreenParameters: screenIDs was \(cachedScreenIDs), is now \(screenIDs)")

    // Update the cached value
    self.cachedScreens = screens

    self.videoView.updateDisplayLink()

    guard !player.info.isRestoring else { return }

    // In normal full screen mode AppKit will automatically adjust the window frame if the window
    // is moved to a new screen such as when the window is on an external display and that display
    // is disconnected. In legacy full screen mode IINA is responsible for adjusting the window's
    // frame.
    // Use very short duration. This usually gets triggered at the end when entering fullscreen, when the dock and/or menu bar are hidden.
    animationPipeline.submit(IINAAnimation.Task(duration: IINAAnimation.FullScreenTransitionDuration * 0.2, { [self] in
      if currentLayout.isLegacyFullScreen {
        let layout = currentLayout
        guard layout.isLegacyFullScreen else { return }  // check again now that we are inside animation
        log.verbose("Updating legacy full screen window in response to ScreenParametersNotification")
        let fsGeo = layout.buildFullScreenGeometry(inside: bestScreen, videoAspectRatio: player.info.videoAspectRatio)
        applyLegacyFullScreenGeometry(fsGeo)
      } else if currentLayout.isWindowed {
        /// In certain corner cases (e.g., exiting legacy full screen after changing screens while in full screen),
        /// the screen's `visibleFrame` can change after `transition.outputGeometry` was generated and won't be known until the end.
        /// By calling `refit()` here, we can make sure the window is constrained to the up-to-date `visibleFrame`.
        let oldGeo = windowedModeGeometry!
        let newGeo = oldGeo.refit()
        guard !newGeo.hasEqual(windowFrame: oldGeo.windowFrame, videoSize: oldGeo.videoSize) else {
          log.verbose("No need to update windowFrame in response to ScreenParametersNotification - no change")
          return
        }
        let newWindowFrame = newGeo.windowFrame
        log.verbose("Calling setFrame() in response to ScreenParametersNotification with windowFrame \(newWindowFrame), videoSize \(newGeo.videoSize)")
        videoView.apply(newGeo)
        player.window.setFrameImmediately(newWindowFrame)
      }
    }))
  }

  func windowWillMove(_ notification: Notification) {
    guard let window = window else { return }
    log.verbose("WindowWillMove frame: \(window.frame)")
    /// Sometimes there is a `windowWillMove` notification without a `windowDidMove`. So do the update here too:
    updateCachedGeometry(updatePreferredSizeAlso: false)
  }

  func windowDidMove(_ notification: Notification) {
    guard !isAnimating else { return }
    guard let window = window else { return }
    log.verbose("WindowDidMove to frame: \(window.frame)")
    let layout = currentLayout
    if layout.isLegacyFullScreen && !player.info.isRestoring {
      // MacOS (as of 14.0 Sonoma) sometimes moves the window around when there are multiple screens
      // and the user is changing focus between windows or apps. This can also happen if the user is using a third-party
      // window management app such as Amethyst. If this happens, move the window back to its proper place:
      log.verbose("Updating legacy full screen window in response to unexpected windowDidMove")
      let fsGeo = layout.buildFullScreenGeometry(inside: bestScreen, videoAspectRatio: player.info.videoAspectRatio)
      applyLegacyFullScreenGeometry(fsGeo)
    } else {
      updateCachedGeometry(updatePreferredSizeAlso: false)
      player.events.emit(.windowMoved, data: window.frame)
    }
  }

  // MARK: - Window delegate: Activeness status

  func windowDidBecomeKey(_ notification: Notification) {
    if currentLayout.isLegacyFullScreen {
      window?.level = .iinaFloating
    }

    if Preference.bool(for: .pauseWhenInactive) && isPausedDueToInactive {
      player.resume()
      isPausedDueToInactive = false
    }
  }

  func windowDidResignKey(_ notification: Notification) {
    if currentLayout.isLegacyFullScreen {
      /// Change from `floating` to `normal` so that window doesn't block all others
      window?.level = .normal
    }

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
    guard let window else { return }
    log.verbose("Window became main: \(window.savedStateName.quoted)")

    PlayerCore.lastActive = player
    if #available(macOS 10.13, *), RemoteCommandController.useSystemMediaControl {
      NowPlayingInfoManager.updateInfo(withTitle: true)
    }
    (NSApp.delegate as? AppDelegate)?.menuController?.updatePluginMenu()

    if isFullScreen && Preference.bool(for: .blackOutMonitor) {
      blackOutOtherMonitors()
    }

    if let customTitleBar {
      // The traffic light buttons should change to active
      customTitleBar.leadingTitleBarView.markButtonsDirty()
      customTitleBar.refreshTitle()
    }


    player.events.emit(.windowMainStatusChanged, data: true)
    NotificationCenter.default.post(name: .iinaPlayerWindowChanged, object: true)
  }

  func windowDidResignMain(_ notification: Notification) {
    guard let window else { return }
    log.verbose("Window is no longer main: \(window.savedStateName.quoted)")

    if Preference.bool(for: .blackOutMonitor) {
      removeBlackWindows()
    }

    if let customTitleBar {
      // The traffic light buttons should change to inactive
      customTitleBar.leadingTitleBarView.markButtonsDirty()
      customTitleBar.refreshTitle()
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
    log.verbose("Window did miniaturize")
    isWindowMiniturized = true
    if Preference.bool(for: .togglePipByMinimizingWindow) && !isWindowMiniaturizedDueToPip {
      if #available(macOS 10.12, *) {
        enterPIP()
      }
    }
    player.events.emit(.windowMiniaturized)
  }

  func windowDidDeminiaturize(_ notification: Notification) {
    log.verbose("Window did deminiaturize")
    isWindowMiniturized = false
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

  func isUITimerNeeded() -> Bool {
//    log.verbose("Checking if UITimer needed. hasPermanentOSC:\(currentLayout.hasPermanentOSC.yn) fadeableViews:\(fadeableViewsAnimationState) topBar: \(fadeableTopBarAnimationState) OSD:\(osdAnimationState)")
    if currentLayout.hasPermanentOSC {
      return true
    }
    let showingFadeableViews = fadeableViewsAnimationState == .shown || fadeableViewsAnimationState == .willShow
    let showingFadeableTopBar = fadeableTopBarAnimationState == .shown || fadeableViewsAnimationState == .willShow
    let showingOSD = osdAnimationState == .shown || osdAnimationState == .willShow
    return showingFadeableViews || showingFadeableTopBar || showingOSD
  }

  // Shows fadeableViews and titlebar via fade
  func showFadeableViews(thenRestartFadeTimer restartFadeTimer: Bool = true,
                         duration: CGFloat = IINAAnimation.DefaultDuration,
                         forceShowTopBar: Bool = false) {
    guard !player.disableUI && !isInInteractiveMode else { return }
    let animationTasks: [IINAAnimation.Task] = buildAnimationToShowFadeableViews(restartFadeTimer: restartFadeTimer,
                                                                                  duration: duration,
                                                                                  forceShowTopBar: forceShowTopBar)
    animationPipeline.submit(animationTasks)
  }

  func buildAnimationToShowFadeableViews(restartFadeTimer: Bool = true,
                                         duration: CGFloat = IINAAnimation.DefaultDuration,
                                         forceShowTopBar: Bool = false) -> [IINAAnimation.Task] {
    var animationTasks: [IINAAnimation.Task] = []

    /// Default `showTopBarTrigger` setting to `.windowHover` if advanced settings not enabled
    let showTopBar = forceShowTopBar || (!Preference.isAdvancedEnabled || Preference.enum(for: .showTopBarTrigger) == Preference.ShowTopBarTrigger.windowHover)

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

    animationTasks.append(IINAAnimation.Task(duration: duration, { [self] in
      guard fadeableViewsAnimationState == .hidden || fadeableViewsAnimationState == .shown else { return }
      fadeableViewsAnimationState = .willShow
      player.refreshSyncUITimer(log: "Showing fadeable views ")
      destroyFadeTimer()

      for v in fadeableViews {
        v.animator().alphaValue = 1
      }

      if showTopBar {
        fadeableTopBarAnimationState = .willShow
        for v in fadeableViewsTopBar {
          v.animator().alphaValue = 1
        }

        if currentLayout.titleBar == .showFadeableTopBar {
          if currentLayout.spec.isLegacyStyle {
            customTitleBar?.view.animator().alphaValue = 1
          } else {
            for button in trafficLightButtons {
              button.alphaValue = 1
            }
            titleTextField?.alphaValue = 1
            documentIconButton?.alphaValue = 1
          }
        }
      }
    }))

    // Not animated, but needs to wait until after fade is done
    animationTasks.append(IINAAnimation.zeroDurationTask { [self] in
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

        if currentLayout.titleBar == .showFadeableTopBar {
          if currentLayout.spec.isLegacyStyle {
            customTitleBar?.view.isHidden = false
          } else {
            for button in trafficLightButtons {
              button.isHidden = false
            }
            titleTextField?.isHidden = false
            documentIconButton?.isHidden = false
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

    var animationTasks: [IINAAnimation.Task] = []

    animationTasks.append(IINAAnimation.Task{ [self] in
      // Don't hide overlays when in PIP or when they are not actually shown
      destroyFadeTimer()
      fadeableViewsAnimationState = .willHide
      fadeableTopBarAnimationState = .willHide
      player.refreshSyncUITimer(log: "Hiding fadeable views ")

      for v in fadeableViews {
        v.animator().alphaValue = 0
      }
      for v in fadeableViewsTopBar {
        v.animator().alphaValue = 0
      }
      /// Quirk 1: special handling for `trafficLightButtons`
      if currentLayout.titleBar == .showFadeableTopBar {
        if currentLayout.spec.isLegacyStyle {
          customTitleBar?.view.alphaValue = 0
        } else {
          documentIconButton?.alphaValue = 0
          titleTextField?.alphaValue = 0
          for button in trafficLightButtons {
            button.alphaValue = 0
          }
        }
      }
    })

    animationTasks.append(IINAAnimation.zeroDurationTask { [self] in
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
      if currentLayout.titleBar == .showFadeableTopBar {
        if currentLayout.spec.isLegacyStyle {
          customTitleBar?.view.isHidden = true
        } else {
          hideBuiltInTitleBarViews(setAlpha: false)
        }
      }
    })

    animationPipeline.submit(animationTasks)
    return true
  }

  // MARK: - UI: Show / Hide Fadeable Views Timer

  func resetFadeTimer() {
    // If timer exists, destroy first
    destroyFadeTimer()

    // Create new timer.
    // Timer and animation APIs require Double, but we must support legacy prefs, which store as Float
    var timeout = Double(Preference.float(for: .controlBarAutoHideTimeout))
    if timeout < IINAAnimation.DefaultDuration {
      timeout = IINAAnimation.DefaultDuration
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
      player.windowController.miniPlayer.playSlider.updateTo(percentage: percentage)
      [player.windowController.miniPlayer.leftLabel, player.windowController.miniPlayer.rightLabel].forEach { $0.updateText(with: duration, given: pos) }
    } else {
      // Normal player
      [leftLabel, rightLabel].forEach { $0.updateText(with: duration, given: pos) }
      playSlider.updateTo(percentage: percentage)
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
    guard let window else { return }

    let title: String
    if player.isInMiniPlayer {
      let (mediaTitle, mediaAlbum, mediaArtist) = player.getMusicMetadata()
      title = mediaTitle
      window.title = title
      _ = miniPlayer.view
      miniPlayer.updateTitle(mediaTitle: mediaTitle, mediaAlbum: mediaAlbum, mediaArtist: mediaArtist)
    } else if player.info.isNetworkResource {
      title = player.getMediaTitle()
      window.title = title
    } else {
      window.representedURL = player.info.currentURL
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
      title = player.info.currentURL?.lastPathComponent ?? ""
      window.setTitleWithRepresentedFilename(player.info.currentURL?.path ?? "")
    }

    /// This call is needed when using custom window style, otherwise the window won't get added to the Window menu or the Dock.
    /// Oddly, there are 2 separate functions for adding and changing the item, but `addWindowsItem` has no effect if called more than once,
    /// while `changeWindowsItem` needs to be called if `addWindowsItem` was already called. To be safe, just call both.
    NSApplication.shared.addWindowsItem(window, title: title, filename: false)
    NSApplication.shared.changeWindowsItem(window, title: title, filename: false)

    log.verbose("Updating window title to: \(title.quoted)")
    customTitleBar?.refreshTitle()
  }

  // MARK: - UI: OSD

  private func updateOSDPosition() {
    guard let contentView = window?.contentView else { return }
    contentView.removeConstraint(leadingSidebarToOSDSpaceConstraint)
    contentView.removeConstraint(trailingSidebarToOSDSpaceConstraint)
    let osdPosition: Preference.OSDPosition = Preference.enum(for: .osdPosition)
    switch osdPosition {
    case .topLeading:
      // OSD on left, AdditionalInfo on right
      leadingSidebarToOSDSpaceConstraint = leadingSidebarView.trailingAnchor.constraint(equalTo: osdVisualEffectView.leadingAnchor, constant: -8.0)
      trailingSidebarToOSDSpaceConstraint = trailingSidebarView.leadingAnchor.constraint(equalTo: additionalInfoView.trailingAnchor, constant: 8.0)
    case .topTrailing:
      // AdditionalInfo on left, OSD on right
      leadingSidebarToOSDSpaceConstraint = leadingSidebarView.trailingAnchor.constraint(equalTo: additionalInfoView.leadingAnchor, constant: -8.0)
      trailingSidebarToOSDSpaceConstraint = trailingSidebarView.leadingAnchor.constraint(equalTo: osdVisualEffectView.trailingAnchor, constant: 8.0)
    }

    leadingSidebarToOSDSpaceConstraint.priority = .defaultHigh
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
        timeout = configuredTimeout <= IINAAnimation.OSDAnimationDuration ? IINAAnimation.OSDAnimationDuration : configuredTimeout
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
      accessoryView.addConstraintsToFillSuperview(leading: 0, trailing: 0)

      accessoryView.wantsLayer = true
      accessoryView.layer?.opacity = 0

      IINAAnimation.runAsync(IINAAnimation.Task(duration: IINAAnimation.OSDAnimationDuration, { [self] in
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

    IINAAnimation.runAsync(IINAAnimation.Task(duration: IINAAnimation.OSDAnimationDuration, { [self] in
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


  func enterInteractiveMode(_ mode: InteractiveMode) {
    guard player.info.videoParams?.videoDisplayRotatedSize != nil else {
      Utility.showAlert("no_video_track")
      return
    }
    log.verbose("Entering interactive mode: \(mode)")

    // TODO: use key binding interceptor to support ESC and ENTER keys for interactive mode

    if mode == .crop, let vf = player.info.cropFilter, let filterLabel = vf.label {
      log.error("Crop mode requested, but found an existing crop filter (\(vf.stringFormat.quoted)). Will remove it before entering")
      // A crop is already set. Need to temporarily remove it so that the whole video can be seen again,
      // so that a new crop can be chosen. But keep info from the old filter in case the user cancels.
      assert(vf.label == Constants.FilterLabel.crop, "Unexpected label for crop filter: \(vf.name.quoted)")
      player.info.videoFiltersDisabled[filterLabel] = vf
      if player.removeVideoFilter(vf) {
        // We can expect to receive a new video-params from mpv asynchronously. Pick it up there.
        // Will check whether there is a disabled crop filter there
        return
      } else {
        log.error("Failed to remove prev crop filter: (\(vf.stringFormat.quoted)) for some reason. Will ignore and try to proceed anyway")
      }
    }
    let oldLayout = currentLayout
    let newMode: WindowMode = oldLayout.mode == .fullScreen ? .fullScreenInteractive : .windowedInteractive
    let interactiveModeLayout = oldLayout.spec.clone(mode: newMode, interactiveMode: mode)
    let duration = IINAAnimation.CropAnimationDuration
    buildLayoutTransition(named: "EnterInteractiveMode", from: oldLayout, to: interactiveModeLayout,
                          totalStartingDuration: duration * 0.5, totalEndingDuration: duration * 0.5,
                          thenRun: true)
  }

  /// Use `immediately: true` to exit without animation
  func exitInteractiveMode(immediately: Bool = false, then doAfter: (() -> Void)? = nil) {
    let oldLayout = currentLayout

    let newMode: WindowMode = oldLayout.mode == .fullScreenInteractive ? .fullScreen : .windowed
    log.verbose("Exiting interactive mode, newMode: \(newMode)")
    let newLayoutSpec = LayoutSpec.fromPreferences(andMode: newMode, fillingInFrom: oldLayout.spec)
    let halfDuration = IINAAnimation.CropAnimationDuration * 0.5
    let transition = buildLayoutTransition(named: "ExitInteractiveMode", from: oldLayout, to: newLayoutSpec,
                                           totalStartingDuration: halfDuration, totalEndingDuration: halfDuration)

    var animationTasks = transition.animationTasks
    if let doAfter {
      animationTasks.append(IINAAnimation.Task({
        doAfter()
      }))
    }
    animationPipeline.submit(animationTasks)
  }

  // MARK: - UI: Thumbnail Preview

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
  private func canShowThumbnailAbove(oscOriginInWindowY: Double, oscHeight: Double, thumbnailHeight: Double) -> Bool {
    switch currentLayout.oscPosition {
    case .top:
      return false
    case .bottom:
      return true
    case .floating:
      // The layout preference for the on screen controller is set to the default floating layout.
      // Must ensure the top of the thumbnail will be below the top of the window.
      // Keep in mind that the thumbnail will also be shrunk to fit if possible.
      let topOfThumbnailY = oscOriginInWindowY + oscHeight + thumbnailHeight
      let availableHeight = viewportView.frame.height
      return topOfThumbnailY <= availableHeight
    }
  }

  /// Display time label & thumbnail when mouse over slider
  private func refreshSeekTimeAndThumnail(from event: NSEvent) {
    thumbDisplayCounter += 1
    let currentTicket = thumbDisplayCounter

    DispatchQueue.main.async { [self] in
      guard currentTicket == thumbDisplayCounter else { return }
      refreshSeekTimeAndThumnailInternal(from: event)
    }
  }

  private func refreshSeekTimeAndThumnailInternal(from event: NSEvent) {
    let isCoveredByOSD = !osdVisualEffectView.isHidden && isMouseEvent(event, inAnyOf: [osdVisualEffectView])
    let isMouseInPlaySlider = isMouseEvent(event, inAnyOf: [playSlider])
    guard isMouseInPlaySlider && !isCoveredByOSD, let duration = player.info.videoDuration else {
      thumbnailPeekView.isHidden = true
      timePositionHoverLabel.isHidden = true
      return
    }
    timePositionHoverLabel.isHidden = false

    let mousePosX = playSlider.convert(event.locationInWindow, from: nil).x
    let originalPosX = event.locationInWindow.x

    timePositionHoverLabelHorizontalCenterConstraint.constant = mousePosX

    let playbackPositionPercentage = max(0, Double((mousePosX - 3) / (playSlider.frame.width - 6)))
    let previewTime = duration * playbackPositionPercentage
    if timePositionHoverLabel.stringValue != previewTime.stringRepresentation {
      //    Logger.log("Updating seek time indicator to: \(previewTime.stringRepresentation)", level: .verbose, subsystem: player.subsystem)
      timePositionHoverLabel.stringValue = previewTime.stringRepresentation
    }

    // Thumbnail:
    guard player.info.thumbnailsReady,
            let ffThumbnail = player.info.getThumbnail(forSecond: previewTime.second),
          let videoParams = player.info.videoParams else {
      thumbnailPeekView.isHidden = true
      return
    }

    let rotatedImage = ffThumbnail.image
    var thumbWidth: Double = rotatedImage.size.width
    var thumbHeight: Double = rotatedImage.size.height

    guard thumbWidth > 0, thumbHeight > 0 else {
      log.error("Cannot display thumbnail: thumbnail width or height is not positive!")
      return
    }
    var thumbAspect = thumbWidth / thumbHeight

    let drAspect = videoParams.videoDisplayRotatedAspect
    // The aspect ratio of some videos is different at display time. May need to resize these videos
    // once the actual aspect ratio is known. (Should they be resized before being stored on disk? Doing so
    // would increase the file size without improving the quality, whereas resizing on the fly seems fast enough).
    if thumbAspect != drAspect {
      thumbHeight = (thumbWidth / drAspect).rounded()
      /// Recalculate this for later use (will use it and `thumbHeight`, and derive width)
      thumbAspect = thumbWidth / thumbHeight
    }

    /// Calculate `availableHeight` (viewport height, minus top & bottom bars)
    /// Easy to get `insideTopBarHeight`, but need to work a bit to get `insideBottomBarHeight`
    let insideBottomBarHeight = currentLayout.bottomBarPlacement == .insideViewport ? bottomBarView.frame.height : 0
    let availableHeight = viewportView.frame.height - currentLayout.insideTopBarHeight - insideBottomBarHeight - thumbnailExtraOffsetY - thumbnailExtraOffsetY

    let sizeOption: Preference.ThumbnailSizeOption = Preference.enum(for: .thumbnailSizeOption)
    switch sizeOption {
    case .fixedSize:
      // Stored thumb size should be correct (but may need to be scaled down)
      break
    case .scaleWithViewport:
      // Scale thumbnail as percentage of available height
      let percentage = min(1, max(0, Preference.double(for: .thumbnailDisplayedSizePercentage) / 100.0))
      thumbHeight = availableHeight * percentage
    }

    // Thumb too tall?
    if thumbHeight > availableHeight {
      // Scale down thumbnail so it doesn't overlap top or bottom bars
      thumbHeight = availableHeight
    }

    thumbWidth = thumbHeight * thumbAspect

    // Also scale down thumbnail if it's wider than the viewport
    let availableWidth = viewportView.frame.width - thumbnailExtraOffsetX - thumbnailExtraOffsetX
    if thumbWidth > availableWidth {
      thumbWidth = availableWidth
      thumbHeight = thumbWidth / thumbAspect
    }

    // Need integers below.
    thumbWidth = round(thumbWidth)
    thumbHeight = round(thumbHeight)

    // Rotating and scaling are expensive operations, so reuse the last image if no change is needed
    if player.info.lastThumbFFTimestamp != ffThumbnail.timestamp {
      player.info.lastThumbFFTimestamp = ffThumbnail.timestamp
      let finalImage = rotatedImage.resized(newWidth: Int(thumbWidth), newHeight: Int(thumbHeight))
      thumbnailPeekView.imageView.image = finalImage
      thumbnailPeekView.frame.size = finalImage.size
    }

    let contentView = window!.contentView!
    if currentLayout.oscPosition != .top && currentLayout.topBarPlacement == .outsideViewport {
      // If top bar is "outside", do not allow thumbnail to overlap onto it
      contentView.addSubview(thumbnailPeekView, positioned: .below, relativeTo: topBarView)
    } else {
      // Otherwise allow thumbnail to occlude top bar (could find a clean look otherwise which works with sidebars and various options)
      contentView.addSubview(thumbnailPeekView, positioned: .above, relativeTo: topBarView)
    }

    let oscOriginInWindowY = currentControlBar!.superview!.convert(currentControlBar!.frame.origin, to: nil).y
    let oscHeight = currentControlBar!.frame.size.height
    let showAbove = canShowThumbnailAbove(oscOriginInWindowY: oscOriginInWindowY, oscHeight: oscHeight, thumbnailHeight: thumbHeight)
    let thumbOriginY: CGFloat
    if showAbove {
      // Show thumbnail above seek time, which is above slider
      thumbOriginY = oscOriginInWindowY + oscHeight + thumbnailExtraOffsetY
    } else {
      // Show thumbnail below slider
      thumbOriginY = max(thumbnailExtraOffsetY, oscOriginInWindowY - thumbHeight - thumbnailExtraOffsetY)
    }
    // Constrain X origin so that it stays entirely inside the viewport (and not inside the outside sidebars)
    let minX = currentLayout.outsideLeadingBarWidth + thumbnailExtraOffsetX
    let maxX = availableWidth + currentLayout.outsideLeadingBarWidth + thumbnailExtraOffsetX
    let thumbOriginX = min(max(minX, round(originalPosX - thumbWidth / 2)), maxX - thumbWidth)
    thumbnailPeekView.frame.origin = NSPoint(x: thumbOriginX, y: thumbOriginY)

    thumbnailPeekView.refreshStyle()

//      log.verbose("Displaying thumbnail: \(thumbnailSize.width) W x \(thumbnailSize.height) H \(showAbove ? "above" : "below") OSC")
    thumbnailPeekView.isHidden = false
  }

  // MARK: - UI: Other

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
    // Must not access mpv while it is asynchronously processing stop and quit commands.
    // See comments in resetViewsForFullScreenTransition for details.
    guard !isClosing else { return }

    log.verbose("UpdateWindowParametersForMPV called, videoSizeIsNil: \((videoSize == nil).yn)")

    guard let videoWidth = player.info.videoParams?.videoDisplayRotatedWidth else {
      log.debug("Skipping send to mpv windowScale; could not get width from videoDisplayRotatedSize")
      return
    }
    guard videoWidth > 0 else {
      log.debug("Skipping send to mpv windowScale; videoDisplayRotated width is \(videoWidth)")
      return
    }

    let videoScale = Double((videoSize ?? windowedModeGeometry.videoSize).width) / Double(videoWidth)
    let prevVideoScale = player.info.cachedWindowScale
    if videoScale != prevVideoScale {
      // Setting the window-scale property seems to result in a small hiccup during playback.
      // Not sure if this is an mpv limitation
      player.mpv.queue.async { [self] in
        log.verbose("Sending mpv windowScale: \(player.info.cachedWindowScale) → \(videoScale)\(videoSize == nil ? "" : " (given videoSize \(videoSize!))")")
        player.info.cachedWindowScale = videoScale
        player.mpv.setDouble(MPVProperty.windowScale, videoScale)
      }
    }
  }

  func refreshHidesOnDeactivateStatus() {
    guard let window else { return }
    window.hidesOnDeactivate = currentLayout.isWindowed && Preference.bool(for: .hideWindowsWhenInactive)
  }

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
      volumeSlider.isEnabled = (player.info.aid != 0)
      volumeSlider.maxValue = Double(Preference.integer(for: .maxVolume))
      volumeSlider.doubleValue = player.info.volume
    }
    if let muteButton = player.isInMiniPlayer ? player.windowController.miniPlayer.muteButton : muteButton {
      muteButton.isEnabled = (player.info.aid != 0)
      muteButton.state = player.info.isMuted ? .on : .off
    }
    if player.isInMiniPlayer {
      miniPlayer.updateVolumeUI()
    }
  }

  func enterMusicMode() {
    animationPipeline.submitZeroDuration { [self] in
      /// Start by hiding OSC and/or "outside" panels, which aren't needed and might mess up the layout.
      /// We can do this by creating a `LayoutSpec`, then using it to build a `LayoutTransition` and executing its animation.
      let oldLayout = currentLayout
      if oldLayout.isNativeFullScreen {
        // Need to do some gymnastics to parameterize exit from native full screen
        modeToSetAfterExitingFullScreen = .musicMode
        window?.toggleFullScreen(self)
      } else {
        let miniPlayerLayout = oldLayout.spec.clone(mode: .musicMode)
        buildLayoutTransition(named: "EnterMusicMode", from: oldLayout, to: miniPlayerLayout, thenRun: true)
      }
    }
  }

  func exitMusicMode() {
    animationPipeline.submitZeroDuration { [self] in
      /// Start by hiding OSC and/or "outside" panels, which aren't needed and might mess up the layout.
      /// We can do this by creating a `LayoutSpec`, then using it to build a `LayoutTransition` and executing its animation.
      let oldLayout = currentLayout
      let windowedLayout = LayoutSpec.fromPreferences(andMode: .windowed, fillingInFrom: oldLayout.spec)
      buildLayoutTransition(named: "ExitMusicMode", from: oldLayout, to: windowedLayout, thenRun: true)
    }
  }

  func blackOutOtherMonitors() {
    removeBlackWindows()

    let screens = NSScreen.screens.filter { $0 != window?.screen }
    var blackWindows: [NSWindow] = []

    for screen in screens {
      var screenRect = screen.frame
      screenRect.origin = CGPoint(x: 0, y: 0)
      let blackWindow = NSWindow(contentRect: screenRect, styleMask: [], backing: .buffered, defer: false, screen: screen)
      blackWindow.backgroundColor = .black
      blackWindow.level = .iinaBlackScreen

      blackWindows.append(blackWindow)
      blackWindow.orderFront(nil)
    }
    self.blackWindows = blackWindows
    log.verbose("Added black windows for screens \((blackWindows.compactMap({$0.screen?.displayId}).map{String($0)}))")
  }

  func removeBlackWindows() {
    let blackWindows = self.blackWindows
    self.blackWindows = []
    guard !blackWindows.isEmpty else { return }
    log.verbose("Removing black windows for screens \(blackWindows.compactMap({$0.screen?.displayId}).map{String($0)})")
    for window in blackWindows {
      window.orderOut(self)
    }
    log.verbose("Removed all black windows")
  }

  func setWindowFloatingOnTop(_ onTop: Bool, updateOnTopStatus: Bool = true) {
    guard !isFullScreen else { return }
    guard let window = window else { return }
    window.level = onTop ? .iinaFloating : .normal
    if updateOnTopStatus {
      self.isOntop = onTop
    }
    resetCollectionBehavior()
  }

  // MARK: - Sync UI with playback

  func forceDraw() {
    dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
    guard loaded, player.info.isPaused || player.info.currentTrack(.video)?.isAlbumart ?? false else { return }
    log.verbose("Forcing redraw")
    player.videoView.displayActive()  // does nothing if already active
    videoView.videoLayer.draw(forced: true)
    if player.info.isPaused {
      player.videoView.displayIdle()  // restarts idle timer
    }
  }

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
    // Show only in music mode when video is visible
    closeButtonBackgroundViewVE.isHidden = !miniPlayer.isVideoVisible

    // Show only in music mode when video is hidden
    closeButtonBackgroundViewBox.isHidden = miniPlayer.isVideoVisible
  }

  // MARK: - IBActions

  @objc func menuSwitchToMiniPlayer(_ sender: NSMenuItem) {
    if player.isInMiniPlayer {
      player.exitMusicMode()
    } else {
      player.enterMusicMode()
    }
  }

  @IBAction func volumeSliderDidChange(_ sender: NSSlider) {
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
      player.seek(relativeSecond: left ? -10 : 10, option: .defaultValue)

    }
  }

  @IBAction func toggleOnTop(_ sender: NSButton) {
    setWindowFloatingOnTop(!isOntop)
  }

  /** When slider changes */
  @IBAction func playSliderDidChange(_ sender: NSSlider) {
    guard !player.info.fileLoading else { return }

    let percentage = 100 * sender.doubleValue / sender.maxValue
    player.seek(percent: percentage, forceExact: !followGlobalSeekTypeWhenAdjustSlider)

    // update position of time label
    timePositionHoverLabelHorizontalCenterConstraint.constant = sender.knobPointPosition() - playSlider.frame.origin.x

    // update text of time label
    let seekTime = player.info.videoDuration! * percentage * 0.01
    log.debug("PlaySliderDidChange: setting slider position time label to \(seekTime.stringRepresentation.quoted)")
    timePositionHoverLabel.stringValue = seekTime.stringRepresentation
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
    case .screenshot:
      player.screenshot()
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

  func enterPIP(usePipBehavior: Preference.WindowBehaviorWhenPip? = nil) {
    guard pipStatus != .inPIP else { return }
    guard let window else { return }
    pipStatus = .inPIP
    showFadeableViews()

    pipVideo = NSViewController()
    // Remove these. They screw up PIP drag
    videoView.apply(nil)
    pipVideo.view = videoView
    videoView.videoLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
    pip.playing = player.info.isPlaying
    pip.title = window.title

    pip.presentAsPicture(inPicture: pipVideo)
    pipOverlayView.isHidden = false

    if !window.styleMask.contains(.fullScreen) && !window.isMiniaturized {
      let pipBehavior = usePipBehavior ?? Preference.enum(for: .windowBehaviorWhenPip) as Preference.WindowBehaviorWhenPip
      log.verbose("Entering PIP with behavior: \(pipBehavior)")
      switch pipBehavior {
      case .doNothing:
        break
      case .hide:
        isWindowHidden = true
        window.orderOut(self)
        log.verbose("PIP entered; adding player to hidden windows list: \(window.savedStateName.quoted)")
        AppDelegate.windowsHidden.insert(window.savedStateName)
        break
      case .minimize:
        isWindowMiniaturizedDueToPip = true
        /// No need to add to `AppDelegate.windowsMinimized` - it will be handled by app-wide listener
        window.miniaturize(self)
        break
      }
      if Preference.bool(for: .pauseWhenPip) {
        player.pause()
      }
    }

    forceDraw()
    player.saveState()
    player.events.emit(.pipChanged, data: true)
  }

  func exitPIP() {
    guard pipStatus == .inPIP else { return }
    log.verbose("Exiting PIP")
    if pipShouldClose(pip) {
      // Prod Swift to pick the dismiss(_ viewController: NSViewController)
      // overload over dismiss(_ sender: Any?). A change in the way implicitly
      // unwrapped optionals are handled in Swift means that the wrong method
      // is chosen in this case. See https://bugs.swift.org/browse/SR-8956.
      pip.dismiss(pipVideo!)
    }
    player.events.emit(.pipChanged, data: false)
  }

  func prepareForPIPClosure(_ pip: PIPViewController) {
    guard pipStatus == .inPIP else { return }
    guard let window = window else { return }
    log.verbose("Preparing for PIP closure")
    // This is called right before we're about to close the PIP
    pipStatus = .intermediate

    // Hide the overlay view preemptively, to prevent any issues where it does
    // not hide in time and ends up covering the video view (which will be added
    // to the window under everything else, including the overlay).
    pipOverlayView.isHidden = true

    if (NSApp.delegate as! AppDelegate).isTerminating {
      // Don't bother restoring window state past this point
      return
    }

    // Set frame to animate back to
    pip.replacementRect = windowedModeGeometry.videoFrameInWindowCoords
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
    guard !(NSApp.delegate as! AppDelegate).isTerminating else { return }

    // seems to require separate animation blocks to work properly
    var animationTasks: [IINAAnimation.Task] = []

    if isWindowHidden {
      animationTasks.append(IINAAnimation.Task({ [self] in
        showWindow(self)
        if let window {
          log.verbose("PIP did close; removing player from hidden windows list: \(window.savedStateName.quoted)")
          AppDelegate.windowsHidden.remove(window.savedStateName)
        }
      }))
    }

    animationTasks.append(IINAAnimation.zeroDurationTask { [self] in
      /// Must set this before calling `addVideoViewToWindow()`
      pipStatus = .notInPIP

      addVideoViewToWindow()
      videoView.apply(windowedModeGeometry)

      // If using legacy windowed mode, need to manually add title to Window menu & Dock
      updateTitle()
    })

    animationTasks.append(IINAAnimation.zeroDurationTask { [self] in
      // Similarly, we need to run a redraw here as well. We check to make sure we
      // are paused, because this causes a janky animation in either case but as
      // it's not necessary while the video is playing and significantly more
      // noticeable, we only redraw if we are paused.
      forceDraw()

      resetFadeTimer()

      isWindowMiniaturizedDueToPip = false
      isWindowHidden = false
      player.saveState()
    })

    animationPipeline.submit(animationTasks)
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
