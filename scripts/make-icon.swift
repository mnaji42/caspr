// Rend l'icône de Caspr depuis `app/Sources/Caspr/Resources/icons/caspr-app-icon.svg`.
//
// L'icône était dessinée en code — un choix qui se défendait tant qu'elle était
// géométrique. Elle est maintenant un dessin, et un dessin se maintient là où
// il a été fait, pas recopié en courbes de Bézier dans un fichier Swift où la
// moindre retouche demanderait de traduire à la main.
//
// `NSImage` lit le SVG nativement et le rend à chaque taille demandée : c'est
// du vectoriel jusqu'au dernier pixel, sans étape de conversion.
import AppKit
import Foundation

// Deux arguments : le dessin source, et le dossier `.iconset` à remplir.
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage : make-icon.swift <svg> <iconset>\n".utf8))
    exit(2)
}
let source = URL(fileURLWithPath: arguments[0])
let iconset = URL(fileURLWithPath: arguments[1])

guard let art = NSImage(contentsOf: source) else {
    FileHandle.standardError.write(
        Data("icône introuvable : \(source.path)\n".utf8))
    exit(1)
}

try? FileManager.default.createDirectory(at: iconset,
                                         withIntermediateDirectories: true)

/// Les tailles qu'`iconutil` attend, chacune en simple et double densité.
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = NSSize(width: pixels, height: pixels)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        art.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
                 from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        let name = scale == 1 ? "icon_\(size)x\(size).png"
                              : "icon_\(size)x\(size)@2x.png"
        guard let png = bitmap.representation(using: .png, properties: [:])
        else { continue }
        try png.write(to: iconset.appending(path: name))
    }
}
