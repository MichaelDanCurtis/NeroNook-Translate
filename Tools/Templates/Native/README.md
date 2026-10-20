# Your independent Nook module

This project builds without the NeroNook app or its source checkout. Its versioned SDK snapshot is vendored in `Vendor/NookPluginSDK`; `SDK-SNAPSHOT.json` records every source hash. Requires macOS 14+, Swift 6/Xcode and Python 3 for development tools. The packaged module has no Python dependency.

```sh
python3 Tools/nook.py doctor . --report build/preflight.json
python3 Tools/nook.py validate .
python3 Tools/nook.py test .
python3 Tools/nook.py dev .
python3 Tools/nook.py dev . --replay Fixtures/replay.json
python3 Tools/nook.py pack .
```

`dev` opens a standalone preview. Stop it by quitting that app; edit code and rerun `dev` to rebuild. It does not automatically install, grant permissions or replace a running plugin. `test` runs your project tests, then the actual packaged process against modern and legacy fake hosts: handshake, SDK-validated messages, timed snapshots and connection-close exit. It does not invoke module actions. `--replay` is a starter-owned demo sequence, not a host feature. Protocol diagnostics never print payload values or captured stderr; compiler output remains ordinary developer output.

In NeroNook 0.20.1+, use Settings → Modules → Install or Update Plugin and choose the `.app` printed by `pack`. Inspect the same module on each monitor. The true shared surface is 16:9 with a separate single-line status and module selector. The standalone preview illustrates these dimensions but does not replace host acceptance.

Change `Sources/ModuleCore/Dashboard.swift` to supply data and actions, `Sources/ModuleApp/ModuleApp.swift` to own lifecycle/setup, and `Resources/NookPlugin.json` to describe the actual capabilities. The demo counter is memory-only, shared across displays and reset on restart. Reset uses in-card confirmation. The shared action bus exports only `read_status` plus expiring state; external changes need correctly classified actions and domain checks before execution. Unknown/offline actions do nothing. Test replay never writes saved preferences or touches hardware.

Keep connection/authentication in the gear settings, content in useful tabs, and ordinary controls in the Nook. Your plugin owns secrets, network clients, state and domain validation. Do not add integration code to NeroNook. Use `PluginApplicationChannel` and your own platform-specific packaging if your framework needs the application-launch transport; this simple starter intentionally uses stdio.

Doctor checks the recorded SDK files and local development tools without building or executing this project. Build/test/pack also reject SDK drift; caches are excluded. Review any deliberate SDK update and regenerate its source record explicitly. A checksum proves source consistency, not publisher identity. Keep JSON reports outside source folders or under build/. Public release checks remain separate from local preflight.

Packaging produces a new content-addressed app and archive for each changed build; previous versions remain available for manual reinstall through the host's normal review. Hosts from 0.18.0 also retain up to five previous installed packages under Settings → Modules → Previous versions. Restoring does not rewind plugin-owned data; verify downgrade compatibility. No automatic rollback, publisher trust or notarization is claimed. Ad hoc signing is local development only; `--identity` selects a specific signing identity. Add your own entitlements, assets and distribution pipeline deliberately before publishing. The starter has no network/device/privacy entitlements.

This is a versioned developer preview. The SDK, tools and starter are MIT-licensed; your own product and release remain independent. A local build does not establish notarization or public release readiness.

On NeroNook 0.20+, the Custom view tab loads your own Resources/Views/studio HTML/CSS/JS, exchanges typed events/state and opens a native SwiftUI window. Edit customDefinition and handleViewEvent in your plugin model, and keep a useful fallback for older hosts. PluginWebSurface can also be used in your own window; PluginWindows is a convenience helper for arbitrary SwiftUI content. The example changes only in-memory demo values.

## Module icon
Edit `icon.symbol`, `icon.color` and optional `icon.badge` in `Resources/NookPlugin.json`. Use an SF Symbol that represents your module and a six-digit RGB accent without `#`. The host renders the icon before the plugin starts. Repackage after changing it. The SDK also provides `PluginIconView` for your own SwiftUI windows; see the creator kit’s `ICONS.md`.

The copied SDK/tools/starter code is MIT-licensed; retain the notices in `LICENSE` and `Vendor/NookPluginSDK/LICENSE`. Your own plugin product can use its own license. For public packaging use `Tools/nook.py pack . --developer-id --identity YOUR_DEVELOPER_ID`, then notarize/staple that exact app archive through your own Apple account. The toolkit does not submit or publish automatically.

Native packages set `LSUIElement` so they can show settings and custom windows without a Dock entry. Hosted startup calls `PluginApplication.configure()`; use `PluginWindows` for plugin-owned windows and keep accessory mode when taking focus. Do not change the application to `.regular` to open a window.
