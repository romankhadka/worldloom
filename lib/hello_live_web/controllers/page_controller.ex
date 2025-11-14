defmodule HelloLiveWeb.PageController do
  use HelloLiveWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
