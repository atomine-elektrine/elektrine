defmodule Mix.Tasks.Elektrine.Dns.EnsureProfileWildcard do
  use Mix.Task

  @shortdoc "Ensure the *.<profile-base> wildcard DNS catch-all records exist"

  @moduledoc """
  Ensures a proxied wildcard record (`*.<base>`) exists in every configured
  profile base-domain zone, so every built-in profile subdomain resolves to the
  edge even when the user never provisioned their own built-in zone.

  Idempotent. Safe to run repeatedly.

      mix elektrine.dns.ensure_profile_wildcard

  In a release (no Mix), call the underlying function from a remote console
  instead:

      Elektrine.DNS.ensure_profile_subdomain_wildcards()
  """

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    Elektrine.DNS.ensure_profile_subdomain_wildcards()
    |> Enum.each(fn {domain, result} ->
      Mix.shell().info("#{domain}: #{inspect(result)}")
    end)
  end
end
