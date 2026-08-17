defmodule MayonnaiOS.Bluetooth.HCISocket do
  @moduledoc """
  Raw HCI over an `AF_BLUETOOTH` user channel, in pure Elixir.

  Everything this project knows about the RTL8821CS Bluetooth side so far comes
  from `dmesg`: btrtl logs `RTL: fw version 0x75b8f098` once during boot, and
  `MayonnaiOS.Diagnostics.rtl_status/0` scrapes that line. It proves firmware
  was uploaded at 1.8 s. It does not prove the controller is answering *now* --
  a wedged chip, a dead H5 link and a healthy controller all leave the same log
  behind, and there is no BlueZ in the image to ask (no `hciconfig`, no
  `btmgmt`, no `bluetoothctl`).

  This module asks the controller directly. It sends HCI Reset and Read Local
  Version and reports what came back off the wire. Manufacturer `0x005D` is
  Realtek; seeing that value arrive is the first evidence in this project that
  the chip is alive rather than merely initialised once.

  ## Why a user channel does not need BlueZ, a rebuild, or `btattach`

  `HCI_CHANNEL_USER` sounds like it takes the UART away from the kernel. It
  does the opposite -- it asks the kernel to open it. Read from
  `net/bluetooth/hci_sock.c`, `hci_sock_bind()`, case `HCI_CHANNEL_USER`
  (checked against the 6.1 tree in `/Users/ke/src/ext/knulli`, and the same in
  v6.18): the bind requires `CAP_NET_ADMIN`, sets `HCI_USER_CHANNEL`, and then
  calls `hci_dev_open(hdev->id)` itself. That runs `hdev->open`, which for this
  board is `hci_uart_open()` on the serdev the kernel already owns from the
  device tree. The kernel keeps driving the wire and the vendor setup; this
  process gets exclusive raw HCI on top of it. So no line discipline attach is
  needed (that is all `btattach` does, and this controller is serdev-bound, not
  ldisc-attached), and no package needs adding to the image.

  `# CONFIG_BT_LE is not set` in the system's kernel config is not a blocker
  either, despite how it reads. `net/bluetooth/Makefile` puts `hci_sock.o`,
  `l2cap_core.o` and `smp.o` in `bluetooth-y` unconditionally; `CONFIG_BT_LE`
  gates only `iso.o`. Read, not assumed.

  ## The traps, in the order they will bite

  * **The socket owns hci0 for as long as it is open.** While a user channel is
    bound, the kernel Bluetooth stack is switched off for that controller: it
    is one-or-the-other with BlueZ, not a layer on top. Closing the socket --
    or the BEAM dying -- closes hci0 with it. `probe/1` therefore opens, asks,
    and closes; nothing here holds the device.

  * **The bind currently succeeds because nothing has ever powered hci0 up.**
    `hci_register_dev()` sets `HCI_AUTO_OFF`, and the `-EBUSY` test is
    `(!HCI_AUTO_OFF && HCI_UP)`. If something ever powers the controller via
    mgmt, the bind starts returning `:ebusy` and there is no `hciconfig` in the
    image to bring it down. That still would not need a rebuild: the escape
    hatch is a second socket bound to `HCI_CHANNEL_CONTROL` (channel 3) with a
    raw mgmt *Set Powered 0* command written to it.

  * **This is the second `hci_dev_open` since boot.** The first was the
    automatic `power_on`; the H5 link state machine and the baud rate
    `h5_btrtl_setup()` switched to both have to survive the `hci_dev_close` in
    between. Firmware is *not* re-downloaded (`hci_dev_setup_sync()`
    early-returns once `HCI_SETUP` is cleared, and hci_h5 does not set
    `HCI_QUIRK_NON_PERSISTENT_SETUP`, so the chip stays powered with firmware
    resident). If the Reset below times out, this is the suspect: check `dmesg`
    for an H5 resync or "Frame reassembly failed", and retry the bind before
    concluding the approach is wrong.

  ## Errors the bind can return, and what each one means

  Straight out of the `case HCI_CHANNEL_USER` branch of `hci_sock_bind()`:

      :eperm     not CAP_NET_ADMIN. Nerves runs as root, so this means the
                 call came from somewhere else.
      :enodev    no hci0 -- the serdev never bound, so btrtl never ran
      :ebusy     HCI_INIT/HCI_SETUP/HCI_CONFIG in progress, or the controller
                 is powered up without the AUTO_OFF grace period
      :eusers    HCI_USER_CHANNEL is already set: another socket has it
      :ealready  this socket is already bound
      :einval    hci_dev was HCI_DEV_NONE (0xffff)

  On the host there is no `AF_BLUETOOTH` at all, so `open/1` fails with
  `:eafnosupport` on Darwin. That is why everything above the socket in this
  module is a pure function over binaries: the framing and parsing are tested
  on the host, and only the four `:socket` calls need the device.
  """

  # AF_BLUETOOTH from include/linux/socket.h; BTPROTO_HCI and HCI_CHANNEL_USER
  # from include/net/bluetooth/hci_sock.h.
  @af_bluetooth 31
  @btproto_hci 1
  @hci_channel_user 1

  # H4 packet types, which the user channel uses on both directions.
  @hci_command_pkt 0x01
  @hci_event_pkt 0x04

  @evt_command_complete 0x0E

  @op_reset 0x0C03
  @op_read_local_version 0x1001

  @default_timeout 2_000

  # Bluetooth SIG company identifiers, only the ones plausible on this board.
  @manufacturers %{
    0x0002 => "Intel",
    0x000A => "Cypress",
    0x000F => "Broadcom",
    0x001D => "Qualcomm",
    0x005D => "Realtek",
    0x0499 => "Ruijie"
  }

  # Core specification version from the HCI_Version byte, Assigned Numbers.
  @core_spec %{6 => "4.0", 7 => "4.1", 8 => "4.2", 9 => "5.0", 10 => "5.1", 11 => "5.2"}

  @typedoc "What the controller said about itself."
  @type version :: %{
          hci_version: non_neg_integer(),
          hci_revision: non_neg_integer(),
          lmp_version: non_neg_integer(),
          lmp_subversion: non_neg_integer(),
          manufacturer: non_neg_integer(),
          manufacturer_name: String.t(),
          core_spec: String.t()
        }

  @doc """
  Open hci0, reset it, ask who it is, and close again.

  The one-shot check. Returns `{:ok, version}` with `manufacturer: 0x5D` on a
  healthy Realtek controller, or `{:error, reason}` -- see the module doc for
  what each bind error means.

  Options: `:dev` (HCI device index, default 0) and `:timeout` (milliseconds
  allowed for *each* command to complete, default #{@default_timeout}).

  The socket is closed before returning, in an `after`, including when a
  command times out. Leaving it open would keep the kernel stack off hci0.
  """
  @spec probe(keyword()) :: {:ok, version()} | {:error, term()}
  def probe(opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    case open(Keyword.get(opts, :dev, 0)) do
      {:ok, socket} ->
        try do
          read_version(socket, timeout)
        after
          close(socket)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Open a user-channel socket on `dev` and bind it. The caller owns hci0 until
  it calls `close/1`.
  """
  @spec open(non_neg_integer()) :: {:ok, :socket.socket()} | {:error, term()}
  def open(dev \\ 0) do
    with {:ok, socket} <- :socket.open(@af_bluetooth, :raw, @btproto_hci) do
      case :socket.bind(socket, sockaddr(dev, @hci_channel_user)) do
        :ok ->
          {:ok, socket}

        {:error, reason} ->
          # A bound-but-failed socket would still hold HCI_USER_CHANNEL until
          # it was garbage collected, and the next attempt would see :eusers.
          :socket.close(socket)
          {:error, reason}
      end
    end
  end

  @doc "Close the socket, which also closes hci0."
  @spec close(:socket.socket()) :: :ok | {:error, term()}
  def close(socket), do: :socket.close(socket)

  @doc """
  The `sockaddr_hci` OTP will build for us.

  `esock_decode_sockaddr_native()` (erts/emulator/nifs/common/socket_util.c)
  zeroes the struct, writes `sa_family` from `:family`, copies `:addr` into
  `sa_data` and sets the length to `2 + byte_size(addr)`. A four-byte addr of
  `hci_dev` then `hci_channel`, both little-endian, is therefore exactly the
  six-byte `sockaddr_hci` the kernel wants.
  """
  @spec sockaddr(non_neg_integer(), non_neg_integer()) :: :socket.sockaddr()
  def sockaddr(dev, channel) do
    %{family: @af_bluetooth, addr: <<dev::16-little, channel::16-little>>}
  end

  @doc """
  Reset the controller, then read its version. Exposed separately from
  `probe/1` so a caller that is already holding a socket can reuse it.
  """
  @spec read_version(:socket.socket(), timeout()) :: {:ok, version()} | {:error, term()}
  def read_version(socket, timeout \\ @default_timeout) do
    # Reset first, deliberately. It is the cheapest command that proves a
    # round trip, and its Command Complete arriving is what tells a live
    # controller from a wedged H5 link.
    with {:ok, _reset_params} <- request(socket, @op_reset, timeout),
         {:ok, params} <- request(socket, @op_read_local_version, timeout) do
      local_version(params)
    end
  end

  @doc """
  Send one command and wait for its Command Complete, returning the return
  parameters with the status byte already checked off.
  """
  @spec request(:socket.socket(), non_neg_integer(), timeout()) ::
          {:ok, binary()} | {:error, term()}
  def request(socket, opcode, timeout \\ @default_timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    with :ok <- :socket.send(socket, command(opcode)),
         {:ok, params} <- await_complete(socket, opcode, deadline) do
      status(params)
    end
  end

  # Anything the controller volunteers that is not this command's completion
  # gets dropped and the wait continues -- bounded by the deadline, not by a
  # retry count, so a chatty controller cannot extend the timeout.
  defp await_complete(socket, opcode, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, {:timeout, opcode}}
    else
      case :socket.recv(socket, 0, remaining) do
        {:ok, packet} ->
          case command_complete(packet, opcode) do
            {:error, {:unrelated, _}} -> await_complete(socket, opcode, deadline)
            other -> other
          end

        {:error, :timeout} ->
          {:error, {:timeout, opcode}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # -- pure framing and parsing ----------------------------------------------
  #
  # Everything below is a function over binaries so it can be tested on a
  # machine with no Bluetooth at all.

  @doc """
  An H4 command packet: type byte, little-endian opcode, parameter length,
  parameters. HCI Reset is `<<0x01, 0x03, 0x0C, 0x00>>`.
  """
  @spec command(non_neg_integer(), binary()) :: binary()
  def command(opcode, params \\ <<>>) do
    <<@hci_command_pkt, opcode::16-little, byte_size(params), params::binary>>
  end

  @doc "HCI Reset, opcode 0x0C03."
  @spec reset() :: binary()
  def reset, do: command(@op_reset)

  @doc "HCI Read Local Version Information, opcode 0x1001."
  @spec read_local_version() :: binary()
  def read_local_version, do: command(@op_read_local_version)

  @doc """
  Pull the return parameters out of a Command Complete for `opcode`.

  `{:error, {:unrelated, packet}}` means "not this command's completion" and is
  the caller's cue to keep waiting; every other error is fatal.
  """
  @spec command_complete(binary(), non_neg_integer()) :: {:ok, binary()} | {:error, term()}
  def command_complete(packet, opcode)

  def command_complete(
        <<@hci_event_pkt, @evt_command_complete, plen, _ncmd, op::16-little, rest::binary>> =
          packet,
        opcode
      ) do
    cond do
      # plen covers num_hci_command_packets and the opcode as well as the
      # return parameters; a mismatch means a truncated read, not a short
      # command, and silently trusting it would misparse the version.
      byte_size(rest) != plen - 3 -> {:error, {:truncated, packet}}
      op != opcode -> {:error, {:unrelated, packet}}
      true -> {:ok, rest}
    end
  end

  def command_complete(packet, _opcode), do: {:error, {:unrelated, packet}}

  @doc """
  Split the leading status byte off a command's return parameters. Status 0x00
  is success; anything else is the controller refusing, and is reported as
  `{:error, {:hci_status, code}}` rather than parsed further.
  """
  @spec status(binary()) :: {:ok, binary()} | {:error, term()}
  def status(<<0x00, rest::binary>>), do: {:ok, rest}
  def status(<<code, _rest::binary>>), do: {:error, {:hci_status, code}}
  def status(<<>>), do: {:error, :no_return_parameters}

  @doc """
  Read Local Version Information return parameters, status already removed.
  """
  @spec local_version(binary()) :: {:ok, version()} | {:error, term()}
  def local_version(
        <<hci_version, hci_revision::16-little, lmp_version, manufacturer::16-little,
          lmp_subversion::16-little>>
      ) do
    {:ok,
     %{
       hci_version: hci_version,
       hci_revision: hci_revision,
       lmp_version: lmp_version,
       lmp_subversion: lmp_subversion,
       manufacturer: manufacturer,
       manufacturer_name: manufacturer_name(manufacturer),
       core_spec: core_spec(hci_version)
     }}
  end

  def local_version(other), do: {:error, {:malformed_local_version, other}}

  @doc "Company identifier as a name, or the hex value when it is not one we know."
  @spec manufacturer_name(non_neg_integer()) :: String.t()
  def manufacturer_name(id) do
    Map.get_lazy(@manufacturers, id, fn -> "0x" <> hex(id) end)
  end

  @doc "Core specification version for an HCI_Version byte."
  @spec core_spec(non_neg_integer()) :: String.t()
  def core_spec(hci_version) do
    Map.get_lazy(@core_spec, hci_version, fn -> "unknown (#{hci_version})" end)
  end

  defp hex(value), do: value |> Integer.to_string(16) |> String.pad_leading(4, "0")
end
