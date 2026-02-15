# Enable feature (Wallaby) tests only when explicitly requested, or in CI when
# chromedriver is available. If Wallaby fails to start, we fall back to skipping
# feature tests so the suite remains runnable in minimal environments.
enable_wallaby? =
  case System.get_env("ENABLE_WALLABY") do
    nil ->
      System.get_env("CI") in ["true", "1"] and not is_nil(System.find_executable("chromedriver"))

    value ->
      String.downcase(value) in ["true", "1"]
  end

enable_wallaby? =
  if enable_wallaby? do
    Application.put_env(:wallaby, :driver, Wallaby.Chrome)
    Application.put_env(:wallaby, :base_url, ElektrineWeb.Endpoint.url())
    # Timeline (and other pages) load async after LiveView connects; give CI
    # enough headroom to avoid flaky `assert_has` timeouts.
    Application.put_env(:wallaby, :max_wait_time, 20_000)

    case Application.ensure_all_started(:wallaby) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  else
    false
  end

ExUnit.start(exclude: if(enable_wallaby?, do: [], else: [:feature]))
Ecto.Adapters.SQL.Sandbox.mode(Elektrine.Repo, :manual)
