# gaea-plugin-sensenova

SenseTime's **SenseNova-U1.5 8B MoT** (a unified Mixture-of-Transformers that draws in pixel space with rectified
flow, no VAE; Apache-2.0) as a [Gaea](https://github.com/xocialize-code/gaea) research plugin. It is built on
[GaeaPluginKit](https://github.com/xocialize-code/gaea-plugin-kit) over
[sensenova-u1-swift](https://github.com/xocialize/sensenova-u1-swift) 0.7.0, runs in its own process, and speaks the
Gaea Plugin Protocol v1. From 0.2.0 it needs Gaea 1.8.0. Add it to Gaea by its repo URL:

```bash
gaea plugins add https://github.com/xocialize-code/gaea-plugin-sensenova
```

## Why every offer is named-only

This is a research plugin (Gaea AB-T-0374): SenseNova is here to be tried by name, not to take over a default. Every
offer's model carries `"named_only": true` and no `"default"`, so the normalizer never picks a SenseNova model on its
own; a request runs one only by naming it (`"model": "sensenova-u1-fast"`). Gaea would make an offer named-only by
itself only for a non-permissive licence, and SenseNova's weights are Apache-2.0, so the manifest says it. Z-Image
Turbo and FLUX.2 Klein keep the defaults, as in mlx-image-runtime's catalog.

## What it offers

| Model | MES operations | Quality tiers | Notes |
|---|---|---|---|
| `sensenova-u1` | `image.generate`, `image.edit` | standard, best | The 50-step base with CFG 4. Honours negative prompts on generate, and `x-sensenova.think` adds a reasoning pass before the render. |
| `sensenova-u1-fast` | `image.generate`, `image.edit` | draft, standard | Distilled to 8 steps without CFG on upstream's V2 adapter (better colour balance, less clipping and oversharpening than V1). A negative prompt does nothing and is reported `negative_prompt_ignored`. |
| `sensenova-u1-fast-v1` | `image.generate`, `image.edit` | draft, standard | The same distillation on the V1 adapter, kept so existing seeds keep reproducing. |
| `sensenova-u1-tailsteer` (0.2.0) | `image.generate`, `image.edit` | draft, standard | The V2 8-step recipe over SenseNova's TailSteer finetune, for pictures that get edited again and again. |

- **Sizes.** Multiples of 32 (one token), at most 2048² in area, 256–4096 px a side. Anything else is fitted and
  reported `size_snapped`. `aspect` with `megapixels` works too. Generate defaults to 1024².
- **`image.edit`** takes exactly one image and an instruction, and draws at that image's size (snapped) unless the
  request names a size. The package's own default would redraw at about 2048² in area; the plugin always sends a size.
  The package's edit has no negative-prompt branch, so a negative prompt is reported `negative_prompt_ignored` on every
  model, and `strength` does nothing (`param_ignored`).
- **`count`** on `image.generate`: 1–8 images, each with `seed + i`. A request without a seed gets one, reported in
  `effective`. `image.edit` has one output.
- **Options**, as MES extensions: `x-sensenova.steps` (every model), `x-sensenova.guidance` (the base only; the
  distilled models run at guidance 1), and `x-sensenova.think` (boolean, the base's `image.generate` only), sent to the
  package as its `think` metaData key, as the catalog's request key does.
- **Chains of edits: `sensenova-u1-tailsteer`.** When each edit's result becomes the next edit's input, the rest of the
  picture drifts a little more every turn. [TailSteer](https://huggingface.co/sensenova/SenseNova-U1.5-8B-MoT-TailSteer)
  is a finetune of the base that drifts less.
  - Over 8 chains of 10 edits, the picture outside the edited area held 18.0 dB PSNR at turn 10, against 15.9 dB for
    `sensenova-u1-fast`. On a 20-turn chain it stayed photographic where `sensenova-u1-fast` broke down by turn 10
    (AB-R-0841, AB-R-0842).
  - A single edit or a generated picture matches `sensenova-u1-fast` at the same seed, slightly softer. Speed and
    memory are the same (AB-R-0843).
  - It has one lane, int8: a 4-bit build loses the benefit, so there is none.
  - Use it when results get edited again; otherwise `sensenova-u1-fast`.
- **Not offered yet:** visual question answering (`imageAnalysis`), which the same resident model serves on every
  tier; the edit's image-guidance axis (the package's `imageGuidance` metaData, 1–4); and the pose tiers.

## Lanes and memory

Each model has a lane per artifact tier, with the package's footprints (measured at the 2048² envelope):

| Model | Lane | Artifact | Resident | Peak while running | Gaea schedules |
|---|---|---|---|---|---|
| `sensenova-u1` | `int8` (default) | `SenseNova-U1.5-8B-MoT-8bit` | 20.5 GB | 4.2 GB | 24.7 GB |
| `sensenova-u1` | `bf16` | `SenseNova-U1.5-8B-MoT-bf16` | 35.5 GB | 4.0 GB | 39.5 GB |
| `sensenova-u1-fast` | `int8` (default) | `SenseNova-U1.5-8B-MoT-8step-v2-8bit` | 20.5 GB | 4.2 GB | 24.7 GB |
| `sensenova-u1-fast` | `int4` | `SenseNova-U1.5-8B-MoT-8step-v2-4bit` | 12.2 GB | 4.5 GB | 16.7 GB |
| `sensenova-u1-fast-v1` | `int8` (default) | `SenseNova-U1.5-8B-MoT-8step-8bit` | 20.5 GB | 4.2 GB | 24.7 GB |
| `sensenova-u1-fast-v1` | `int4` | `SenseNova-U1.5-8B-MoT-8step-4bit` | 12.2 GB | 4.5 GB | 16.7 GB |
| `sensenova-u1-tailsteer` | `int8` (its only lane) | `SenseNova-U1.5-8B-MoT-TailSteer-8step-v2-8bit` | 20.5 GB | 4.2 GB | 24.7 GB |

int8 is the default, as in mlx-image-runtime's catalog. When it doesn't fit, Gaea loads a smaller lane and warns
(`lane_fallback`, G-23); `gaea models lane sensenova-u1-fast int4` makes another lane the default. A request naming a
lane (`x-gaea.lane`) never falls back.

## Weights

Gaea sends its models root in `configure` (MLXEngine's store by default, `gaea models root` to change it). Each lane is
its own self-contained artifact, `mlx-community/SenseNova-U1.5-8B-MoT-<tier>` (the table above); the worker looks for
it there and downloads a missing snapshot on `prepare` or `materialize`. Nothing is quantized on load. The artifacts
were converted from `sensenova/SenseNova-U1.5-8B-MoT` at the pinned revision `07d76f6`; the 8-step tiers carry the
official distillation LoRA merged in. The TailSteer artifact (19.9 GB) was converted from
`sensenova/SenseNova-U1.5-8B-MoT-TailSteer` at `d6dc59d`, with the V2 adapter merged the same way.

## Build and check locally

```bash
scripts/build-plugin.sh
```

```bash
scripts/check-plugin.sh
```

`check-plugin.sh` generates one 512² image with SenseNova-U1.5 8-step int8 against the weights in MLXEngine's store
(`CHECK_MODELS_ROOT` moves it), with every `.build` folder hidden so MLX can find its metallib only inside the bundle.
A control then shows that the bare worker, outside the bundle, can't. `scripts/release.sh` builds, checks, notarizes
with the fleet's `mlx-notary` profile, and publishes the GitHub release. See the
[demo plugin](https://github.com/xocialize-code/gaea-plugin-demo) for signing, notarization and CI secrets.

`sensenova-inproc` (`swift run -c release sensenova-inproc`; its header lists the options) is not part of the plugin:
it runs the same lane in-process through MLXServeEngine and builds its request with the plugin's own functions, the
reference that Gaea's runs are compared against byte for byte.

```bash
scripts/golden.sh <out-dir>
```

`golden.sh` makes pictures over GPP on the signed bundle and through `sensenova-inproc`, and needs each pair to be the
same PNG, byte for byte:
- `sensenova-u1-fast` at 512², the control that the earlier models are unchanged;
- `sensenova-u1-tailsteer`: a picture, an edit of it, and an edit of that edit;
- the same first edit by `sensenova-u1-fast`, which must give another picture.

## Licence

The plugin is Apache-2.0 (Gaea G-21) and ships no weights. SenseNova-U1.5 8B MoT's weights are Apache-2.0 (SenseTime,
[sensenova/SenseNova-U1.5-8B-MoT](https://huggingface.co/sensenova/SenseNova-U1.5-8B-MoT); the fleet's verdict is
AB-D-0043), and so are the TailSteer finetune's
([sensenova/SenseNova-U1.5-8B-MoT-TailSteer](https://huggingface.co/sensenova/SenseNova-U1.5-8B-MoT-TailSteer)).
sensenova-u1-swift is MIT.
