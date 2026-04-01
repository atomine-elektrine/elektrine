defmodule Elektrine.InternalAPI do
  @moduledoc false

  alias Elektrine.RuntimeEnv
  alias Elektrine.RuntimeSecrets

  def api_key(extra_env_names \\ []) when is_list(extra_env_names) do
    RuntimeEnv.first_present(extra_env_names ++ ["INTERNAL_API_KEY"]) ||
      RuntimeEnv.app_config(:internal_api_key) || RuntimeSecrets.internal_api_key()
  end
end
