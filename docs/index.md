> **Documentation for current `trunk`; installed firmware may differ.**

# MayonnaiOS

MayonnaiOS is firmware for the **Anbernic RG40XXV handheld**: a focused launcher,
device tools, sandboxed Lua apps called Pickles, and independently installed
RetroArch cores and programs. These pages describe the current source tree. There
is **no supported prebuilt firmware image**; building from source is the only
supported installation route.

> ## Use your device
>
> Already running MayonnaiOS? [Connect to WiFi][wifi], then [upload a game][games]
> from a phone or computer on the same trusted network.

> ## Build and flash
>
> Starting with an RG40XXV? [Follow the source-build procedure][build]. It requires
> firmware credentials, an SSH public key, and the RG40XXV board-support repository.

## What the status words mean

Status is always written in text as well as styled visually.

- **Verified** — implemented and observed on RG40XXV hardware.
- **Experimental** — implemented and observed, but incomplete, unreliable, or
  carrying an unresolved risk.
- **Untested** — implemented, but not yet run on RG40XXV hardware.
- **Unsupported** — not provided by MayonnaiOS.

**Measured** and **Estimated** qualify evidence or numbers; they are not maturity
levels. **Historical** marks a decision record rather than a current procedure.
See the [complete RG40XXV capability matrix](hardware-status.md).

## Choose a route

### Evaluate MayonnaiOS

**Prerequisite:** none.

1. Read the [hardware status matrix](hardware-status.md).
2. Compare each textual status and limitation with what you need.

**Success:** you can distinguish observed hardware behavior from implemented but
untested behavior. For product detail, continue to the [repository overview][repo].

### First owner outcome

**Prerequisites:** MayonnaiOS is already flashed, and a phone or computer can join
the same trusted network.

1. Open **System → WiFi** and join a network.
2. Visit `http://nerves.local/` from the other device and upload a game.

**Success:** WiFi reports the network as connected and the uploaded game appears in
the launcher. If either step fails, use the [WiFi procedure][wifi] and review the
[WiFi and storage status rows](hardware-status.md).

### First builder outcome

**Prerequisites:** the repository's Elixir/Erlang versions, firmware SSH and WiFi
credentials, and the sibling `nerves_system_rg40xxv` board-support repository.

1. Set `MIX_TARGET=rg40xxv` and the required credentials.
2. Fetch dependencies and run `mix firmware`.

**Success:** Nerves produces the firmware artifact without a missing-credential or
missing-system error. Continue with the [build and flash procedure][build]; its
recovery notes matter before writing a card.

### First contributor outcome

**Prerequisites:** the repository's Elixir/Erlang versions and the Cairo/GTK native
dependencies used by `scenic_driver_local`.

1. Run `mix test` with the host target.
2. Run `iex -S mix` and drive the 640×480 host window with the keyboard.

**Success:** tests pass and the launcher opens in the host runtime. Use the
[current development notes][develop] for reload and native-dependency help, then
browse the API reference.

## Documentation map

- **Start here** — this orientation and audience routes.
- **Use the device** — WiFi, upload games, files, Bluetooth controller and device
  scanning, sleep, Moonlight, and advanced SSH/IEx tasks.
- **Build and develop** — firmware builds, host development, contributing, and
  authoring Pickles.
- **Architecture and internals** — data ownership, repository boundaries,
  Bluetooth, RetroArch runtime details, and historical decisions.
- **Hardware status** — one evidence-aware RG40XXV capability matrix.

Quick links: [WiFi][wifi] · [upload games][games] · [build/flash][build] ·
[development][develop] · [contributing][contribute] ·
[repository responsibilities][repositories] · [report a documentation issue][issues] ·
[view source][source]

[wifi]: wifi.md
[games]: games-and-cores.md
[build]: build-and-flash.md
[develop]: development.md
[contribute]: contributing.md
[repositories]: repositories.md
[repo]: https://github.com/kek/mayonnaios
[issues]: https://github.com/kek/mayonnaios/issues/new
[source]: https://github.com/kek/mayonnaios/edit/trunk/docs/index.md
