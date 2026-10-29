import Foundation
import GaeaPluginKit
import GaeaProtocol
import ImageIO
import MLXSenseNovaU1
import MLXToolKit

// gaea-plugin-sensenova: SenseTime's SenseNova-U1.5 8B MoT (Apache-2.0 weights, MIT port) as a Gaea research plugin, on
// sensenova-u1-swift through MLXServeEngine (Gaea AB-T-0374).
//
// One unified model (pixel-space rectified flow, no VAE), three checkpoints, as mlx-image-runtime's catalog serves them:
// - sensenova-u1: the 50-step base with CFG 4, and `think`, a reasoning pass before a text-to-image render;
// - sensenova-u1-fast: the 8-step distillation on upstream's V2 adapter, without CFG;
// - sensenova-u1-fast-v1: the same on the V1 adapter, kept so existing seeds keep reproducing.
// Each generates and edits from one reference. The package also answers visual questions (imageAnalysis) on every
// tier; that is not offered yet.
//
// Every offer is named-only: the normalizer never picks a SenseNova model by default, and a request runs one only by
// naming it. Each model has lanes, one per artifact tier, with the package's footprints; the default is the catalog's
// int8. Weights come from the models root Gaea sends in configure; the engine materializes a missing snapshot.

/// The catalog's envelope: at most 2048² in area (the footprints' envelope), in multiples of 32 (one token). The package
/// itself checks only the 32 grid; 256 px is the floor of its own resize (`smartResize`), and 4096 a side keeps 4:1.
public let maxPixels = 2048 * 2048
public let minSide = 256, maxSide = 4096, grid = 32, maxReferences = 1

public enum Model: String, CaseIterable, Sendable {
    case base = "sensenova-u1"
    case fast = "sensenova-u1-fast"
    case fastV1 = "sensenova-u1-fast-v1"

    public var title: String {
        switch self {
        case .base: "SenseNova-U1.5"
        case .fast: "SenseNova-U1.5 8-step"
        case .fastV1: "SenseNova-U1.5 8-step (V1 adapter)"
        }
    }

    /// The lanes, default first: each is one of the package's artifact tiers. int8 is the catalog's.
    public var variants: [(quant: Quant, variant: SenseNovaVariant)] {
        switch self {
        case .base: [(.int8, .q8), (.bf16, .bf16)]
        case .fast: [(.int8, .fast8V2), (.int4, .fast4V2)]
        case .fastV1: [(.int8, .fast8), (.int4, .fast4)]
        }
    }

    public var defaultQuant: Quant { variants[0].quant }
    public var distilled: Bool { variants[0].variant.isDistilled }
    public var defaultSteps: Int { variants[0].variant.defaultSteps }
    public var defaultGuidance: Double { Double(variants[0].variant.defaultGuidance) }

    /// The package's think mode runs on the base tiers only (`distilledTierCannotThink`).
    public var thinks: Bool { !distilled }

    /// The package configuration for one lane, nil for a lane the model doesn't have; sensenova-inproc builds the same
    /// one. An empty snapshot path lets the engine's store resolve the artifact.
    public func configuration(quant: Quant) -> SenseNovaU1Configuration? {
        variants.first { $0.quant == quant }.map { SenseNovaU1Configuration(variant: $0.variant) }
    }
}

/// The MES size a job asks for (`size`, or `aspect` with `megapixels`, Image profile §2), else `fallback`.
func requestedSize(_ job: Job, fallback: (Int, Int)) throws -> (Int, Int) {
    if let size = job.param("size") {
        guard let w = size["width"]?.intValue, let h = size["height"]?.intValue, w > 0, h > 0 else {
            throw GPPError(.invalidRequest, "size is {width, height} in pixels.")
        }
        return (w, h)
    }
    if let aspect = job.param("aspect")?.stringValue {
        let parts = aspect.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { throw GPPError(.invalidRequest, "aspect is W:H, e.g. 16:9.") }
        let pixels = (job.param("megapixels")?.doubleValue ?? 1.0) * 1_000_000
        let height = (pixels * parts[1] / parts[0]).squareRoot()
        return (Int(height * parts[0] / parts[1]), Int(height))
    }
    return fallback
}

/// The pixel size of a PNG or JPEG file, read from its header; nil when it isn't readable.
public func pixelSize(of url: URL) -> (Int, Int)? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
    return (width, height)
}

/// Fits a size to SenseNova's envelope: scaled down to the area cap, keeping the aspect, then floored to multiples of 32
/// (the package refuses anything else). A change is reported as `size_snapped`.
public func snapped(_ size: (Int, Int)) throws -> (width: Int, height: Int, warning: Warning?) {
    var (w, h) = (Double(size.0), Double(size.1))
    if w * h > Double(maxPixels) {
        let scale = (Double(maxPixels) / (w * h)).squareRoot()
        w *= scale
        h *= scale
    }
    let width = Int(w) / grid * grid, height = Int(h) / grid * grid
    guard min(width, height) >= minSide, max(width, height) <= maxSide else {
        throw GPPError(.invalidRequest, "SenseNova-U1.5 draws \(minSide)–\(maxSide) px a side and at most 2048² in area; "
            + "\(size.0)×\(size.1) doesn't fit.", detail: ["param": "size"])
    }
    let warning = (width, height) == size ? nil : Warning(
        code: "size_snapped", message: "Drew \(width)×\(height) for \(size.0)×\(size.1): multiples of 32, at most 2048² in area.",
        param: "size")
    return (width, height, warning)
}

/// The request's metaData, as the catalog's `think` request key sends it: only when true, and only on the base model.
public func metaData(_ model: Model, think: Bool) -> MetaData {
    think && model.thinks ? ["think": .bool(true)] : [:]
}

/// The engine request for one generated image. The worker and sensenova-inproc both build it here, so the two send the
/// same request: a distilled model gets no negative prompt and guidance 1.
public func generateRequest(_ model: Model, prompt: String, negative: String?, width: Int, height: Int, steps: Int,
                            guidance: Double, seed: UInt64, think: Bool) -> T2IRequest {
    T2IRequest(prompt: prompt, negativePrompt: model.distilled ? nil : negative.flatMap { $0.isEmpty ? nil : $0 },
               width: width, height: height, steps: steps, guidanceScale: model.distilled ? 1 : guidance, seed: seed,
               metaData: metaData(model, think: think))
}

/// The engine request for one edit, built the same way. The package's edit has no negative-prompt branch (it throws
/// `negativePromptUnsupportedOnEdit`) and no think mode, so neither is sent.
public func editRequest(_ model: Model, images: [Image], instruction: String, width: Int, height: Int, steps: Int,
                        guidance: Double, seed: UInt64) -> IEditRequest {
    IEditRequest(images: images, prompt: instruction, negativePrompt: nil, width: width, height: height, steps: steps,
                 guidanceScale: model.distilled ? 1 : guidance, seed: seed)
}

/// The run's settings shared by generate and edit: steps, guidance, seed, and the warnings for what a model ignores.
struct Shared {
    var steps: Int
    var guidance: Double
    var negative: String?
    var seed: UInt64
    var count: Int
    var think = false
    var warnings: [Warning] = []

    /// `edit`: image.edit has one output and no count, and neither a negative prompt nor think mode.
    init(_ job: Job, model: Model, edit: Bool = false) throws {
        steps = job.param("x-sensenova.steps")?.intValue ?? model.defaultSteps
        guard (1...100).contains(steps) else { throw GPPError(.invalidRequest, "x-sensenova.steps is 1–100.") }
        guidance = model.distilled ? 1 : job.param("x-sensenova.guidance")?.doubleValue ?? model.defaultGuidance
        guard (1...20).contains(guidance) else { throw GPPError(.invalidRequest, "x-sensenova.guidance is 1–20.") }
        count = edit ? 1 : job.param("count")?.intValue ?? 1
        guard (1...8).contains(count) else { throw GPPError(.invalidRequest, "count is 1–8.") }
        let negative = job.param("negative_prompt")?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        if negative != nil, model.distilled || edit {
            warnings.append(Warning(code: "negative_prompt_ignored",
                                    message: edit ? "SenseNova-U1.5's edit has no negative-prompt branch, so a negative prompt does nothing."
                                        : "\(model.title) is distilled to run without CFG, so a negative prompt does nothing; "
                                        + "sensenova-u1 honours it.",
                                    param: "negative_prompt"))
        }
        self.negative = model.distilled || edit ? nil : negative
        if let asked = job.param("x-sensenova.think")?.boolValue, asked {
            if model.thinks, !edit {
                think = true
            } else {
                warnings.append(Warning(code: "param_ignored",
                                        message: edit ? "Think mode plans a text-to-image render; SenseNova's edit doesn't use it."
                                            : "Think mode needs the base model, sensenova-u1; \(model.title) is distilled.",
                                        param: "x-sensenova.think"))
            }
        }
        if job.param("prompt_enhance")?.stringValue == "on" {
            warnings.append(Warning(code: "prompt_enhance_ignored", message: "This plugin doesn't rewrite prompts; Gaea's enhancer does.",
                                    param: "prompt_enhance"))
        }
        // Image profile §2: a request without a seed still gets one, reported in effective.
        seed = job.seed ?? UInt64.random(in: 0..<(1 << 31))
    }

    func effective(width: Int, height: Int, model: Model, counted: Bool = true) -> [String: JSONValue] {
        var values: [String: JSONValue] = [
            "size": ["width": .int(Int64(width)), "height": .int(Int64(height))],
            "seed": .int(Int64(seed)), "x-sensenova.steps": .int(Int64(steps)),
        ]
        if counted { values["count"] = .int(Int64(count)) }
        if !model.distilled { values["x-sensenova.guidance"] = .double(guidance) }
        if let negative { values["negative_prompt"] = .string(negative) }
        if think { values["x-sensenova.think"] = true }
        return values
    }
}

/// MES image.generate: one engine call per image, each with seed + i.
func generate(_ model: Model) -> EngineOperation {
    EngineOperation("image.generate", outputNames: ["image": "images"]) { job in
        guard let prompt = try job.text("prompt"), !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GPPError(.invalidRequest, "image.generate needs a prompt.")
        }
        let size = try snapped(try requestedSize(job, fallback: (1024, 1024)))
        var shared = try Shared(job, model: model)
        if let warning = size.warning { shared.warnings.insert(warning, at: 0) }
        let effective = shared.effective(width: size.width, height: size.height, model: model)
        return (0..<shared.count).map { i in
            EngineCall(generateRequest(model, prompt: prompt, negative: shared.negative, width: size.width, height: size.height,
                                       steps: shared.steps, guidance: shared.guidance, seed: shared.seed + UInt64(i),
                                       think: shared.think),
                       effective: effective, warnings: shared.warnings)
        }
    }
}

/// MES image.edit: instruction editing from one image, drawn at that image's size (snapped) unless the request names
/// one (Image profile §3). One output. The package's own default would redraw at ~2048² in area; an explicit size is
/// always sent, so the worker and sensenova-inproc agree.
func edit(_ model: Model) -> EngineOperation {
    EngineOperation("image.edit", outputNames: ["image": "image"]) { job in
        guard let instruction = try job.text("instruction") ?? job.text("prompt"), !instruction.isEmpty else {
            throw GPPError(.invalidRequest, "image.edit needs an instruction.")
        }
        let name = job.inputs["images"] == nil ? "image" : "images"
        let references = job.inputs[name] ?? []
        guard (1...maxReferences).contains(references.count) else {
            throw GPPError(.invalidRequest, "image.edit takes exactly \(maxReferences) image; got \(references.count).",
                           detail: ["param": "images"])
        }
        guard let inputSize = pixelSize(of: references[0]) else {
            throw GPPError(.invalidRequest, "image.edit needs a readable PNG or JPEG image.")
        }
        let size = try snapped(try requestedSize(job, fallback: inputSize))
        var shared = try Shared(job, model: model, edit: true)
        if let warning = size.warning { shared.warnings.insert(warning, at: 0) }
        if job.param("strength") != nil {
            shared.warnings.append(Warning(code: "param_ignored",
                                           message: "SenseNova edits by conditioning on the image from noise, so strength does nothing.",
                                           param: "strength"))
        }
        let image = try job.image(name)
        return [EngineCall(editRequest(model, images: [image], instruction: instruction, width: size.width, height: size.height,
                                       steps: shared.steps, guidance: shared.guidance, seed: shared.seed),
                           effective: shared.effective(width: size.width, height: size.height, model: model, counted: false),
                           warnings: shared.warnings)]
    }
}

public func lanes(_ model: Model) -> [LaneDefinition] {
    model.variants.map { lane in
        LaneDefinition(id: lane.quant.rawValue, default: lane.quant == model.defaultQuant,
                       configuration: SenseNovaU1Configuration(variant: lane.variant)) // = model.configuration(quant:)
    }
}

let apache: JSONValue = ["spdx": "Apache-2.0", "commercial_use": true,
                         "terms_url": "https://huggingface.co/sensenova/SenseNova-U1.5-8B-MoT"]
let limits = PluginManifest.Limits(maxPixels: maxPixels, minSide: minSide, maxSide: maxSide, sizeMultiple: grid)
let editLimits = PluginManifest.Limits(maxPixels: maxPixels, minSide: minSide, maxSide: maxSide, sizeMultiple: grid,
                                       maxImages: maxReferences)

func params(_ model: Model, edit: Bool) -> JSONValue {
    var properties: [String: JSONValue] = [
        "x-sensenova.steps": ["type": "integer", "minimum": 1, "maximum": 100, "default": .int(Int64(model.defaultSteps)),
                              "description": .string(model.distilled ? "Denoising steps. \(model.title) is distilled for 8."
                                  : "Denoising steps; more is slower and finer."),
                              "x-mes-ui": ["widget": "slider", "label": "Steps", "advanced": true]],
    ]
    if !model.distilled {
        properties["x-sensenova.guidance"] = [
            "type": "number", "minimum": 1, "maximum": 20, "default": .double(model.defaultGuidance),
            "description": .string(edit ? "Classifier-free guidance: how strongly the instruction steers. 1 turns CFG off."
                : "Classifier-free guidance: how strongly the prompt (and against the negative prompt) steers. 1 turns CFG off."),
            "x-mes-ui": ["widget": "slider", "label": "Guidance", "advanced": true],
        ]
    }
    if model.thinks, !edit {
        properties["x-sensenova.think"] = [
            "type": "boolean", "default": false,
            "description": "Reason about the prompt before drawing: a planning pass ahead of the render. Slower.",
            "x-mes-ui": ["widget": "toggle", "label": "Think", "advanced": true],
        ]
    }
    return ["type": "object", "properties": .object(properties), "additionalProperties": false]
}

func offerModel(_ model: Model, edit: Bool) -> JSONValue {
    let notes: String = switch (model, edit) {
    case (.base, false): "The 50-step base with CFG 4, honours negative prompts; x-sensenova.think adds a reasoning pass before "
        + "the render. Strong text rendering. Multiples of 32, up to 2048² in area."
    case (.base, true): "Instruction editing from one image, 50 steps with CFG 4. Drawn at the image's size; a negative prompt "
        + "does nothing."
    case (.fast, false): "Distilled to 8 steps without CFG (upstream's V2 adapter): negative prompts do nothing. Multiples of 32, "
        + "up to 2048² in area."
    case (.fast, true): "Instruction editing from one image in 8 steps without CFG (V2 adapter). Drawn at the image's size."
    case (.fastV1, false): "The V1 8-step adapter, kept so existing seeds reproduce; sensenova-u1-fast's V2 adapter clips "
        + "and oversharpens less. No CFG: negative prompts do nothing."
    case (.fastV1, true): "Instruction editing from one image in 8 steps on the V1 adapter. Drawn at the image's size."
    }
    let tiers: JSONValue = model.distilled ? ["draft", "standard"] : ["standard", "best"]
    return [
        "id": .string(model.rawValue), "title": .string(model.title), "license": apache,
        "memory_class": "large", "speed_class": .string(model.distilled ? "fast" : "slow"),
        "quality_tiers": tiers, "named_only": true,
        "notes": .string("Research plugin, named-only: runs only when a request names it. " + notes),
    ]
}

public let senseNovaPlugin = GaeaPluginDefinition(
    id: "com.xocialize.gaea.sensenova",
    version: "0.1.0",
    minGaea: "0.2.0",
    team: "CFZS6RXUCP",
    repo: "https://github.com/xocialize-code/gaea-plugin-sensenova",
    title: "SenseNova-U1.5",
    summary: "SenseTime's SenseNova-U1.5 8B MoT (Apache-2.0): a unified Mixture-of-Transformers drawing in pixel space "
        + "with rectified flow, no VAE. Text-to-image (the 50-step base with think mode, and two 8-step distillations) "
        + "and instruction editing from one image. A research plugin: every model is named-only.",
    license: "Apache-2.0",
    executable: "gaea-sensenova-worker",
    models: Model.allCases.map { model in
        .engine(SenseNovaU1Package.self, id: model.rawValue, title: model.title, lanes: lanes(model),
                operations: [generate(model), edit(model)])
    },
    offers: Model.allCases.flatMap { model in
        [
            PluginManifest.Offer(operation: "image.generate", profile: "image", model: offerModel(model, edit: false),
                                 params: params(model, edit: false), defaults: ["count": 1], limits: limits),
            PluginManifest.Offer(operation: "image.edit", profile: "image", model: offerModel(model, edit: true),
                                 params: params(model, edit: true), limits: editLimits),
        ]
    })
