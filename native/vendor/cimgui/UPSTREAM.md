# Vendored upstream sources

These trees are copied verbatim from upstream and must not be edited. They are built by
`mix compile` through `native/host/build.zig` (host executable) — no network access is
required at build or run time.

## cimgui

- Repository: <https://github.com/cimgui/cimgui>
- Branch: `docking_inter`
- Commit: `125f397e0982fe9466eb0a162de547be5efec849`
- License: MIT — see `LICENSE`
- Retrieved with:
  ```sh
  git clone https://github.com/cimgui/cimgui.git
  git checkout 125f397e0982fe9466eb0a162de547be5efec849
  ```
- Files vendored: `cimgui.cpp`, `cimgui.h`, `cimconfig.h`, `README.md`, `LICENSE`.
- `cimgui.h` header comment records the ImGui revision it was generated from:
  `imgui.h file version "1.92.9b" 19291`.

## Dear ImGui

- Repository: <https://github.com/ocornut/imgui>
- Branch: `docking`
- Commit: `b48d1afbe8ee8b238e2961dc363a949dd7304e23` — the revision pinned by the cimgui
  submodule at the commit above, i.e. the revision `cimgui.h` corresponds to.
- Version macros in `imgui/imgui.h`: `IMGUI_VERSION "1.92.9b"`, `IMGUI_VERSION_NUM 19291`.
- License: MIT — see `imgui/LICENSE.txt`
- Retrieved with:
  ```sh
  git submodule update --init imgui   # inside the cimgui checkout above
  ```
- Files vendored: core (`imgui.cpp`, `imgui_draw.cpp`, `imgui_tables.cpp`,
  `imgui_widgets.cpp`, `imgui_demo.cpp`, `imgui.h`, `imgui_internal.h`,
  `imconfig.h`, `imstb_*.h`) and the two backends used by the host
  (`backends/imgui_impl_sdl2.{cpp,h}`, `backends/imgui_impl_opengl3.{cpp,h}`,
  `backends/imgui_impl_opengl3_loader.h`). `imgui_demo.cpp` is required because
  Dear ImGui defines the demo entry points there and `cimgui.cpp` references
  them, exactly as upstream's own builds do.
- Not vendored: examples, other backends, freetype and the other `misc/` extras.
