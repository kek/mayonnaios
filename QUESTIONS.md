# Product and design questions for #81

## Settled constraints

These are inputs, not open questions:

- The site should be a fresh design rather than an adaptation of an existing site.
- The documentation toolchain must not introduce Python.
- The site must be generated with ExDoc through Mix.
- The complete implementation must fit in one PR, with no deployment partway through that PR.

The questions below are the unresolved decisions needed to turn those constraints and the issue outcome into an acceptance-ready design.

## Audience and success

1. **Who is the primary reader at launch, and whose path should the home page optimize for?** The current README addresses at least four distinct groups: someone evaluating the project, an RG40XXV owner operating an already-flashed device, someone building/flashing firmware, and a contributor changing Elixir/Nerves code. Which is primary, and what is the priority order for the others?

2. **What is the intended first successful outcome for each audience?** For example, should an owner be led first to uploading a game, should a new builder be led to producing and burning firmware, and should a contributor be led to the host development runtime? This determines whether the site opens with task-based onboarding, a feature tour, or a conventional developer reference.

3. **Is obtaining a prebuilt firmware image part of the user journey, or is building from source the only supported installation path?** The README currently starts installation at `mix firmware`/`mix burn`, but a user-facing docs site may imply an end-user installation route. If prebuilt images are not available, should the site explicitly say so?

4. **What measurable conditions define success for this issue beyond “the site exists”?** Possible acceptance signals include a new reader being able to find the flash, WiFi, game-upload, and development instructions from the landing page; every current README section having an intentional destination; and no substantive content having two canonical homes. Which should be explicit acceptance criteria?

## Scope and content ownership

5. **Exactly what should remain in the concise README?** Should it contain only the one-paragraph project overview, a short feature summary, a minimal build/flash quick start, and links to the site, or should operational essentials such as game upload and recovery access remain there too? Is there a target length or a “reader can do X without leaving GitHub” requirement?

6. **Should the site be the canonical home for all prose documentation, or will some repository-only documents remain intentionally outside it?** In particular, should every current top-level `docs/*.md` page appear in navigation, or can historical/reference material remain version-controlled but unpublished?

7. **What should happen to `docs/retroarch-provisioning.md` and `docs/retroarch-reference/`?** The provisioning document records a decision and says the retained Buildroot reference comments should be treated with suspicion. Is this useful contributor-facing architecture history that should be published, an archive that should remain out of navigation, or material to consolidate into the current RetroArch internals page?

8. **Are source-code moduledocs part of the product documentation, an API reference for contributors, or implementation detail?** The source contains substantial explanations that the README currently points readers toward (for example `MayonnaiOS.WiFi`, `Files`, `Led`, `Sleep`, and `LowPower`). Should ExDoc publish all documented modules, expose a curated subset, or keep the guide pages self-contained and treat module pages as secondary reference?

9. **If guide content and a moduledoc currently explain the same behavior, which is canonical and how much repetition is acceptable?** A firm rule is needed so migration does not merely move today’s duplication from README-versus-source to guides-versus-module-reference.

10. **Should IEx/API examples be aimed only at maintainers, or are they a supported advanced-user interface?** The README mixes panel/browser tasks with calls such as `MayonnaiOS.Cores.install/1`, `GamesCard.unmount/0`, and `Pairing.status/0`. The answer affects whether these remain alongside user tasks or move into an “SSH and IEx”/API-reference area.

11. **Is documentation for adjacent repositories in scope?** The README describes the three-repository boundary and links to `nerves_system_rg40xxv` and `mayonnaios_bundles`. Should this site only explain MayonnaiOS and link outward, or provide an integrated contributor journey across all three repositories while leaving their detailed procedures canonical there?

## Information architecture and findability

12. **Which top-level navigation model should the site use?** A proposed task split could be “Get started,” “Use the device,” “Develop,” “Architecture and internals,” “Hardware status,” and “API reference,” but the audience priority may call for different labels or fewer sections. Which concepts must be visible in the global navigation rather than discoverable through page links?

13. **Should feature pages be organized around user goals or implementation subsystems?** For example, Bluetooth controller and Bluetooth devices are distinct user tasks sharing one stack, while cores, bundles, games, saves, and RetroArch provisioning cross several subsystems. Which mental model should control navigation and page boundaries?

14. **What belongs on the requested hardware-status page?** Is it a concise RG40XXV capability matrix, a list of tested/unverified/broken behaviors, measurements and known limitations, or target support across every Mix target listed in `mix.exs`? Are the non-RG40XXV targets actual supported products or dependency scaffolding that should not appear as supported hardware?

15. **Should the site document only current `trunk`, or must it support released/versioned documentation?** `mix.exs` currently reports version `0.1.0`, while operational statements are tied to particular firmware hashes or bundle versions. Is a single “latest” site sufficient, and if so should pages prominently say that they describe current `trunk` rather than every installed firmware?

16. **What search and discovery behavior is required at launch?** Is ExDoc’s built-in search enough, and should API modules and guides share one search index, or should user-facing guide results be favored over module/function results?

## Status, claims, and terminology

17. **What status vocabulary should be used, and what does each label promise?** The issue asks for labels for experimental features, but the current prose distinguishes at least implemented, hardware-tested, not hardware-tested, measured, estimated, unavailable, and known-broken. Should there be a small formal set such as Stable / Experimental / Untested / Unsupported, and who assigns each status?

18. **Which current features should carry a non-stable label on day one?** Candidates explicitly called out in existing prose include Moonlight (“not run on the handheld yet”), low-power savings (the mechanism exists but the saving is unmeasured), Bluetooth’s intermittent hci0 recovery, and historical RetroArch build/provisioning notes. Please confirm the initial classification rather than leaving it to visual design.

19. **How should contradictory or time-sensitive claims be resolved before migration?** For example, the README says the USB gadget provides SSH when WiFi is down, while `MayonnaiOS.WiFi` says USB-C gadget enumeration has not been observed; the README presents low-power behavior as a supported feature while `MayonnaiOS.LowPower` says its savings are unmeasured. Which statement is current, and should the site separate “implemented,” “verified on hardware,” and “expected” claims?

20. **Which product name and style conventions are authoritative?** Please confirm capitalization (`MayonnaiOS`), whether “RG40XXV” needs a manufacturer prefix on first use, whether the audience-facing term is “firmware,” “OS,” or both, and whether terms such as “Pickles” should be introduced as product terminology or treated as developer jargon.

## Visual design and media

21. **What visual character should the fresh design communicate?** Should it echo the on-device NeXTSTEP/pixel aesthetic and bundled typefaces, use a restrained technical-documentation style, or establish a separate web identity? Are there existing logo/wordmark, color, or trademark assets outside this repository that must be used?

22. **What accessibility and device requirements are acceptance criteria?** At minimum, should the site target keyboard navigation, visible focus, semantic heading order, sufficient contrast, reduced-motion preferences, alt text, and useful layouts on phones as well as desktops? Is a dark theme required, optional, or undesirable?

23. **Which screenshots are required for the first release?** There are currently no image files in the repository. Should launch include a device hero image, launcher and settings screens, browser upload UI, and/or procedural screenshots? Which pages are unacceptable without imagery?

24. **How should screenshots be produced and maintained?** Can host-runtime captures be presented as authoritative because it renders at the panel’s 640×480 size, or are photographs/captures from real hardware required? Who supplies any hardware-only images, and should screenshot freshness be a manual release responsibility or merely documented guidance?

25. **Should screenshots show only current stable behavior, or may experimental features be shown with an adjacent status treatment?** This affects both the initial asset list and whether an image can accidentally overstate support.

## URLs, migration, and compatibility

26. **What is the public canonical URL?** Should deployment use the repository’s GitHub Pages URL, an organization/user Pages URL, or a custom domain? If a custom domain is desired, is DNS already available and should domain setup be in this PR’s acceptance scope?

27. **How much compatibility is required for existing GitHub URLs such as `docs/pickles.md` and `docs/bluetooth-controller.md`?** Should those files remain at their current repository paths and be consumed directly by ExDoc, should small pointer files remain after content moves, or is it acceptable for old GitHub deep links to redirect only through manually maintained links? “No broken links” needs a defined boundary for inbound links that may already exist externally.

28. **What URL scheme should the published guides use, and must it be treated as a stable public interface?** A decision is needed before page filenames and cross-links are migrated, especially if future information-architecture changes should preserve today’s URLs.

29. **When content is split during migration, is editorial rewriting expected or should the first release preserve wording as closely as possible?** Several README sections combine user instructions, rationale, guarantees, and implementation detail. The desired balance between faithful relocation and a task-focused rewrite will materially affect review scope within the one-PR constraint.

30. **Should external links be allowed to fail CI?** Nerves/HexDocs, GitHub, and other external sites can fail transiently or change independently. Should CI enforce only internal links and report external failures, enforce an allowlisted subset, or fail on every external link?

## Publishing, review, and operations

31. **Where should the generated site be hosted and which branch/event is authoritative for deployment?** Assuming GitHub Pages is acceptable, should every merge to `trunk` publish automatically, should tagged releases publish, or should deployment require a manual approval? The “no mid-PR deployment” constraint rules out using a live deployment as a review step but does not choose the post-merge policy.

32. **How should reviewers approve the fresh design without a mid-PR deployment?** Is a locally generated ExDoc artifact attached to the PR sufficient, should CI upload a downloadable artifact, or are screenshots of representative pages expected? This needs to be reproducible without creating a public preview environment.

33. **What should happen on a documentation build failure after merge?** Should the previously published site remain untouched (atomic publish), and is a failed docs deployment release-blocking/urgent or simply a failing repository check to repair?

34. **Which CI checks are mandatory?** Please confirm whether acceptance requires, in addition to generating ExDoc, warnings-as-errors, internal anchor/link validation, image existence and alt-text checks, spelling/style checks, and verification that README links resolve against the final site. Adding every possible content check may be disproportionate for one PR.

35. **Must docs generation work with the ordinary host dependency set and no firmware credentials or target toolchain?** This appears consistent with the current host development flow, but should be an explicit requirement so docs do not accidentally depend on `MIX_TARGET=rg40xxv`, WiFi environment variables, a Nerves system build, GTK, or device access.

36. **What local author workflow should be documented as supported?** Is `mix docs` plus opening generated files enough, or is a watch/live-reload command an acceptance requirement? Should contributors be expected to install any tools beyond the versions and Mix dependencies already declared by the project?

37. **Who owns ongoing content review, especially hardware status and screenshots?** Should PRs that change behavior be expected to update a named guide/status page, and is there a checklist or contribution policy to enforce that, or is maintenance guidance in the docs README sufficient?

38. **Are analytics, feedback links, or edit-page links wanted?** A privacy-preserving site may intentionally have no analytics. Conversely, “Edit this page” and issue-report links can make stale hardware claims easier to correct. These choices affect the page chrome and privacy statement and should be deliberate.
