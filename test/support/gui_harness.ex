defmodule LiveCimgui.GuiHarness do
  @moduledoc """
  Helpers shared by the GUI acceptance tests: they drive the *real* window
  through the test-only input path (`LiveCimgui.HostManager.inject/2`, which
  feeds Dear ImGui's own input queue) and read native state back through
  `LiveCimgui.HostManager.inspect_host/2`.

  Every wait is a bounded poll: no test asserts on wall-clock timing, and no
  test sleeps its way to a conclusion.
  """

  alias LiveCimgui.HostManager

  @poll_attempts 100
  @poll_interval_ms 50

  @doc """
  Polls `fun` until it returns a truthy value, else fails with `message`.

  Returns `:ok` for `true`, the value itself for anything else truthy.
  """
  def wait_until(fun, message, attempts \\ @poll_attempts) do
    poll(fun, fn -> raise ExUnit.AssertionError, message: message end, attempts)
  end

  defp poll(fun, on_timeout, 0) do
    case fun.() do
      falsy when falsy in [nil, false] -> on_timeout.()
      true -> :ok
      value -> value
    end
  end

  defp poll(fun, on_timeout, remaining) do
    case fun.() do
      falsy when falsy in [nil, false] ->
        Process.sleep(@poll_interval_ms)
        poll(fun, on_timeout, remaining - 1)

      true ->
        :ok

      value ->
        value
    end
  end

  @doc "Native widget state for `id` (raises when the host does not know it)."
  def widget!(manager, id) do
    {:ok, result} = HostManager.inspect_host(manager)

    case Enum.find(result.widgets, &(&1.id == id)) do
      nil ->
        raise ExUnit.AssertionError,
          message:
            "no native widget #{inspect(id)}; saw #{inspect(Enum.map(result.widgets, & &1.id))}"

      widget ->
        widget
    end
  end

  @inspect_timeout 15_000

  def inspect_host!(manager) do
    {:ok, result} =
      case HostManager.inspect_host(manager, @inspect_timeout) do
        {:ok, result} ->
          {:ok, result}

        other ->
          wait_until(
            fn -> match?({:ok, _}, HostManager.inspect_host(manager, @inspect_timeout)) end,
            "native inspect unavailable: #{inspect(other)}"
          )

          HostManager.inspect_host(manager, @inspect_timeout)
      end

    result
  end

  @doc """
  Asks the native host for a framebuffer capture and returns the parsed image.

  This is the test-only capture path: the host reads its own framebuffer with
  `glReadPixels` immediately before the buffer swap, so the file holds exactly
  the pixels Dear ImGui produced for one frame of *this* window — no compositor,
  no window manager, no screenshot tool. It exists because this environment has
  no way to screenshot a GL window (see `docs/TESTING.md`).
  """
  def capture!(manager, path) do
    File.rm(path)
    :ok = HostManager.inject(manager, {:test_input, :capture, path})

    wait_until(
      fn ->
        match?({:ok, %File.Stat{size: size}} when size > 0, File.stat(path))
      end,
      "the native host never wrote a capture to #{path}"
    )

    path |> File.read!() |> parse_ppm!()
  end

  @doc """
  Parses a binary PPM (P6) into `%{width:, height:, pixels:, distinct_colors:,
  bright_pixels:}`. Raises when the file is truncated or not a P6 image, so a
  half-written capture can never be mistaken for a rendered frame.
  """
  def parse_ppm!(<<"P6\n", rest::binary>>) do
    case String.split(rest, "\n255\n", parts: 2) do
      [header, pixels] ->
        [width, height] = header |> String.split(" ") |> Enum.map(&String.to_integer/1)
        expected = width * height * 3

        if byte_size(pixels) != expected do
          raise ExUnit.AssertionError,
            message:
              "PPM payload is #{byte_size(pixels)} bytes, expected #{expected} for #{width}x#{height}"
        end

        %{
          width: width,
          height: height,
          pixels: pixels,
          distinct_colors: pixels |> colors() |> MapSet.size(),
          bright_pixels: pixels |> count_where(&(&1 > 180))
        }

      _ ->
        raise ExUnit.AssertionError, message: "PPM header is not P6/<width> <height>/255"
    end
  end

  def parse_ppm!(other) do
    raise ExUnit.AssertionError,
      message:
        "capture is not a binary PPM (P6): #{inspect(binary_part(other, 0, min(byte_size(other), 16)))}"
  end

  defp colors(pixels), do: for(<<r::8, g::8, b::8 <- pixels>>, into: MapSet.new(), do: {r, g, b})

  defp count_where(pixels, fun) do
    for(<<r::8, g::8, b::8 <- pixels>>,
      reduce: 0,
      do: (acc -> if fun.(div(r + g + b, 3)), do: acc + 1, else: acc)
    )
  end

  @doc "Pixel at `{x, y}`, top-left origin, as PPM stores it."
  def pixel(%{width: width, pixels: pixels}, x, y) when x >= 0 and y >= 0 do
    <<r, g, b>> = binary_part(pixels, (y * width + x) * 3, 3)
    {r, g, b}
  end

  @doc """
  Number of pixels that differ between two captures of the same geometry. This
  is how the capture tests prove the image is *live*: a description change must
  move pixels, and an unrelated part of the window must not move.
  """
  def pixel_diff(%{pixels: left}, %{pixels: right}) when byte_size(left) == byte_size(right) do
    count_different(left, right, 0)
  end

  defp count_different(<<>>, <<>>, acc), do: acc

  defp count_different(<<l::24, lt::binary>>, <<r::24, rt::binary>>, acc) do
    count_different(lt, rt, if(l == r, do: acc, else: acc + 1))
  end

  @doc "Rectangle centre of an interactive item submitted in the last native frame."
  def rect_center!(manager, id) do
    result = inspect_host!(manager)

    case Enum.find(result.rects, &(&1.id == id)) do
      nil ->
        raise ExUnit.AssertionError,
          message:
            "no rectangle for #{inspect(id)}; saw #{inspect(Enum.map(result.rects, & &1.id))}"

      rect ->
        {min_x, min_y} = rect.min
        {max_x, max_y} = rect.max
        {(min_x + max_x) / 2, (min_y + max_y) / 2}
    end
  end

  @doc """
  Clicks the named widget with injected pointer input.

  Waits for the whole loop to settle unless `settle: false` is passed, which is
  what tests need while the view is deliberately stalled: a stalled view has an
  event in flight by definition, so it can never settle.
  """
  def click!(manager, id, opts \\ []) do
    {x, y} = Keyword.get(opts, :at) || rect_center!(manager, id)
    :ok = HostManager.inject(manager, {:test_input, :mouse, {:move, x, y}})
    :ok = HostManager.inject(manager, {:test_input, :mouse, {:click, x, y}})
    :ok = HostManager.inject(manager, {:test_input, :mouse, {:release, x, y}})
    if Keyword.get(opts, :settle, true), do: settle(manager), else: wait_for_native_input(manager)
  end

  @doc "Injects keyboard text into the currently focused editor."
  def type!(manager, text, opts \\ []) do
    :ok = HostManager.inject(manager, {:test_input, :text, text})
    if Keyword.get(opts, :settle, true), do: settle(manager), else: wait_for_native_input(manager)
  end

  @doc """
  Waits until the native host has consumed injected input, without requiring the
  view to be idle (used while a callback is intentionally stalled).
  """
  def wait_for_native_input(manager) do
    frames = inspect_host!(manager).frame_count

    wait_until(
      fn -> inspect_host!(manager).frame_count > frames + 1 end,
      "the native host never consumed injected input"
    )
  end

  @doc "Waits until a native widget's text contains `needle`."
  def wait_for_widget_text_contains(manager, id, needle) do
    wait_until(
      fn -> String.contains?(widget!(manager, id).text, needle) end,
      "widget #{inspect(id)} text never contained #{inspect(needle)} (saw #{inspect(widget!(manager, id).text)})"
    )
  end

  @doc "Injects one key press/release pair (ImGui key codes, named keys start at 512)."
  def key!(manager, keycode) do
    :ok = HostManager.inject(manager, {:test_input, :key, {keycode, true}})
    :ok = HostManager.inject(manager, {:test_input, :key, {keycode, false}})
    settle(manager)
  end

  @doc """
  Drags from `from` to `to` inside the focused editor, which is how a text
  selection is made with real pointer input.
  """
  def drag!(manager, {from_x, from_y}, {to_x, to_y}) do
    :ok = HostManager.inject(manager, {:test_input, :mouse, {:move, from_x, from_y}})
    :ok = HostManager.inject(manager, {:test_input, :mouse, {:click, from_x, from_y}})
    Process.sleep(60)
    :ok = HostManager.inject(manager, {:test_input, :mouse, {:move, to_x, to_y}})
    :ok = HostManager.inject(manager, {:test_input, :mouse, {:release, to_x, to_y}})
    settle(manager)
  end

  @doc """
  Waits until the whole loop is caught up:

    * the host has advanced at least one frame since the call started (so injected
      input has been consumed by Dear ImGui), and
    * the manager has nothing in flight and nothing queued, and
    * the host reports the newest published description as applied.
  """
  def settle(manager) do
    frames = inspect_host!(manager).frame_count

    wait_until(
      fn ->
        status = HostManager.status(manager)
        diagnostics = status.diagnostics

        status.in_flight == false and status.pending_events == 0 and
          status.pending_snapshot == false and
          diagnostics != %{} and
          Map.get(diagnostics, :applied_ui_revision, 0) == status.ui_revision and
          inspect_host!(manager).frame_count > frames
      end,
      "the view never settled (status: #{inspect(HostManager.status(manager) |> Map.take([:ui_revision, :in_flight, :pending_events, :pending_snapshot]))})"
    )
  end

  @doc """
  Ids of the interactive items in *render order*, taken from the rectangles the
  host records while drawing. Use this to assert layout order (a keyed reorder
  changes render order, not the order of native widget state).
  """
  def render_order(manager) do
    manager |> inspect_host!() |> Map.fetch!(:rects) |> Enum.map(& &1.id)
  end

  @doc "Subsequence of `render_order/1` for the row editors."
  def editor_order(manager) do
    manager |> render_order() |> Enum.filter(&String.starts_with?(&1, "editor/"))
  end

  @doc "Waits until a native widget's text equals `expected`."
  def wait_for_widget_text(manager, id, expected) do
    wait_until(
      fn -> widget!(manager, id).text == expected end,
      "widget #{inspect(id)} text never became #{inspect(expected)} (saw #{inspect(widget!(manager, id).text)})"
    )
  end

  @doc "Waits until a native widget reports an acknowledged revision at least `revision`."
  def wait_for_ack(manager, id, revision) do
    wait_until(
      fn ->
        widget = widget!(manager, id)
        widget.ack_revision >= revision
      end,
      "widget #{inspect(id)} never acknowledged revision #{revision}"
    )
  end

  @doc "Waits until native frame progress advances past `frames`."
  def wait_for_frames(manager, frames) do
    wait_until(
      fn -> inspect_host!(manager).frame_count > frames end,
      "native frame progress did not advance past #{frames}"
    )
  end

  @doc "Number of file descriptors and OS threads currently used by the BEAM."
  def resources do
    fds =
      case File.ls("/proc/self/fd") do
        {:ok, entries} -> length(entries)
        _ -> -1
      end

    threads =
      case File.read("/proc/self/status") do
        {:ok, contents} ->
          case Regex.run(~r/^Threads:\s+(\d+)$/m, contents) do
            [_, count] -> String.to_integer(count)
            _ -> -1
          end

        _ ->
          -1
      end

    %{fds: fds, threads: threads}
  end
end
