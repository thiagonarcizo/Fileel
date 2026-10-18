// swift-tools-version: 6.0
import PackageDescription

// exercise real engines without launching the menu bar app
let package = Package(
    name: "FileelCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "FileelCore", targets: ["FileelCore"])],
    targets: [
        .target(name: "FileelCore", path: "Fileel", exclude: [
            "MyApp.swift", "ContentView.swift", "Brand.swift", "IconArtwork.swift", "WheelAppearance.swift", "FloatingShelf.swift", "OperationEditor.swift", "ResettableSlider.swift", "CropEditor.swift", "PDFOrganizerView.swift", "PDFWatermarkView.swift", "PDFCompressionView.swift", "UpdaterManager.swift", "OnboardingView.swift", "MediaToolInspector.swift", "SettingsView.swift", "AppModel.swift", "DragController.swift", "ImageEditorView.swift", "MediaPreviewView.swift", "FilePreviewView.swift", "Assets.xcassets", "FileelIcon.icon", "Fileel.entitlements"
        ]),
        .testTarget(name: "FileelCoreTests", dependencies: ["FileelCore"], path: "Tests", exclude: ["Release"])
    ],
    swiftLanguageModes: [.v5]
)
