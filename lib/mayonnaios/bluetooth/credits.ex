defmodule MayonnaiOS.Bluetooth.Credits do
  @moduledoc """
  The controller's ACL buffer accounting: what may be sent now, what waits,
  and what is not worth waiting for.

  A Bluetooth controller holds a small, fixed number of outbound ACL packets
  -- eight of 27 bytes on this board's Realtek -- and sending more than it
  has room for is a protocol violation, not a queue. Every packet spends one
  credit; a Number of Completed Packets event gives credits back. This module
  is that arithmetic, kept pure so it can be tested on a laptop:
  `MayonnaiOS.Bluetooth.Host` owns the socket and asks this what to write.

  ## Two kinds of PDU, two verbs

  `offer/2` is for input reports and their kin: all-or-nothing, never queued.
  A report is the *current* state of the buttons; if it cannot go now, the
  next one supersedes it a few milliseconds later, and queueing them would
  deliver a burst of stale states that reads as the controller sticking and
  then catching up. A dropped report is the right answer and the caller
  counts it.

  `push/2` is for everything that is an answer to a question: ATT responses,
  SMP, L2CAP signalling. These are not superseded by anything -- a host that
  asked for the report map waits thirty seconds for it and then gives up on
  the device. What does not fit now is queued, and `completed/2` hands back
  what each returned credit lets through, in order.

  ## Why the queue exists at all

  It did not, and the stack worked -- until the report descriptor grew. The
  descriptor is read at MTU 247, and a 246-byte ATT response is ten fragments
  of 27 bytes where the controller holds eight. The old all-or-nothing send
  refused the PDU, nothing was ever written, and BlueZ on a Steam Deck
  reported `Report Map read failed: unlikely error` -- its words for an ATT
  request nothing answered -- and declined to create the input device. A
  controller that pairs, encrypts and notifies perfectly, invisible to every
  game, because the one answer that did not fit was silently thrown away.

  ## Fragments must stay contiguous

  The fragments of one L2CAP PDU must arrive on the link back to back;
  another PDU's fragment between them corrupts the reassembly on the far
  side. That is why `offer/2` refuses whenever the queue is non-empty, even
  with credits in hand: a report slipped in ahead of a half-sent response
  would land in the middle of it. The queue drains in insertion order for
  the same reason.

  ## One connection

  Credits are per controller, not per connection, and `disconnected/1`
  restores the full allowance and empties the queue. That is correct only
  while there is at most one connection -- which is what this peripheral is
  -- because a controller with a second link still holds the other link's
  unacknowledged packets. If a central role ever shares this stack, this
  module is where the accounting has to grow up.
  """

  defstruct credits: 1, total: 1, queue: :queue.new()

  @typedoc "The running account: credits in hand, the allowance, and what waits."
  @type t :: %__MODULE__{
          credits: non_neg_integer(),
          total: pos_integer(),
          queue: :queue.queue(binary())
        }

  @doc "A fresh account with the controller's full allowance in hand."
  @spec new(pos_integer()) :: t()
  def new(total) when total > 0, do: %__MODULE__{credits: total, total: total}

  @doc """
  Spend credits on a droppable PDU: all of it now, or none of it ever.

  Refused when the fragments outnumber the credits in hand, and refused
  whenever anything is queued -- see the moduledoc on contiguity. The caller
  drops the PDU and counts why; nothing is remembered here.
  """
  @spec offer(t(), [binary()]) :: {:ok, [binary()], t()} | {:error, :no_credits}
  def offer(%__MODULE__{} = account, packets) do
    count = length(packets)

    if :queue.is_empty(account.queue) and count <= account.credits do
      {:ok, packets, %{account | credits: account.credits - count}}
    else
      {:error, :no_credits}
    end
  end

  @doc """
  Queue a PDU that must arrive: send what credits allow, keep the rest.

  Returns the packets to write now. What does not fit waits for
  `completed/2`, behind everything already waiting.
  """
  @spec push(t(), [binary()]) :: {[binary()], t()}
  def push(%__MODULE__{} = account, packets) do
    queue = Enum.reduce(packets, account.queue, &:queue.in/2)
    drain(%{account | queue: queue})
  end

  @doc """
  Take back the credits a Number of Completed Packets event returned.

  Returns the queued packets those credits let through, oldest first. The
  clamp to the allowance is for a controller that acknowledges more than it
  was given, which would otherwise mint credits out of thin air.
  """
  @spec completed(t(), non_neg_integer()) :: {[binary()], t()}
  def completed(%__MODULE__{} = account, returned) do
    drain(%{account | credits: min(account.credits + returned, account.total)})
  end

  @doc """
  The connection is gone: full allowance back, queue emptied.

  The controller frees a dead link's buffers without acknowledging them, so
  waiting for completions that will never come leaks credits until nothing
  can be sent at all. The queued fragments are for a handle that no longer
  exists and sending them would be an error, so they go too.
  """
  @spec disconnected(t()) :: t()
  def disconnected(%__MODULE__{} = account) do
    %{account | credits: account.total, queue: :queue.new()}
  end

  @doc "How many packets are waiting. For the curious and the diagnostics screen."
  @spec queued(t()) :: non_neg_integer()
  def queued(%__MODULE__{} = account), do: :queue.len(account.queue)

  defp drain(account), do: drain(account, [])

  defp drain(%{credits: 0} = account, acc), do: {Enum.reverse(acc), account}

  defp drain(account, acc) do
    case :queue.out(account.queue) do
      {{:value, packet}, rest} ->
        drain(%{account | queue: rest, credits: account.credits - 1}, [packet | acc])

      {:empty, _queue} ->
        {Enum.reverse(acc), account}
    end
  end
end
