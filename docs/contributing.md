> **Documentation for current `trunk`; installed firmware may differ.**

# Contributing

Keep user procedures, source contracts, and hardware evidence in agreement.
Guides own user intent and support status; moduledocs own callable contracts and
implementation mechanics.

## Host prerequisites

Use the Elixir/Erlang versions accepted by the project (`mix.exs` requires
Elixir `~> 1.20`; no OTP version is currently pinned). Ordinary host development
and documentation compilation use the existing native prerequisites required by
`scenic_driver_local`: GTK 3 (`gtk+3` in Homebrew), Cairo, and `pkgconf`, plus
XQuartz on macOS. On Debian/Ubuntu, install `build-essential`, `libcairo2-dev`,
`libfreetype6-dev`, `libgtk-3-dev`, `libsystemd-dev`, and `pkg-config`.
Documentation generation does not remove or bypass those prerequisites.

With `MIX_TARGET=host`, docs generation does not evaluate target credential
guards, access `../nerves_system_rg40xxv`, start Scenic or application children,
or require a firmware toolchain, handheld, SSH key, WiFi credentials, or Python.
However, `mix deps.get` resolves the project's declared dependency graph and may
download or resolve dependencies that are target-scoped; `MIX_TARGET=host` is
not a promise that target dependency declarations are invisible.

## Verify a change

**Context: MayonnaiOS repository on a host satisfying the native prerequisites.**

```console
$ MIX_TARGET=host mix deps.get
$ MIX_TARGET=host mix docs --warnings-as-errors
$ MIX_TARGET=host mix docs.check
```

The first command fetches Mix dependencies. The second writes the static site to
`doc/` and fails on ExDoc guide/module-reference warnings. The third validates
all generated internal links, fragments, and local assets. Run the commands in
this order; the checker operates on the generated `doc/` tree. External HTTP
availability is reviewed when a link is introduced, but does not gate CI.

Optionally open ExDoc's normal local view:

**Context: same host checkout, after generating `doc/`.**

```console
$ MIX_TARGET=host mix docs --open
```

### Inspect the GitHub Pages base path

Opening files directly or serving `doc/` at `/` does not exercise the
`/mayonnaios/` project path. The following server uses only the already-declared
Bandit and Plug dependencies and mounts `doc/` at the Pages base.

**Context: same host checkout, after generating `doc/`; keep this process
running.**

```console
$ MIX_TARGET=host mix run --no-start -e 'Application.ensure_all_started(:bandit); {:ok, _} = Bandit.start_link(plug: {Plug.Static, at: "/mayonnaios", from: "doc"}, port: 4001); IO.puts("http://localhost:4001/mayonnaios/index.html"); Process.sleep(:infinity)'
```

Visit <http://localhost:4001/mayonnaios/index.html>. Stop the server with
Control-C. This is a static inspection server, not a live-reload workflow, and
it introduces no Python or extra dependency.

**Success:** docs build without warnings, the checker succeeds, and the Pages
URL loads styling, navigation, search assets, guide links, and images beneath
`/mayonnaios/`.

## Documentation maintenance checklist

For every behavior-changing pull request, review and update as applicable:

- **User-visible behavior:** the canonical task guide, success indication,
  limitation, and troubleshooting path.
- **Commands and configuration:** run commands in their stated host, target, or
  device context; compare environment variables and paths with source config.
- **Hardware status:** textual maturity label plus evidence. Record the RG40XXV,
  observation date, and firmware hash when known; tests alone are not hardware
  evidence.
- **Links and assets:** local guides/modules/anchors and newly introduced
  external URLs. External status is a review item, not a CI gate.
- **Screenshots:** update affected authoritative captures. Future desired
  captures are the launcher, WiFi wheel, upload UI, and physical device.

Real-hardware captures or photos are authoritative for hardware claims. A host
capture must be captioned **host runtime**. Any image of an Experimental or
Untested feature needs an adjacent textual status label and a caption naming the
capture environment. Do not use an unverified image as an unlabeled hero.

## Content and review boundaries

- Keep published guide basenames stable and link between extras with source
  `.md` paths rather than generated `doc/` URLs.
- Repeat only the shortest command or warning needed to finish a task; link to
  the canonical guide or API contract for the detail.
- Never turn host tests or a 640×480 host window into an RG40XXV verification
  claim.
- Do not add external fonts, CDNs, analytics, custom JavaScript, or Python to
  the documentation toolchain.
- Do not commit generated `doc/`, `_build/`, `deps/`, host scratch state, or
  credentials.
- Put application, board-support, and native bundle changes in their owning
  repositories; see [Repository responsibilities](repositories.md).

Run focused tests for the subsystem you changed and `MIX_TARGET=host mix test`
when feasible. Changed Elixir/config files must pass `mix format`, and every
commit should pass `git diff --check`.

[Edit this page](https://github.com/kek/mayonnaios/edit/trunk/docs/contributing.md) ·
[Report a documentation issue](https://github.com/kek/mayonnaios/issues/new)
