//
//  MPVGeometryDef.swift
//  iina
//
//  Created by Collider LI on 20/12/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Foundation

struct MPVGeometryDef: CustomStringConvertible {
  var x: String?, y: String?, w: String?, h: String?, xSign: String?, ySign: String?

  static func parse(_ geometryString: String) -> MPVGeometryDef? {
    // guard option value
    guard !geometryString.isEmpty else { return nil }
    // match the string, replace empty group by nil
    let captures: [String?] = Regex.geometry.captures(in: geometryString).map { $0.isEmpty ? nil : $0 }
    // guard matches
    guard captures.count == 9 else { return nil }
    // return struct
    return MPVGeometryDef(x: captures[6],
                          y: captures[8],
                          w: captures[2],
                          h: captures[4],
                          xSign: captures[5],
                          ySign: captures[7])
  }

  var description: String {
    let x0 = x == nil ? "nil" : String(x!)
    let y0 = y == nil ? "nil" : String(y!)
    let w0 = w == nil ? "nil" : String(w!)
    let h0 = h == nil ? "nil" : String(h!)
    let xSign0 = xSign == nil ? "nil" : String(xSign!)
    let ySign0 = ySign == nil ? "nil" : String(ySign!)
    return "Geometry(x: (\(xSign0)) \(x0), y: (\(ySign0)) \(y0), W: \(w0), H: \(h0))"
  }
}
