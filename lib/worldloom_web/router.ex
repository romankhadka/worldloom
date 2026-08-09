defmodule WorldloomWeb.Router do
  use WorldloomWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug WorldloomWeb.Plugs.AnonymousIdentity
    plug :fetch_live_flash
    plug :put_root_layout, html: {WorldloomWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", WorldloomWeb do
    pipe_through :browser

    live "/", WorldLive, :live
    live "/chapters", WorldLive, :archive
    live "/chapters/:date/:sequence", WorldLive, :chapter
    live "/about", WorldLive, :about
  end

  scope "/", WorldloomWeb do
    pipe_through :api

    get "/healthz", HealthController, :index
  end

  if Mix.env() == :test do
    scope "/__e2e__", WorldloomWeb do
      pipe_through :api

      post "/events/late", E2EController, :late
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", WorldloomWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:worldloom, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: WorldloomWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
