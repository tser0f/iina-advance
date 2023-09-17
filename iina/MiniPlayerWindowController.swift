//
//  MiniPlayerWindowController.swift
//  iina
//
//  Created by lhc on 30/7/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Cocoa

// Hide playlist if its height is too small to display at least 3 items:

class MiniPlayerWindowController: NSViewController, NSPopoverDelegate {
  static let controlViewHeight: CGFloat = 72
  static let defaultWindowWidth: CGFloat = 280
  static let minWindowWidth: CGFloat = 260
  static let PlaylistMinHeight: CGFloat = 138
  static private let animationDurationShowControl: TimeInterval = 0.2

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
  @IBOutlet weak var playlistWrapperView: NSVisualEffectView!
  @IBOutlet weak var mediaInfoView: NSView!
  @IBOutlet weak var controlView: NSView!
  @IBOutlet weak var titleLabel: ScrollingTextField!
  @IBOutlet weak var titleLabelTopConstraint: NSLayoutConstraint!
  @IBOutlet weak var artistAlbumLabel: ScrollingTextField!
  @IBOutlet weak var volumeLabel: NSTextField!
  @IBOutlet weak var togglePlaylistButton: NSButton!
  @IBOutlet weak var toggleAlbumArtButton: NSButton!
  let defaultAlbumArtView = NSView()

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
      mainWindow.musicModeGeometry.isPlaylistVisible
    }
  }

  var isVideoVisible: Bool {
    get {
      return mainWindow.musicModeGeometry.isVideoVisible
    }
  }

  static var maxWindowWidth: CGFloat {
    return CGFloat(Preference.float(for: .musicModeMaxWidth))
  }

  lazy var hideVolumePopover: DispatchWorkItem = {
    DispatchWorkItem {
      self.volumePopover.animates = true
      self.volumePopover.performClose(self)
    }
  }()

  var currentDisplayedPlaylistHeight: CGFloat {
    let bottomBarHeight = mainWindow.videoContainerBottomOffsetFromContentViewBottomConstraint.constant
    return bottomBarHeight - MiniPlayerWindowController.controlViewHeight
  }

  // MARK: - Initialization

  override func viewDidLoad() {
    super.viewDidLoad()

    playlistWrapperView.heightAnchor.constraint(greaterThanOrEqualToConstant: MiniPlayerWindowController.PlaylistMinHeight).isActive = true

    backgroundView.heightAnchor.constraint(equalToConstant: MiniPlayerWindowController.controlViewHeight).isActive = true

    /// Set up tracking area to show controller when hovering over it
    mainWindow.videoContainerView.addTrackingArea(NSTrackingArea(rect: mainWindow.videoContainerView.bounds, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self, userInfo: nil))
    backgroundView.addTrackingArea(NSTrackingArea(rect: backgroundView.bounds, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self, userInfo: nil))

    // default album art
//    mainWindow.videoContainerView.addSubview(defaultAlbumArtView)
//    defaultAlbumArtView.addConstraintsToFillSuperview()
//    defaultAlbumArtView.widthAnchor.constraint(equalTo: defaultAlbumArtView.heightAnchor).isActive = true
//    defaultAlbumArtView.wantsLayer = true
//    defaultAlbumArtView.layer?.contents = #imageLiteral(resourceName: "default-album-art")
//    defaultAlbumArtView.isHidden = true

    // close button
    mainWindow.closeButtonVE.action = #selector(mainWindow.close)
    mainWindow.closeButtonBox.action = #selector(mainWindow.close)
    mainWindow.closeButtonBackgroundViewVE.roundCorners(withRadius: 8)

    // hide controls initially
    mainWindow.closeButtonBackgroundViewBox.isHidden = true
    mainWindow.closeButtonBackgroundViewVE.isHidden = true
    mainWindow.closeButtonView.alphaValue = 0
    controlView.alphaValue = 0
    
    // tool tips
    togglePlaylistButton.toolTip = Preference.ToolBarButton.playlist.description()
    toggleAlbumArtButton.toolTip = NSLocalizedString("mini_player.album_art", comment: "album_art")
    volumeButton.toolTip = NSLocalizedString("mini_player.volume", comment: "volume")
    mainWindow.closeButtonVE.toolTip = NSLocalizedString("mini_player.close", comment: "close")
    mainWindow.backButtonVE.toolTip = NSLocalizedString("mini_player.back", comment: "back")

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
    /// The goal is to always show the control when the cursor is hovering over either of the 2 tracking areas.
    /// Although they are adjacent to each other, `mouseExited` can still be called when moving from one to the other.
    /// Detect and ignore this case.
    guard !mainWindow.isMouseEvent(event, inAnyOf: [backgroundView, mainWindow.videoContainerView]) else {
      return
    }

    hideControl()
  }

  // MARK: - UI: Show / Hide

  private func showControl() {
    mainWindow.animationQueue.run(CocoaAnimation.Task(duration: MiniPlayerWindowController.animationDurationShowControl, { [self] in
      mainWindow.closeButtonView.animator().alphaValue = 1
      controlView.animator().alphaValue = 1
      mediaInfoView.animator().alphaValue = 0
    }))
  }

  private func hideControl() {
    mainWindow.animationQueue.run(CocoaAnimation.Task(duration: MiniPlayerWindowController.animationDurationShowControl, { [self] in
      mainWindow.closeButtonView.animator().alphaValue = 0
      controlView.animator().alphaValue = 0
      mediaInfoView.animator().alphaValue = 1
    }))
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

  private func saveCurrentPlaylistHeight() {
    let playlistHeight = round(currentDisplayedPlaylistHeight)
    // don't save if invalid height or hidden
    guard playlistHeight >= MiniPlayerWindowController.PlaylistMinHeight else { return }

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
    let showPlaylist = !isPlaylistVisible
    Logger.log("Toggling playlist visibility from \((!showPlaylist).yn) to \(showPlaylist.yn)", level: .verbose)
    let currentDisplayedPlaylistHeight = currentDisplayedPlaylistHeight
    let oldGeometry = mainWindow.musicModeGeometry
    var newWindowFrame = window.frame

    if showPlaylist {
      mainWindow.playlistView.reloadData(playlist: true, chapters: true)

      // Try to show playlist using previous height
      let desiredPlaylistHeight = oldGeometry.playlistHeight
      // The window may be in the middle of a previous toggle, so we can't just assume window's current frame
      // represents a state where the playlist is fully shown or fully hidden. Instead, start by computing the height
      // we want to set, and then figure out the changes needed to the window's existing frame.
      let targetHeightToAdd = desiredPlaylistHeight - currentDisplayedPlaylistHeight
      // Fill up screen if needed
      newWindowFrame.size.height += targetHeightToAdd
    } else { // hide playlist
      // Save playlist height first
      saveCurrentPlaylistHeight()
      newWindowFrame.size.height -= currentDisplayedPlaylistHeight
    }

    let heightDifference = newWindowFrame.height - window.frame.height
    // adjust window origin to expand downwards
    newWindowFrame.origin.y = newWindowFrame.origin.y - heightDifference

    // Constrain window so that it doesn't expand below bottom of screen, or fall offscreen
    let newGeometry = oldGeometry.clone(windowFrame: newWindowFrame, isPlaylistVisible: showPlaylist)

    mainWindow.animationQueue.run(CocoaAnimation.Task(duration: CocoaAnimation.DefaultDuration, timing: .easeInEaseOut, { [self] in
      Preference.set(showPlaylist, for: .musicModeShowPlaylist)
      apply(newGeometry)
    }))
  }

  @IBAction func toggleVideoView(_ sender: Any) {
    let showVideo = !isVideoVisible
    log.verbose("Toggling videoView visibility from \((!showVideo).yn) to \(showVideo.yn)")
    mainWindow.updateMusicModeButtonsVisibility()

    let oldGeometry = mainWindow.musicModeGeometry
    var newWindowFrame = oldGeometry.windowFrame
    if showVideo {
      newWindowFrame.size.height += oldGeometry.videoHeightIfVisible
    } else {
      newWindowFrame.size.height -= oldGeometry.videoHeightIfVisible
    }

    let newGeometry = oldGeometry.clone(windowFrame: newWindowFrame, isVideoVisible: showVideo)

    mainWindow.animationQueue.run(CocoaAnimation.Task(duration: CocoaAnimation.DefaultDuration, timing: .easeInEaseOut, { [self] in
      Preference.set(showVideo, for: .musicModeShowAlbumArt)

      log.verbose("VideoView setting visible=\(isVideoVisible), videoHeight=\(newGeometry.videoHeight)")
      mainWindow.videoView.isHidden = !showVideo
      apply(newGeometry)
      player.saveState()
    }))
  }

  // MARK: - Window size & layout

  func windowDidResize() {
    _ = view
    resetScrollingLabels()
  }

  func windowDidEndLiveResize() {
    saveCurrentPlaylistHeight()
    log.verbose("WindowDidEndLiveResize: updating music mode geometry")
    updateMusicModeGeometry(newWindowFrame: window!.frame)
    player.saveState()
  }

  func windowWillResize(_ window: NSWindow, to requestedSize: NSSize) -> NSSize {
    resetScrollingLabels()

    if !window.inLiveResize && requestedSize.width <= MiniPlayerWindowController.minWindowWidth {
      // Responding with the current size seems to work much better with certain window management tools
      // (e.g. BetterTouchTool's window snapping) than trying to respond with the min size,
      // which seems to result in the window manager retrying with different sizes, which results in flickering.
      player.log.verbose("WindowWillResize: requestedSize smaller than min \(MiniPlayerWindowController.minWindowWidth); returning existing size")
      return window.frame.size
    }

    let oldGeometry = mainWindow.musicModeGeometry
    let requestedWindowFrame = NSRect(origin: oldGeometry.windowFrame.origin, size: requestedSize)
    var newGeometry = oldGeometry.clone(windowFrame: requestedWindowFrame)

    CocoaAnimation.disableAnimation{
      apply(newGeometry)  /// this will set `mainWindow.musicModeGeometry` after applying any necessary constraints
    }

    return mainWindow.musicModeGeometry.windowFrame.size
  }

  func updateVideoHeightConstraint(height: CGFloat? = nil, animate: Bool = false) {
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
      videoHeightConstraint = mainWindow.videoView.heightAnchor.constraint(equalToConstant: newHeight)
      videoHeightConstraint.priority = .defaultLow
      videoHeightConstraint.isActive = true
    }
    mainWindow.videoView.superview!.layout()
  }

  func cleanUpForMusicModeExit() {
    view.removeFromSuperview()

    /// Remove `playlistView` from wrapper. It will be added elsewhere if/when it is needed there
    for view in playlistWrapperView.subviews {
      view.removeFromSuperview()
    }
//    defaultAlbumArtView.isHidden = true

    if let videoHeightConstraint = videoHeightConstraint {
      videoHeightConstraint.isActive = false
      self.videoHeightConstraint = nil
    }
  }

  func refreshDefaultAlbumArtVisibility() {
//    defaultAlbumArtView.isHidden = player.info.vid != 0
  }

  func adjustLayoutForVideoChange() {
    guard let window = window else { return }
    resetScrollingLabels()

    refreshDefaultAlbumArtVisibility()

    CocoaAnimation.runAsync(CocoaAnimation.Task{ [self] in
      let newVideoAspectRatio = mainWindow.videoView.aspectRatio
      let newGeometry = mainWindow.musicModeGeometry.clone(windowFrame: window.frame, videoAspectRatio: newVideoAspectRatio)
      apply(newGeometry)
      log.verbose("Updating music mode geometry for video change")
    })
  }

  func buildMusicModeGeometryFromPrefs() -> MusicModeGeometry {
    // Default to left-top of screen. Try to use last-saved playlist height and visibility settings.
    // TODO: just save the whole struct in a prefs entry
    let isPlaylistVisible = Preference.bool(for: .musicModeShowPlaylist)
    let isVideoVisible = Preference.bool(for: .musicModeShowAlbumArt)
    let desiredPlaylistHeight = CGFloat(Preference.float(for: .musicModePlaylistHeight))
    let videoAspectRatio = mainWindow.videoView.aspectRatio
    let desiredWindowWidth = MiniPlayerWindowController.defaultWindowWidth
    let desiredVideoHeight = isVideoVisible ? desiredWindowWidth / videoAspectRatio : 0
    let desiredWindowHeight = desiredVideoHeight + MiniPlayerWindowController.controlViewHeight + (isPlaylistVisible ? desiredPlaylistHeight : 0)

    let screenFrame = mainWindow.bestScreen.visibleFrame
    let windowSize = NSSize(width: desiredWindowWidth, height: desiredWindowHeight)
    let windowOrigin = NSPoint(x: screenFrame.origin.x, y: screenFrame.maxY - windowSize.height)
    let windowFrame = NSRect(origin: windowOrigin, size: windowSize)
    let desiredGeo = MusicModeGeometry(windowFrame: windowFrame, playlistHeight: desiredPlaylistHeight,
                             isVideoVisible: isVideoVisible, isPlaylistVisible: isPlaylistVisible,
                             videoAspectRatio: videoAspectRatio)
    // Resize as needed to fit on screen:
    return desiredGeo.constrainWithin(screenFrame)
  }

  /// Updates `mainWindow.musicModeGeometry` with the given params, falling back to prev values. Also takes care of updating `videoAspectRatio`.
  func updateMusicModeGeometry(newWindowFrame windowFrame: NSRect? = nil, isVideoVisible: Bool? = nil, isPlaylistVisible: Bool? = nil) {
    mainWindow.musicModeGeometry = mainWindow.musicModeGeometry.clone(windowFrame: windowFrame,
                                                                      isVideoVisible: isVideoVisible,
                                                                      isPlaylistVisible: isPlaylistVisible,
                                                                      videoAspectRatio: mainWindow.videoView.aspectRatio)
  }

  /// Updates the current window to match the given `geometry`, and caches it.
  func apply(_ geometry: MusicModeGeometry) {
    let geometry = geometry.constrainWithin(mainWindow.bestScreen.visibleFrame)

    updateVideoHeightConstraint(height: geometry.videoHeight, animate: true)
    mainWindow.updateBottomBarHeight(to: geometry.bottomBarHeight, bottomBarPlacement: .outsideVideo)
    (window as! MainWindow).setFrameImmediately(geometry.windowFrame, animate: true)
    mainWindow.musicModeGeometry = geometry
    player.saveState()
  }
}
