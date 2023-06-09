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

  override var videoView: VideoView {
    return player.mainWindow.videoView
  }

  @IBOutlet weak var volumeButton: NSButton!
  @IBOutlet var volumePopover: NSPopover!
  @IBOutlet weak var volumeSliderView: NSView!
  @IBOutlet weak var backgroundView: NSVisualEffectView!
  @IBOutlet weak var closeButtonView: NSView!
  @IBOutlet weak var closeButtonBackgroundViewVE: NSVisualEffectView!
  @IBOutlet weak var closeButtonBackgroundViewBox: NSBox!
  @IBOutlet weak var closeButtonVE: NSButton!
  @IBOutlet weak var backButtonVE: NSButton!
  @IBOutlet weak var closeButtonBox: NSButton!
  @IBOutlet weak var backButtonBox: NSButton!
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

  // The window size determines whether the playlist is shown or not.
  var isPlaylistVisible: Bool {
    get {
      Preference.bool(for: .musicModeShowPlaylist)
    }
    set {
      // We already use autosave to save the window frame across launches, so one would think we could
      // determinte whether the playlist is visible just by inspecting the window's size.
      // But we still need to save this info and restore it in case IINA is later relaunched using
      // some very different display/resolution which changes the window size.
      Preference.set(newValue, for: .musicModeShowPlaylist)
    }
  }

  var isVideoVisible = true

  var videoViewAspectConstraint: NSLayoutConstraint?

  private var originalWindowFrame: NSRect!

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

    guard let window = window else { return }

    window.styleMask = [.fullSizeContentView, .titled, .resizable, .closable]
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
      button?.frame.size = .zero
    }

    playlistWrapperView.widthAnchor.constraint(greaterThanOrEqualToConstant: MiniPlayerMinWidth).isActive = true
    let maxWidth = CGFloat(Preference.float(for: .musicModeMaxWidth))
    playlistWrapperView.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth).isActive = true
    playlistWrapperView.heightAnchor.constraint(greaterThanOrEqualToConstant: PlaylistMinHeight).isActive = true

    controlViewTopConstraint.isActive = false

    // tracking area
    let trackingView = NSView()
    trackingView.translatesAutoresizingMaskIntoConstraints = false
    window.contentView?.addSubview(trackingView, positioned: .above, relativeTo: nil)
    Utility.quickConstraints(["H:|[v]|"], ["v": trackingView])
    NSLayoutConstraint.activate([
      NSLayoutConstraint(item: trackingView, attribute: .bottom, relatedBy: .equal, toItem: backgroundView, attribute: .bottom, multiplier: 1, constant: 0),
      NSLayoutConstraint(item: trackingView, attribute: .top, relatedBy: .equal, toItem: videoWrapperView, attribute: .top, multiplier: 1, constant: 0)
    ])
    trackingView.addTrackingArea(NSTrackingArea(rect: trackingView.bounds, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self, userInfo: nil))

    // default album art
    defaultAlbumArt.isHidden = false
    defaultAlbumArt.wantsLayer = true
    defaultAlbumArt.layer?.contents = #imageLiteral(resourceName: "default-album-art")

    // close button
    closeButtonVE.action = #selector(self.close)
    closeButtonBox.action = #selector(self.close)
    closeButtonView.alphaValue = 0
    closeButtonBackgroundViewVE.roundCorners(withRadius: 8)
    closeButtonBackgroundViewBox.isHidden = true

    // switching UI
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

  func windowWillClose(_ notification: Notification) {
    player.switchedToMiniPlayerManually = false
    player.switchedBackFromMiniPlayerManually = false
    if !player.isShuttingDown {
      // not needed if called when terminating the whole app
      player.switchBackFromMiniPlayer(automatically: true, showMainWindow: false)
    }
    player.mainWindow.close()
  }

  // MARK: - Window delegate: Size

  func windowWillStartLiveResize(_ notification: Notification) {
    originalWindowFrame = window!.frame
  }

  func windowWillResize(_ window: NSWindow, to requestedSize: NSSize) -> NSSize {
    return adjustWindowSize(requestedSize)
  }

  func windowDidResize(_ notification: Notification) {
    guard let window = window, !window.inLiveResize else { return }
    videoView.videoLayer.draw()
  }

  func windowDidEndLiveResize(_ notification: Notification) {
    guard let window = window else { return }
    let windowHeight = window.frame.height
    let minHeightForPlaylist = windowHeightWithoutPlaylist() + PlaylistMinHeight
    let shouldShowPlaylist = windowHeight >= minHeightForPlaylist
    Logger.log("WindowDidEndLiveResize: windowHeight=\(windowHeight) minHeightForPlaylist=\(minHeightForPlaylist) shouldShowPlaylist=\(shouldShowPlaylist), isPlaylistVisible=\(isPlaylistVisible)", level: .verbose)
    if shouldShowPlaylist {
      // save playlist height
      if playlistWrapperView.frame.height >= PlaylistMinHeight {
        Preference.set(playlistWrapperView.frame.height, for: .musicModePlaylistHeight)
      }
    } else {
      resizeWindowToHidePlaylist()
    }
    isPlaylistVisible = shouldShowPlaylist
  }

  // MARK: - Window delegate: Activeness status

  override func windowDidBecomeMain(_ notification: Notification) {
    super.windowDidBecomeMain(notification)

    titleLabel.scroll()
    artistAlbumLabel.scroll()
  }

  // MARK: - UI: Show / Hide

  private func showControl() {
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = AnimationDurationShowControl
      closeButtonView.animator().alphaValue = 1
      controlView.animator().alphaValue = 1
      mediaInfoView.animator().alphaValue = 0
    }, completionHandler: {})
  }

  private func hideControl() {
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = AnimationDurationShowControl
      closeButtonView.animator().alphaValue = 0
      controlView.animator().alphaValue = 0
      mediaInfoView.animator().alphaValue = 1
    }, completionHandler: {
      self.titleLabel.scroll()
      self.artistAlbumLabel.scroll()
    })
  }

  // MARK: - UI
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
    titleLabel.scroll()
    artistAlbumLabel.scroll()
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

  func updateVideoSize() {
    guard let window = window else { return }
    let (width, height) = player.originalVideoSize
    let aspect = (width == 0 || height == 0) ? 1 : CGFloat(width) / CGFloat(height)
    let currentHeight = videoView.frame.height
    let newHeight = videoView.frame.width / aspect
    updateVideoViewAspectConstraint(withAspect: aspect)
    // resize window
    guard isVideoVisible else { return }
    var frame = window.frame
    frame.size.height += newHeight - currentHeight - 0.5
    window.setFrame(frame, display: true, animate: false)
  }

  func updateVideoViewAspectConstraint(withAspect aspect: CGFloat) {
    if let constraint = videoViewAspectConstraint {
      constraint.isActive = false
    }
    videoViewAspectConstraint = NSLayoutConstraint(item: videoView, attribute: .width, relatedBy: .equal,
                                                   toItem: videoView, attribute: .height, multiplier: aspect, constant: 0)
    videoViewAspectConstraint?.isActive = true
  }

  // Hides the playlist
  private func resizeWindowToHidePlaylist() {
    guard let window = window else { return }

    let newFrame = window.frame.rectWithoutPlaylistHeight(providedWindowHeight: windowHeightWithoutPlaylist())
    window.animator().setFrame(newFrame, display: true, animate: !AccessibilityPreferences.motionReductionEnabled)
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

  @IBAction func togglePlaylist(_ sender: Any) {
    guard let window = window else { return }
    guard let screen = window.screen else { return }
    let showPlaylist = !isPlaylistVisible
    Logger.log("Toggling playlist visibility from \(!showPlaylist) to \(showPlaylist)", level: .verbose)
    self.isPlaylistVisible = showPlaylist

    if showPlaylist {
      player.mainWindow.playlistView.reloadData(playlist: true, chapters: true)

      // show playlist using previous height
      let playlistHeight = CGFloat(Preference.float(for: .musicModePlaylistHeight))
      // The window may be in the middle of a previous toggle, so we can't just assume window's current frame
      // represents a state where the playlist is fully shown or fully hidden. Instead, start by computing the height
      // we want to set, and then figure out the changes needed to the window's existing frame.
      var newFrame = window.frame
      let heightWithoutPlaylist = windowHeightWithoutPlaylist()
      let heightToAdd = playlistHeight - (newFrame.size.height - heightWithoutPlaylist)
      // Fill up screen if needed
      newFrame.origin.y = max(newFrame.origin.y - heightToAdd, screen.visibleFrame.origin.y)
      newFrame.size.height = min(heightWithoutPlaylist + playlistHeight, screen.visibleFrame.height)

      // May need to reduce size of album art to fit playlist on screen, or other adjustments:
      newFrame.size = adjustWindowSize(newFrame.size)

      window.animator().setFrame(newFrame, display: true, animate: !AccessibilityPreferences.motionReductionEnabled)
    }
    else {
      // hide playlist
      resizeWindowToHidePlaylist()
    }
  }

  @IBAction func toggleVideoView(_ sender: Any) {
    guard let window = window else { return }
    isVideoVisible = !isVideoVisible
    videoWrapperViewBottomConstraint.isActive = isVideoVisible
    controlViewTopConstraint.isActive = !isVideoVisible
    closeButtonBackgroundViewVE.isHidden = !isVideoVisible
    closeButtonBackgroundViewBox.isHidden = isVideoVisible
    let videoViewHeight = round(videoView.frame.height)
    if isVideoVisible {
      var frame = window.frame
      frame.size.height += videoViewHeight
      window.setFrame(frame, display: true, animate: false)
    } else {
      var frame = window.frame
      frame.size.height -= videoViewHeight
      window.setFrame(frame, display: true, animate: false)
    }
    Preference.set(isVideoVisible, for: .musicModeShowAlbumArt)
  }

  @IBAction func backBtnAction(_ sender: NSButton) {
    player.switchBackFromMiniPlayer(automatically: false)
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

  // MARK: - Utils

  // Returns the current height of the window,
  // including the album art, but not including the playlist.
  private func windowHeightWithoutPlaylist() -> CGFloat {
    return backgroundView.frame.height + (isVideoVisible ? videoWrapperView.frame.height : 0)
  }

  private func adjustWindowSize(_ requestedSize: NSSize) -> NSSize {
    guard let screen = window?.screen else { return requestedSize }
    /// The window has the same width as the album art, and the album art is square,
    /// so when the window's width is expanded, the art's height also expands,
    /// and the control bar (`backgroundView`) and playlist are pushed down.
    /// Calculate the maximum width/height the art can grow to so that the
    /// control bar is not pushed off the screen.
    let visibleScreenSize = screen.visibleFrame.size
    let usableScreenHeight = visibleScreenSize.height
    let minPlaylistHeight = isPlaylistVisible ? PlaylistMinHeight : 0
    let minWindowHeightWithoutArt = backgroundView.frame.height + minPlaylistHeight
    let maxArtSize = min(usableScreenHeight - minWindowHeightWithoutArt, visibleScreenSize.width)

    let requestedArtSize = isVideoVisible ? requestedSize.width : 0
    if requestedArtSize > maxArtSize {
      // No more space on screen: clamp art to max size
      let clampedSize = NSSize(width: maxArtSize,
                               height: maxArtSize + minWindowHeightWithoutArt)
      Logger.log("AdjustWindowSize: no more space on screen; clamped requested size \(requestedSize) to: \(clampedSize)",
                 level: .verbose)
      return clampedSize
    } else if isPlaylistVisible {
      let minRequiredHeightWithRequestedArt = minWindowHeightWithoutArt + requestedArtSize
      if requestedSize.height <= minRequiredHeightWithRequestedArt {
        let availableHeightForArt = usableScreenHeight - minWindowHeightWithoutArt
        let artAdjustmentNeeded = min(0,
                                      availableHeightForArt - requestedArtSize,
                                      visibleScreenSize.width - requestedArtSize)
        let adjustedSize = NSSize(width: requestedArtSize + artAdjustmentNeeded,
                                  height: minRequiredHeightWithRequestedArt + artAdjustmentNeeded)
        Logger.log("AdjustWindowSize: adjusted requested height to satisfy min playlist size", level: .verbose)
        return adjustedSize
      }
    } else if !isPlaylistVisible {
      // Fix the window height so that playlist does not appear
      return NSSize(width: requestedSize.width,
                    height: requestedSize.width + backgroundView.frame.height)
    }

    Logger.log("AdjustWindowSize: returning requested size \(requestedSize)", level: .verbose)
    return requestedSize
  }

  internal override func handleIINACommand(_ cmd: IINACommand) {
    super.handleIINACommand(cmd)
    switch cmd {
    case .toggleMusicMode:
      menuSwitchToMiniPlayer(.dummy)
    default:
      break
    }
  }

}

fileprivate extension NSRect {
  func rectWithoutPlaylistHeight(providedWindowHeight windowHeight: CGFloat) -> NSRect {
    var newRect = self
    newRect.origin.y += (newRect.height - windowHeight)
    newRect.size.height = windowHeight
    return newRect
  }
}
