# Creator kit 0.1.9

A local authoring kit for independent native plugins. Generated projects use the SDK in `Vendor/NookPluginSDK` and keep their own code, tests, fixture data and build products. They do not compile or link the NeroNook app. Creator tooling does not become a runtime dependency.

## Commands

Run `python3 Creator/nook.py` from the SDK directory, or `python3 Tools/nook.py` inside a generated project.

| Command | Result |
| --- | --- |
| `create /path/to/MyModule --id com.example.my-module --name "My Module"` | New Swift project with local SDK, tests and instructions; existing destinations are never overwritten |
| `doctor /path/to/MyModule --report /path/to/result.json` | Read-only source-snapshot and macOS/Swift/build-tool checks; optional local result without protocol payloads, credentials or environment dumps |
| `doctor /path/to/NeroNook-Creator-Kit` | Verify the extracted kit's complete recorded file set and development environment |
| `validate /path/to/MyModule` | Builds the project checker and validates the manifest with the actual vendored SDK |
| `dev /path/to/MyModule` | Builds/packages and opens the standalone native preview; rerun after edits, quit the preview to stop it |
| `dev /path/to/MyModule --replay /path/to/replay.json` | Replays bounded starter-owned ready/offline/recovered states every two seconds |
| `test /path/to/MyModule` | Runs project tests and the packaged process against old/current fake hosts, without invoking actions |
| `test /path/to/MyModule --replay /path/to/replay.json` | Also verifies the starter's ordered status/availability replay |
| `pack /path/to/MyModule --identity YOUR_SIGNING_IDENTITY` | Release build, manifest validation, stable certificate signing, compatibility verification, a new app and zip |

`pack --developer-id --identity YOUR_DEVELOPER_ID` enables hardened runtime and a secure timestamp, then verifies the Developer ID Application signature. It also includes the SDK license notice in the app. Notarization and stapling are separate explicit release steps; see [signing](../SIGNING.md). An installed development signature is not silently migrated to a distribution identity.

`pack` and `dev` create content-addressed app names in the project's `build` directory. They never overwrite the installed plugin or a running app. Older builds remain there for manual reinstall with the host's usual review. Edited existing output is rejected. Nothing automatically grants cross-plugin access or starts device/account connections.

Installable builds use an explicit `--identity`, `NERONOOK_SIGNING_IDENTITY`, or the installed plugin's certificate. They never fall back to ad hoc signing. An update must keep its bundle identifier and satisfy the installed app's designated requirement. A first installation needs an explicit certificate. Signing that does not finish within 25 seconds stops with one actionable error; it does not retry or change Keychain settings. The independently copied `signing.py` contains no private keys or credential values. See [signing and Keychain](../SIGNING.md).

The `test` command alone uses ad hoc signing under a distinct `.protocol-test` bundle identifier. This exercises the protocol without impersonating the installed app's privacy/credential identity; it is not an installable update.

Before building, the tools verify the vendored SDK against `SDK-SNAPSHOT.json`. Changed, missing, extra or linked SDK source fails without updating that record. Build caches are excluded. Deliberate SDK upgrades require reviewing the change and deliberately regenerating the source record. The snapshot identifies source drift, not a trusted publisher.

The test host checks identity, fresh session, sequence ordering, real SDK validation, three periodic snapshots and clean EOF shutdown. Protocol payloads and plugin stderr are not printed in diagnostics. Compiler/test output is ordinary local developer output, not a general secret-redaction service. Test only source projects you trust: native code and its build scripts are executable code.

## Starter behavior

Upcoming required creator migration: [shared appearance](../APPEARANCE.md) for
native views, custom HTML/CSS and module-owned windows. Light, Dark, Follow System
and paired themes must inherit by default, with Nearly Nothing as the initial
theme. The current starter has not yet been migrated; do not claim appearance
conformance solely from the existing build/protocol checks.

The module supplies a local counter, inline Add and reviewed Reset, a Settings gear with an offline toggle, a read-only shared `read_status` action and an expiring status channel. Modern hosts receive control cards; older hosts receive ordinary fields and actions, with Reset review kept in a plugin-owned native alert. The counter is memory-only and does not claim restart persistence. State is shared by both displays through one plugin process. The native preview has a 720×405 content area plus a status line; the host owns actual card styling, selector and display sizing.

The generated README explains where to replace demo logic. The tool supports these Swift-package stdio starter projects; existing specialized Xcode/Catalyst/plugin build systems stay independent. The full SDK's application-launch transport is documented separately. Automatic rebuild/watch, arbitrary third-party project adapters, interactive error-console UI and integrated automatic rollback are not part of this version.

## Export

From the host source checkout, `python3 SDK/Creator/export-kit.py` creates `build/NeroNook-Creator-Kit-0.1.9.zip`. It freezes source bytes, writes their hashes, extracts the actual archive and verifies it before replacing the output. A prior archive is retained under its content digest. It includes SDK source, creator templates/tools, reference docs and source hashes. The kit can create another independent project after extraction. It excludes build caches, the host implementation, installed-plugin packages and account/device data.

`kit.json` separates creator version **0.1.9**, SDK source-host version **0.29.1**, starter minimum host **0.20.1** and protocol **1**. Newer SDK capabilities remain optional and negotiated; current source does not make an old host support them. Reports belong outside source directories or under `build/`, so they do not change the files they checked.

If Command Line Tools select an SDK requiring a SwiftUI macro plugin they do not include, doctor reports it before building. Select full Xcode for the complete XCTest-based workflow. `NERONOOK_SDK_PATH` can select a compatible installed SDK for build/test, but does not add XCTest to Command Line Tools. The same explicit SDK is passed to build and test; source is not altered.

Run `doctor` before `test`, then `pack`. Doctor does not compile the project, run plugin code, inspect accounts, grant permissions, install an app or establish full manifest compatibility. `validate` and `test` use the actual Swift SDK validators. Packaging still verifies stable signing identity. Neither preflight nor hashes establish notarization or public release readiness.

The SDK, creator tools and examples use the [MIT License](../LICENSE); see [scope and creator obligations](../LICENSING.md). Generated projects retain the notices. Export remains a preview artifact; publication, notarization, external creator trials and distribution policy remain separate milestones.

## Creator trial

Use only the extracted kit on another Mac, without the host source checkout. After making your own module change, `python3 Tools/trial.py . --output build/trial-1.json --role owner` runs preflight, verifies the sole local SDK dependency and runs build/tests/protocol checks. Use `--role external-creator` only when that describes the actual tester. Every result needs a new filename; source and historical receipts are retained. Results contain OS/build/architecture/model and stage outcomes, without serial numbers, usernames, source, credentials or captured protocol output. They stay local.

Native checks are never inferred from a successful build. Optional `--observed install=pass` records a check you actually performed; absent checks remain `not-run`. UI failures and skipped checks survive automated success. See [the full trial](../CREATOR-TRIAL.md). The helper executes trusted project code for explicit tests; it does not install an app, create a certificate, accept agreements, grant permissions or upload a result.

## Recover an installed native plugin

NeroNook 0.18.0 records up to five distinct previous packages during updates. In host Settings → Modules, expand **Previous versions** for your plugin and review **Restore**. The host checks the exact saved package again and keeps current enabled/display/compact settings. Older unindexed folders are not automatically discovered. Restoring code does not rewind module-owned settings or data; test schema compatibility before recommending a downgrade. No actions are replayed. See [compatibility and recovery boundaries](../COMPATIBILITY.md).

Creator kit 0.1.3 introduced a bundled custom-view example and independent native-window helper. Read [custom views](../CUSTOM-VIEWS.md). View assets under Resources/Views are packaged with the plugin; no host checkout is required.

Creator kit 0.1.4 adds an editable manifest icon to every new module and a reusable SwiftUI icon view. Read [module icons](../ICONS.md).

Native packages are agent applications (`LSUIElement = true`), including the standalone preview. They remain usable through their windows without a Dock tile. The shared `PluginApplication.configure()` and `PluginWindows` preserve hosted accessory mode. Independent Catalyst projects should set the same boolean Info.plist flag in their own build.

## Paired themes (local SDK milestone)

Every theme includes Light and Dark palettes. New native modules inherit the
shared context through `PluginThemedRoot`/`PluginWindows` and advertise optional
`appearance-v1`. The bundled web starter includes the paired CSS fallback, so it
stays usable with older hosts and without the host. See [appearance](../APPEARANCE.md)
for semantic tokens, session handling and current platform qualifications. This
source milestone is not a public SDK release or proof that an older installed
host supports live theme delivery.
