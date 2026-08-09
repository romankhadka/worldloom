defmodule WorldloomWeb.RouterTest do
  use ExUnit.Case, async: true

  test "normal test builds do not expose the deterministic acceptance route" do
    assert :error ==
             Phoenix.Router.route_info(
               WorldloomWeb.Router,
               "POST",
               "/__e2e__/events/late",
               "localhost"
             )
  end
end
