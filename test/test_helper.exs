# GUI acceptance tests are excluded from the default run because they open a real
# window. Run them with `mix live_cimgui.gui_test` (see docs/TESTING.md).
ExUnit.start(exclude: [:gui])
