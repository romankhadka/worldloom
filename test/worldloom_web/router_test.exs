defmodule WorldloomWeb.RouterTest do
  use ExUnit.Case, async: true

  test "normal test builds do not expose the deterministic acceptance route" do
    for path <- ["/__e2e__/events/late", "/__e2e__/scenes/balanced"] do
      assert :error ==
               Phoenix.Router.route_info(
                 WorldloomWeb.Router,
                 "POST",
                 path,
                 "localhost"
               )
    end
  end
end
