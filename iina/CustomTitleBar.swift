//
//  CustomTitleBarViewController.swift
//  iina
//
//  Created by Matt Svoboda on 10/16/23.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

/// For legacy windowed mode. Manual reconstruction of title bar is needed when not using `titled` window style.
class CustomTitleBarViewController: NSViewController {
  var windowController: PlayerWindowController!

  var leadingTitleBarView: TitleBarButtonsContainerView!
  //  var fakeCenterTitleBarView: NSStackView? = nil
  var trailingTitleBarView: NSStackView!

  override func viewDidLoad() {
    super.viewDidLoad()
    view.translatesAutoresizingMaskIntoConstraints = false

    // Add fake traffic light buttons:
    let btnTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
    let trafficLightButtons: [NSButton] = btnTypes.compactMap{ NSWindow.standardWindowButton($0, for: .titled) }

    let leadingSidebarToggleButton = makeTitleBarButton(imgName: "sidebar.leading",
                                                        action: #selector(windowController.toggleLeadingSidebarVisibility(_:)))

    let leadingStackView = TitleBarButtonsContainerView(views: trafficLightButtons + [leadingSidebarToggleButton])
    leadingStackView.wantsLayer = true
    leadingStackView.layer?.backgroundColor = .clear
    leadingStackView.orientation = .horizontal
    leadingStackView.detachesHiddenViews = false
    leadingStackView.spacing = 6  // matches spacing as of MacOS Sonoma (14.0)
    leadingStackView.alignment = .centerY
    leadingStackView.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
    for btn in trafficLightButtons {
      btn.alphaValue = 1
      btn.isHidden = false
    }
    view.addSubview(leadingStackView)
    leadingStackView.leadingAnchor.constraint(equalTo: leadingStackView.superview!.leadingAnchor).isActive = true
    leadingStackView.topAnchor.constraint(equalTo: leadingStackView.superview!.topAnchor).isActive = true
    leadingStackView.bottomAnchor.constraint(equalTo: leadingStackView.superview!.bottomAnchor).isActive = true
    leadingTitleBarView = leadingStackView

    if leadingStackView.trackingAreas.count <= 1 && trafficLightButtons.count == 3 {
      for btn in trafficLightButtons {
        /// This solution works better than using `window` as owner, because with that the green button would get stuck with highlight
        /// when menu was shown.
        /// FIXME: zoom button context menu items are grayed out
        btn.addTrackingArea(NSTrackingArea(rect: btn.bounds, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: leadingStackView, userInfo: ["obj": 2]))
      }
    }

    let trailingSidebarToggleButton = makeTitleBarButton(imgName: "sidebar.trailing",
                                                         action: #selector(windowController.toggleTrailingSidebarVisibility(_:)))
    let trailingStackView = NSStackView(views: [trailingSidebarToggleButton])
    trailingStackView.wantsLayer = true
    trailingStackView.layer?.backgroundColor = .clear
    trailingStackView.orientation = .horizontal
    trailingStackView.detachesHiddenViews = false
    trailingStackView.alignment = .centerY
    trailingStackView.spacing = 6  // matches spacing as of MacOS Sonoma (14.0)
    trailingStackView.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)

    view.addSubview(trailingStackView)
    trailingStackView.topAnchor.constraint(equalTo: trailingStackView.superview!.topAnchor).isActive = true
    trailingStackView.trailingAnchor.constraint(equalTo: trailingStackView.superview!.trailingAnchor).isActive = true
    trailingStackView.bottomAnchor.constraint(equalTo: trailingStackView.superview!.bottomAnchor).isActive = true
    trailingTitleBarView = trailingStackView

    view.heightAnchor.constraint(equalToConstant: PlayerWindowController.standardTitleBarHeight).isActive = true
  }

  func makeTitleBarButton(imgName: String, action: Selector) -> NSButton {
    let btnImage = NSImage(imageLiteralResourceName: imgName)
    let button = NSButton(image: btnImage, target: windowController, action: action)
    button.setButtonType(.momentaryPushIn)
    button.bezelStyle = .smallSquare
    button.isBordered = false
    button.imagePosition = .imageOnly
    button.refusesFirstResponder = true
    button.imageScaling = .scaleNone
    button.font = NSFont.systemFont(ofSize: 17)
    button.widthAnchor.constraint(equalTo: button.heightAnchor, multiplier: 1).isActive = true
    return button
  }

  // Add to different superview
  func addViewToSuperview(_ superview: NSView) {
    superview.addSubview(view)
    view.addConstraintsToFillSuperview(top: 0, leading: 0, trailing: 0)
  }

  func removeAndCleanUp() {
    // Remove fake traffic light buttons & other custom title bar buttons (if any)
    for subview in view.subviews {
      for subSubview in subview.subviews {
        subSubview.removeFromSuperview()
      }
      subview.removeFromSuperview()
    }
    view.removeFromSuperview()
  }
}


/// Leading stack view for custom title bar. Needed to subclass parent view of traffic light buttons
/// in order to get their highlight working properly. See: https://stackoverflow.com/a/30417372/1347529
class TitleBarButtonsContainerView: NSStackView {
  var isMouseInside: Bool = false

  @objc func _mouseInGroup(_ button: NSButton) -> Bool {
    return isMouseInside
  }

  func markButtonsDirty() {
    for btn in views {
      btn.needsDisplay = true
    }
  }

  override func mouseEntered(with event: NSEvent) {
    isMouseInside = true
    markButtonsDirty()
  }

  override func mouseExited(with event: NSEvent) {
    isMouseInside = false
    markButtonsDirty()
  }
}
