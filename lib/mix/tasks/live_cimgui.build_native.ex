defmodule Mix.Tasks.LiveCimgui.BuildNative do
  @shortdoc "Builds the native host executable into priv/native"

  @moduledoc """
  Builds `priv/native/live_cimgui_host` with the same Zig compiler that Zigler
  uses for the NIF.

      mix live_cimgui.build_native [--force]

  Compiler resolution order (documented in `docs/TESTING.md`):

    1. `ZIG` in the environment,
    2. Zigler's own cache: `~/.cache/zigler/zig-<arch>-<os>-<version>/zig`,
    3. `zig` on `PATH`.

  The compiler version is checked against the version Zigler requires
  (`Zigler.MixProject.zig_version/0`), because a mismatch would produce a NIF and
  a host built by different toolchains.

  The build is incremental: the host is rebuilt only when a source file, the
  build script, or a vendored upstream file is newer than the installed binary,
  unless `--force` is given. Zig's own cache lives under `_build/` so the source
  tree stays clean.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("compile", [])

    {opts, _rest} = OptionParser.parse!(args, strict: [force: :boolean])
    root = File.cwd!()
    host_dir = Path.join([root, "native", "host"])
    unless File.dir?(host_dir), do: Mix.raise("native host sources are missing at #{host_dir}")

    zig = zig_path(root)
    check_zig_version!(zig)
    targets = install_targets(root)

    if Keyword.get(opts, :force, false) or Enum.any?(targets, &stale?(host_dir, &1)) do
      Mix.shell().info("building #{Path.relative_to_cwd(List.first(targets))} with #{zig}")
      run_zig!(zig, host_dir, root, targets)
    else
      Mix.shell().info("#{Path.relative_to_cwd(List.first(targets))} is up to date")
    end
  end

  @doc """
  Every path the built host is installed to, in order.

  The **source tree** copy is canonical: `mix compile` copies `priv/` into
  `_build/<env>/lib/live_cimgui/priv`, so a stale file left there silently
  replaces a freshly built one. Writing the build output there keeps one source
  of truth. The **application directory** copy is what a running node resolves
  through `LiveCimgui.Native.host_executable/0`; it is written too so that a
  build is usable immediately, without waiting for the next `mix compile`.
  """
  @spec install_targets(String.t()) :: [String.t()]
  def install_targets(root) do
    source = Path.join([root, "priv", "native", "live_cimgui_host"])
    runtime = Path.join([Application.app_dir(:live_cimgui), "priv", "native", "live_cimgui_host"])
    Enum.uniq([source, runtime])
  end

  @doc "Absolute path of the Zig compiler this project uses."
  @spec zig_path(String.t()) :: String.t()
  def zig_path(root) do
    version = zigler_zig_version()

    candidates =
      [
        System.get_env("ZIG"),
        Path.expand("~/.cache/zigler/zig-#{arch()}-#{os()}-#{version}/zig", root),
        System.find_executable("zig")
      ]
      |> Enum.reject(&is_nil/1)

    case Enum.find(candidates, &File.exists?/1) do
      nil ->
        Mix.raise("""
        no Zig compiler found. Install Zig #{version} (see docs/TESTING.md) or set ZIG=/path/to/zig.
        """)

      path ->
        path
    end
  end

  @doc "The Zig version Zigler requires for the NIF."
  @spec zigler_zig_version() :: String.t()
  def zigler_zig_version do
    case System.cmd(
           "sed",
           ["-n", ~s{s/ *def zig_version, do: "\\(.*\\)"/\\1/p}, deps_path("zigler")],
           stderr_to_stdout: true
         ) do
      {version, 0} ->
        case String.trim(version) do
          "" -> Mix.raise("cannot read the Zig version pin from deps/zigler/mix.exs")
          trimmed -> trimmed
        end

      {output, _status} ->
        Mix.raise("cannot read the Zig version pin from deps/zigler/mix.exs: #{output}")
    end
  end

  defp deps_path(app), do: Path.join([File.cwd!(), "deps", app, "mix.exs"])

  defp check_zig_version!(zig) do
    expected = zigler_zig_version()

    case System.cmd(zig, ["version"], stderr_to_stdout: true) do
      {version, 0} ->
        actual = String.trim(version)

        if actual != expected do
          Mix.raise("""
          #{zig} is Zig #{actual}, but Zigler (and therefore the NIF) requires Zig #{expected}.
          Install the pinned compiler or set ZIG to it; mixing versions would build the NIF and the
          host with different toolchains.
          """)
        end

      {output, status} ->
        Mix.raise("cannot run #{zig} version (exit #{status}): #{output}")
    end
  end

  defp stale?(host_dir, target) do
    case File.stat(target, time: :posix) do
      {:ok, %{mtime: binary_mtime}} ->
        (host_sources(host_dir) ++ vendor_sources(host_dir))
        |> Enum.any?(&newer_than?(&1, binary_mtime))

      _ ->
        true
    end
  end

  defp newer_than?(path, binary_mtime) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime > binary_mtime
      _ -> false
    end
  end

  defp host_sources(host_dir) do
    Path.wildcard(Path.join([host_dir, "**", "*.zig"])) ++
      [Path.join(host_dir, "build.zig")] ++ Path.wildcard(Path.join([host_dir, "src", "*.cpp"]))
  end

  defp vendor_sources(host_dir) do
    Path.wildcard(Path.join([host_dir, "..", "vendor", "cimgui", "**", "*.{cpp,h}"]))
  end

  # Installs the freshly built host next to the previous one and renames it into
  # place: a running host cannot be overwritten in place, and a rename is atomic.
  defp install!(built, target) do
    staging = target <> ".new"
    File.cp!(built, staging)
    File.chmod!(staging, 0o755)
    File.rename!(staging, target)
  end

  defp run_zig!(zig, host_dir, root, targets) do
    cache_dir = Path.join([root, "_build", to_string(Mix.env()), "zig-host-cache"])

    args = [
      "build",
      "--release=safe",
      "--prefix",
      root,
      "--cache-dir",
      cache_dir,
      "--global-cache-dir",
      Path.expand("~/.cache/zig")
    ]

    case System.cmd(zig, args, cd: host_dir, stderr_to_stdout: true) do
      {output, 0} ->
        built = Path.join([root, "bin", "live_cimgui_host"])

        Enum.each(targets, fn target ->
          File.mkdir_p!(Path.dirname(target))
          install!(built, target)
          Mix.shell().info("installed #{Path.relative_to_cwd(target)}")
        end)

        if String.trim(output) != "", do: Mix.shell().info(String.trim(output))

      {output, status} ->
        Mix.raise("zig build failed (exit #{status}):\n#{output}")
    end
  end

  defp arch do
    case :erlang.system_info(:system_architecture) |> List.to_string() do
      "x86_64" <> _ -> "x86_64"
      arch -> arch
    end
  end

  defp os do
    case :os.type() do
      {:unix, :linux} -> "linux"
      {:unix, :darwin} -> "macos"
      {:win32, _} -> "windows"
      other -> other |> Tuple.to_list() |> Enum.join("-")
    end
  end
end
