defmodule Mix.Tasks.LiveCimgui.NativeTest do
  @shortdoc "Runs the native host's Zig unit tests"

  @moduledoc """
  Runs the host's Zig unit tests (`native/host/src/*.zig`) with the pinned Zig
  compiler:

      mix live_cimgui.native_test

  These tests are display-independent: protocol framing, scene identity and
  revision rules, and bounded-queue behaviour. GUI acceptance is a separate
  command (`mix live_cimgui.gui_test`).
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    zig = Mix.Tasks.LiveCimgui.BuildNative.zig_path(File.cwd!())
    host_dir = Path.join([File.cwd!(), "native", "host"])

    command_args =
      [
        "build",
        "test",
        "--summary",
        "all",
        "--cache-dir",
        Path.join([File.cwd!(), "_build", "zig-host-cache"])
      ] ++ args

    case System.cmd(zig, command_args, cd: host_dir, stderr_to_stdout: true) do
      {output, 0} ->
        Mix.shell().info(output)

      {output, status} ->
        Mix.shell().info(output)
        Mix.raise("native tests failed (exit #{status})")
    end
  end
end
