//
//  Item.swift
//  Shirusu
//
//  Created by Moizes Sousa on 19/09/26.
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
