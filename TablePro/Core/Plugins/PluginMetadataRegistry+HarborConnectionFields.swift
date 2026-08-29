//
//  PluginMetadataRegistry+HarborConnectionFields.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension PluginMetadataRegistry {
    // Mirrors HarborPlugin.additionalConnectionFields so the New Connection form
    // is right before the plugin loads. The plugin's own value replaces this on
    // load, so the two must agree or the form changes shape underneath the user.
    static var harborConnectionFields: [ConnectionField] {
        [
            ConnectionField(
                id: "harborToken",
                label: String(localized: "Token"),
                placeholder: "Contents of the berth's .token file",
                fieldType: .secure,
                section: .authentication,
                hidesPassword: true
            ).withHidesUsername(true),
        ]
    }
}
