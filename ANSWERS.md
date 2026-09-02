# Architectural answers for #81: published documentation site

## Architectural baseline

Issue #81 will deliver the complete first public documentation site, not a scaffold. The site will use MkDocs Material, built by an isolated and fully locked Python/uv toolchain, and will be published from successful `trunk` builds to <https://kek.github.io/mayonnaios/>. Markdown remains in `docs/`; existing Markdown paths and their corresponding first public URLs remain stable. The site documents the continuously updated development state of `trunk`.

The README remains the repository landing page: project pitch, maturity, RG40XXV support, source-build quick start, critical warnings, and links. Detailed user, operational, Pickle, contributor, hardware-status, and internals material moves to task-oriented site navigation. The launch uses stock accessible Material styling, built-in offline search, and exactly two reproducible host-runtime screenshots stored with docs-only assets.

API generation, documentation versioning, localization, analytics, custom branding, custom domains, pull-request previews, and broad firmware CI are explicitly outside this issue.

## 1. Product scope and launch shape

1. **Deliver the complete first site and README migration.** A representative subset would not meet the issue outcome and would leave two manuals. The implementation must migrate every substantive README section and integrate all current `docs/*.md` pages.
2. **Launch with the full minimum set.** Required sections are Overview, Get started, User guides, Troubleshooting, Pickles, Development, Hardware status, and Internals; each must contain usable content rather than placeholders.
3. **Document `trunk`.** There is no public stable release to anchor instructions to, and the repository's default branch is `trunk`. Every page must describe the checked-out source state and avoid calling it a released product.
4. **Publish one continuously updated development set.** Label the site “Development documentation” globally. Do not add a version selector or preserve per-release copies.
5. **Keep the site curated prose.** ExDoc/API generation is out of scope; pages may name and link to source modules when that helps contributors.
6. **Publish architectural decisions contextually.** `retroarch-provisioning.md` remains reachable under Internals/decisions, but it is not a primary user-navigation item.
7. **Do not document a prebuilt-image installation path yet.** No supported public firmware release or image is evidenced. The install page must state this plainly and provide the source-build path only.
8. **RG40XXV is the only supported hardware.** The other `mix.exs` targets are dependency scaffolding, not complete device profiles or demonstrated products. They may be mentioned only as unsupported engineering scaffolding.
9. **Document user workflows and the complete Pickle HTTP API.** The ROM/core HTTP routes are implementation details behind the web UI and need only a compact operator reference; Pickle endpoints are a public author workflow and remain fully documented.
10. **No current prose is security-sensitive enough to hide.** Secrets, ROMs/BIOS, real SSIDs, addresses, keys, and private host data must never be published. Unfinished and risky behavior must be published with status and warnings rather than concealed.

## 2. Audiences and user journeys

11. **The primary audience is an RG40XXV owner building and operating the firmware.** Contributors, Pickle authors, and maintainers are secondary explicit tracks; there is not yet an image-flashing consumer track.
12. **Expose three home-page journeys:** “Build and flash,” “Add games and use the launcher,” and “Develop MayonnaiOS or a Pickle.” They must use ordinary language and require no Nerves knowledge to choose.
13. **Start user setup before flashing.** Cover card selection, source build, safe device identification, burn, first boot, network discovery, and first connection. Do not assume a reachable device.
14. **Assume command-line familiarity, not Elixir/Nerves expertise.** Define Mix targets, firmware versus host commands, SSH/IEx, required SSH keys, WiFi environment variables, and destructive disk selection at first use.
15. **Create a distinct Operations subsection under Development.** It owns firmware update/rollback, release and asset naming, bundle/core publishing boundaries, logs, access, and recovery. It must not imply procedures exist where the repositories do not evidence them.
16. **Give Pickle authors a separate start-to-finish track.** It covers manifest, capabilities, local example, package, deploy, invoke, logs, update, and delete, independent of firmware-contributor setup.
17. **Serve evaluators on the landing and Hardware status pages.** Show two screenshots, a clear development/maturity banner, supported hardware, verified capabilities, limitations, and unsupported features before asking readers to build.
18. **English-only is the launch policy.** Use semantic Markdown, ordinary theme strings, and no text baked into diagrams, but do not install translation tooling or design parallel locale paths.

## 3. Site UX and information architecture

19. **Use this top-level navigation:** Overview; Get started; User guides; Troubleshooting; Pickles; Development; Hardware status; Internals. Operations sits under Development, and existing deep dives sit under Internals.
20. **Lead with product explanation, maturity, and the two screenshots, followed immediately by task cards.** The page must answer what the project is before presenting Build and flash, Add games, and Develop paths.
21. **The canonical quick start is source build and flash for RG40XXV.** There is no release-image variant until a supported image exists; contributor setup is a separate Development quick start.
22. **Organize day-to-day guides around launcher concepts.** Games, Files, Apps, and System are stable on-device labels and should form the User guides overview, while individual page titles remain task verbs such as “Connect to WiFi.”
23. **Put cross-cutting risks in a Safety and security page and repeat concise warnings at the action.** No-auth HTTP, destructive flashing, exFAT unmounting, pulled-power save limits, and connectivity recovery must never rely on a single remote warning page.
24. **Create a central symptom-led troubleshooting index.** Each symptom links to the canonical feature section containing diagnosis and recovery; do not duplicate full remedies in the index.
25. **Use one hardware/software status matrix.** Fields are scope, implementation state, automated evidence, RG40XXV hardware evidence, external-host evidence, user-support status, known issue, and last verification reference.
26. **Create an Internals page for the three repositories.** `mayonnaios` owns product-wide setup and release orchestration docs; each sibling repository owns its own build details, linked rather than copied.
27. **Keep `docs/data-layout.md` as the one canonical layout reference.** Link it from storage user tasks and Development/Operations; do not create a second table.
28. **Keep module names out of the primary procedure.** Put IEx alternatives and implementation names in optional “Console/implementation” subsections and link to source by repository-relative branch URL.
29. **Enable Material breadcrumbs, page table of contents, and previous/next navigation.** Add visible “Edit this page” links targeting `trunk`; navigation order is explicit in `mkdocs.yml`.
30. **Do not add per-page dates or firmware metadata.** They become stale. Apply hardware/status callouts only where scope differs, and use the global development-docs label.
31. **Support current mobile and desktop browsers.** At 320 CSS pixels, navigation and warnings must remain usable and code/tables may scroll horizontally; desktop code blocks must not be artificially narrowed.
32. **Require keyboard operation, WCAG AA contrast, reduced-motion respect, descriptive alt text, visible focus, semantic headings, and text/icon status labels.** Stock Material behavior is the baseline and custom CSS may not weaken it.

## 4. README boundary and migration map

33. **The README is a repository front door.** It retains pitch, explicit development maturity, concise features, RG40XXV-only support, source-build quick start, critical warnings, `mix test`, docs link, and repository map.
34. **Keep the README quick start source-build oriented.** No release image exists. Retain both the minimal firmware build/burn commands and `mix test`; move host-runtime detail to Development.
35. **Cap the migrated README at 150 lines excluding badges.** Before any click it must show what MayonnaiOS is, its maturity, supported device, major capabilities, source-build prerequisites/commands, destructive/security warnings, and docs/contribution links.
36. **Replace the full Supported inventory with highlights.** The maintained status matrix becomes canonical; README states RG40XXV support and links to it.
37. **Retain concise high-risk caveats.** README must state unauthenticated HTTP, safe SD-device selection/unmounting, Moonlight hardware-unverified status, and that recovery access cannot be assumed; details live on-site.
38. **Migration map:** build/flashing → Get started/Build and flash; WiFi → User guides/WiFi; games/uploads/cores → User guides/Add games; second card/Files → User guides/Storage and files; Moonlight → User guides/Moonlight; Bluetooth controller/devices → User guides/Bluetooth plus existing deep dive; running-device commands → Development/Operations; host runtime → Development/Host runtime; support inventory → Hardware status; repositories → Internals/Architecture.
39. **Allow deliberate summary duplication only.** README and warning callouts may summarize canonical pages; all procedures, exhaustive lists, rationale, and troubleshooting have one canonical site location.
40. **Small command duplication is acceptable.** Do not introduce snippet templating: it makes Markdown harder to read on GitHub. Duplicated quick-start commands must be covered by the content audit.
41. **Replace “Going deeper” with a compact site index.** Keep direct links for Get started, User guides, Pickles, Development, Hardware status, and Internals rather than one opaque homepage link.
42. **Use public-site links for site sections and retain source-relative links only for repository artifacts.** Existing `docs/*.md` files remain readable on forks; their README deep links can become public URLs after the initial deployment is live.
43. **Change source comments/moduledocs to say “user guide” or name a stable source file, not “the README.”** Avoid embedding deployment URLs in firmware source.

## 5. Existing content and source-of-truth boundaries

44. **Keep all published Markdown under `docs/`.** Engineering artifacts under `docs/retroarch-reference/` also stay there but are excluded from page discovery/navigation.
45. **Preserve all four current file paths and map them to stable matching URLs:** `/bluetooth-controller/`, `/data-layout/`, `/pickles/`, and `/retroarch-internals/`. Navigation placement must not force URL-directory moves.
46. **Revise `retroarch-provisioning.md` before publication.** Mark it as a historical design decision, separate decided architecture from obsolete pre-build wording, and identify current implementation evidence.
47. **Exclude `docs/retroarch-reference/` from generated navigation and search.** Link to the repository directory from the provisioning decision as non-authoritative historical source artifacts.
48. **Consolidate duplication in this issue.** Current dedicated docs win for internals; current code/config wins for behavior; README material fills user workflows and is then reduced to summaries.
49. **Treat config and source as authoritative for exact values.** Docs cite the owning file beside volatile bundle/core versions, systems/extensions, paths, controls, limits, and profile facts; reviewers compare those sources when either side changes.
50. **Do not generate tables from Elixir config.** That would violate toolchain isolation. Add narrow docs consistency checks only for values whose drift is dangerous; manual maintenance plus review owns the rest.
51. **Extract user-impacting behavior from moduledocs into curated pages.** Sleep, LowPower, Files, LED, recovery, and Bluetooth caveats belong in user/troubleshooting pages; source remains the deep implementation reference and no API site is generated.
52. **Define ownership by evidence type, not named individuals.** User procedures require code/config review, hardware claims require a linked hardware observation, and internals require the owning module/config review; encode this in the docs contribution checklist.
53. **Present dated observations as evidence records.** Say “Observed on RG40XXV on YYYY-MM-DD; cause remains a known issue,” never as a timeless frequency or guarantee. Link the relevant issue/commit where available.

## 6. Generator and repository integration

54. **Choose for existing Markdown, subpath-safe static output, offline search, accessible theme, strict links, and low operational burden.** Versioning, runtime diagrams, and redirects are not selection drivers for launch.
55. **Use the separate Python toolchain.** MkDocs Material is a better task-documentation fit than coupling site generation to Mix/Nerves evaluation.
56. **Do not use ExDoc.** Its API-first structure and Mix evaluation conflict with task navigation and docs isolation.
57. **Preserve CommonMark-style source.** Tables, fences, relative `.md` links, and predictable heading anchors must build without rewriting existing pages solely for the generator.
58. **The docs build must never invoke Mix.** It must not fetch Elixir dependencies, evaluate target config, inspect SSH keys, require WiFi variables, or cross-compile.
59. **Use a root `pyproject.toml` plus `uv.lock` dedicated to docs.** No docs dependency enters `mix.exs`; uv's environment stays ignored and disposable.
60. **Pin Python 3.13.7 in `.python-version`, MkDocs 1.6.1 and Material 9.6.20 exactly in `pyproject.toml`, and every transitive dependency in `uv.lock`.** Pin uv 0.8.17 for local/CI use, pin its CI action to a full commit SHA, and always sync with `uv sync --frozen`; version changes are explicit reviewed lock updates.
61. **Ignore generated HTML and deploy a Pages artifact.** Never commit `site/` or maintain `gh-pages`.
62. **Use stock MkDocs Material with only configuration and minimal safety/layout CSS.** No custom logo, fonts, palette design, or MayonnaiOS branding work is in scope.

## 7. Public URLs, hosting, and lifecycle

63. **Host at <https://kek.github.io/mayonnaios/>.** No custom domain is introduced.
64. **The repository is public.** The maintainer must enable GitHub Pages “GitHub Actions” as the source and grant Pages deployment permissions; implementation must document this manual prerequisite.
65. **No custom domain is planned in this issue.** Do not add CNAME, DNS instructions, host-independent canonicals, or renewal ownership.
66. **Build and test for the `/mayonnaios/` base path.** Set `site_url` to the full Pages URL and forbid root-absolute internal links.
67. **Stable new URL families are** `/getting-started/`, `/user-guide/`, `/troubleshooting/`, `/development/`, `/hardware-status/`, and `/internals/`; Pickles retains `/pickles/`. Existing pages retain the URLs in answer 45.
68. **Follow `trunk` only.** The global header says Development documentation; there is no “latest” alias or tag publishing.
69. **Do not create PR previews.** Pull requests receive a built artifact/check log, not a hosted site.
70. **Keep the site fully static and locally buildable.** Content and navigation work without Pages APIs; source-relative Markdown links should remain useful on GitHub and forks.
71. **Enable MkDocs' sitemap and basic title/description metadata.** Use no analytics, custom favicon, robots customization, social-card generator, or custom canonical machinery beyond `site_url`.

## 8. Navigation, discovery, and search

72. **Limit navigation to three levels including top-level.** Split long pages by task, not deeper hierarchy.
73. **Keep Build and flash, Add games, WiFi, Controls, Troubleshooting, and Development setup one click from the landing page.** They may be second-level in the persistent nav.
74. **Built-in client-side full-text search is required at launch.** Navigation alone is insufficient for symptom and module discovery.
75. **Search must work offline with no service, account, or API key.** The index ships in the Pages artifact.
76. **Index all published pages, including internals and decisions.** Improve user result titles and headings rather than maintaining a fragile split index; excluded reference artifacts are not indexed.
77. **Do not add tags or filters.** Status badges/callouts and the hardware matrix cover scope without plugin complexity.
78. **Use consistent callouts:** `Action`, `Warning`, `Console alternative`, and `Implementation note`. Warning language states consequence before rationale.
79. **Use Material's copy button and write command blocks without prompts where direct copying is safe.** Keep prompts only when they distinguish host shell (`$`) from device IEx (`iex>`), and then place commands in separate blocks if copying matters.
80. **Use plain module/file names plus links to `blob/trunk`.** Avoid commit permalinks for living development docs; relative repository links remain meaningful in forks where possible.

## 9. Status labels and product truth

81. **Use this controlled vocabulary:** Supported, Experimental, Host-tested, Hardware-verified, Known issue, and Unsupported. “Implemented” and “Included in image” are separate factual matrix fields, not synonyms for supported.
82. **Evidence rules:** Host-tested requires an automated test on the host; Hardware-verified requires a dated manual RG40XXV observation; Supported requires hardware verification plus an intended user workflow; external-host claims name each manually verified OS/device; release evidence remains absent until releases exist.
83. **Apply status to individual claims when evidence differs.** Moonlight settings UI is Host-tested; on-device Moonlight streaming is Experimental/Not hardware-verified. A broad feature label may only summarize its least-proven essential claim.
84. **A maintainer changes status through review.** Every Hardware-verified or external-platform change must cite a date and issue, PR, commit, or test log in the status matrix; automated evidence cites its test path.
85. **Put destructive-risk warnings immediately before commands and experimental banners at page tops.** The hardware matrix repeats status; navigation badges are unnecessary and noisy.
86. **State unsupported capabilities as present-tense boundaries.** Bluetooth audio, outbound pairing, right stick, rumble, and other inert controls receive no ETA and no roadmap promise.
87. **USB truth is narrower than the README claim.** Device-side gadget creation, UDC binding, and `usb0` presence were hardware-verified, but the repository also records that host enumeration/reliable access was not observed. Document WiFi as primary, USB Ethernet/SSH as Experimental recovery that must not be relied on, UART as inaccessible, and card reflash as the dependable recovery.
88. **The matrix must distinguish all four:** code implemented, included by target configuration/image, observed on RG40XXV, and supported for users. No single “supported” checkbox may collapse them.

## 10. Screenshots, diagrams, and assets

89. **Require exactly two launch screenshots:** the host runtime's 640×480 launcher/columns and its Files view. These demonstrate the product and core navigation without fabricating target hardware state.
90. **Use the host Scenic runtime as the canonical source.** Both captures must render at 640×480 from deterministic checked-in sample state.
91. **Do not capture target-only state at launch.** Describe WiFi, battery, Bluetooth, diagnostics, and Moonlight states in prose/status tables until a documented hardware capture exists; never substitute a simulated screenshot without labeling it.
92. **The implementation author produces the deterministic host captures and the maintainer approves them against current UI.** No physical hardware capture is required for acceptance.
93. **Captured state must contain only fixtures.** No real SSID, IP/hostname, Bluetooth address, bond, token, ROM title, user path, or credential may appear.
94. **Store lossless PNG at native 640×480, lowercase kebab-case names, and descriptive alt text in the referencing Markdown.** Keep each file below 300 KB; no light/dark variants.
95. **Store assets under `docs/assets/`.** Never reuse root `assets/`, which is compiled into Scenic and contains separately licensed fonts.
96. **Do not reuse firmware fonts or visual assets.** The site uses Material/system assets, so no new font attribution surface is needed.
97. **No diagram is required for launch.** The data-layout and repository-boundary tables are sufficient; add a diagram later only when prose demonstrably fails.
98. **Future diagrams must have checked-in editable source and checked-in SVG output.** CI must not require a diagram renderer merely to build prose.
99. **Keep screenshots limited to the two stable navigation concepts.** A docs PR changing visible launcher labels or layout must update/confirm both images in the review checklist.

## 11. Link and anchor compatibility

100. **Treat repository file paths and direct links to current `docs/*.md` as contracts.** Also preserve references from `.claude/skills/pickle/SKILL.md`, source moduledocs, and issues; README heading fragments are best-effort, not all permanent contracts.
101. **Retain compact README headings for Supported/Status, Building and flashing, and Development/Contributing.** Other old fragments cannot redirect and need not survive after their detailed content moves.
102. **Do not move existing Markdown files.** Render them in place; no stubs and no reliance on Git history.
103. **Do not depend on redirects.** Existing public URLs are established directly by retained filenames; any future rename requires a checked redirect mechanism and CI test before merge.
104. **Author internal content links as source-relative `.md` paths and asset links as relative paths.** This keeps GitHub/forks useful and lets MkDocs resolve them under the Pages subpath.
105. **Living docs link to `blob/trunk` source when crossing out of docs.** There are no docs versions, so commit pinning would misrepresent a continuously updated site.
106. **CI must validate file links, generated URLs, fragments, and asset existence/case.** A generator success alone is insufficient.
107. **External failures do not block ordinary PRs.** Run a scheduled non-blocking external-link check with retries and an explicit allowlist; internal links always block.
108. **Bootstrap in two trunk-safe stages.** First deploy the framework and current docs while README keeps repository links; after the Pages URL returns successfully, migrate README and switch site links. This prevents dead public links.

## 12. Local authoring and contributor workflow

109. **The preview command is `uv run --frozen mkdocs serve`.** It creates/synchronizes the locked environment and serves with reload; the documented production check is `uv run --frozen mkdocs build --strict` followed by the link checker.
110. **Authoring requires only uv and network access for the initial locked dependency download.** After the uv cache is populated it requires no Elixir, Nerves, target, credentials, keys, Docker, hardware, or network.
111. **Support macOS, Linux, and Windows via WSL.** Native Windows is not a launch requirement; Scenic/XQuartz requirements are irrelevant to ordinary docs editing except screenshot regeneration.
112. **Preview with the production `site_url`, and run link checks against generated `site/`.** Local serving may use localhost, but no content may assume root hosting.
113. **Adopt a small enforceable style:** ATX headings, one H1, unique descriptive headings, fenced blocks with language, `WiFi` as the product UI term, `Wi-Fi` only in external proper names, descriptive links/alt text, and no hard line-length gate.
114. **Do not execute documentation commands in docs CI.** Mark blocks as Host shell, Device IEx, or destructive Device/host action; only purpose-built consistency tests may validate inert examples.
115. **The contributor page must cover adding/navving a page, assets, status evidence, warnings, local strict build/link checks, screenshot updates, and reporting missing captures.**
116. **Add a docs section to the normal PR checklist, not a new issue template.** It asks audience, canonical source, links, status/evidence, secrets, assets, and hardware verification.
117. **Use conspicuous placeholders such as `your-ssid`, `<device-hostname>`, and `/dev/diskN`; never example real credentials.** Screenshot fixture data is checked in and synthetic.
118. **Do not add spelling CI at launch.** Maintain a terminology list in the contributor guide; a spell checker and dictionary are deferred until false-positive policy is justified.

## 13. CI, deployment, and security

119. **Run docs checks on every pull request, every push to `trunk`, and manual dispatch.** Do not path-filter: README, config, source comments, or deleted files can invalidate docs.
120. **Create a separate lightweight docs workflow.** It runs only uv/MkDocs/link tooling and never invokes Mix or target configuration.
121. **Block on frozen dependency sync, strict generator build, explicit nav completeness, and internal URL/fragment/asset checks.** Do not add Markdown lint, spelling, accessibility automation, full HTML validation, or asset-size policy beyond the narrow checked limit in this issue.
122. **Leave `mix test` separate and unchanged.** General project CI is outside #81.
123. **Only a successful protected `trunk` build deploys production.** Pull requests and non-trunk branches have read-only checks.
124. **Use GitHub's official Pages artifact/deploy actions with least privilege.** The build job has `contents: read`; only the deploy job has `pages: write` and `id-token: write`. Do not push with a token.
125. **Use a `pages` concurrency group with queued latest deployment and no stale overwrite.** Cancel superseded in-progress build jobs before deployment; the deploy job must consume the artifact from its own commit.
126. **Surface failure in the required GitHub check and Actions summary.** The previously published Pages artifact remains live; manual rerun/revert is the recovery, and automated rollback is not required.
127. **PR previews are disabled.** Fork content receives no write credentials and only runs the pinned static toolchain.
128. **Pin third-party actions to full commit SHAs.** Dependabot/Renovate may propose reviewed lock/action updates monthly; uv lock changes must be committed and strict builds must pass.
129. **Fail on files above the documented asset limit and scan the published tree for known secret/private-key patterns.** Do not reject documentation examples such as private RFC1918 ranges; review owns contextual privacy.
130. **After deployment, request the homepage and the six critical paths: getting started, add games, WiFi, troubleshooting, development, and Pickles.** A failed smoke test reports failure but leaves the prior deployment strategy unchanged; no automatic restore is needed because deployment is atomic.
131. **Document administrator setup:** Pages source set to GitHub Actions, Actions enabled, required docs check on protected `trunk`, and the `github-pages` environment configured. Repository code cannot enforce these settings.

## 14. Edge cases and content safety

132. **All pages and navigation remain usable without JavaScript.** Only search and copy buttons may degrade; no content is loaded dynamically.
133. **Require unique headings per page and ASCII slugs where practical.** Unicode remains valid in prose; punctuation-heavy names belong in code spans, and mobile code/table containers scroll.
134. **Label every command context.** SSH opens Device IEx; never show an on-device POSIX shell command after `ssh nerves.local`. External bundle binaries invoked from IEx require `System.cmd` or a clearly documented alternate access path.
135. **Explain mDNS ambiguity in connectivity troubleshooting.** `nerves.local` is convenience for one device; with multiple devices use the device-specific `nerves-<serial>.local` name or its displayed IP.
136. **Provide ordered fallbacks:** device-specific mDNS, displayed/DHCP IP, Experimental USB Ethernet if available, return to a known configured WiFi network, then reflash. Wrong build-time WiFi credentials have no guaranteed remote repair.
137. **Put a destructive warning and device-enumeration verification immediately before `mix burn`.** Put the unmount command and confirmation before physical exFAT removal; never imply power-off alone journals exFAT.
138. **Add a legal/safety note:** users supply lawfully obtained ROMs/BIOS; MayonnaiOS is unaffiliated with Anbernic, Microsoft, RetroArch, and Moonlight; third-party marks identify compatibility. Explain the Xbox identity technically without using its branding as project branding.
139. **State the unauthenticated, unencrypted LAN model globally and repeat it at upload, delete, core install, and Pickle deployment.** Consequence: any device on the reachable network can perform those actions.
140. **Use the content audit plus targeted consistency checks for controls, paths, systems/extensions, and limits.** Bundle/package versions should normally be described generically, not copied into prose.
141. **Navigation-only changes run the full docs check.** Deleting a page is prohibited while `trunk` README/docs/source links reference it; released tags remain immutable and are not retroactively repaired.
142. **CI runs on GitHub's case-sensitive Linux filesystem and validates every generated asset URL.** Missing/case-mismatched assets fail before deployment.
143. **Every page gets “Edit this page”; add a “Report a documentation issue” link that pre-fills the source page and public URL.** It targets repository issues and requires no custom service.

## 15. Acceptance criteria

144. **Acceptance URL is <https://kek.github.io/mayonnaios/> returning HTTP 200.** The repository owner verifies and records the external Pages setting and smoke-test result.
145. **Required launch pages:** landing, Build and flash, First boot/connectivity, Controls, Add games/cores, WiFi, Storage/Files/second card, Moonlight, Bluetooth, Updates/operations, Troubleshooting index, Pickles guide/API, Host development, Contributing/docs authoring, Hardware status, Repository architecture, Data layout, RetroArch internals, Bluetooth internals, and provisioning decision. Corresponding detailed prose must be removed from README.
146. **README must be at most 150 lines and satisfy answer 33.** This is the measurable migration boundary.
147. **Every current top-level `docs/*.md` page must be published and reachable.** All except the historical provisioning decision appear in navigation; that decision is contextually linked and searchable.
148. **Summary duplication is allowed only as identified in answers 39–40.** No detailed procedure or exhaustive reference may have two maintained copies.
149. **All intended links from current repository Markdown, docs navigation, retained source references, and legacy `docs/*.md` paths must pass automated internal checks.** External availability is not a merge gate.
150. **Both 640×480 host-runtime PNGs are required; placeholders are not acceptable.** No launch diagram or physical-device capture is required.
151. **Search is required and must return relevant pages for:** add games, WiFi, Bluetooth, cores, Moonlight, and Pickles.
152. **A clean-checkout reviewer runs:** `uv run --frozen mkdocs serve` for preview, and `uv run --frozen mkdocs build --strict` plus the documented internal-link command for the production artifact. No Mix setup is permitted for these checks.
153. **Required green checks are locked dependency setup, strict MkDocs build with zero warnings, nav completeness, internal links/fragments/assets, asset-size/secret guard, and Pages deployment smoke test on `trunk`.** Warning budget is zero for build/internal-link checks.
154. **A successful merge to `trunk` deploys automatically.** A failed check/build does not run deployment and leaves the currently published site untouched.
155. **Both deployment/recovery and page-authoring workflows must be documented before closure.** Rollback is revert-or-rerun of a known-good `trunk` commit, not artifact mutation.
156. **Sign-off roles:** repository owner for user and hardware truth; a contributor familiar with host runtime for developer accuracy; automated checks plus keyboard/mobile manual review for accessibility/layout; repository owner for production deployment. One person may fill multiple roles, but each sign-off is recorded separately.
157. **Require a completed migration audit table.** Every substantive removed README section names one canonical destination, and every destination is linked from README or site navigation/context.
158. **Record these non-goals:** generated API docs, localization, release/versioned docs, custom domain/branding/theme, analytics, PR previews, broad firmware CI, executable prose tests, spell-checking, physical-device screenshots, and prebuilt-image installation instructions.
