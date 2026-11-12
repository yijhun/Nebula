// Downloads macOS on-demand fonts through CoreText's download API.
//
// ctex's macOS font set (fontset=mac → macold, since there is no
// /System/Library/Fonts/PingFang.ttc) uses STSong, STHeiti, STXihei, STKaiti
// and STFangsong. Only STSong ships with the system; the others are
// download-on-demand assets. On a GitHub runner they aren't downloaded, and
// XeTeX's lookup by name then blocks forever in CFMessagePortSendRequest
// (CoreText asking the font service to activate the font). Fetching them
// first gives the runner the fonts a user's Mac has.
//
// Usage: swift fetch-cjk-fonts.swift [timeout-seconds] FontName...
import CoreText
import Foundation

var args = Array(CommandLine.arguments.dropFirst())
let timeout = args.first.flatMap(Double.init) ?? 300
if args.first.flatMap(Double.init) != nil { args.removeFirst() }
let names = args.isEmpty ? ["STSong", "STHeiti", "STXihei", "STKaiti", "STFangsong"] : args

func fileFor(_ name: String) -> String? {
    let d = CTFontDescriptorCreateWithAttributes([kCTFontNameAttribute: name] as CFDictionary)
    return (CTFontDescriptorCopyAttribute(d, kCTFontURLAttribute) as? URL)?.path
}

let missing = names.filter { fileFor($0) == nil }
for n in names { print("  \(n): \(fileFor(n) ?? "not downloaded")") }
if missing.isEmpty { print("All present."); exit(0) }

print("Downloading: \(missing.joined(separator: ", ")) (limit \(Int(timeout)) s)")
let descriptors = missing.map {
    CTFontDescriptorCreateWithAttributes([kCTFontNameAttribute: $0] as CFDictionary)
} as CFArray

let finished = DispatchSemaphore(value: 0)
var errors: [String] = []
var lastPercent = -10
let started = CTFontDescriptorMatchFontDescriptorsWithProgressHandler(descriptors, nil) { state, progress in
    let info = progress as NSDictionary
    switch state {
    case .downloading:
        let pct = Int((info[kCTFontDescriptorMatchingPercentage] as? Double) ?? 0)
        if pct >= lastPercent + 10 { lastPercent = pct; print("  \(pct)%") }
    case .didFailWithError:
        let err = info[kCTFontDescriptorMatchingError] as? NSError
        errors.append(err.map { "\($0.domain) \($0.code): \($0.localizedDescription)" } ?? "unknown error")
    case .didFinish:
        finished.signal()
    default:
        break
    }
    return true
}
guard started else { print("::error::CoreText refused to start the font download"); exit(1) }

if finished.wait(timeout: .now() + timeout) == .timedOut {
    print("::error::Font download didn't finish within \(Int(timeout)) s")
    exit(1)
}
let stillMissing = names.filter { fileFor($0) == nil }
for n in names { print("  \(n): \(fileFor(n) ?? "not downloaded")") }
if !errors.isEmpty { print("Errors: \(errors.joined(separator: "; "))") }
if !stillMissing.isEmpty {
    print("::error::Still not available: \(stillMissing.joined(separator: ", "))")
    exit(1)
}
print("Done.")
