defmodule Elektrine.Accounts.BuiltInSubdomain do
  @moduledoc false

  @modes ~w(path platform external_dns)

  def modes, do: @modes

  def mode(%{built_in_subdomain_mode: mode}) when mode in @modes, do: mode
  def mode(_), do: "path"

  def hosted_by_platform?(user), do: mode(user) == "platform"
end
