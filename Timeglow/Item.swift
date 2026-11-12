//
//  Item.swift
//  Timeglow
//
//  Created by 陈晓峰 on 2026/11/12.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
