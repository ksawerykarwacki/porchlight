import AppKit
import PorchlightUI

// Writes the app icon as an .iconset folder, which `iconutil` turns into an .icns file.
// Used by scripts/make-app.sh, so the icon is drawn by the same code as the menu-bar lantern.

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: PorchlightIconTool <folder.iconset>\n".utf8))
    exit(2)
}
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        guard let bitmap = StatusIcon.appIconBitmap(pixels: points * scale),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            FileHandle.standardError.write(Data("could not draw the icon at \(points)pt @\(scale)x\n".utf8))
            exit(1)
        }
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try png.write(to: folder.appendingPathComponent(name))
    }
}
