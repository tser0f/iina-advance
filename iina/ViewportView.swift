//
//  ViewportView.swift
//  iina
//
//  Created by Matt Svoboda on 11/24/23.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

class ViewportView: NSView {
  unowned var player: PlayerCore!

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    registerForDraggedTypes([.nsFilenames, .nsURL, .string])
  }
  
  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    return player.acceptFromPasteboard(sender)
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    return player.openFromPasteboard(sender)
  }

}

