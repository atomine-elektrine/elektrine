defmodule Elektrine.Repo do
  use Ecto.Repo,
    otp_app: :elektrine,
    adapter: Ecto.Adapters.Postgres
end
