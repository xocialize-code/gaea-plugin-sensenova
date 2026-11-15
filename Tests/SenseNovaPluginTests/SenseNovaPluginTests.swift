import Foundation
@testable import GaeaPluginKit
import GaeaProtocol
import MLXSenseNovaU1
import MLXToolKit
@testable import SenseNovaPlugin
import Testing

@Suite struct SenseNovaPluginTests {
    func job(_ params: [String: JSONValue], operation: String = "image.generate", model: String = "sensenova-u1-tailsteer") -> Job {
        Job(requestID: "r", job: "job_1", operation: operation, model: model, lane: "int8", inputs: [:],
            params: params, modelParams: [:], adapters: [], seed: 7, outputDir: URL(fileURLWithPath: "/tmp"))
    }

    @Test func tailSteerIsTheV2EightStepRecipeOnOneLane() throws {
        let model = Model.tailSteer
        #expect(model.variants.map(\.quant) == [.int8] && model.variants[0].variant == .fast8V2TailSteer)
        #expect(model.distilled && !model.thinks && model.defaultSteps == 8 && model.defaultGuidance == 1)
        #expect(model.configuration(quant: .int8)?.variant == .fast8V2TailSteer)
        #expect(model.configuration(quant: .int4) == nil, "a 4-bit build loses the benefit, so there is none")
    }

    @Test func tailSteerRunsWithoutCFGAndIgnoresWhatDistilledModelsIgnore() throws {
        let shared = try Shared(job(["negative_prompt": "blurry", "x-sensenova.guidance": 6, "x-sensenova.think": true]),
                                model: .tailSteer)
        #expect(shared.steps == 8 && shared.guidance == 1 && shared.negative == nil && !shared.think)
        #expect(shared.warnings.map(\.code) == ["negative_prompt_ignored", "param_ignored"])
        let request = editRequest(.tailSteer, images: [], instruction: "add a red scarf", width: 1024, height: 768, steps: 8,
                                  guidance: 6, seed: 7)
        #expect(request.guidanceScale == 1 && request.negativePrompt == nil && request.steps == 8)
    }

    @Test func theManifestAddsTailSteerByNameOnlyAndLeavesTheOthersAlone() throws {
        let manifest = try senseNovaPlugin.manifest()
        #expect(manifest.version == "0.2.0" && manifest.minGaea == "1.8.0")
        #expect(manifest.models.map(\.id) == ["sensenova-u1", "sensenova-u1-fast", "sensenova-u1-fast-v1", "sensenova-u1-tailsteer"])
        #expect(manifest.offers.allSatisfy { $0.model["named_only"] == true && $0.model["default"] == nil })
        let offers = manifest.offers.filter { $0.modelID == "sensenova-u1-tailsteer" }
        #expect(offers.map(\.operation) == ["image.generate", "image.edit"])
        #expect(offers[0].model["license"]?["terms_url"] == "https://huggingface.co/sensenova/SenseNova-U1.5-8B-MoT-TailSteer")
        #expect(manifest.offers[0].model["license"]?["terms_url"] == "https://huggingface.co/sensenova/SenseNova-U1.5-8B-MoT")
        #expect(offers[0].model["quality_tiers"]?.arrayValue?.compactMap(\.stringValue) == ["draft", "standard"])
        let properties = try #require(offers[1].params?["properties"]?.objectValue)
        #expect(Set(properties.keys) == ["x-sensenova.steps"], "no guidance and no think on a distilled model")
        let tail = try #require(manifest.models.last)
        #expect(tail.lanes.map(\.id) == ["int8"] && tail.lanes[0].default)
        #expect(tail.lanes[0].resolved.weightSources.map(\.repo) == ["mlx-community/SenseNova-U1.5-8B-MoT-TailSteer-8step-v2-8bit"])
        // The lanes the earlier models had.
        #expect(manifest.models[0].lanes.map(\.id) == ["int8", "bf16"])
        #expect(manifest.models[1].lanes.map(\.id) == ["int8", "int4"])
        #expect(manifest.models[2].lanes.map(\.id) == ["int8", "int4"])
    }

    @Test func sizesSnapToTheGridAndTheAreaCap() throws {
        let kept = try snapped((1024, 768))
        #expect(kept.width == 1024 && kept.height == 768 && kept.warning == nil)
        let cut = try snapped((1000, 700))
        #expect(cut.width == 992 && cut.height == 672 && cut.warning?.code == "size_snapped")
        let big = try snapped((4096, 4096))
        #expect(big.width * big.height <= maxPixels && big.width % 32 == 0)
        #expect(throws: GPPError.self) { try snapped((200, 200)) }
    }
}
