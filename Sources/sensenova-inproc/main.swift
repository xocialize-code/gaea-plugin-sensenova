import Foundation
import MLXSenseNovaU1
import MLXServeCore
import MLXToolKit
import SenseNovaPlugin

// The in-process reference for the plugin: one SenseNova lane loaded by MLXServeEngine in this process, with the lane
// configuration the worker uses (SenseNovaPlugin) and the request it would build (`snapped`, `generateRequest`,
// `editRequest`). A cold run then warm ones; the first image is written to --out, and one JSON line of timings is
// printed. Not part of the plugin bundle.
//
//   sensenova-inproc [--model sensenova-u1 | sensenova-u1-fast | sensenova-u1-fast-v1] [--lane bf16 | int8 | int4]
//                    [--prompt <text>] [--negative <text>] [--width 1024] [--height 1024] [--steps N] [--guidance G]
//                    [--seed 42] [--think] [--image <png>] [--models-root <dir>] [--out <png>] [--runs 2]
//
// With --image (exactly one) it runs image edit with the prompt as the instruction, at the image's size unless --width
// and --height are given. Sizes are snapped as the worker snaps an MES size, so the same numbers give the same request.

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...(i + 1)) }
    return args[i + 1]
}
func options(_ name: String) -> [String] {
    var values: [String] = []
    while let value = option(name) { values.append(value) }
    return values
}
func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}
func seconds(since start: ContinuousClock.Instant) -> Double {
    let d = ContinuousClock.now - start
    return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

let started = ContinuousClock.now
guard let model = Model(rawValue: option("--model") ?? "sensenova-u1-fast") else {
    fail("unknown --model; one of \(Model.allCases.map(\.rawValue))")
}
let quant = Quant(rawValue: option("--lane") ?? model.defaultQuant.rawValue) ?? model.defaultQuant
guard let configuration = model.configuration(quant: quant) else {
    fail("\(model.rawValue) has no lane \(quant.rawValue); one of \(model.variants.map(\.quant.rawValue))")
}
let prompt = option("--prompt") ?? "a lighthouse on a rocky coast at dusk, photorealistic"
let negative = option("--negative")
let askedWidth = Int(option("--width") ?? ""), askedHeight = Int(option("--height") ?? "")
let steps = Int(option("--steps") ?? "") ?? model.defaultSteps
let guidance = Double(option("--guidance") ?? "") ?? model.defaultGuidance
let seed = UInt64(option("--seed") ?? "") ?? 42
let think = flag("--think")
let imagePaths = options("--image")
let outPath = option("--out")
let runs = Int(option("--runs") ?? "") ?? 2
let modelsRoot = URL(fileURLWithPath: option("--models-root")
                     ?? NSHomeDirectory() + "/Library/Application Support/MLXEngine/Models", isDirectory: true)
guard imagePaths.count <= maxReferences else { fail("--image takes exactly \(maxReferences) image") }

// The worker's size: the asked one, else 1024² for generate and the reference's size for edit, then snapped.
let edit = !imagePaths.isEmpty
let fallback: (Int, Int)
if edit {
    guard let size = pixelSize(of: URL(fileURLWithPath: imagePaths[0])) else { fail("--image isn't a readable PNG or JPEG") }
    fallback = size
} else {
    fallback = (1024, 1024)
}
let size = try snapped((askedWidth ?? fallback.0, askedHeight ?? fallback.1))

var result: [String: Any] = ["model": model.rawValue, "lane": quant.rawValue, "width": size.width, "height": size.height,
                             "size_snapped": size.warning != nil, "steps": steps, "guidance": model.distilled ? 1 : guidance,
                             "seed": seed, "think": think && model.thinks, "references": imagePaths.count]

// The budget Gaea sends a worker on a large Mac (wiresWeights off, the automatic pool cap).
let engine = MLXServeEngine(workerBudget: WorkerBudget(ceilingBytes: 64_000_000_000, wiresWeights: false))
await engine.useModelStore(ModelStore(root: modelsRoot))
let id = PackageID(model.rawValue)
_ = try await engine.register(SenseNovaU1Package.registration, configuration: configuration, id: id)

var clock = ContinuousClock.now
_ = try await engine.prepare(edit ? .imageEdit : .textToImage, package: id)
result["prepare_s"] = seconds(since: clock)

let images = try imagePaths.map { path in
    Image(format: path.lowercased().hasSuffix(".png") ? .png : .jpeg, data: try Data(contentsOf: URL(fileURLWithPath: path)))
}
// The worker's request, built by the same functions (SenseNovaPlugin's generate and edit).
let request: any CapabilityRequest = edit
    ? editRequest(model, images: images, instruction: prompt, width: size.width, height: size.height, steps: steps,
                  guidance: guidance, seed: seed)
    : generateRequest(model, prompt: prompt, negative: negative, width: size.width, height: size.height, steps: steps,
                      guidance: guidance, seed: seed, think: think)

for run in 1...max(1, runs) {
    clock = ContinuousClock.now
    let response = try await engine.run(request, package: id)
    result["run\(run)_s"] = seconds(since: clock)
    let image = (response as? T2IResponse)?.image ?? (response as? IEditResponse)?.image
    if run == 1, let image, let outPath { try image.data.write(to: URL(fileURLWithPath: outPath)) }
}
result["cold_s"] = seconds(since: started) - (runs > 1 ? result["run\(runs)_s"] as! Double : 0)

let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
