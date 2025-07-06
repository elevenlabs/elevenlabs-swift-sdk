//
//  DeviceCheck.swift
//  ElevenLabsSDK
//
//  Created by Mathew Gacy on 7/6/25.
//

import DeviceKit
import Foundation
import os.log

enum DeviceCheck {
    /// Checks if the current device is likely an iPhone 13 or older model using DeviceKit.
    static func isOlderDeviceModel() -> Bool {
        let currentDevice = Device.current
        let logger = Logger(subsystem: "com.elevenlabs.ElevenLabsSDK", category: "DeviceCheck")

        // Define the array of older iPhone models (up to iPhone 13 series)
        // Note: This array might need updates if DeviceKit adds more specific older models or you need to support very old ones.
        let olderModels: [Device] = [
            // iPhone 13 Series
            .iPhone13, .iPhone13Mini, .iPhone13Pro, .iPhone13ProMax,
            // iPhone SE Series (relevant generations)
            .iPhoneSE2, .iPhoneSE3, // Assuming SE 2/3 fall under 'older'
            // iPhone 12 Series
                .iPhone12, .iPhone12Mini, .iPhone12Pro, .iPhone12ProMax,
            // iPhone 11 Series
            .iPhone11, .iPhone11Pro, .iPhone11ProMax,
            // iPhone X Series
            .iPhoneX, .iPhoneXR, .iPhoneXS, .iPhoneXSMax,
            // iPhone 8 Series
            .iPhone8, .iPhone8Plus,
            // iPhone 7 Series
            .iPhone7, .iPhone7Plus,
            // Older SE
            .iPhoneSE,
            // Add older models here if needed (e.g., .iPhone6s, .iPhone6sPlus, etc.)
        ]

        if currentDevice.isPhone && olderModels.contains(currentDevice) {
            logger.debug("DeviceKit check: Detected older iPhone model (\(currentDevice.description)). Applying workaround.")
            return true
        }

        // Covers iPhone 14 series and newer, iPads, iPods, Simulators, unknown devices.
        logger.debug("DeviceKit check: Detected newer iPhone model (\(currentDevice.description)) or non-applicable device. No workaround needed.")
        return false
    }
}
