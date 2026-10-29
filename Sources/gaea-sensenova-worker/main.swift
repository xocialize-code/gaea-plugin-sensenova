import GaeaPluginKit
import SenseNovaPlugin

// The plugin's worker: SenseNovaPlugin's definition over GPP (GaeaPluginKit). `--manifest <path>` writes manifest.json.
await GaeaPluginMain.run(senseNovaPlugin)
