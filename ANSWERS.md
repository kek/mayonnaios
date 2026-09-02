# Architecture answers for #81

These decisions apply the settled constraints in `QUESTIONS.md`: this is a fresh design, the generator is ExDoc invoked through Mix, Python is not introduced, and the implementation is delivered in one PR without using a public preview or an intermediate deployment.

## Audience and success

### 1. Primary reader and priority

**Decision.** Optimize the home page first for an RG40XXV owner who has MayonnaiOS installed. The remaining order is: (2) someone evaluating MayonnaiOS, (3) someone building/flashing it, and (4) a contributor changing Elixir/Nerves code.

**Rationale and constraints.** Most of the product's distinctive value is in device tasks—WiFi, games, files, controllers, and sleep—not in its internal API. Evaluation belongs on the same landing page, but build and contributor detail can sit one level deeper. The site must not imply that merely owning an RG40XXV is enough; there is currently no prebuilt image journey.

**Acceptance criteria.** The first viewport identifies MayonnaiOS and the Anbernic RG40XXV, shows its current support status, and offers prominent “Use your device” and “Build and flash” paths. Contributor/API navigation remains globally reachable but is not the primary call to action.

### 2. First successful outcome per audience

**Decision.** Use task-based onboarding. An owner is led to connect WiFi and upload a game; an evaluator gets a concise capability/status overview; a builder gets a successful `mix firmware` and `mix burn`; a contributor gets `mix test` and the host runtime (`iex -S mix`).

**Rationale and constraints.** These are observable outcomes and match existing behavior. A feature tour alone would not help an owner operate the device, while conventional API-first docs would optimize for the lowest-priority audience.

**Acceptance criteria.** Each audience path has a short prerequisites section, one ordered procedure, an explicit success indication, and links to troubleshooting or deeper reference. All four paths are linked from the landing page.

### 3. Prebuilt firmware

**Decision.** Building from source is the only documented installation path at launch. State plainly on both the concise README and “Build and flash” page that no supported prebuilt firmware image is currently offered.

**Rationale and constraints.** No release-image download or credential-provisioning flow exists in the repository. Inventing one is outside this documentation issue and would dangerously imply a supported end-user install path.

**Acceptance criteria.** No download button or “install” wording suggests a prebuilt image. The build guide includes the SSH-key and WiFi environment prerequisites already enforced by `config/target.exs`, plus target selection, dependency retrieval, firmware creation, burning, and upload updates.

### 4. Measurable success

**Decision.** Success requires content coverage, findability, one canonical home, reproducibility, and link-safe publication—not traffic metrics.

**Rationale and constraints.** Analytics would not measure whether the migration is complete and would add privacy/operations scope. Repository-verifiable criteria are appropriate for a one-PR implementation.

**Acceptance criteria.** (1) Landing-page links reach flash, WiFi, upload-games, and development instructions in one click; (2) every substantive current README section and every `docs/*.md` file has an intentional destination recorded in the PR; (3) detailed prose has one canonical home; (4) `mix docs --warnings-as-errors` succeeds on the ordinary host setup; (5) CI checks internal guide/module references; and (6) a merge to `trunk` can publish the same artifact CI reviewed.

## Scope and content ownership

### 5. Concise README

**Decision.** Keep: the one-paragraph overview, a compact verified/experimental feature summary, a minimal source-build quick start, an explicit “no prebuilt image” note, project/docs links, and a short contributor command pair (`mix test`, `iex -S mix`). Move all operational instructions—including WiFi controls, upload/file operations, cards, cores, Bluetooth, Moonlight, sleep details, IEx recipes, and internals—to the site.

**Rationale and constraints.** GitHub visitors can identify, assess, and build the project without leaving the repository, but there is no second user manual to keep synchronized.

**Acceptance criteria.** README is at most about 120 lines, can produce the first firmware when its linked prerequisites are met, and links to the canonical docs for every omitted task. Recovery access is described accurately as WiFi-first rather than preserving the contradicted USB guarantee.

### 6. Canonical prose and repository-only material

**Decision.** The ExDoc site is canonical for maintained prose documentation. Every current top-level `docs/*.md` file is included in ExDoc and navigation. Repository mechanics such as workflow comments and fixture/reference source files may remain repository-only; they are not parallel prose manuals.

**Rationale and constraints.** ExDoc supports additional Markdown pages through its `:extras` configuration, so existing Markdown can remain version-controlled at its current path while joining one navigation and search system ([ExDoc additional pages](https://hexdocs.pm/ex_doc/readme.html#additional-pages)).

**Acceptance criteria.** `mix.exs` lists all published guides explicitly as extras and groups them. No maintained guide is omitted merely because it is contributor-facing. A page that is intentionally historical says so in the page and navigation.

### 7. RetroArch provisioning history

**Decision.** Publish `docs/retroarch-provisioning.md` under “Architecture and internals” as a **Historical decision record**, edited to separate the still-current “bundle, not Buildroot” decision from the pre-decision investigation. Keep `docs/retroarch-reference/` as repository-only source evidence linked from that page; do not render each retained Buildroot file as a guide. Do not merge it into `retroarch-internals.md`, which describes current runtime behavior.

**Rationale and constraints.** The decision explains an important repository boundary, while the reference comments are explicitly suspect and are not user documentation. Keeping a status-marked decision record avoids losing history or presenting stale build notes as instructions.

**Acceptance criteria.** Navigation labels the page “Decision record”; its opening status box says what remains authoritative and what has never been built; it links to current internals and the bundles repository; no copied reference comment is presented as verified fact.

### 8. Moduledocs

**Decision.** Publish documented source modules as a secondary contributor API reference, but curate navigation with `groups_for_modules`: Public/operational APIs, device and runtime, UI, Bluetooth internals, and Pickles internals. Hide only modules already marked `@moduledoc false`; do not create a fragile hand-maintained `:modules` allowlist.

**Rationale and constraints.** The moduledocs contain valuable implementation contracts and ExDoc is designed to combine guides and API docs. Curated groups improve orientation without suppressing searchable implementation details; ExDoc supports custom module and page grouping ([ExDoc features and grouping](https://hexdocs.pm/ex_doc/readme.html)).

**Acceptance criteria.** All modules with moduledocs build and are searchable; the sidebar clearly distinguishes “Guides” from “API reference”; `MayonnaiOS.WiFi`, `Files`, `Led`, `Sleep`, and `LowPower` are reachable from relevant guides.

### 9. Canonical rule for duplicated behavior

**Decision.** Guides own user intent, supported procedures, status, and cross-feature concepts. Moduledocs own callable contracts, arguments/returns, invariants, and implementation mechanics. A guide may repeat only the minimum command or warning needed to complete a task, then link to the module; a moduledoc may link back but must not become an alternate user tutorial.

**Rationale and constraints.** This preserves useful API explanations while preventing the current README-versus-source duplication from reappearing.

**Acceptance criteria.** Each migrated README paragraph has one canonical destination. Repeated commands are short and identical; long rationale is not copied between a guide and moduledoc. Review includes a search for distinctive duplicated paragraphs.

### 10. IEx/API examples

**Decision.** Treat SSH/IEx as a supported advanced-user and maintainer interface, not the primary owner interface. Put task-level alternatives in one “SSH and IEx” guide and keep complete function detail in API reference.

**Rationale and constraints.** The device deliberately opens an IEx prompt over SSH, and some current tasks (Moonlight pairing, unmounting the second card) require it. Mixing IEx into every basic task obscures panel/browser workflows.

**Acceptance criteria.** Basic pages lead with panel or browser steps. Required IEx exceptions are called out where needed and linked to the advanced guide. The advanced guide covers connecting, logs, bundle/core operations, card unmounting, and pairing diagnostics without duplicating full moduledocs.

### 11. Adjacent repositories

**Decision.** Explain the three-repository architecture and provide an integrated orientation, but keep detailed BSP and native-bundle build procedures canonical in `nerves_system_rg40xxv` and `mayonnaios_bundles`.

**Rationale and constraints.** This repository cannot guarantee or validate detailed procedures owned elsewhere. Readers still need to know where a board-support or native-bundle change belongs.

**Acceptance criteria.** A contributor page has a responsibility table and links to each repository. No copied cross-repository procedure is presented as local truth; external links name the owning repository.

## Information architecture and findability

### 12. Top-level navigation

**Decision.** Use these guide groups, in order: **Start here**, **Use the device**, **Build and develop**, **Architecture and internals**, **Hardware status**, followed by **API reference** module groups. “Start here,” “Use the device,” “Build and develop,” and “Hardware status” must be globally visible.

**Rationale and constraints.** This is a task-first split with enough separation for owners and contributors, implemented directly with ExDoc extras/module groups rather than a second navigation framework.

**Acceptance criteria.** Every page belongs to exactly one sidebar group. Landing-page cards mirror the first five labels. Navigation remains usable at phone width and does not require custom JavaScript.

### 13. Feature-page boundaries

**Decision.** Organize user pages around goals; organize architecture pages around subsystems. Examples: separate “Use as a Bluetooth controller” and “Inspect nearby Bluetooth devices” tasks, with one linked Bluetooth-stack internals page; group games, cores, cards, and saves under owner goals while retaining RetroArch internals separately.

**Rationale and constraints.** Owners recognize desired outcomes, while contributors debug subsystem boundaries. A single model cannot serve both without awkward pages.

**Acceptance criteria.** User-page titles begin with recognizable verbs/outcomes and avoid internal module names. Each links to at most the relevant subsystem reference; internals pages link back to the user behaviors they implement.

### 14. Hardware-status page

**Decision.** Publish one RG40XXV capability matrix with columns for area, status, evidence/firmware reference, and limitation/next step. Include tested, untested, experimental, unsupported, and known-broken behavior plus measured facts where useful. Do not present other `@all_targets` entries as supported products; describe them as Nerves dependency scaffolding unless a complete profile and hardware verification are later documented.

**Rationale and constraints.** `config/rg40xxv.exs` is the only physical product profile in scope; `config/host.exs` is a development profile. A list of Mix targets is not a support claim.

**Acceptance criteria.** The matrix covers display/GPU, controls, audio, power/battery/thermal, WiFi, USB gadget, Bluetooth, both card slots, sleep/low power, RetroArch, and Moonlight. Each non-verified row says exactly what is missing. A note distinguishes host development and dependency targets from supported hardware.

### 15. Versioning

**Decision.** Publish a single latest site for `trunk`, not per-release docs. Every page header/site banner states “Documentation for current `trunk`; installed firmware may differ,” and hardware evidence may name the tested firmware hash/date.

**Rationale and constraints.** The project version remains `0.1.0` and there is no established release-doc lifecycle. HexDocs’ package/version model would imply version guarantees that this application does not currently make.

**Acceptance criteria.** The site has no release selector and makes no promise that `0.1.0` identifies all described behavior. Time-sensitive claims carry evidence or a last-verified marker. A future versioned-doc design is explicitly outside #81.

### 16. Search

**Decision.** Use ExDoc’s built-in full-text search with guides and module reference in the same site/index; add no external search service. Guide titles and summaries must use owner vocabulary so task searches surface useful pages naturally.

**Rationale and constraints.** ExDoc already provides full-text search, quick search, responsive behavior, keyboard shortcuts, and night mode ([ExDoc features](https://hexdocs.pm/ex_doc/readme.html)). Building ranking overrides or a second index is unnecessary launch scope.

**Acceptance criteria.** Searches for “flash,” “WiFi,” “upload games,” “Bluetooth controller,” “sleep,” and “development” find the intended guide. API results remain available; no analytics/search SaaS is loaded.

## Status, claims, and terminology

### 17. Status vocabulary

**Decision.** Use four feature labels: **Verified** (implemented and observed on RG40XXV), **Experimental** (implemented and observed, but incomplete, unreliable, or with unresolved risk), **Untested** (implemented but not run on RG40XXV), and **Unsupported** (not provided). Use separate evidence qualifiers—**Measured** and **Estimated**—for numbers, and **Historical** for decision records; those are not feature maturity levels.

**Rationale and constraints.** “Stable” would imply a compatibility/release policy that does not exist. Separating implementation maturity from measurement prevents an implemented mechanism from turning an estimate into a claim.

**Acceptance criteria.** A shared status legend defines all terms on the landing and hardware-status pages. The maintainer changing behavior assigns/updates status in the same PR based on tests or named hardware evidence; no label is inferred from visual styling alone.

### 18. Initial classifications

**Decision.** Day-one classifications are: Moonlight **Untested**; low-power mode **Experimental**, with backlight sleep/wake **Verified** but savings **Estimated/unmeasured**; Bluetooth controller **Experimental** because operation is verified but hci0 bring-up has an unexplained intermittent failure (the recovery itself is verified); Bluetooth device scanning/bond management **Verified**, while outbound pairing and Bluetooth audio are **Unsupported**; USB gadget recovery **Untested** until enumeration is observed; current RetroArch runtime/core/save behavior **Verified** where existing hardware evidence says so; provisioning notes **Historical**.

**Rationale and constraints.** These labels preserve distinctions stated in README, moduledocs, config comments, and tests rather than flattening “code exists” into “works.”

**Acceptance criteria.** The landing feature summary and capability matrix agree. Moonlight screenshots/claims cannot imply successful handheld operation. Low-power current savings are never presented as measurements. Bluetooth’s known hci0 issue is adjacent to its Experimental label.

### 19. Contradictory and time-sensitive claims

**Decision.** Hardware observation wins over intended code behavior. Replace the README’s “USB gadget, for SSH when WiFi is down” guarantee with: gadget setup is implemented, but RG40XXV USB-C enumeration has not been observed, so WiFi is currently the only verified remote access and a bad initial network can require reflashing. Describe sleep as implemented fake sleep; backlight behavior is verified, extra power-saving actions are partly no-ops on the current system, and total savings remain unmeasured.

**Rationale and constraints.** `MayonnaiOS.WiFi` and `config/target.exs` explicitly record the USB observation; `MayonnaiOS.LowPower` separates measured baseline facts from estimated savings. Tests prove host-side logic, not physical effect.

**Acceptance criteria.** Migration includes a claim audit against relevant config, moduledocs, and tests. Every hardware claim is phrased as implemented, verified, estimated, untested, or unsupported. No “guarantee” contradicts the hardware-status matrix.

### 20. Product terminology

**Decision.** Use **MayonnaiOS** exactly. On first mention use “the Anbernic RG40XXV handheld,” then “RG40XXV.” Call MayonnaiOS “firmware” when discussing building, flashing, or updates and “OS” only as the product name/general experience; do not imply a general-purpose distribution. Introduce **Pickles** once as “sandboxed Lua apps,” then use the name; treat lower-level names such as bundles as contributor/advanced terminology.

**Rationale and constraints.** This matches the current project title and accurately distinguishes firmware artifacts from product language.

**Acceptance criteria.** Page titles, navigation, metadata, logo alt text, and README follow this style. First-use expansions exist for Pickles and other project-specific terms.

## Visual design and media

### 21. Visual character

**Decision.** Create a fresh, restrained technical design influenced by the on-device NeXTSTEP/pixel character: neutral surfaces, crisp one-pixel rules, a limited charcoal/cream/green/red status palette, and small pixel-inspired accents—not a browser replica of the launcher. Create repository-owned SVG wordmark/logo and favicon; do not depend on assets outside this repository.

**Rationale and constraints.** This gives MayonnaiOS an identity while keeping long documentation readable and implementation within ExDoc. Use ExDoc’s supported copied `:assets` and head-tag extension points rather than replacing its templates ([ExDoc configuration](https://hexdocs.pm/ex_doc/ExDoc.html#module-configuration)). Preserve ExDoc’s required visible attribution.

**Acceptance criteria.** A small custom CSS file, SVG mark, and favicon are version-controlled and wired through ExDoc; no external font/CDN or custom JavaScript is required. The design is visibly distinct from stock ExDoc but retains ExDoc structure, search, and attribution.

### 22. Accessibility and devices

**Decision.** Require keyboard operation, visible focus, semantic heading order, WCAG AA text contrast, meaningful alt text, reduced-motion compliance, and useful layouts from 320px phones through desktops. Keep ExDoc’s automatic light/dark preference behavior and make both palettes accessible; no manual theme switch is required beyond ExDoc behavior.

**Rationale and constraints.** ExDoc already provides responsive design, enhanced accessibility, and preference-based night mode ([ExDoc features](https://hexdocs.pm/ex_doc/readme.html)); custom CSS must not regress them.

**Acceptance criteria.** Representative landing, task, matrix, and API pages are manually checked at phone/desktop widths, by keyboard, in light/dark and reduced-motion modes. Focus is never removed, color is not the sole carrier of status, and every informative image has alt text.

### 23. Launch screenshots

**Decision.** No screenshot is required for the first release. The required visual asset is the new SVG project mark; procedural instructions must stand on text and controls. Add clearly bounded screenshot slots only after authoritative captures exist.

**Rationale and constraints.** There are no image files or supplied hardware captures. Requiring imagery would make the one-PR deliverable depend on an unavailable asset or encourage misleading mockups.

**Acceptance criteria.** No page is blocked on a placeholder image, no host mockup is presented as hardware, and layout remains complete without screenshots. The implementation documents the desired future capture list: launcher, WiFi wheel, upload UI, and hardware/device view.

### 24. Screenshot production and maintenance

**Decision.** Real-hardware captures/photos are authoritative for hardware claims. Host-runtime captures may be used only for contributor UI-development instructions and must be captioned “host runtime.” Screenshot refresh is a manual responsibility in behavior-changing PRs, recorded in the contribution guidance; no automated capture pipeline is in #81.

**Rationale and constraints.** The host matches panel dimensions but cannot establish device drivers, rendering, or hardware behavior.

**Acceptance criteria.** Future images live under a single docs asset directory, have descriptive filenames/alt text and a caption naming hardware versus host. Contribution guidance requires checking affected captures when visible behavior changes.

### 25. Experimental screenshots

**Decision.** Experimental or untested features may be shown only with an adjacent text status label and a caption that states the capture environment. Never use an untested feature as an unlabeled hero image.

**Rationale and constraints.** Images communicate support more strongly than footnotes; status cannot depend only on color or a distant matrix.

**Acceptance criteria.** Every non-Verified screenshot has a same-figure textual label. Moonlight cannot be shown as running on the handheld until hardware verification changes its status.

## URLs, migration, and compatibility

### 26. Canonical public URL

**Decision.** Use the repository project Pages URL, `https://kek.github.io/mayonnaios/`. Do not add a custom domain in #81.

**Rationale and constraints.** The repository owner already controls GitHub Pages; there is no DNS/domain input. ExDoc’s `:canonical` should be set to that HTTPS base so generated pages identify their preferred URLs. GitHub Pages custom workflows accept arbitrary static generators ([GitHub Pages custom workflows](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages)).

**Acceptance criteria.** README and ExDoc metadata use exactly that base URL, repository Pages source is set to GitHub Actions, and there is no `CNAME` or DNS acceptance dependency.

### 27. Existing GitHub deep links

**Decision.** Keep every current top-level `docs/*.md` file at its repository path and use it directly as an ExDoc extra. Rewrite those files in place where needed. New split content gets new files; old pages become concise canonical overview/index pages linking to the split pages rather than pointer-only stubs.

**Rationale and constraints.** This preserves existing GitHub URLs with no redirect machinery and gives ExDoc one source. It also satisfies incorporation of existing material.

**Acceptance criteria.** All current README links to `docs/pickles.md`, `docs/bluetooth-controller.md`, `docs/data-layout.md`, and `docs/retroarch-internals.md` continue resolving on GitHub. No tracked guide is moved solely for navigation aesthetics.

### 28. Published URL scheme

**Decision.** Treat published guide URLs as a stable public interface. Use lower-case kebab-case Markdown basenames and ExDoc’s generated `<basename>.html` URLs, with unique basenames repository-wide. Existing guide basenames remain unchanged; the canonical base is the Pages project path.

**Rationale and constraints.** ExDoc extras naturally generate deterministic page names. Avoiding nested URL assumptions keeps links compatible with ExDoc’s output and the `/mayonnaios/` Pages base.

**Acceptance criteria.** Cross-links use source `.md` references where ExDoc can resolve them, not hard-coded build directories. Renaming/removing a published basename requires an explicit compatibility plan in a later PR.

### 29. Editorial migration

**Decision.** Perform a task-focused rewrite, not a verbatim move. Preserve verified facts, commands, warnings, and deliberate guarantees; split mixed sections into procedures, explanation, and internals according to the canonical-content rule.

**Rationale and constraints.** Faithful relocation would preserve the navigation problem and contradictions. The one-PR constraint requires bounded editing, so do not broaden into feature redesign or undocumented new behavior.

**Acceptance criteria.** A migration checklist maps each old heading to its destination and notes corrected claims. Commands are checked against code/config; unsupported behavior is not “cleaned up” into a promise.

### 30. External-link failures

**Decision.** CI fails on internal pages, anchors, source references, and local assets. External links do not fail CI; reviewers check newly added external links, and a scheduled checker is out of scope.

**Rationale and constraints.** External hosts can fail transiently or change independently, making every merge depend on Nerves, HexDocs, and GitHub uptime. ExDoc warnings-as-errors gives a simple Mix-native baseline for internal references (`mix docs --warnings-as-errors` is an official option: [mix docs](https://hexdocs.pm/ex_doc/Mix.Tasks.Docs.html)).

**Acceptance criteria.** Broken local guide/module references and missing local assets cause the docs check to fail. External HTTP status does not gate CI and this policy is documented.

## Publishing, review, and operations

### 31. Hosting and authoritative event

**Decision.** Host ExDoc static output on GitHub Pages, publishing automatically only after a successful push to `trunk`. PRs build but never deploy; tags do not deploy; no manual approval is required after merge.

**Why Pages, not HexDocs.** HexDocs publication is coupled to a Hex package/version: official Hex guidance says documentation is automatically published with a package, or `mix hex.publish docs` republishes docs for an **existing package version** ([Hex publishing guide](https://hex.pm/docs/publish), [mix hex.publish](https://hexdocs.pm/hex/Mix.Tasks.Hex.Publish.html)). MayonnaiOS is a firmware application with Git/path dependencies and is not a reusable Hex package; publishing a registry package merely to host its website would create false package/version semantics and Hex ownership credentials. Pages accepts any static generator, supports the canonical project URL, permits fresh ExDoc assets, and deploys directly from the authoritative `trunk` artifact.

**Acceptance criteria.** One GitHub Actions workflow builds on pull requests and `trunk`; its deploy job is guarded to `push` on `refs/heads/trunk`, depends on the successful build, and uses the `github-pages` environment. Nothing in a PR run calls a Pages deployment action.

### 32. Design review without deployment

**Decision.** CI uploads the generated `doc/` directory as a downloadable PR artifact, and the PR includes screenshots of the landing page plus one guide at desktop and phone widths. Reviewers can also run `mix docs` locally. There is no public preview environment.

**Rationale and constraints.** The artifact is the exact static output that will be passed to Pages after merge. Screenshots make visual review immediate, while the artifact allows navigation/search review.

**Acceptance criteria.** Every PR build exposes a named artifact with a finite retention period; the implementation PR description includes four representative screenshots; the documented local command reproduces it without firmware credentials or device access.

### 33. Build failure after merge

**Decision.** Build and deploy are separate, ordered jobs; deployment runs only after a successful docs build/upload. On failure, Pages keeps the previously deployed artifact. A broken `trunk` docs workflow is an urgent failing repository check but does not roll back application code or replace the live site.

**Rationale and constraints.** The official Pages workflow separates artifact creation from `deploy-pages`; `needs` prevents an independent deployment ([GitHub Pages deployment guidance](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages#deploying-github-pages-artifacts)).

**Acceptance criteria.** No deploy step can run after a failed build/check. Workflow concurrency cancels superseded in-progress docs runs without cancelling an in-progress deployment, and the previous site remains available.

### 34. Mandatory CI checks

**Decision.** Mandatory launch checks are: formatting for changed Elixir/config files, `mix docs --warnings-as-errors`, ExDoc-resolved internal guide/module/anchor links, and existence of referenced local assets. Keep tests in the repository's existing CI; do not add docs-specific spelling, prose-style, external-status, or automated alt-text linters in #81. Alt text/accessibility are review acceptance criteria.

**Rationale and constraints.** ExDoc’s official warnings-as-errors mode turns its reference warnings into a non-zero build while staying in Mix ([mix docs options](https://hexdocs.pm/ex_doc/Mix.Tasks.Docs.html)). More content tools would add disproportionate dependencies and false positives to a one-PR migration.

**Acceptance criteria.** Deliberately breaking an internal page/module link or local image makes the docs job fail. A typo or transient external 500 does not. The workflow logs the exact `mix docs --warnings-as-errors` command.

### 35. Host-only docs generation

**Decision.** Documentation generation must work with `MIX_TARGET=host` (or no `MIX_TARGET`) in a non-`dev` Mix environment, without firmware credentials, SSH keys, target toolchains, GTK/XQuartz, device access, or the sibling system repository. Add ExDoc only for the docs/development host environment with `runtime: false`.

**Rationale and constraints.** `config/target.exs` intentionally demands SSH keys and WiFi credentials, and host `dev` may start Scenic/GTK. Docs need source BEAM metadata, not a firmware or running application.

**Acceptance criteria.** A clean Linux CI runner can fetch host dependencies and run the docs command headlessly. The workflow does not set `MIX_TARGET=rg40xxv`, invoke `mix firmware`, start the application, or install Python.

### 36. Local author workflow

**Decision.** Support `mix deps.get`, `mix docs --warnings-as-errors`, then a documented static-file server/open step. `mix docs --open` is optional for a desktop. Watch/live reload is not required.

**Rationale and constraints.** ExDoc documents `mix docs` as the generator and its own contribution flow uses a simple local static server as an optional step ([ExDoc usage](https://hexdocs.pm/ex_doc/readme.html#usage)). A watcher would add tooling unrelated to authoring Markdown.

**Acceptance criteria.** A contributor guide states the exact commands, output directory (`doc/`), and how to inspect the Pages-base behavior locally. No tool beyond project-pinned Elixir/Erlang, Mix dependencies, Git, and an ordinary browser is required.

### 37. Ongoing ownership

**Decision.** Behavior-changing PRs own corresponding guide, hardware-status, status-label, and screenshot updates. Add a short documentation-maintenance checklist to the contributor guide and PR template if one exists; ownership remains with the code reviewer/maintainer rather than a new named team.

**Rationale and constraints.** The project has no documented docs team. Keeping evidence updates with behavior changes minimizes stale hardware claims.

**Acceptance criteria.** The checklist asks: user-visible behavior, commands/config, hardware matrix/status/evidence, links, and screenshots. Hardware-status rows include enough evidence/date/hash for a reviewer to know when revalidation is needed.

### 38. Analytics, feedback, and edit links

**Decision.** Ship no analytics or third-party scripts. Enable ExDoc source links and provide “Edit this page”/“Report a documentation issue” links to GitHub using the current `trunk` source paths and issue tracker.

**Rationale and constraints.** Source/feedback links improve correction of stale claims without cookies, a privacy statement, or an analytics operation. ExDoc supports source repository metadata and direct source links ([ExDoc configuration and features](https://hexdocs.pm/ex_doc/readme.html)).

**Acceptance criteria.** Every guide has a working edit-source path, site chrome links to issue #81’s repository issue tracker (not to a third party), and generated HTML makes no analytics/network request beyond user-followed links.

## Primary research summary

- ExDoc current documentation (v0.40.3 at research time): [README/features, extras, and configuration](https://hexdocs.pm/ex_doc/readme.html), [`mix docs` options including warnings-as-errors](https://hexdocs.pm/ex_doc/Mix.Tasks.Docs.html), and [configuration API](https://hexdocs.pm/ex_doc/ExDoc.html#module-configuration).
- Hex official publishing guidance: [Publishing a package](https://hex.pm/docs/publish) and [`mix hex.publish`](https://hexdocs.pm/hex/Mix.Tasks.Hex.Publish.html). These establish that HexDocs follows Hex package/version publication and that docs-only publication addresses an existing package version.
- GitHub official Pages guidance: [Using custom workflows with GitHub Pages](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages). The implementation should use `actions/configure-pages@v5`, `actions/upload-pages-artifact@v4`, and `actions/deploy-pages@v4`; the deploy job needs `pages: write` and `id-token: write`, a `github-pages` environment, and an explicit dependency on the build job.
