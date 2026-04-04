defmodule Elektrine.Repo.Migrations.HashExportAndRegistrationTokens do
  use Ecto.Migration

  import Ecto.Query

  defmodule DataExport do
    use Ecto.Schema

    schema "data_exports" do
      field(:download_token, :string)
    end
  end

  defmodule RegistrationCheckout do
    use Ecto.Schema

    schema "registration_checkouts" do
      field(:lookup_token, :string)
    end
  end

  def up do
    flush()

    repo().transaction(fn ->
      repo().all(DataExport)
      |> Enum.each(fn export ->
        repo().update_all(
          from(e in DataExport, where: e.id == ^export.id),
          set: [download_token: hash_token(export.download_token)]
        )
      end)

      repo().all(RegistrationCheckout)
      |> Enum.each(fn checkout ->
        repo().update_all(
          from(c in RegistrationCheckout, where: c.id == ^checkout.id),
          set: [lookup_token: hash_token(checkout.lookup_token)]
        )
      end)
    end)
  end

  def down, do: :ok

  defp hash_token(token) when is_binary(token) do
    :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
  end

  defp hash_token(_), do: nil
end
