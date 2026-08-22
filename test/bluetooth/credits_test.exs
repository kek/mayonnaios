defmodule MayonnaiOS.Bluetooth.CreditsTest do
  use ExUnit.Case, async: true

  alias MayonnaiOS.Bluetooth.Credits

  # The scenario this module exists for is written out as its own test at the
  # bottom: the report map read that a Steam Deck timed out on, ten fragments
  # against eight buffers, which the old all-or-nothing send silently threw
  # away. Everything above it is the arithmetic that makes that case work
  # without breaking the property the old send was right about -- reports
  # drop rather than queue.

  defp packets(range), do: Enum.map(range, &<<&1>>)

  describe "offer/2, the droppable send" do
    test "spends credits when the whole PDU fits" do
      {:ok, to_send, account} = Credits.offer(Credits.new(8), packets(1..3))

      assert to_send == packets(1..3)
      assert account.credits == 5
    end

    test "refuses the whole PDU when it does not, spending nothing" do
      account = Credits.new(8)

      assert {:error, :no_credits} = Credits.offer(account, packets(1..9))
      assert account.credits == 8
    end

    test "refuses while anything is queued, even with credits in hand" do
      # A fragment slipped between a queued PDU's fragments corrupts the
      # far side's reassembly, so the rule is the queue or nothing.
      {_sent, account} = Credits.push(Credits.new(2), packets(1..3))

      assert {:error, :no_credits} = Credits.offer(account, packets([9]))
    end
  end

  describe "push/2, the queued send" do
    test "sends everything immediately when it fits" do
      {sent, account} = Credits.push(Credits.new(8), packets(1..3))

      assert sent == packets(1..3)
      assert Credits.queued(account) == 0
    end

    test "sends what fits and queues the rest, in order" do
      {sent, account} = Credits.push(Credits.new(2), packets(1..5))

      assert sent == packets(1..2)
      assert Credits.queued(account) == 3
      assert account.credits == 0
    end

    test "a second PDU waits behind the first" do
      {_sent, account} = Credits.push(Credits.new(2), packets(1..4))
      {sent, account} = Credits.push(account, packets(5..6))

      assert sent == []

      # An allowance of two means at most two packets are ever in flight,
      # so completions come back at most two at a time.
      {first, account} = Credits.completed(account, 2)
      {second, _account} = Credits.completed(account, 2)
      assert first ++ second == packets(3..6)
    end
  end

  describe "completed/2" do
    test "returns credits and lets the queue through, oldest first" do
      {_sent, account} = Credits.push(Credits.new(2), packets(1..5))

      {sent, account} = Credits.completed(account, 1)
      assert sent == packets([3])

      {sent, account} = Credits.completed(account, 2)
      assert sent == packets(4..5)
      assert account.credits == 0
    end

    test "credits above the allowance are not minted" do
      {sent, account} = Credits.completed(Credits.new(4), 100)

      assert sent == []
      assert account.credits == 4
    end
  end

  describe "disconnected/1" do
    test "restores the allowance and empties the queue" do
      {_sent, account} = Credits.push(Credits.new(3), packets(1..8))

      account = Credits.disconnected(account)

      assert account.credits == 3
      assert Credits.queued(account) == 0

      # Nothing left over from the dead link comes out later.
      {sent, _account} = Credits.completed(account, 3)
      assert sent == []
    end
  end

  test "the report map read that started this: ten fragments, eight buffers" do
    # A 246-byte ATT read response at MTU 247 is ten 27-byte fragments, and
    # the Realtek on this board holds eight. The host acknowledges packets a
    # few at a time; every returned buffer must carry the next fragment, and
    # the far side must see all ten, in order, exactly once.
    fragments = packets(1..10)

    {sent, account} = Credits.push(Credits.new(8), fragments)
    assert sent == packets(1..8)

    {sent_a, account} = Credits.completed(account, 1)
    {sent_b, account} = Credits.completed(account, 3)

    assert sent_a ++ sent_b == packets(9..10)
    assert Credits.queued(account) == 0

    # And the drop-only path is open again for the next report.
    assert {:ok, _report, _account} = Credits.offer(account, packets([99]))
  end
end
