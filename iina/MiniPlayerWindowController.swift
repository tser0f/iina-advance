//
//  MiniPlayerWindowController.swift
//  iina
//
//  Created by lhc on 30/7/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Cocoa

// Hide playlist if its height is too small to display at least 3 items:
fileprivate let PlaylistMinHeight: CGFloat = 138
fileprivate let AnimationDurationShowControl: TimeInterval = 0.2
fileprivate let MiniPlayerMinWidth: CGFloat = 240

class MiniPlayerWindowController: NSViewController, NSPopoverDelegate {
  override var nibName: NSNib.Name {
    return NSNib.Name("MiniPlayerWindowController")
  }

  @objc let monospacedFont: NSFont = {
    let fontSize = NSFont.systemFontSize(for: .mini)
    return NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
  }()

  @IBOutlet weak var volumeSlider: NSSlider!
  @IBOutlet weak var muteButton: NSButton!
  @IBOutlet weak var playButton: NSButton!
  @IBOutlet weak var playSlider: PlaySlider!
  @IBOutlet weak var rightLabel: DurationDisplayTextField!
  @IBOutlet weak var leftLabel: DurationDisplayTextField!

  @IBOutlet weak var volumeButton: NSButton!
  @IBOutlet var volumePopover: NSPopover!
  @IBOutlet weak var volumeSliderView: NSView!
  @IBOutlet weak var backgroundView: NSVisualEffectView!
  @IBOutlet weak var closeButtonView: NSView!
  // Mini island containing window buttons which hover over album art / video:
  @IBOutlet weak var closeButtonBackgroundViewVE: NSVisualEffectView!
  // Mini island containing window buttons which appear next to controls (when video not visible):
  @IBOutlet weak var closeButtonBackgroundViewBox: NSBox!
  @IBOutlet weak var closeButtonVE: NSButton!
  @IBOutlet weak var backButtonVE: NSButton!
  @IBOutlet weak var closeButtonBox: NSButton!
  @IBOutlet weak var backButtonBox: NSButton!
  @IBOutlet weak var playlistWrapperView: NSVisualEffectView!
  @IBOutlet weak var mediaInfoView: NSView!
  @IBOutlet weak var controlView: NSView!
  @IBOutlet weak var titleLabel: ScrollingTextField!
  @IBOutlet weak var titleLabelTopConstraint: NSLayoutConstraint!
  @IBOutlet weak var artistAlbumLabel: ScrollingTextField!
  @IBOutlet weak var volumeLabel: NSTextField!
//  @IBOutlet weak var defaultAlbumArt: NSView!
  @IBOutlet weak var togglePlaylistButton: NSButton!
  @IBOutlet weak var toggleAlbumArtButton: NSButton!

  unowned var mainWindow: MainWindowController!
  var player: PlayerCore {
    return mainWindow.player
  }

  var window: NSWindow? {
    return mainWindow.window
  }

  var log: Logger.Subsystem {
    return mainWindow.log
  }

  /// When resizing the window, need to control the aspect ratio of `videoView`. But cannot use an `aspectRatio` constraint,
  /// because: when playlist is hidden but videoView is shown, that prevents the window from being expanded when the user drags
  /// from the right window edge. Possibly AppKit treats it like a fixed-width constraint. Workaround: use only a `height` constraint
  /// and recalculate it from the video's aspect ratio whenever the window's width changes.
  private var videoHeightConstraint: NSLayoutConstraint!

  var isPlaylistVisible: Bool {
    get {
      Preference.bool(for: .musicModeShowPlaylist)
    }
    set {
      Preference.set(newValue, for: .musicModeShowPlaylist)
    }
  }

  var isVideoVisible: Bool {
    get {
      Preference.bool(for: .musicModeShowAlbumArt)
    }
    set {
      Preference.set(newValue, for: .musicModeShowAlbumArt)
    }
  }

  static let maxWindowWidth = CGFloat(Preference.float(for: .musicModeMaxWidth))

  lazy var hideVolumePopover: DispatchWorkItem = {
    DispatchWorkItem {
      self.volumePopover.animates = true
      self.volumePopover.performClose(self)
    }
  }()

  // MARK: - Initialization

  override func viewDidLoad() {
    super.viewDidLoad()

    playlistWrapperView.heightAnchor.constraint(greaterThanOrEqualToConstant: PlaylistMinHeight).isActive = true

    /// Set up tracking area to show controller when hovering over it
    if let window = window {
      mainWindow.videoContainerView.addTrackingArea(NSTrackingArea(rect: mainWindow.videoContainerView.bounds, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self, userInfo: nil))
      backgroundView.addTrackingArea(NSTrackingArea(rect: backgroundView.bounds, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self, userInfo: nil))
    }

    // default album art
//    defaultAlbumArt.wantsLayer = true
//    defaultAlbumArt.layer?.contents = #imageLiteral(resourceName: "default-album-art")

    // close button
    closeButtonVE.action = #selector(mainWindow.close)
    closeButtonBox.action = #selector(mainWindow.close)
    closeButtonBackgroundViewVE.roundCorners(withRadius: 8)

    // hide controls initially
    closeButtonBackgroundViewBox.isHidden = true
    closeButtonView.alphaValue = 0
    controlView.alphaValue = 0

    updateVideoViewLayout()
    
    // tool tips
    togglePlaylistButton.toolTip = Preference.ToolBarButton.playlist.description()
    toggleAlbumArtButton.toolTip = NSLocalizedString("mini_player.album_art", comment: "album_art")
    volumeButton.toolTip = NSLocalizedString("mini_player.volume", comment: "volume")
    closeButtonVE.toolTip = NSLocalizedString("mini_player.close", comment: "close")
    backButtonVE.toolTip = NSLocalizedString("mini_player.back", comment: "back")

    volumePopover.delegate = self

    leftLabel.mode = .current
    rightLabel.mode = Preference.bool(for: .showRemainingTime) ? .remaining : .duration

    log.verbose("MiniPlayer viewDidLoad done")
  }

  // MARK: - Mouse / Trackpad events

  override func mouseEntered(with event: NSEvent) {
    showControl()
  }

  override func mouseExited(with event: NSEvent) {
    guard !volumePopover.isShown else { return }
    hideControl()
  }

  // MARK: - UI: Show / Hide

  private func showControl() {
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = AnimationDurationShowControl
      closeButtonView.animator().alphaValue = 1
      controlView.animator().alphaValue = 1
      mediaInfoView.animator().alphaValue = 0
    })
  }

  private func hideControl() {
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = AnimationDurationShowControl
      closeButtonView.animator().alphaValue = 0
      controlView.animator().alphaValue = 0
      mediaInfoView.animator().alphaValue = 1
    })
  }

  // MARK: - UI

  func updateScrollingLabels() {
    titleLabel.stepNext()
    artistAlbumLabel.stepNext()
  }

  private func resetScrollingLabels() {
    titleLabel.reset()
    artistAlbumLabel.reset()
  }

  func saveCurrentPlaylistHeight() {
    let playlistHeight = round(currentPlaylistHeight)
    guard playlistHeight >= PlaylistMinHeight else { return }

    // save playlist height
    log.verbose("Saving playlist height: \(playlistHeight)")
    Preference.set(playlistHeight, for: .musicModePlaylistHeight)
  }

  func updateTitle(mediaTitle: String, mediaAlbum: String, mediaArtist: String) {
    titleLabel.stringValue = mediaTitle
    // hide artist & album label when info not available
    if mediaArtist.isEmpty && mediaAlbum.isEmpty {
      titleLabelTopConstraint.constant = 6 + 10
      artistAlbumLabel.stringValue = ""
    } else {
      titleLabelTopConstraint.constant = 6
      if mediaArtist.isEmpty || mediaAlbum.isEmpty {
        artistAlbumLabel.stringValue = "\(mediaArtist)\(mediaAlbum)"
      } else {
        artistAlbumLabel.stringValue = "\(mediaArtist) - \(mediaAlbum)"
      }
    }
  }

  func updateVolumeUI() {
    let vol = player.info.volume
    volumeSlider.doubleValue = vol
    volumeLabel.intValue = Int32(vol)
    if player.info.isMuted {
      volumeButton.image = NSImage(named: "mute")
    } else {
      switch volumeLabel.intValue {
      case 0:
        volumeButton.image = NSImage(named: "volume-0")
      case 1...33:
        volumeButton.image = NSImage(named: "volume-1")
      case 34...66:
        volumeButton.image = NSImage(named: "volume-2")
      case 67...1000:
        volumeButton.image = NSImage(named: "volume")
      default:
        break
      }
    }
  }

  // MARK: - NSPopoverDelegate

  func popoverWillClose(_ notification: Notification) {
    if NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) != window!.windowNumber {
      hideControl()
    }
  }

  func handleVolumePopover(_ isTrackpadBegan: Bool, _ isTrackpadEnd: Bool, _ isMouse: Bool) {
    hideVolumePopover.cancel()
    hideVolumePopover = DispatchWorkItem {
      self.volumePopover.animates = true
      self.volumePopover.performClose(self)
    }
    if isTrackpadBegan {
       // enabling animation here causes user not seeing their volume changes during popover transition
       volumePopover.animates = false
       volumePopover.show(relativeTo: volumeButton.bounds, of: volumeButton, preferredEdge: .minY)
     } else if isTrackpadEnd {
       DispatchQueue.main.asyncAfter(deadline: .now(), execute: hideVolumePopover)
     } else if isMouse {
       // if it's a mouse, simply show popover then hide after a while when user stops scrolling
       if !volumePopover.isShown {
         volumePopover.animates = false
         volumePopover.show(relativeTo: volumeButton.bounds, of: volumeButton, preferredEdge: .minY)
       }
       let timeout = Preference.double(for: .osdAutoHideTimeout)
       DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: hideVolumePopover)
     }
  }

  // MARK: - IBActions

  @IBAction func playSliderChanges(_ sender: NSSlider) {
    mainWindow.playSliderChanges(sender)
  }

  @IBAction func volumeSliderChanges(_ sender: NSSlider) {
    mainWindow.volumeSliderChanges(sender)
  }

  @IBAction func muteButtonAction(_ sender: NSButton) {
    player.toggleMute()
  }

  @IBAction func backBtnAction(_ sender: NSButton) {
    player.exitMusicMode()
  }

  @IBAction func playButtonAction(_ sender: NSButton) {
    mainWindow.playButtonAction(sender)
  }

  @IBAction func nextBtnAction(_ sender: NSButton) {
    player.navigateInPlaylist(nextMedia: true)
  }

  @IBAction func prevBtnAction(_ sender: NSButton) {
    player.navigateInPlaylist(nextMedia: false)
  }

  @IBAction func volumeBtnAction(_ sender: NSButton) {
    if volumePopover.isShown {
      volumePopover.performClose(self)
    } else {
      updateVolumeUI()
      volumePopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }
  }

  @IBAction func togglePlaylist(_ sender: Any) {
    guard let window = mainWindow.window else { return }
    guard let screen = window.screen else { return }
    let showPlaylist = !isPlaylistVisible
    Logger.log("Toggling playlist visibility from \((!showPlaylist).yn) to \(showPlaylist.yn)", level: .verbose)
    self.isPlaylistVisible = showPlaylist
    let currentPlaylistHeight = currentPlaylistHeight
    var newWindowFrame = window.frame

    if showPlaylist {
      mainWindow.playlistView.reloadData(playlist: true, chapters: true)

      // Try to show playlist using previous height
      let desiredPlaylistHeight = CGFloat(Preference.float(for: .musicModePlaylistHeight))
      // The window may be in the middle of a previous toggle, so we can't just assume window's current frame
      // represents a state where the playlist is fully shown or fully hidden. Instead, start by computing the height
      // we want to set, and then figure out the changes needed to the window's existing frame.
      let targetHeightToAdd = desiredPlaylistHeight - currentPlaylistHeight
      // Fill up screen if needed
      newWindowFrame.size.height += targetHeightToAdd
    } else { // hide playlist
      // Save playlist height first
      if currentPlaylistHeight > PlaylistMinHeight {
        Preference.set(currentPlaylistHeight, for: .musicModePlaylistHeight)
      }
    }

    // May need to reduce size of video/art to fit playlist on screen, or other adjustments:
    newWindowFrame.size = constrainWindowSize(newWindowFrame.size)
    let heightDifference = newWindowFrame.height - window.frame.height
    // adjust window origin to expand downwards, but do not allow bottom of window to fall offscreen
    newWindowFrame.origin.y = max(newWindowFrame.origin.y - heightDifference, screen.visibleFrame.origin.y)


    let videoHeight = isVideoVisible ? newWindowFrame.width / mainWindow.videoView.aspectRatio : 0
    let bottomBarHeight = newWindowFrame.height - videoHeight

    mainWindow.animationQueue.run(CocoaAnimation.Task(duration: CocoaAnimation.DefaultDuration, timing: .easeInEaseOut, { [self] in
      mainWindow.updateBottomBarHeight(to: bottomBarHeight, bottomBarPlacement: .outsideVideo)
      updateVideoHeightConstraint(height: videoHeight, animate: true)
      (window as! MainWindow).setFrameImmediately(newWindowFrame, animate: true)
      player.saveState()
    }))
  }

  @IBAction func toggleVideoView(_ sender: Any) {
    guard let window = mainWindow.window else { return }
    isVideoVisible = !isVideoVisible
    Logger.log("Toggling videoView visibility from \((!isVideoVisible).yn) to \(isVideoVisible.yn)", level: .verbose)
    updateVideoViewLayout()
    var newWindowFrame = window.frame
    let videoHeightIfVisible = newWindowFrame.width / mainWindow.videoView.aspectRatio
    if isVideoVisible {
      newWindowFrame.size.height += videoHeightIfVisible
    } else {
      newWindowFrame.size.height -= round(mainWindow.videoView.frame.height)
    }
    newWindowFrame.size = constrainWindowSize(newWindowFrame.size)


    let videoHeight = isVideoVisible ? videoHeightIfVisible : 0
    let bottomBarHeight = newWindowFrame.height - videoHeight

    mainWindow.animationQueue.run(CocoaAnimation.Task(duration: CocoaAnimation.DefaultDuration, timing: .easeInEaseOut, { [self] in
      updateVideoHeightConstraint(height: isVideoVisible ? videoHeight : 0, animate: true)
      mainWindow.updateBottomBarHeight(to: bottomBarHeight, bottomBarPlacement: .outsideVideo)
      (window as! MainWindow).setFrameImmediately(newWindowFrame, animate: true)
      player.saveState()
    }))
  }

  // MARK: - Window size & layout

  func windowDidResize() {
    resetScrollingLabels()
  }

  func windowWillResize(_ window: NSWindow, to requestedSize: NSSize) -> NSSize {
    resetScrollingLabels()

    if !window.inLiveResize && requestedSize.width <= MiniPlayerMinWidth {
      // Responding with the current size seems to work much better with certain window management tools
      // (e.g. BetterTouchTool's window snapping) than trying to respond with the min size,
      // which seems to result in the window manager retrying with different sizes, which results in flickering.
      Logger.log("WindowWillResize: requestedSize smaller than min \(MiniPlayerMinWidth); returning existing size", level: .verbose, subsystem: player.subsystem)
      return window.frame.size
    }

    let newWindowSize = constrainWindowSize(requestedSize)

    CocoaAnimation.disableAnimation{
      let videoHeight = isVideoVisible ? newWindowSize.width / mainWindow.videoView.aspectRatio : 0
      let bottomBarHeight = newWindowSize.height - videoHeight
      updateVideoHeightConstraint(height: isVideoVisible ? videoHeight : 0, animate: false)
      mainWindow.updateBottomBarHeight(to: bottomBarHeight, bottomBarPlacement: .outsideVideo)
//      player.saveState()
    }

    return newWindowSize
  }

  private func updateVideoViewLayout() {
    closeButtonBackgroundViewVE.isHidden = !isVideoVisible
    closeButtonBackgroundViewBox.isHidden = isVideoVisible
  }

  /// The MiniPlayerWindow's width must be between `MiniPlayerMinWidth` and `Preference.musicModeMaxWidth`.
  /// It is composed of up to 3 vertical sections:
  /// 1. `videoWrapperView`: Visible if `isVideoVisible` is true). Scales with the aspect ratio of its video
  /// 2. `backgroundView`: Visible always. Fixed height
  /// 3. `playlistWrapperView`: Visible if `isPlaylistVisible` is true. Height is user resizable, and must be >= `PlaylistMinHeight`
  /// Must also ensure that window stays within the bounds of the screen it is in. Almost all of the time the window  will be
  /// height-bounded instead of width-bounded.
  private func constrainWindowSize(_ requestedSize: NSSize) -> NSSize {
    guard let screen = window?.screen else { return requestedSize }
    /// When the window's width changes, the video scales to match while keeping its aspect ratio,
    /// and the control bar (`backgroundView`) and playlist are pushed down.
    /// Calculate the maximum width/height the art can grow to so that `backgroundView` is not pushed off the screen.
    let videoAspectRatio = mainWindow.videoView.aspectRatio
    let isVideoVisible = isVideoVisible
    let isPlaylistVisible = isPlaylistVisible
    let visibleScreenSize = screen.visibleFrame.size
    let minPlaylistHeight = isPlaylistVisible ? PlaylistMinHeight : 0

    let maxWindowWidth: CGFloat
    if isVideoVisible {
      var maxVideoHeight = visibleScreenSize.height - backgroundView.frame.height - minPlaylistHeight
      /// `maxVideoHeight` can be negative if very short screen! Fall back to height based on `MiniPlayerMinWidth` if needed
      maxVideoHeight = max(maxVideoHeight, MiniPlayerMinWidth / videoAspectRatio)
      maxWindowWidth = maxVideoHeight * videoAspectRatio
    } else {
      maxWindowWidth = MiniPlayerWindowController.maxWindowWidth
    }

    let newWidth: CGFloat
    if requestedSize.width < MiniPlayerMinWidth {
      // Clamp to min width
      newWidth = MiniPlayerMinWidth
    } else if requestedSize.width > maxWindowWidth {
      // Clamp to max width
      newWidth = maxWindowWidth
    } else {
      // Requested size is valid
      newWidth = requestedSize.width
    }
    let videoHeight = isVideoVisible ? newWidth / videoAspectRatio : 0
    let minWindowHeight = videoHeight + backgroundView.frame.height + minPlaylistHeight
    // Make sure height is within acceptable values
    var newHeight = max(requestedSize.height, minWindowHeight)
    let maxHeight = isPlaylistVisible ? visibleScreenSize.height : minWindowHeight
    newHeight = min(newHeight, maxHeight)
    let newWindowSize = NSSize(width: newWidth, height: newHeight)
    Logger.log("Constraining miniPlayer. Video=\(isVideoVisible.yn) Playlist=\(isPlaylistVisible.yn) VideoAspect=\(videoAspectRatio.string2f), ReqSize=\(requestedSize), NewSize=\(newWindowSize)", level: .verbose)

    return newWindowSize
  }

  private func updateVideoHeightConstraint(height: CGFloat? = nil, animate: Bool = false) {
    let newHeight: CGFloat
    guard isVideoVisible else { return }
    guard let window = window else { return }

    newHeight = height ?? window.frame.width / mainWindow.videoView.aspectRatio

    if let videoHeightConstraint = videoHeightConstraint {
      if animate {
        videoHeightConstraint.animateToConstant(newHeight)
      } else {
        videoHeightConstraint.constant = newHeight
      }
    } else {
      videoHeightConstraint = mainWindow.videoContainerView.heightAnchor.constraint(equalToConstant: newHeight)
      videoHeightConstraint.priority = .defaultLow
      videoHeightConstraint.isActive = true
    }
    mainWindow.videoContainerView.superview!.layout()
  }

  // Returns the current height of the window,
  // including the album art, but not including the playlist.
  private var windowHeightWithoutPlaylist: CGFloat {
    guard let window = mainWindow.window else { return backgroundView.frame.height }
    return backgroundView.frame.height + (isVideoVisible ? window.frame.width / mainWindow.videoView.aspectRatio : 0)
  }

  private var currentPlaylistHeight: CGFloat {
    guard let window = mainWindow.window else { return 0 }
    return window.frame.height - windowHeightWithoutPlaylist
  }

  func cleanUpForMusicModeExit() {
    view.removeFromSuperview()

    /// Remove `playlistView` from wrapper. It will be added elsewhere if/when it is needed there
    for view in playlistWrapperView.subviews {
      view.removeFromSuperview()
    }

    if let videoHeightConstraint = videoHeightConstraint {
      videoHeightConstraint.isActive = false
      self.videoHeightConstraint = nil
    }
  }

  func adjustLayoutForVideoChange() {
    guard let window = window else { return }
    resetScrollingLabels()

//    defaultAlbumArt.isHidden = player.info.vid != 0

    CocoaAnimation.runAsync(CocoaAnimation.Task{ [self] in
      var newWindowFrame = window.frame
      newWindowFrame.size = constrainWindowSize(newWindowFrame.size)

      let videoHeight = isVideoVisible ? newWindowFrame.width / mainWindow.videoView.aspectRatio : 0
      let bottomBarHeight = newWindowFrame.height - videoHeight
      updateVideoHeightConstraint(height: isVideoVisible ? videoHeight : 0, animate: true)
      mainWindow.updateBottomBarHeight(to: bottomBarHeight, bottomBarPlacement: .outsideVideo)

      (window as! MainWindow).setFrameImmediately(newWindowFrame, animate: true)
    })
  }

}
