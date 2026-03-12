defmodule ElektrineWeb.Admin.CustomDomainsHTML do
  @moduledoc """
  View helpers and templates for admin custom domain inspection.
  """

  use ElektrineWeb, :html

  defdelegate custom_domains(assigns), to: ElektrineWeb.AdminHTML
end
