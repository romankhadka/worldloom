defmodule WorldloomWeb.Presence do
  use Phoenix.Presence,
    otp_app: :worldloom,
    pubsub_server: Worldloom.PubSub

  @topic "worldloom:presence"

  @spec topic() :: String.t()
  def topic, do: @topic

  @spec viewer_count() :: non_neg_integer()
  def viewer_count, do: @topic |> list() |> map_size()
end
