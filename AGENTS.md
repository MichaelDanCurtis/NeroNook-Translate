# Working on Translate

Read `README.md` and `docs/ARCHITECTURE-PLAN.md` first. The plan records every owner decision (D‑1 to D‑14) and the milestone exit checks; keep its §8 and the README status current.

- Translate is an independent NeroNook plugin. It builds with `swift build` from this workspace alone, with the vendored `Vendor/NookPluginSDK`. It never imports, links or path-depends on host or Voice source.
- Anything copied from another tree is recorded in `docs/PROVENANCE.md` with origin and commit, and modified only here.
- Audio and model work stay outside the host: the app owns audio I/O and persistence; MLX inference lives in separate helper processes under `Engine/`.
- Engine choices (recognition, translation) are open until the §6.1 comparison reports. Do not pick a default in code; keep providers behind protocols with fakes.
- Nothing here authorizes installing a driver, restarting Core Audio, capturing a call, downloading a model, reading another plugin's storage, changing Voice or the host, or publishing. Each of those is an explicit owner approval, listed per milestone in the plan.
- Inventory the sibling working trees before reading them; other work commits there concurrently.
- Tests cover state, schema, scheduling, recovery and evidence logic, not views. Keep authoring and review as separate passes.
- Build with `swift build`; test with `swift test`; check the vendored SDK with `python3 -I Tools/nook.py doctor .`. The MLX helper builds with `swift build -c release --package-path Engine`; its `Package.resolved` mirrors Voice's pins and changes only deliberately.
- The engine protocol codec exists twice (`Engine/Sources/TranslateEngine/Frames.swift`, `Sources/TranslateEngineClient/EngineFrames.swift`); change both together and keep `docs/PROTOCOL.md` current.
- Release policy: all development stays local. No public host or plugin release, catalog update, website deployment or download before host 0.35.0, and that floor alone does not authorize publication.
