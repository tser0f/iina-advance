//
//  Switch.swift
//  iina
//
//  Created by Collider LI on 12/6/2020.
//  Copyright © 2020 lhc. All rights reserved.
//

import Cocoa

@IBDesignable
class Switch: NSView {
  private var _title = ""
  private var _checkboxMargin = true
  private var _checked = false
  private var _switchOnLeft = false

  /// For some panels (such as Video Settings sidebar) it is desirable to refuse first responder status, so that tab
  /// navigation will skip over it and not highlight it. Defaults to `false`, but can be configured for each `Switch`
  /// in the XIB via Interface Builder's Attributes Inspector.
  @IBInspectable var refusesFirstResponder: Bool = false {
    didSet {
      /// As of MacOS Sonoma (14.0), property `refusesFirstResponder` is not set until after `init()`
      /// (it was not a good idea to assume it would be). Instead, make sure to update these child views
      /// whenever the property is updated.
      if #available(macOS 10.15, *) {
        if let nsSwitch = self.nsSwitch as? FirstResponderOptionalSwitch {
          nsSwitch._acceptsFirstResponder = !refusesFirstResponder
        }
        if let checkbox = self.checkbox as? FirstResponderOptionalButton {
          checkbox._acceptsFirstResponder = !refusesFirstResponder
        }
      }
    }
  }

  @IBInspectable var title: String {
    get {
      return _title
    }
    set {
      _title = NSLocalizedString(newValue, comment: newValue)
      if #available(macOS 10.15, *) {
        label?.stringValue = _title
      } else {
        checkbox?.title = (checkboxMargin ? " " : "") + _title
      }
    }
  }

  @IBInspectable var checkboxMargin: Bool {
    get {
      return _checkboxMargin
    }
    set {
      _checkboxMargin = newValue
      guard let checkbox = checkbox else { return }
      if newValue {
        checkbox.title = " " + checkbox.title
      } else {
        checkbox.title = String(checkbox.title.dropFirst())
      }
    }
  }

  var checked: Bool {
    get {
      return _checked
    }
    set {
      _checked = newValue
      if #available(macOS 10.15, *) {
        (nsSwitch as! NSSwitch).state = _checked ? .on : .off
      } else {
        checkbox?.state = _checked ? .on : .off
      }
    }
  }

  private lazy var viewMap: [String: Any] = {
    ["l": label!, "s": nsSwitch!]
  }()
  private lazy var switchOnLeftConstraint = {
    NSLayoutConstraint.constraints(withVisualFormat: "H:|-0-[s]-8-[l]-(>=0)-|", options: [], metrics: nil, views: viewMap)
  }()
  private lazy var switchOnRightConstraint = {
    NSLayoutConstraint.constraints(withVisualFormat: "H:|-0-[l]-(>=8)-[s]-0-|", options: [], metrics: nil, views: viewMap)
  }()

  @IBInspectable var switchOnLeft: Bool {
    get {
      return _switchOnLeft
    }
    set {
      if #available(macOS 10.15, *) {
        if newValue {
          NSLayoutConstraint.deactivate(switchOnRightConstraint)
          NSLayoutConstraint.activate(switchOnLeftConstraint)
        } else {
          NSLayoutConstraint.deactivate(switchOnLeftConstraint)
          NSLayoutConstraint.activate(switchOnRightConstraint)
        }
      }
      _switchOnLeft = newValue
    }
  }

  @IBInspectable var isEnabled: Bool {
    get {
      if #available(macOS 10.15, *) {
        return (nsSwitch as? NSSwitch)?.isEnabled ?? false
      } else {
        return checkbox?.isEnabled ?? false
      }
    }
    set {
      if #available(macOS 10.15, *) {
        (nsSwitch as? NSSwitch)?.isEnabled = newValue
      } else {
        checkbox?.isEnabled = newValue
      }
    }
  }

  override var intrinsicContentSize: NSSize {
    if #available(macOS 10.15, *) {
      return NSSize(width: 0, height: 22)
    } else {
      return NSSize(width: 0, height: 14)
    }
  }

  var action: (Bool) -> Void = { _ in }

  private var nsSwitch: Any?
  private var label: NSTextField?
  private var checkbox: NSButton?

  override var acceptsFirstResponder: Bool {
    return !refusesFirstResponder
  }

  private func setupSubViews() {
    if #available(macOS 10.15, *) {
      let label = NSTextField(labelWithString: title)
      let nsSwitch = FirstResponderOptionalSwitch()
      nsSwitch.acceptsFirstResponder = !refusesFirstResponder
      nsSwitch.target = self
      nsSwitch.action = #selector(statusChanged)
      label.translatesAutoresizingMaskIntoConstraints = false
      nsSwitch.translatesAutoresizingMaskIntoConstraints = false
      addSubview(label)
      addSubview(nsSwitch)
      self.nsSwitch = nsSwitch
      self.label = label
      if switchOnLeft {
        NSLayoutConstraint.activate(switchOnLeftConstraint)
      } else {
        NSLayoutConstraint.activate(switchOnRightConstraint)
      }
      label.centerYAnchor.constraint(equalTo: self.centerYAnchor).isActive = true
      nsSwitch.centerYAnchor.constraint(equalTo: self.centerYAnchor).isActive = true
    } else {
      let checkbox: NSButton
      if #available(macOS 10.12, *) {
        let cb = FirstResponderOptionalButton(checkboxWithTitle: title, target: self, action: #selector(statusChanged))
        cb.acceptsFirstResponder = !refusesFirstResponder
        checkbox = cb
      } else {
        checkbox = FirstResponderOptionalButton()
        checkbox.setButtonType(.switch)
        checkbox.target = self
        checkbox.action = #selector(statusChanged)
      }
      checkbox.translatesAutoresizingMaskIntoConstraints = false
      checkbox.focusRingType = .none
      self.checkbox = checkbox
      addSubview(checkbox)
      Utility.quickConstraints(["H:|-0-[b]-(>=0)-|"], ["b": checkbox])
      checkbox.centerYAnchor.constraint(equalTo: self.centerYAnchor).isActive = true
    }
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setupSubViews()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupSubViews()
  }

  @objc func statusChanged() {
    if #available(macOS 10.15, *) {
      _checked = (nsSwitch as! NSSwitch).state == .on
    } else {
      _checked = checkbox!.state == .on
    }
    self.action(_checked)
  }

  @available(macOS 10.15, *)
  class FirstResponderOptionalSwitch: NSSwitch {
    var _acceptsFirstResponder = true
    override var acceptsFirstResponder: Bool {
      get {
        return _acceptsFirstResponder
      } set {
        _acceptsFirstResponder = newValue
      }
    }
  }

  class FirstResponderOptionalButton: NSButton {
    var _acceptsFirstResponder = true
    override var acceptsFirstResponder: Bool {
      get {
        return _acceptsFirstResponder
      } set {
        _acceptsFirstResponder = newValue
      }
    }
  }
}
