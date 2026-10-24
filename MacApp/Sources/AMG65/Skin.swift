import AppKit
import CoreText
import SwiftUI

/// Loads the original app's artwork from the bundle (copied in by build_app.sh
/// from extracted/app/skins/theme1). Not redistributable — AULA/LEOBOG artwork.
enum Skin {
    static let root: URL = {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("Skin"),
           FileManager.default.fileExists(atPath: r.path) { return r }
        if let env = ProcessInfo.processInfo.environment["AMG65_SKIN"] { return URL(fileURLWithPath: env) }
        return URL(fileURLWithPath: "../local/official-driver/extracted/app/skins/theme1")
    }()

    private static var cache: [String: NSImage] = [:]

    static func image(_ name: String) -> NSImage {
        if let img = cache[name] { return img }
        let img = NSImage(contentsOf: root.appendingPathComponent(name)) ?? NSImage(size: .init(width: 1, height: 1))
        // Some PNGs carry DPI metadata; always lay them out at 1 pt per pixel like the original.
        if let rep = img.representations.first, rep.pixelsWide > 0 {
            img.size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        cache[name] = img
        return img
    }

    /// One frame of a horizontal sprite strip (normal / hover / pressed / … states).
    static func sprite(_ name: String, frames: Int, index: Int) -> NSImage {
        let key = "\(name)#\(frames)#\(index)"
        if let img = cache[key] { return img }
        let base = image(name)
        guard let cg = base.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return base }
        let w = cg.width / frames
        let rect = CGRect(x: w * min(index, frames - 1), y: 0, width: w, height: cg.height)
        guard let cropped = cg.cropping(to: rect) else { return base }
        let img = NSImage(cgImage: cropped, size: .init(width: w, height: cg.height))
        cache[key] = img
        return img
    }

    /// Crop an arbitrary pixel rect (top-left origin).
    static func crop(_ name: String, _ rect: CGRect) -> NSImage {
        let key = "\(name)@\(rect)"
        if let img = cache[key] { return img }
        let base = image(name)
        guard let cg = base.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let cropped = cg.cropping(to: rect) else { return base }
        let img = NSImage(cgImage: cropped, size: rect.size)
        cache[key] = img
        return img
    }

    static func registerFonts() {
        let fonts = Bundle.main.resourceURL?.appendingPathComponent("Fonts")
            ?? URL(fileURLWithPath: "../local/official-driver/extracted/app/font")
        guard let files = try? FileManager.default.contentsOfDirectory(at: fonts, includingPropertiesForKeys: nil) else { return }
        for f in files where ["ttf", "otf"].contains(f.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
        }
    }
}

extension Font {
    static func openSans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        switch weight {
        case .semibold, .bold: return .custom("Open Sans Semibold", size: size)
        case .light: return .custom("Open Sans Light", size: size)
        default: return .custom("Open Sans", size: size)
        }
    }
}

enum Palette {
    static let accent = Color(red: 0, green: 198 / 255, blue: 1)        // slider fill colour
    static let text = Color.white
    static let dim = Color.white.opacity(0.55)
}
