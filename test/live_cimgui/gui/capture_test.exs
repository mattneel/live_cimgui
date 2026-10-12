defmodule LiveCimgui.Gui.CaptureView do
  @moduledoc false
  # View used by the framebuffer capture tests: a title, a label, a keyed list of
  # editors, and a button. Small enough that every pixel the native window shows
  # can be traced back to a node this module declared.

  use LiveCimgui.View
  import LiveCimgui.UI

  def mount(_params, _session, socket) do
    {:ok, assign(socket, rows: [%{key: "alpha", incarnation: 1, text: "Alpha"}])}
  end

  def render(assigns) do
    column([
      text("capture view"),
      input("draft", "draft text", label: "draft:"),
      keyed(
        "rows",
        Enum.map(assigns.rows, fn row ->
          {row.key, row.incarnation, input("editor/" <> row.key, row.text, label: row.key)}
        end)
      ),
      button("act", "Act")
    ])
  end

  def handle_event(_id, _params, socket), do: {:noreply, socket}

  def handle_info({:add_row, row}, socket),
    do: {:noreply, assign(socket, :rows, socket.assigns.rows ++ [row])}

  def handle_info(_message, socket), do: {:noreply, socket}
end

defmodule LiveCimgui.Gui.CaptureTest do
  @moduledoc """
  Pixel-level GUI acceptance: the window is captured from its own framebuffer
  (`glReadPixels` in the native host, immediately before the buffer swap) and the
  captured image is asserted on.

  This is what makes "the native window shows what Elixir described" checkable
  without a human looking at it. It is also the only way to get pixels out of a
  window in this environment, which has no window manager and therefore no
  screenshot tool that can see this GL surface (see `docs/TESTING.md`).
  """

  use ExUnit.Case, async: false

  import LiveCimgui.GuiHarness

  alias LiveCimgui.HostManager

  @moduletag :gui
  @moduletag timeout: 180_000

  @window_width 940
  @window_height 620

  defp start_view(opts \\ []) do
    child =
      {HostManager,
       [
         view: LiveCimgui.Gui.CaptureView,
         params: %{},
         session: %{},
         title: "live_cimgui capture",
         width: Keyword.get(opts, :width, @window_width),
         height: Keyword.get(opts, :height, @window_height),
         restart_limit: 3,
         restart_window_ms: 5_000
       ]}

    {:ok, manager} = DynamicSupervisor.start_child(LiveCimgui.HostSupervisor, child)

    on_exit(fn ->
      if Process.alive?(manager), do: HostManager.close(manager)
    end)

    wait_until(fn -> HostManager.status(manager).ready end, "the native host never became ready")
    wait_until(fn -> HostManager.status(manager).view_pid != nil end, "the view never started")
    settle(manager)
    manager
  end

  @tag :tmp_dir
  test "a captured frame is the window: title bar, text pixels, and geometry", %{tmp_dir: tmp_dir} do
    manager = start_view()
    image = capture!(manager, Path.join(tmp_dir, "frame.ppm"))

    diagnostics = HostManager.status(manager).diagnostics

    # The capture contains exactly the window's drawable area: logical size
    # times the display's framebuffer scale (1.0 here, 2.0 on a HiDPI display).
    assert image.width == round(diagnostics.window_width * diagnostics.framebuffer_scale)
    assert image.height == round(diagnostics.window_height * diagnostics.framebuffer_scale)

    # The panel is the window: every pixel of the client area is panel, none of
    # it the clear colour behind it (which is what an inset or a stale size
    # leaves behind).
    assert clear_pixels(image) == []

    # A real Dear ImGui frame is not a flat fill: the widget frames and the
    # glyphs give more than one colour, and text is drawn (near-white pixels).
    assert image.distinct_colors > 4
    assert image.bright_pixels > 200

    assert image
           |> text_region_pixels()
           |> Enum.count(fn {r, g, b} -> div(r + g + b, 3) > 180 end) > 100
  end

  @tag :tmp_dir
  test "the panel follows the window size, not a constant", %{tmp_dir: tmp_dir} do
    # A window that is not the default size: the panel must fill *this* client
    # area, which is what makes the layout correct after a resize or on a
    # different display.
    manager = start_view(width: 1_024, height: 768)
    image = capture!(manager, Path.join(tmp_dir, "resized.ppm"))
    diagnostics = HostManager.status(manager).diagnostics

    assert diagnostics.window_width == 1_024
    assert diagnostics.window_height == 768
    assert image.width == 1_024
    assert image.height == 768
    assert clear_pixels(image) == []
  end

  @tag :tmp_dir
  test "pixels follow Elixir: a description change moves pixels, and only where it changed", %{
    tmp_dir: tmp_dir
  } do
    manager = start_view()
    before = capture!(manager, Path.join(tmp_dir, "before.ppm"))

    view_pid = HostManager.status(manager).view_pid
    send(view_pid, {:add_row, %{key: "bravo", incarnation: 1, text: "Bravo"}})

    wait_until(
      fn -> widget!(manager, "editor/bravo") end,
      "the new row never reached the native window"
    )

    settle(manager)

    after_add = capture!(manager, Path.join(tmp_dir, "after.ppm"))

    changed = pixel_diff(before, after_add)
    total = before.width * before.height

    # A whole new labelled editor appeared: hundreds of pixels must differ...
    assert changed > 500

    # ...but the window is the same window: everything else is untouched.
    assert changed < div(total, 20)
  end

  # The colour the host clears the framebuffer with before drawing. Anything of
  # this colour left in a capture is window area the panel failed to cover.
  @clear_colour {15, 18, 23}

  defp clear_pixels(image) do
    for x <- 0..(image.width - 1),
        y <- 0..(image.height - 1),
        pixel(image, x, y) == @clear_colour,
        do: {x, y}
  end

  defp text_region_pixels(image) do
    for x <- 2..(image.width - 2)//2, y <- 2..div(image.height, 3), do: pixel(image, x, y)
  end
end
