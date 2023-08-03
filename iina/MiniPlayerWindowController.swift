//
//  MiniPlayerWindowController.swift
//  iina
//
//  Created by lhc on 30/7/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Cocoa

// Hide playlist if its height is too small to display at least 3 items:
fileprivate let PlaylistMinHeight: CGFloat = 140
fileprivate let AnimationDurationShowControl: TimeInterval = 0.2
fileprivate let MiniPlayerMinWidth: CGFloat = 300

class MiniPlayerWindowController: PlayerWindowController, NSPopoverDelegate {

  override var windowNibName: NSNib.Name {
    return NSNib.Name("MiniPlayerWindowController")
  }

  @objc let monospacedFont: NSFont = {
    let fontSize = NSFont.systemFontSize(for: .mini)
    return NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
  }()

  @IBOutlet weak var volumeButton: NSButton!
  @IBOutlet var volumePopover: NSPopover!
  @IBOutlet weak var volumeSliderView: NSView!
  @IBOutlet weak var backgroundView: NSVisualEffectView!
  @IBOutlet weak var closeButtonView: NSView!
  @IBOutlet weak var closeButtonBackgroundViewVE: NSVisualEffectView!
  @IBOutlet weak var closeButtonVE: NSButton!
  @IBOutlet weak var backButtonVE: NSButton!
  @IBOutlet weak var videoWrapperView: NSView!
  @IBOutlet var videoWrapperViewBottomConstraint: NSLayoutConstraint!
  @IBOutlet var controlViewTopConstraint: NSLayoutConstraint!
  @IBOutlet weak var playlistWrapperView: NSVisualEffectView!
  @IBOutlet weak var mediaInfoView: NSView!
  @IBOutlet weak var controlView: NSView!
  @IBOutlet weak var titleLabel: ScrollingTextField!
  @IBOutlet weak var titleLabelTopConstraint: NSLayoutConstraint!
  @IBOutlet weak var artistAlbumLabel: ScrollingTextField!
  @IBOutlet weak var volumeLabel: NSTextField!
  @IBOutlet weak var defaultAlbumArt: NSView!
  @IBOutlet weak var togglePlaylistButton: NSButton!
  @IBOutlet weak var toggleAlbumArtButton: NSButton!

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

  override var mouseActionDisabledViews: [NSView?] {[backgroundView, playlistWrapperView] as [NSView?]}

  // MARK: - Initialization

  override init(playerCore: PlayerCore) {
    super.init(playerCore: playerCore)
    self.windowFrameAutosaveName = String(format: Constants.WindowAutosaveName.miniPlayer, playerCore.label)
    Logger.log("MiniPlayerWindowController init, autosaveName: \(self.windowFrameAutosaveName.quoted)", level: .verbose, subsystem: playerCore.subsystem)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func windowDidLoad() {
    super.windowDidLoad()

    guard let window = window,
          let contentView = window.contentView else { return }

    window.styleMask = [.fullSizeContentView, .titled, .resizable, .closable, .miniaturizable]
    window.isMovableByWindowBackground = true
    window.titleVisibility = .hidden
    ([.closeButton, .miniaturizeButton, .zoomButton, .documentIconButton] as [NSWindow.ButtonType]).forEach {
      let button = window.standardWindowButton($0)
      button?.isHidden = true
      // The close button, being obscured by standard buttons, won't respond to clicking when window is inactive.
      // i.e. clicking close button (or any position located in the standard buttons's frame) will only order the window
      // to front, but it never becomes key or main window.
      // Removing the button directly will also work but it causes crash on 10.12-, so for the sake of safety we don't use that way for now.
      // FIXME: Not a perfect solution. It should respond to the first click.
    }

    contentView.widthAnchor.constraint(greaterThanOrEqualToConstant: MiniPlayerMinWidth).isActive = true
    contentView.widthAnchor.constraint(lessThanOrEqualToConstant: MiniPlayerWindowController.maxWindowWidth).isActive = true

    playlistWrapperView.heightAnchor.constraint(greaterThanOrEqualToConstant: PlaylistMinHeight).isActive = true

    controlViewTopConstraint.isActive = false

    // tracking area
    let trackingView = NSView()
    trackingView.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(trackingView, positioned: .above, relativeTo: nil)
    Utility.quickConstraints(["H:|[v]|"], ["v": trackingView])
    NSLayoutConstraint.activate([
      NSLayoutConstraint(item: trackingView, attribute: .bottom, relatedBy: .equal, toItem: backgroundView, attribute: .bottom, multiplier: 1, constant: 0),
      NSLayoutConstraint(item: trackingView, attribute: .top, relatedBy: .equal, toItem: videoWrapperView, attribute: .top, multiplier: 1, constant: 0)
    ])
    trackingView.addTrackingArea(NSTrackingArea(rect: trackingView.bounds, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self, userInfo: nil))

    // default album art
    defaultAlbumArt.wantsLayer = true
    defaultAlbumArt.layer?.contents = #imageLiteral(resourceName: "default-album-art")

    // close button
    closeButtonVE.action = #selector(self.close)
    closeButtonBackgroundViewVE.roundCorners(withRadius: 8)

    // hide controls initially
    closeButtonView.alphaValue = 0
    controlView.alphaValue = 0
    
    // tool tips
    togglePlaylistButton.toolTip = Preference.ToolBarButton.playlist.description()
    toggleAlbumArtButton.toolTip = NSLocalizedString("mini_player.album_art", comment: "album_art")
    volumeButton.toolTip = NSLocalizedString("mini_player.volume", comment: "volume")
    closeButtonVE.toolTip = NSLocalizedString("mini_player.close", comment: "close")
    backButtonVE.toolTip = NSLocalizedString("mini_player.back", comment: "back")

    if Preference.bool(for: .alwaysFloatOnTop) {
      setWindowFloatingOnTop(true)
    }
    volumeSlider.maxValue = Double(Preference.integer(for: .maxVolume))
    volumePopover.delegate = self
  }

  override internal func setMaterial(_ theme: Preference.Theme?) {
    if #available(macOS 10.14, *) {
      super.setMaterial(theme)
      return
    }
    guard let window = window, let theme = theme else { return }

    let (appearance, material) = Utility.getAppearanceAndMaterial(from: theme)

    [backgroundView, closeButtonBackgroundViewVE, playlistWrapperView].forEach {
      $0?.appearance = appearance
      $0?.material = material
    }

    window.appearance = appearance
  }

  // MARK: - Mouse / Trackpad events

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(window)
    super.mouseDown(with: event)
  }

  override func scrollWheel(with event: NSEvent) {
    if isMouseEvent(event, inAnyOf: [playSlider]) && playSlider.isEnabled {
      seekOverride = true
    } else if isMouseEvent(event, inAnyOf: [volumeSliderView]) && volumeSlider.isEnabled {
      volumeOverride = true
    } else {
      guard !isMouseEvent(event, inAnyOf: [backgroundView]) else { return }
    }

    super.scrollWheel(with: event)

    seekOverride = false
    volumeOverride = false
  }

  override func mouseEntered(with event: NSEvent) {
    showControl()
  }

  override func mouseExited(with event: NSEvent) {
    guard !volumePopover.isShown else { return }
    hideControl()
  }

  // MARK: - Window delegate: Open / Close

  override func showWindow(_ sender: Any?) {
    resetScrollingLabels()
    super.showWindow(sender)
  }

  func windowWillClose(_ notification: Notification) {
    if !player.isShuttingDown {
      // not needed if called when terminating the whole app
      player.overrideAutoSwitchToMusicMode = false
      player.switchBackFromMiniPlayer(automatically: true)
    }
    player.mainWindow.close()
  }

  // MARK: - Window delegate: Size

  func windowWillResize(_ window: NSWindow, to requestedSize: NSSize) -> NSSize {
    resetScrollingLabels()
    return constrainWindowSize(requestedSize)
  }

  func windowDidResize(_ notification: Notification) {
    guard let window = window, !window.inLiveResize else { return }

    // Re-evaluate space requirements for labels. May need to scroll
    resetScrollingLabels()

    videoView.videoLayer.draw()
  }

  func windowDidEndLiveResize(_ notification: Notification) {
    let playlistHeight = currentPlaylistHeight
    if playlistHeight >= PlaylistMinHeight {
      // save playlist height
      Logger.log("Saving playlist height: \(playlistHeight)")
      Preference.set(playlistHeight, for: .musicModePlaylistHeight)
    }
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

  @objc
  override func updateTitle() {
    let (mediaTitle, mediaAlbum, mediaArtist) = player.getMusicMetadata()
    titleLabel.stringValue = mediaTitle
    window?.title = mediaTitle
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

  override func updateVolume() {
    guard loaded else { return }
    super.updateVolume()
    volumeLabel.intValue = Int32(player.info.volume)
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

  @objc func menuAlwaysOnTop(_ sender: AnyObject) {
    setWindowFloatingOnTop(!isOntop)
  }

  @IBAction func backBtnAction(_ sender: NSButton) {
    player.switchBackFromMiniPlayer()
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
      volumePopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }
  }

  func updateVideoViewLayout() {
    videoWrapperViewBottomConstraint.isActive = isVideoVisible
    controlViewTopConstraint.isActive = !isVideoVisible
    closeButtonBackgroundViewVE.isHidden = !isVideoVisible
  }

  @IBAction func togglePlaylist(_ sender: Any) {
    guard let window = window else { return }
    guard let screen = window.screen else { return }
    let showPlaylist = !isPlaylistVisible
    Logger.log("Toggling playlist visibility from \(!showPlaylist) to \(showPlaylist)", level: .verbose)
    self.isPlaylistVisible = showPlaylist
    let currentPlaylistHeight = currentPlaylistHeight
    var newFrame = window.frame

    if showPlaylist {
      player.mainWindow.playlistView.reloadData(playlist: true, chapters: true)

      // Try to show playlist using previous height
      let desiredPlaylistHeight = CGFloat(Preference.float(for: .musicModePlaylistHeight))
      // The window may be in the middle of a previous toggle, so we can't just assume window's current frame
      // represents a state where the playlist is fully shown or fully hidden. Instead, start by computing the height
      // we want to set, and then figure out the changes needed to the window's existing frame.
      let heightToAdd = desiredPlaylistHeight - currentPlaylistHeight
      // Fill up screen if needed
      newFrame.origin.y = max(newFrame.origin.y - heightToAdd, screen.visibleFrame.origin.y)
      newFrame.size.height = min(newFrame.size.height + heightToAdd, screen.visibleFrame.height)

      // May need to reduce size of video/art to fit playlist on screen, or other adjustments:
      newFrame.size = constrainWindowSize(newFrame.size)
    } else { // hide playlist
      // Save playlist height first
      if currentPlaylistHeight > PlaylistMinHeight {
        Preference.set(currentPlaylistHeight, for: .musicModePlaylistHeight)
      }
      let heightWithoutPlaylist = windowHeightWithoutPlaylist
      newFrame.origin.y += newFrame.size.height - heightWithoutPlaylist
      newFrame.size.height = heightWithoutPlaylist
    }

    window.animator().setFrame(newFrame, display: true, animate: !AccessibilityPreferences.motionReductionEnabled)
  }

  @IBAction func toggleVideoView(_ sender: Any) {
    guard let window = window else { return }
    isVideoVisible = !isVideoVisible
    updateVideoViewLayout()
    let videoViewHeight = round(videoView.frame.height)
    if isVideoVisible {
      var frame = window.frame
      frame.size.height += videoViewHeight
      frame.size = constrainWindowSize(frame.size)
      window.setFrame(frame, display: true, animate: false)
    } else {
      var frame = window.frame
      frame.size.height -= videoViewHeight
      window.setFrame(frame, display: true, animate: false)
    }
  }

  // MARK: - Utils

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
    let videoAspectRatio = videoView.aspectRatio
    let visibleScreenSize = screen.visibleFrame.size
    let minPlaylistHeight = isPlaylistVisible ? PlaylistMinHeight : 0

    let maxWindowWidth: CGFloat
    if isVideoVisible {
      var maxVideoHeight = visibleScreenSize.height - backgroundView.frame.height - minPlaylistHeight
      /// `maxVideoHeight` can be negative if very short screen! Fall back to height based on `MiniPlayerMinWidth` if needed
      maxVideoHeight = max(maxVideoHeight, MiniPlayerMinWidth / videoView.aspectRatio)
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
    Logger.log("Constrained miniPlayerWindow. VideoAspect: \(videoAspectRatio), RequestedSize: \(requestedSize), NewSize: \(newWindowSize)", level: .verbose)

    return newWindowSize
  }

  // Returns the current height of the window,
  // including the album art, but not including the playlist.
  private var windowHeightWithoutPlaylist: CGFloat {
    return backgroundView.frame.height + (isVideoVisible ? videoWrapperView.frame.height : 0)
  }

  private var currentPlaylistHeight: CGFloat {
    guard let window = window else { return 0 }
    return window.frame.height - windowHeightWithoutPlaylist
  }

}
