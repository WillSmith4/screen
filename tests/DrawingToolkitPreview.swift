// Small simulator host for visual QA of the actual production SwiftUI views.
// This file is only compiled by capture-drawing-ui.sh, never by the app target.
import SwiftUI

@main struct DrawingToolkitPreviewApp: App {
    @State private var options: DrawingToolkitOptions = {
        var value = DrawingToolkitOptions()
        value.enabled = true
        value.highDensity = true
        value.hookFilterDepth = 10
        value.equalizationDepth = 24
        return value
    }()
    var body: some Scene {
        WindowGroup {
            NavigationView {
                if CommandLine.arguments.contains("--pressure") {
                    DrawingPressureView(options: $options)
                } else {
                    Form { DrawingToolkitSection(options: $options) }
                        .navigationBarTitle("Edit Session", displayMode: .inline)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") {} }
                            ToolbarItem(placement: .navigationBarTrailing) { Button("Save") {} }
                        }
                }
            }.navigationViewStyle(.stack)
        }
    }
}
