# Design questions for #81: published documentation site

## Context to confirm

The repository currently has no `.github/workflows` directory or documentation-site tooling. `README.md` is roughly 440 lines and combines the project pitch, hardware/software status, firmware build and flashing instructions, player workflows, operational caveats, IEx commands, and host-development setup. The existing `docs/` directory contains a mix of user/developer references (`pickles.md`), internals and troubleshooting (`bluetooth-controller.md`, `retroarch-internals.md`, `data-layout.md`), and an architectural decision/reference artifact (`retroarch-provisioning.md` plus `retroarch-reference/`). Code moduledocs and comments are also important sources of detailed behavior.

The questions below are intended to resolve product and delivery decisions before implementation.

## 1. Product scope and launch shape

1. Is this issue expected to deliver the complete first public site and README migration, or only establish the generator/deployment framework and migrate a representative subset?
2. What is the minimum useful launch content: a landing page, install/quick-start guide, player manual, troubleshooting, developer setup, internals, and hardware status, or a smaller set?
3. Should the site document only behavior available on `trunk`, or the latest published firmware release? There currently appears to be no stable public release to anchor versioned instructions to.
4. Do we want one continuously updated documentation set, release-versioned docs, or an explicit “development version” now with versioning deferred?
5. Is API/reference documentation generated from Elixir moduledocs in scope, or should the site remain curated prose that links readers to source where appropriate?
6. Should architectural decisions such as RetroArch provisioning be first-class published content, or remain repository records linked only from developer pages?
7. Is documenting installation of a prebuilt firmware image in scope? The current README explains building and flashing from source, but not a non-developer download/install path.
8. Should the site cover only the RG40XXV, which the README identifies as the product today, or expose the other Mix targets listed in `mix.exs`? Are those targets supported, inherited Nerves scaffolding, or development-only?
9. Should documentation include the web API (ROM/core/Pickle endpoints), or only user-facing workflows and the Pickle API already described in prose?
10. Is there any content that must stay repository-only for security, support burden, hardware-risk, licensing, or unfinished-design reasons?

## 2. Audiences and user journeys

11. Who is the primary launch audience: a player flashing an existing image, an owner building firmware from source, a contributor developing on a laptop, a Pickle author, or a maintainer debugging hardware?
12. Which two or three journeys must be reachable from the home page without understanding Nerves or Elixir?
13. Should “user” instructions assume a device is already flashed and reachable, or begin with choosing an SD card, downloading/building, burning, first boot, and discovering the hostname?
14. How much baseline knowledge may setup pages assume about Elixir/Mix, Nerves, SSH keys, SD-card devices, WiFi security, and IEx?
15. Do maintainers need a distinct operations area for release creation, firmware deployment/rollback, bundle/core publishing, and device recovery?
16. Should Pickle authors be treated as app developers with their own start-to-finish track, separate from firmware contributors?
17. Do we need content for people evaluating the project before owning supported hardware, including screenshots, current limitations, and a clear maturity statement?
18. Is English-only acceptable for the initial site? If so, should the information architecture and theme avoid choices that make localization difficult later?

## 3. Site UX and information architecture

19. What top-level organization best matches the audiences: for example **Overview**, **Get started**, **Use MayonnaiOS**, **Troubleshoot**, **Build and contribute**, **Pickles**, and **Internals**?
20. Should the landing page lead with a product explanation and screenshots, or immediately offer task-oriented paths such as “Install,” “Add games,” and “Develop”?
21. What should be the canonical quick start, and should it differ between players using a release image and contributors building from source?
22. Should user tasks be organized around launcher labels—Games, Files, Apps, and System—so docs mirror the on-device mental model?
23. Where should cross-cutting operational warnings live, such as no authentication on the device web UI, safely unmounting exFAT media, pulled-power save behavior, and WiFi being the primary route into a device?
24. Should troubleshooting be a central symptom-led section (“no cores,” “controller connects but no input,” “hci0 missing,” “cannot reach nerves.local”), or remain embedded in feature guides with a troubleshooting index?
25. Should hardware support be one status matrix, separate tested/experimental pages, or retain prose? What fields matter: supported, hardware-verified, host-tested only, incomplete, known issue, and unsupported?
26. Should the repository relationships (`mayonnaios`, `nerves_system_rg40xxv`, and `mayonnaios_bundles`) have a dedicated architecture page, and which repository owns cross-project setup and release instructions?
27. Where should the canonical on-device data layout live: an operator/reference section, contributor internals, or both through one canonical page and contextual links?
28. Should code/module names such as `MayonnaiOS.WiFi`, `MayonnaiOS.Files`, and `MayonnaiOS.LowPower` be visible in user guides, moved to “implementation notes,” or linked as optional deeper reading?
29. Do pages need “previous/next,” breadcrumbs, an automatically generated table of contents, and visible “Edit this page” links?
30. Should every page display its applicable hardware, firmware version/status, and last reviewed date, or would that metadata become stale too easily?
31. What mobile and desktop layouts must be supported? The likely user may read from a phone while operating the handheld, while developers need usable code blocks and tables on desktop.
32. Are there accessibility requirements beyond reasonable defaults—keyboard navigation, contrast, reduced motion, descriptive alt text, and avoiding status communicated by color alone?

## 4. README boundary and migration map

33. What exact job should the final README perform: repository pitch, current maturity/status, concise feature highlights, one supported-device statement, minimal quick start, contributor commands, and links to the site?
34. Should the README quick start remain source-build oriented, or point users to a release-image install guide and keep only `mix test`/developer bootstrapping locally?
35. How long is “concise” in practical terms, and which information must remain visible on GitHub before a reader clicks away?
36. Should the full “Supported” inventory remain in README as a project capability snapshot, become a shorter highlights list, or move entirely to a maintained hardware/software status page?
37. Should README retain high-risk caveats—no web authentication, unmount before removing exFAT media, Moonlight unverified—or only summarize and link to prominent site warnings?
38. Which README sections map to which destination pages? In particular, should WiFi, games/uploads, second card, Files, cores, Moonlight, Bluetooth controller/devices, running-device operations, and host development each become standalone task pages?
39. Is content allowed to be repeated in a deliberately short form in README and expanded on-site, or must every detailed statement have exactly one source to prevent drift?
40. For commands retained in README, should the site include them from shared snippets/source files, or is small intentional duplication acceptable?
41. Should the “Going deeper” table be replaced by one docs-site link, retained as a compact deep-link index, or redirected to the equivalent site pages?
42. Should the README continue linking directly to repository `docs/*.md` so it works offline/on forks, or always use the public site once launched?
43. Should source comments/moduledocs that currently say “the README” be updated to name canonical site pages, or should they refer generically to “the user guide” to avoid URL churn?

## 5. Existing `docs/` content and source-of-truth boundaries

44. Will Markdown sources remain under `docs/`, move under a generator-specific directory, or be split between published prose and non-published engineering artifacts?
45. Should `docs/bluetooth-controller.md`, `docs/data-layout.md`, `docs/pickles.md`, and `docs/retroarch-internals.md` preserve their current file paths in the repository even if their public URLs differ?
46. Is `docs/retroarch-provisioning.md` current enough to publish despite historical language such as “nothing here has ever been built,” or should it be revised/marked as a dated decision record?
47. Should `docs/retroarch-reference/` be included in navigation, linked as source artifacts from the provisioning decision, or explicitly excluded from the generated site?
48. Should prose now duplicated between README and existing docs be consolidated during this issue, and which copy wins when wording or scope differs?
49. How should code-level facts be kept synchronized with docs—for example configured bundle/core versions, supported systems/extensions, paths, button mappings, upload limits, and the device profile?
50. Should generated tables pull from Elixir configuration, should CI merely test documented values, or is manual maintenance acceptable?
51. Where should details that intentionally live in moduledocs (`Sleep`, `LowPower`, `Files`, `Led`, Bluetooth stack) be surfaced? Should this issue extract selected operational material, link to generated API docs, or leave code as the deep reference?
52. Do we need explicit content ownership/review rules per section so user behavior, hardware observations, and internals do not silently age?
53. How should date-specific observations (for example an intermittent Bluetooth failure observed on a specific date) be presented so they do not look like timeless product guarantees?

## 6. Generator and repository integration

54. What constraints should drive the generator choice: Markdown compatibility, low dependency weight, built-in search, versioning, redirects, theme accessibility, diagram support, and GitHub Pages deployment?
55. Is an Elixir-native approach preferred because this is a Mix project, or is a separate docs toolchain (for example a Node/Python/Rust static-site generator) acceptable?
56. If ExDoc is considered, can it provide the desired task-oriented navigation, landing pages, search, assets, and stable page URLs without making the site look primarily like API docs?
57. Must the chosen generator consume the existing CommonMark-style Markdown unchanged, including tables, fenced code, relative links, and heading anchors?
58. Should docs tooling be isolated from firmware dependencies so a docs build never evaluates target config, asks for WiFi credentials/SSH keys, fetches Nerves systems, or triggers cross-compilation?
59. Should docs dependencies live in `mix.exs` (perhaps docs-only), a separate manifest, a container/devcontainer, or a pinned standalone binary?
60. What versions must be pinned, and where, so local output and CI output remain reproducible?
61. Should generated HTML be ignored and deployed as an artifact, or committed to a publishing branch such as `gh-pages`?
62. Are custom theme work and a MayonnaiOS visual identity part of launch scope, or should the first version use a lightly configured stock theme?

## 7. Public URLs, hosting, and lifecycle

63. Where should the site live: GitHub Pages under `https://kek.github.io/mayonnaios/`, a custom domain, or another host?
64. If GitHub Pages is chosen, is the repository public and are Pages settings/permissions available to GitHub Actions?
65. Is a custom domain planned now or later, and who owns DNS, HTTPS, and renewal? Should canonical URLs be independent of GitHub from day one?
66. Must the generated site work correctly under a repository subpath rather than assuming it is hosted at `/`?
67. What URL scheme should be stable—for example `/getting-started/`, `/user-guide/wifi/`, `/development/host/`, `/internals/retroarch/`—and which names are acceptable as long-term public contracts?
68. Should docs follow `trunk`, release tags, or both? If both, which URL is “latest,” and how are readers warned when viewing development or old docs?
69. Should preview deployments be available for pull requests? If yes, can they be public, and how are preview URLs cleaned up?
70. Is site availability on forks/offline important enough to require relative links and a fully local static build, rather than depending on host-specific features?
71. Do we need a sitemap, robots policy, social metadata, favicon, canonical tags, or analytics at launch? If analytics are desired, what privacy constraints apply?

## 8. Navigation, discovery, and search

72. How many navigation levels are acceptable before the site becomes as hard to scan as the README?
73. Which pages must always be top-level or one click from the landing page: install, add games, WiFi, controls, troubleshooting, and development setup?
74. Is client-side full-text search required at launch, or is a clear navigation tree and browser/GitHub search sufficient initially?
75. If search is required, must it work offline and without a third-party hosted service or API key?
76. Should search index code/reference material and historical decisions, or prioritize user guides to avoid developer internals overwhelming common tasks?
77. Do we need tags or filters for audience, hardware support, experimental status, and troubleshooting symptoms?
78. How should cross-links distinguish user action, operational warning, API/IEx alternative, and implementation detail?
79. Should commands be copyable with a button, and should shell prompts (`$`, `iex>`) be excluded from copied text?
80. Should pages expose source-file/module references with GitHub permalinks, branch links, or plain names that remain useful in forks?

## 9. Status labels and product truth

81. What controlled vocabulary should replace ad hoc statements such as “supported,” “not run on the handheld yet,” “not done yet,” and “cause is still open”?
82. What evidence is required for each status: automated host test, manual hardware test, verified on macOS/Windows/SteamOS, or shipped in a release?
83. Should labels apply to whole features or individual claims—for example Moonlight configuration UI may be host-tested while streaming remains hardware-unverified?
84. Who can change a status, and should every status change require a linked issue/test log/date?
85. How prominently must experimental or destructive-risk warnings appear—in navigation badges, page banners, feature tables, and individual procedures?
86. How should unsupported capabilities be documented without implying roadmap commitment, especially Bluetooth audio/outbound pairing and inert Xbox-controller controls?
87. The README says the USB gadget supports SSH when WiFi is down, while target comments describe USB-C as unreliable/not observed. What is the current verified truth, and how should fallback/recovery guidance express it?
88. Should the hardware status page distinguish “implemented in code,” “included in image,” “observed on device,” and “supported for users”?

## 10. Screenshots, diagrams, and other assets

89. Which initial screenshots are required to make onboarding useful: launcher home/columns, WiFi/passphrase wheel, upload UI on phone, Files actions, diagnostics, Bluetooth stages, Moonlight settings, and host development window?
90. Must screenshots come from the physical RG40XXV, or may the 640×480 host Scenic runtime be the canonical capture source for reproducibility?
91. How will target-only screens and states be captured reproducibly when the host runtime has no real radio, battery, or devices?
92. Who supplies captures and approves that they match current firmware? Is there available hardware for the implementation/review phase?
93. What data must be redacted: SSIDs, IP/host names, Bluetooth addresses, bond data, API credentials, ROM names, and local file paths?
94. Should the project define image dimensions, formats (WebP/PNG/SVG), compression limits, light/dark variants, naming, and alt-text conventions?
95. Should documentation assets live under a new docs-specific directory rather than the existing `assets/`, which is currently compiled by Scenic and contains licensed fonts?
96. Are any existing font licenses/visual assets appropriate for site reuse, and do attribution notices need to be surfaced?
97. Which concepts warrant diagrams rather than prose: A/B firmware updates, bundle/core installation, data layout across two cards, RetroArch config layering, Bluetooth protocol stages, and repository boundaries?
98. Must diagrams be stored as editable source and rendered in CI, or should checked-in SVG/PNG be canonical?
99. How do we prevent screenshots from becoming stale when launcher labels or controls change—review checklist, visual tests, dated captions, or limiting screenshots to stable concepts?

## 11. Link and anchor compatibility

100. Which existing links are considered compatibility contracts: GitHub links to `README.md` headings, direct `docs/*.md` links, links from `.claude/skills/pickle/SKILL.md`, source moduledocs, external bookmarks, and issue/PR references?
101. Must old README heading anchors remain available? GitHub cannot redirect an old `README.md#...` fragment to the site, so should compact compatibility headings remain for commonly linked sections?
102. If existing Markdown files move, should thin stub files remain at old paths, should Git history be relied upon, or should the files remain in place and be rendered directly?
103. Can the hosting platform provide permanent redirects for renamed public pages, and how will redirect behavior be tested?
104. Should internal links be authored as source-relative `.md` links that work on GitHub and are rewritten by the generator, or as site-root URLs that are stable only after publication?
105. How should links from published docs to exact source code behave across `trunk`, versions, and forks?
106. Do we need CI to validate fragments/anchors as well as files and HTTP status codes?
107. Should external-link failures block merges, given rate limits and transient outages, or run as a scheduled/non-blocking check with an allowlist?
108. What URL should README use before the first successful deployment, so merging migration changes never creates a period of dead links?

## 12. Local authoring and contributor workflow

109. What is the single documented local command to install docs dependencies, build the site, and start a live-reload preview?
110. Must local docs authoring work without Elixir/Nerves dependencies, target hardware, WiFi environment variables, SSH keys, Docker, or network access after initial dependency installation?
111. Which operating systems must the workflow support (macOS, Linux, Windows/WSL), given the current developer setup has macOS-specific XQuartz requirements for Scenic?
112. Should contributors be able to preview the exact production base path and broken-link behavior locally?
113. What linting/style policy should apply to Markdown, headings, line length, terminology (“WiFi” versus “Wi-Fi”), command syntax, and alt text?
114. Should code examples be executable/testable snippets? Which are safe to run on host, and which must be marked device-only or destructive?
115. Should the contributor guide explain how to add a page, place it in navigation, add assets, mark feature status, test links, and request screenshots?
116. Do we want a docs-specific contribution template or pull-request checklist requiring audience, source-of-truth, screenshots, and hardware verification?
117. How should secrets be kept out of screenshots and examples, especially build-time WiFi credentials and SSH configuration?
118. Should local authoring include spelling checks and a project dictionary for terms such as MayonnaiOS, Nerves, RetroArch, libretro, Luerl, Panfrost, and fwup?

## 13. CI, deployment, and security

119. Which events should build docs: every pull request, every push to `trunk`, changes only under relevant paths, tags/releases, and manual dispatch?
120. Should docs checks be a separate lightweight workflow from firmware tests so they cannot trigger target config or expensive Nerves/system builds?
121. What checks block merging: generator build with warnings as errors, internal links/fragments, navigation completeness, Markdown lint, spelling, asset size, accessibility, and HTML validation?
122. Should `mix test` remain a separate required check, or is issue #81 expected to introduce general project CI because none currently exists?
123. What is the authoritative deployment branch/event? Should only a successful build of protected `trunk` update production?
124. Should deployment use GitHub’s Pages artifact action with least-privilege `pages`/OIDC permissions, or push generated files to `gh-pages` with a token?
125. How are concurrent deployments serialized/cancelled so an older run cannot overwrite a newer site?
126. How are failed deployments surfaced, and who is responsible for recovery? Is rollback to a previous artifact required?
127. If PR previews are enabled, how do we prevent untrusted fork content from receiving write credentials or executing unsafe custom plugins?
128. Are third-party actions required to be pinned to immutable commit SHAs? What dependency update policy applies to the generator, theme, and actions?
129. Should the build enforce that no secrets, private addresses, or unexpectedly large/binary files enter the published artifact?
130. Should production deployment include a smoke test of key public URLs after publish, and can failure automatically preserve or restore the prior site?
131. Do branch protection or repository Pages settings need manual administrator steps, and must those be documented as part of the implementation outcome?

## 14. Edge cases and content safety

132. What should users see when JavaScript is disabled or search fails? Must all content/navigation remain usable as static HTML?
133. How should the site behave with duplicate headings, punctuation-heavy module names, non-ASCII text (for example `640×480`), and code blocks wider than a phone screen?
134. How should commands distinguish host shell, device IEx, and on-device external shell contexts, especially because SSH opens IEx rather than a shell?
135. How should multi-device mDNS ambiguity be documented? `nerves.local` may resolve unpredictably when more than one device advertises it, while device-specific hostnames differ.
136. Should network-dependent instructions provide alternatives when mDNS does not work, when WiFi credentials are wrong, or when the USB gadget is unavailable?
137. How should instructions prevent users from burning firmware to the wrong disk or removing a journal-less exFAT card without unmounting?
138. Must legal/project policy address obtaining ROMs, BIOS files, Microsoft Xbox identifiers/branding, screenshots of third-party software, and trademark notices?
139. Should unauthenticated HTTP/API behavior be called out globally as a security model and repeated at each network operation, especially Pickle installation and file deletion?
140. How should stale docs for renamed launcher labels, button mappings, paths, supported extensions, and package versions be detected during review?
141. What happens when a docs-only PR changes navigation but not content, or deletes a page still referenced by a released README/tag?
142. If a site build succeeds but screenshots or remote assets are missing due to case-sensitive paths, will CI run on a case-sensitive filesystem and verify every asset reference?
143. Should the published site include a clear feedback route (“report a docs issue”) that pre-fills the page URL/version?

## 15. Acceptance criteria to agree before implementation

144. What exact public URL must return successfully for the issue to be accepted, and who verifies Pages/DNS configuration outside the repository?
145. Which named pages and user journeys must exist at launch, and which current README sections must no longer contain detailed prose?
146. What maximum README scope/length demonstrates that migration is complete without making the repository landing page unhelpful?
147. Must every current `docs/*.md` page appear in site navigation, or may historical/reference content be reachable only through contextual links?
148. Is zero duplicated detailed content an acceptance criterion, or is explicitly identified summary duplication allowed?
149. Must all existing repository Markdown links and intended legacy paths pass automated checks after migration?
150. Which screenshots/diagrams are required for acceptance, and can the initial release ship with documented placeholders if hardware captures are unavailable?
151. Must search be present and return useful results for agreed terms such as “add games,” “WiFi,” “Bluetooth,” “cores,” “Moonlight,” and “Pickles”?
152. What local clean-checkout commands must a reviewer run successfully to preview and produce the production artifact?
153. Which CI checks must be required and green, and what warning budget is acceptable (ideally none for internal links/build warnings)?
154. Must a merge to `trunk` automatically deploy without manual artifact copying, and must a failed docs build leave the currently published site untouched?
155. Do we require a documented deployment/rollback procedure and a documented page-authoring workflow before closing the issue?
156. Who signs off separately on user accuracy, developer accuracy, hardware-status claims, accessibility/mobile UX, and production deployment?
157. Should acceptance include a content audit proving every substantive section removed from README has one canonical destination and every destination is linked from README or site navigation?
158. What explicit non-goals should be recorded so API generation, localization, release-versioned docs, custom branding, analytics, or broad firmware CI do not expand this issue unintentionally?
