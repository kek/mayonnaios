# Implementation plan for #81 — MayonnaiOS documentation site

## Scope and implementation rules

- Generate one static, latest-`trunk` site with ExDoc through Mix. Use no Python, Node asset pipeline, external font/CDN, analytics, search service, or custom JavaScript.
- Build and validate the complete site in this PR: repository content, workflow, and the generated review artifact must be complete and reviewable before merge. Pull requests never deploy. Enabling **Settings → Pages → Source: GitHub Actions**, the first deployment from a successful push to `trunk`, and verification of `https://kek.github.io/mayonnaios/` inherently happen after merge as repository-owner issue-closure checks; they are not implementation-PR acceptance or mid-PR prerequisites, and production acceptance is not complete until they pass.
- Keep the current `docs/*.md` paths so existing GitHub deep links remain valid. Published page basenames are lower-case kebab-case and are treated as stable; do not hard-code `doc/` URLs in prose.
- Guides own user procedures, support status, and cross-feature explanations. Moduledocs own callable contracts and implementation mechanics. Retain only the shortest command/warning needed in both and cross-link to the canonical detail.
- Use the formal feature labels **Verified**, **Experimental**, **Untested**, and **Unsupported**; use **Measured**, **Estimated**, and **Historical** only as evidence/record qualifiers. Text labels, not color alone, carry meaning.

## Migration audit to preserve during implementation

The content edit must check off this mapping in the implementation PR description. A heading may be rewritten or split, but no command, warning, deliberate guarantee, or limitation may disappear without an explicit correction note.

| Existing source | Canonical destination(s) | Required correction or treatment |
|---|---|---|
| README introduction, Supported | `docs/index.md`, `docs/hardware-status.md` | Replace a flat success list with the status vocabulary; do not describe Mix dependency targets as supported products. |
| Building and flashing | `docs/build-and-flash.md` | State that there is no supported prebuilt image; include SSH public-key and WiFi environment prerequisites from `config/target.exs`. |
| Changing which WiFi it joins | `docs/wifi.md` | Keep panel controls, additive-network and rejected-password guarantees, and EAP/WEP limits; say WiFi is the only verified remote access. |
| Putting games on it, second card, Emulator cores | `docs/games-and-cores.md`, `docs/files-and-storage.md`, `docs/ssh-and-iex.md`, `docs/retroarch-internals.md` | Preserve unauthenticated-LAN warning, streaming uploads, plain `scp` (not `scp -O`), internal-write/removable-read behavior, unmount requirement, checksums, versioned installs, and save durability. |
| Pickles | existing `docs/pickles.md` | Keep the full author/deploy/API guide and link it from owner and contributor paths; introduce it as “sandboxed Lua apps.” |
| Moving files around | `docs/files-and-storage.md`; implementation details in `MayonnaiOS.Files` | Keep no-overwrite, `.part`/fsync, root policy, and symlink caveats without copying the full moduledoc. |
| Game streaming (Moonlight) | `docs/moonlight.md`, `docs/ssh-and-iex.md` | Mark **Untested** on RG40XXV; distinguish host-side config tests from handheld operation and retain the SSH pairing exception. |
| Using it as a Bluetooth controller | existing `docs/bluetooth-controller.md`, new `docs/bluetooth-internals.md`, `docs/ssh-and-iex.md` | Make the retained basename the task page; mark **Experimental**, place the intermittent hci0 limitation beside the label, and move stack/identity internals rather than duplicate them. |
| Seeing what Bluetooth is nearby | `docs/bluetooth-devices.md`, `docs/bluetooth-internals.md` | Mark scanning/bond management **Verified** and outbound pairing/audio **Unsupported**; retain mutual exclusion over hci0. |
| Poking at a running device | `docs/ssh-and-iex.md` | Make IEx an advanced/sometimes-required interface, not the primary owner path. |
| Working on it | `docs/development.md`, `docs/contributing.md` | Keep `mix test`, host runtime, reload behavior, keyboard map, dependencies, headless-test distinction, and the 640×480 evidence warning. |
| Going deeper, three repositories | `docs/index.md`, `docs/repositories.md` | Keep an ownership table and link out for BSP/native-bundle procedures rather than copying them. |
| existing `docs/data-layout.md` | same path | Publish in Architecture and internals; reconcile paths with the task guides. |
| existing `docs/retroarch-internals.md` | same path | Keep as current runtime architecture and link back to games/core tasks. |
| existing `docs/retroarch-provisioning.md` | same path | Retitle/label as a **Historical decision record**. Clearly separate the still-current bundle decision from unbuilt investigation and link to current internals, `mayonnaios_bundles`, and repository-only evidence. |
| existing `docs/retroarch-reference/*` | same repository-only paths | Do not add these Buildroot files as ExDoc extras. Link to their GitHub tree as historical evidence and preserve the warning that comments are suspect and the package was never built. |
| source claims in `MayonnaiOS.WiFi`, `USBGadget`, `LowPower`, `LowPower.Radio`, config, and tests | `docs/hardware-status.md` plus corrected source docs/comments | Hardware observation wins: gadget setup is implemented but RG40XXV USB-C enumeration is **Untested/not observed**; backlight sleep/wake is **Verified**, low-power mode **Experimental**, and savings **Estimated/unmeasured**. |

## Dependency-ordered implementation

### 1. Add a reproducible host-only ExDoc foundation

**Files to modify**

- `mix.exs`
- `mix.lock`

**Behavior and content**

- Add `{:ex_doc, "~> 0.40.3", only: :dev, runtime: false}` and regenerate `mix.lock`; use the ordinary host/dev dependency and build environment rather than inventing a separate docs Mix environment. Do not add a link checker, HTML parser, web framework, or any non-Elixir dependency.
- Add `source_url: "https://github.com/kek/mayonnaios"`, `homepage_url: "https://kek.github.io/mayonnaios/"`, `description`, and `docs: &docs/0` to `project/0`. Keep application version `0.1.0`; this is not release-versioned documentation.
- Define `docs/0` with exactly:
  - `formatters: ["html"]`, `output: "doc"`, `main: "index"`, `extra_section: "Guides"`, `canonical: "https://kek.github.io/mayonnaios/"`, `source_ref: "trunk"`, and the repository SVG `logo`/`favicon` paths.
  - an explicit `extras` list containing every published file named in steps 2–4, including all five current top-level guides, and no wildcard. Give extras stable titles where the Markdown title is not the desired navigation title.
  - `groups_for_extras` in this order: **Start here**, **Use the device**, **Build and develop**, **Architecture and internals**, **Hardware status**. Each explicit extra occurs in exactly one group.
  - `groups_for_modules` in this order: **Public and operational APIs** (explicitly including `MayonnaiOS`, `WiFi`, `Files`, `Led`, `Sleep`, `LowPower`, `Bundle`, `Cores`, `GamesCard`, `Controller`, `Pairing`, `Moonlight`, `Pickles`, `Web`, and other owner/maintainer entry points), **Device and runtime**, **UI**, **Bluetooth internals**, and **Pickles internals**. Use ordered exact lists/anchored regular expressions so every documented `MayonnaiOS.*` module has one predictable group while modules marked `@moduledoc false` remain hidden; do not introduce a `:modules` allowlist.
  - `assets: %{"docs/assets" => "mayonnaios"}` and HTML-only `before_closing_head_tag` markup for `assets/mayonnaios/docs.css`; return an empty string for non-HTML formatters. Add an HTML-only footer hook containing a visible current-`trunk` notice and “Report a documentation issue” link while preserving ExDoc’s required attribution. Each guide also starts with the same current-`trunk` notice so it is present in semantic document order; API pages retain the global notice.
- Confirm these names/options against ExDoc 0.40.3’s official `ExDoc` and `Mix.Tasks.Docs` APIs during implementation; notably, `:assets` is a source-to-target directory map, `:favicon`/`:logo` accept SVG, extras generate basename HTML pages, and `mix docs --warnings-as-errors` is supported.

**Focused verification**

- From a host checkout with the project's existing Cairo/GTK native prerequisites but no firmware credentials, target toolchain, sibling BSP, device, or Python, run `MIX_TARGET=host mix deps.get` and `MIX_TARGET=host mix docs --warnings-as-errors`. The final author/CI sequence adds `MIX_TARGET=host mix docs.check` after step 5 creates that task.
- Inspect `doc/index.html`, one guide, and one module page for the canonical URL, source links pinned to `trunk`, all five guide/module group labels, stylesheet, logo/favicon, current-trunk notice, search data, and ExDoc attribution.

**Commit boundary:** `Configure ExDoc for the documentation site`

### 2. Build the landing experience, visual identity, and status reference

**Files to create**

- `docs/index.md`
- `docs/hardware-status.md`
- `docs/assets/docs.css`
- `docs/assets/mayonnaios-mark.svg`
- `docs/assets/favicon.svg`

**Behavior and content**

- Make `docs/index.md` the owner-first landing page. Its first viewport names MayonnaiOS and the Anbernic RG40XXV, says docs describe current `trunk` and that source builds are the only supported installation route, shows the status legend, and gives prominent **Use your device** and **Build and flash** paths. Add cards for all five guide groups and one-click links to WiFi, upload games, build/flash, and development. Include concise evaluator, owner, builder, and contributor routes, each with prerequisites, ordered first outcome, success signal, and troubleshooting/deeper link.
- Build `docs/hardware-status.md` as a matrix with area, textual status, evidence/firmware reference, and limitation/next step. Cover display/GPU, controls, audio, power/battery/thermal, WiFi, USB gadget, Bluetooth controller, Bluetooth scanning/bonds, outbound pairing/audio, both SD slots, sleep/backlight, extra low-power measures, RetroArch/core/save behavior, and Moonlight. Apply the classifications from `ANSWERS.md`: Moonlight **Untested**; low power **Experimental** with backlight **Verified** and savings **Estimated**; Bluetooth controller **Experimental** with verified recovery but unexplained intermittent hci0 bring-up; scanning/bonds **Verified**; outbound pairing/audio **Unsupported**; USB gadget **Untested** until enumeration is observed. Include measured firmware hash/date where the repository provides one, and explicitly distinguish host development and the other Mix dependency targets from supported RG40XXV hardware.
- Draw original repository-owned SVGs with text alternatives supplied where embedded. The CSS should use system fonts, neutral cream/charcoal surfaces, one-pixel rules, restrained green/red accents, and pixel-inspired details without copying the launcher. Scope selectors to stable ExDoc classes, preserve its layout/search/night mode/attribution, provide AA light/dark contrast and visible `:focus-visible`, honor `prefers-reduced-motion`, never encode status only by color, and remain usable at 320px and desktop widths. Load no remote resource.
- Do not add screenshots or placeholders. Record the future authoritative capture list (launcher, WiFi wheel, upload UI, and physical device) in contribution guidance later; any future host capture must be captioned “host runtime,” and non-Verified imagery must have an adjacent textual status.

**Focused verification**

- Generate docs with warnings as errors and search generated output for the six terms “flash,” “WiFi,” “upload games,” “Bluetooth controller,” “sleep,” and “development”; confirm each intended guide is indexed.
- Manually inspect landing, matrix, and API pages at 320px and desktop widths, keyboard-only, in light/dark and reduced-motion modes. Confirm heading order, focus visibility, contrast, SVG alt treatment, text status labels, no horizontal content loss, and no external asset/script request.

**Commit boundary:** `Add the docs landing page and visual design`

### 3. Migrate owner and advanced-user tasks into canonical guides

**Files to create**

- `docs/wifi.md`
- `docs/games-and-cores.md`
- `docs/files-and-storage.md`
- `docs/bluetooth-devices.md`
- `docs/bluetooth-internals.md`
- `docs/sleep-and-power.md`
- `docs/moonlight.md`
- `docs/ssh-and-iex.md`

**Files to modify**

- `docs/bluetooth-controller.md`
- `docs/pickles.md`
- `docs/data-layout.md`
- `docs/retroarch-internals.md`

**Behavior and content**

- Give every goal page a short prerequisites section, an ordered panel/browser-first procedure, an explicit success indication, troubleshooting/status limitations, relevant module links, and edit/report links to its exact `trunk` source path. Use source `.md` links between extras so ExDoc resolves them; use ExDoc module/function references for API links.
- `wifi.md`: connecting/changing/forgetting networks, character wheel controls, additive configuration and wrong-key rollback, EAP/WEP limits, and reflash risk when initial WiFi fails.
- `games-and-cores.md`: browser upload, unauthenticated home-LAN trust boundary, `scp` caveat, internal/removable libraries, core installation/checksum behavior, RetroArch prerequisite, save behavior, and links to internals.
- `files-and-storage.md`: Files-column copy/move/rename/delete, roots and two-card ownership, no-overwrite and durable `.part` behavior, backup/unmount warning, and the canonical data-layout link.
- Rewrite retained `bluetooth-controller.md` as the **Experimental** user task (host-specific pairing, controls, macOS permission, two-sided re-pairing, panel stages, known hci0 issue). Move borrowed identity, security, raw-HCI stack, recovery mechanics, and future protocol work to `bluetooth-internals.md`; cross-link both directions and remove distinctive paragraph duplication.
- `bluetooth-devices.md`: scan and forget-bond task, hci0 mutual exclusion, and explicit **Unsupported** outbound pairing/headphone audio.
- `sleep-and-power.md`: power-button/manual/three-minute automatic behavior, persisted automatic-sleep switch, charging/program pause rules, orderly poweroff, LED meanings, fake-sleep limitation, and measured-versus-estimated distinction.
- `moonlight.md`: **Untested** installation/config task, editable settings and preserved unknown keys, save/success indication, next-stream behavior, and clearly separated SSH pairing. Do not imply a successful handheld stream.
- `ssh-and-iex.md`: WiFi-first SSH/IEx connection, logs, bundle/core operations, library/card operations including required unmount, Bluetooth diagnostics/recovery, and Moonlight pairing; link to function docs rather than reproduce contracts.
- Keep `pickles.md` the complete Pickles author/deploy guide, reconcile its opening claim with current UI-capable Pickles, and add navigation/status/source links. Reconcile `data-layout.md` and `retroarch-internals.md` with the new user guides and link back to them without changing their current architecture role.

**Focused verification**

- Run `MIX_TARGET=host mix docs --warnings-as-errors`; manually follow every procedure’s local links and compare commands/controls against `config/target.exs`, `MayonnaiOS.WiFi`, `Files`, `GamesCard`, `Bundle`, `Cores`, `Moonlight`, `Controller`, `Pairing`, `Sleep`, `LowPower`, `Led`, `Web`, `Pickles`, and their focused tests.
- Search for distinctive old README sentences and ensure long-form prose has only one canonical home. Check off every owner/advanced-user row in the migration audit and verify the four retained GitHub links (`docs/pickles.md`, `docs/bluetooth-controller.md`, `docs/data-layout.md`, `docs/retroarch-internals.md`) still exist.

**Commit boundary:** `Migrate device tasks into ExDoc guides`

### 4. Add build/contributor guidance and finish the architecture migration

**Files to create**

- `docs/build-and-flash.md`
- `docs/development.md`
- `docs/contributing.md`
- `docs/repositories.md`

**Files to modify**

- `docs/retroarch-provisioning.md`
- `lib/mayonnaios/usb_gadget.ex`
- `lib/mayonnaios/low_power.ex`
- `lib/mayonnaios/low_power/radio.ex`
- `config/target.exs`

**Behavior and content**

- `build-and-flash.md`: state “no supported prebuilt firmware,” list supported RG40XXV/source prerequisites (Elixir/Erlang project versions, SSH public key, `MAYONNAIOS_WIFI_SSID`, `MAYONNAIOS_WIFI_PSK`, `MIX_TARGET=rg40xxv`, sibling BSP availability), then exact `mix deps.get`, `mix firmware`, `mix burn`, and later `mix upload nerves.local` procedures with success/recovery checks. Do not require these target credentials for docs generation.
- `development.md`: host `mix test` and `iex -S mix` outcomes, native GUI prerequisites, 640×480 caveat, reload workflow, keyboard mapping, web UI, scratch paths, and headless-test behavior.
- `contributing.md`: acknowledge the existing host prerequisites (`gtk+3`, Cairo, `pkgconf`, and XQuartz on macOS), then give the exact documentation author sequence used everywhere: `MIX_TARGET=host mix deps.get`, `MIX_TARGET=host mix docs --warnings-as-errors`, and `MIX_TARGET=host mix docs.check` (with optional `MIX_TARGET=host mix docs --open`). Document output at `doc/` and a Pages-base inspection command using only existing Elixir/Mix dependencies (serve `Plug.Static` with Bandit at `/mayonnaios`, then visit `/mayonnaios/index.html`; no Python server). Add a maintenance checklist for user-visible behavior, commands/config, hardware status/evidence/hash/date, links, and screenshots. Document that external HTTP status is reviewed when introduced but does not gate CI.
- `repositories.md`: explain which changes belong to this application, `nerves_system_rg40xxv`, and `mayonnaios_bundles`; link to owner repositories and leave detailed external build procedures there.
- Rewrite `retroarch-provisioning.md` opening as a **Historical decision record**: identify the current “bundle, not Buildroot” decision, date/evidence status, and never-built investigation; link to current runtime internals and bundles repository. Keep `docs/retroarch-reference/` repository-only and link to its GitHub tree without presenting comments as verified facts.
- Resolve published-source contradictions: edit the `USBGadget`, `LowPower`, and `LowPower.Radio` moduledocs and stale `config/target.exs` comments so they say `usb0` setup is implemented but cable enumeration is not observed and cannot be promised as recovery. Preserve WiFi as the only verified remote access and low-power savings as unmeasured. Do not change runtime behavior.

**Focused verification**

- From a fresh host/dev environment satisfying the project's existing Cairo/GTK native prerequisites, prove docs generation uses `MIX_TARGET=host`, does not evaluate target credential guards, access `../nerves_system_rg40xxv`, start Scenic/application children, or need a target toolchain, device, firmware credentials, or Python.
- Run formatting, docs warnings-as-errors, and focused existing tests covering WiFi, USB-adjacent configuration assumptions, low power/sleep, Moonlight, Bluetooth, cores/bundles/cards, and host runtime. Complete the README/docs/source claim-audit rows and review newly added external URLs manually.

**Commit boundary:** `Document building, development, and architecture`

### 5. Add Mix-native generated-site link and asset validation

**Files to create**

- `lib/mix/tasks/docs.check.ex`
- `test/mix/tasks/docs_check_test.exs`

**Files to modify**

- `.formatter.exs`
- `docs/contributing.md`

**Behavior and content**

- Implement `Mix.Tasks.Docs.Check` with `@moduledoc false`, accepting an optional output directory defaulting to `doc/`. Use only Elixir/OTP (`File`, `Path`, `Regex`, and `URI`), not Python or another dependency.
- Walk every generated HTML/CSS file. Extract local `href`, `src`, and `srcset` references plus CSS `url(...)`; ignore external schemes, protocol-relative URLs, `mailto:`, and `tel:` without making network requests. Strip query strings, percent-decode paths, understand the `/mayonnaios/` Pages prefix, resolve relative paths, map directory links to `index.html`, reject paths escaping `doc/`, and require every local file/asset to exist.
- For local HTML fragments, collect generated `id` (and legacy `name`) attributes in the target document and fail when the decoded fragment is absent. Report all source file/reference/reason failures together via `Mix.raise/1`; print a checked-file/reference summary on success.
- Test same-page and cross-page anchors, relative and Pages-prefixed paths, query/fragment combinations, percent encoding, directory indexes, images/stylesheets/srcset/CSS assets, ignored external links, missing files/assets/anchors, and traversal. Tests use temporary generated-HTML fixtures and never access the network.
- Document the required sequence consistently as `MIX_TARGET=host mix deps.get`, `MIX_TARGET=host mix docs --warnings-as-errors`, and `MIX_TARGET=host mix docs.check`; the docs command catches ExDoc guide/module reference warnings and the checker catches generated internal links, anchors, and local assets. External HTTP availability remains non-blocking.

**Focused verification**

- Run `MIX_TARGET=host mix test test/mix/tasks/docs_check_test.exs` and the full suite.
- Run both docs commands successfully, then deliberately break one guide anchor and one SVG/CSS reference in the working tree, confirm each command fails in the intended layer with an actionable path, and restore the changes before committing.

**Commit boundary:** `Validate generated documentation links`

### 6. Reduce README to the repository entry point

**File to modify**

- `README.md`

**Behavior and content**

- Reduce to at most about 120 lines: one-paragraph product/RG40XXV overview, compact feature/status summary consistent with `hardware-status.md`, explicit no-prebuilt-image note, minimal source-build quick start, canonical `https://kek.github.io/mayonnaios/` link plus task links, repository ownership links, and contributor commands (`mix test`, `iex -S mix`).
- Keep enough prerequisite warning to avoid producing unreachable firmware and link to the full build guide. Remove operational detail now canonical on the site; do not leave a second manual. Describe access as WiFi-first and do not restore the contradicted USB recovery guarantee.
- Use exact MayonnaiOS/Anbernic RG40XXV terminology and verify every omitted old heading against the migration table.

**Focused verification**

- Check line count, all README local/public links, quick-start commands against `mix.exs` and `config/target.exs`, and status text against the hardware matrix.
- Search README and guides for copied distinctive paragraphs; allow only short identical commands/warnings under the canonical-content rule.

**Commit boundary:** `Make README the concise project entry point`

### 7. Add pinned CI artifact and guarded Pages deployment

**File to create**

- `.github/workflows/docs.yml`

**Behavior and content**

- Trigger on `pull_request` and pushes to `trunk`. Default permissions are `contents: read`; no tag or `workflow_dispatch` deploy path is added.
- Add a `docs` job on `ubuntu-latest` with pinned Elixir `1.20.3` and compatible OTP (the version verified in the implementation), full-SHA actions with version comments, and no firmware credentials. Install the same Cairo/GTK native build prerequisites already required for ordinary Linux host development. Run the exact documentation sequence `MIX_TARGET=host mix deps.get`, `MIX_TARGET=host mix docs --warnings-as-errors`, and `MIX_TARGET=host mix docs.check`; also run `MIX_TARGET=host mix format --check-formatted` and `MIX_TARGET=host mix test`. Do not create or use a separate docs Mix environment.
- Pin the researched current action revisions (refresh against each official action repository immediately before implementation): `actions/checkout@11d5960a326750d5838078e36cf38b85af677262` (`v4`), `erlef/setup-beam@0f75c29430f34bb5af4cce5e3b7f6a8860fca236` (`v1`), `actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02` (`v4`), `actions/configure-pages@983d7736d9b0ae728b81ab479565c72886d7745b` (`v5`), `actions/upload-pages-artifact@7b1f4a764d45c48632c6b24a0339c27f5614fb0b` (`v4`), and `actions/deploy-pages@d6db90164ac5ed86f2b6aed7e0febac5b3c0c03e` (`v4`). Do not use floating tags in workflow `uses:` values.
- Upload `doc/` on every successful PR/trunk build as a clearly named generic review artifact with `retention-days: 7`. On `push` to `refs/heads/trunk` only, run `configure-pages` and `upload-pages-artifact` on that already-validated `doc/` directory.
- Add a separate `deploy` job with `needs: docs`, the exact guard `github.event_name == 'push' && github.ref == 'refs/heads/trunk'`, `pages: write` and `id-token: write` job permissions, `environment.name: github-pages`, and environment URL from `deploy-pages`. It downloads no unreviewed output and cannot run after build/check failure.
- Give docs builds ref-scoped concurrency with `cancel-in-progress: true`; give deployment a separate `pages` concurrency group with `cancel-in-progress: false` so superseded checks can be cancelled without interrupting an active publish. PR/fork jobs have no deployment permissions and never call a deployment action. A failed trunk build leaves the previously deployed Pages artifact untouched.

**Focused verification**

- Validate workflow syntax by review against official GitHub Pages custom-workflow documentation and action manifests; inspect each pinned SHA in its official repository.
- Push the implementation branch and confirm the PR check uploads the complete validated review artifact, runs no configure/upload-pages/deploy step, and logs the exact host/dev docs sequence. Inspect the downloaded artifact locally at the project base path; this repository/workflow/content/artifact review is the implementation-PR acceptance boundary.
- Do not alter Pages settings or deploy during the PR. After merge, the owner selects GitHub Actions as the Pages source if needed, observes the first guarded `trunk` deployment, verifies the canonical live URL, and records the result for issue closure. These operator checks are not retroactive PR blockers, but production acceptance remains incomplete until they pass.

**Commit boundary:** `Build and publish docs with GitHub Actions`

### 8. Final clean-checkout and manual acceptance

**Files to modify only if verification finds defects**

- The exact guide, asset, ExDoc config, validator, README, or workflow file responsible; keep fixes with the nearest coherent commit above, or use one final `Polish documentation site acceptance` commit if commits are already shared.

**Verification**

1. Clone/fetch the branch into a clean directory with no `_build/`, `deps/`, `doc/`, target environment variables, firmware credentials/SSH keys, target toolchain, sibling BSP, or device. Satisfy the project's existing Cairo/GTK host build prerequisites, then run:
   - `MIX_TARGET=host mix deps.get`
   - `MIX_TARGET=host mix docs --warnings-as-errors`
   - `MIX_TARGET=host mix docs.check`
   - `MIX_TARGET=host mix format --check-formatted`
   - `MIX_TARGET=host mix test`
2. Confirm every current/new published guide appears once in navigation; `docs/retroarch-reference/*` remains tracked but unpublished; all documented modules are searchable in the intended API group; and searches for the six launch terms reach their task pages.
3. Walk landing → WiFi, upload games, build/flash, and development in one click. Walk each audience path through prerequisites, ordered outcome, success signal, and troubleshooting. Confirm edit/report/source links, canonical URLs under `/mayonnaios/`, local assets, and retained GitHub deep links.
4. Repeat manual accessibility/design checks on representative landing, task, matrix, and API pages at 320px/desktop, keyboard-only, light/dark, and reduced motion. Confirm no screenshot placeholder, remote font/script, analytics request, hidden focus, color-only status, or removed ExDoc attribution.
5. Reconcile every migration-audit row, all status labels, and all USB/low-power/Moonlight/Bluetooth claims across README, guides, config comments, and published moduledocs. Attach implementation-PR screenshots of landing and one guide at desktop and phone widths (four captures total) for review; these are PR evidence, not site assets.
6. Verify `git status` contains no generated `doc/`, dependency, cache, or temporary files. Confirm the PR workflow artifact is the validated `doc/` tree and that deployment remains skipped before merge.

**Final acceptance boundary:** repository code/workflow/content, tests, the generated artifact, and manual review are complete and are the acceptance boundary for this implementation PR. Pages source enablement, the first live deployment, and live-URL verification are explicit post-merge owner operations required for issue closure; production acceptance is not complete before that follow-up succeeds.
