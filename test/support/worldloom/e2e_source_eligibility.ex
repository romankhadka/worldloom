defmodule Worldloom.E2ESourceEligibility do
  @moduledoc false

  @application :worldloom
  @config_key :e2e_source_eligibility
  @sources [:wikimedia, :usgs, :open_meteo, :bluesky, :ripe_ris, :solana, :drand]

  @spec enable_all() :: :ok
  def enable_all do
    Application.put_env(@application, @config_key, Map.new(@sources, &{&1, true}))
  end

  @spec current(map()) :: map()
  def current(configured_eligibility) when is_map(configured_eligibility) do
    Application.get_env(@application, @config_key, configured_eligibility)
  end
end
