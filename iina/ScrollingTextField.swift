//
//  ScrollingTextField.swift
//  IINA
//
//  Created by Yuze Jiang on 7/28/18.
//  Copyright © 2018 Yuze Jiang. All rights reserved.
//

import Cocoa

class ScrollingTextField: NSTextField {

  enum State {
    case idle
    case scrolling
  }

  private var state: State = .idle

  let offsetPerSec: CGFloat = 30.0
  let timeToWaitBeforeStart: TimeInterval = 0.2

  private var timeSinceLastReset = Date()

  private var scrollingTimer: Timer?
  private var drawPoint: NSPoint = .zero

  private var scrollingString = NSAttributedString(string: "")
  private var appendedStringCopyWidth: CGFloat = 0

  // Updates the text location based on time elapsed since the last scroll
  func updateScroll() {
    let stringWidth = attributedStringValue.size().width
    let frameWidth = superview!.frame.width
    if stringWidth < frameWidth {
      // Plenty of space. Center text instead
      let xOffset = (frameWidth - stringWidth) / 2
      drawPoint.x = xOffset
      state = .idle
    } else {
      state = .scrolling
      let now = Date()
      let scrollStartTime = timeSinceLastReset + timeToWaitBeforeStart
      if now < scrollStartTime {
        // Initial pause
        return
      }
      let timeElapsed = now.timeIntervalSince(scrollStartTime)
      let offsetSinceStart = timeElapsed * offsetPerSec
      if appendedStringCopyWidth - offsetSinceStart < 0 {
        reset()
        return
      } else {
        drawPoint.x = -offsetSinceStart
      }
    }
    needsDisplay = true
  }

  func reset() {
//    Logger.log("Resetting scroll animation", level: .verbose)
    guard !attributedStringValue.string.isEmpty else { return }  // prevents crash while quitting
    let attributes = attributedStringValue.attributes(at: 0, effectiveRange: nil)
    // Add padding between end and start of the copy
    let appendedStringCopy = "    " + stringValue
    appendedStringCopyWidth = NSAttributedString(string: appendedStringCopy, attributes: attributes).size().width
    scrollingString = NSAttributedString(string: stringValue + appendedStringCopy, attributes: attributes)
    timeSinceLastReset = Date()
    drawPoint = .zero
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    if state == .scrolling {
      scrollingString.draw(at: drawPoint)
    } else {
      attributedStringValue.draw(at: drawPoint)
    }
  }

}
