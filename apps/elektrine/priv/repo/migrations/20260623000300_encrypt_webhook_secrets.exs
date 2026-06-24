defmodule Elektrine.Repo.Migrations.EncryptWebhookSecrets do
  use Ecto.Migration

  import Ecto.Query

  alias Elektrine.Secrets.EncryptedString

  defmodule DeveloperWebhook do
    use Ecto.Schema

    schema "developer_webhooks" do
      field(:secret, :string)
    end
  end

  defmodule StaticSiteDeployment do
    use Ecto.Schema

    schema "static_site_deployments" do
      field(:webhook_secret, :string)
    end
  end

  def up do
    encrypt_secret_field(DeveloperWebhook, :secret)
    encrypt_secret_field(StaticSiteDeployment, :webhook_secret)
  end

  def down do
    decrypt_secret_field(StaticSiteDeployment, :webhook_secret)
    decrypt_secret_field(DeveloperWebhook, :secret)
  end

  defp encrypt_secret_field(schema, field) do
    repo().transaction(fn ->
      schema
      |> repo().all()
      |> Enum.each(fn row ->
        value = Map.get(row, field)

        if present?(value) do
          repo().update_all(
            from(r in schema, where: r.id == ^row.id),
            set: [{field, encrypted_secret!(value)}]
          )
        end
      end)
    end)
  end

  defp decrypt_secret_field(schema, field) do
    repo().transaction(fn ->
      schema
      |> repo().all()
      |> Enum.each(fn row ->
        value = Map.get(row, field)

        if present?(value) do
          repo().update_all(
            from(r in schema, where: r.id == ^row.id),
            set: [{field, plaintext_secret(value)}]
          )
        end
      end)
    end)
  end

  defp encrypted_secret!(value) when is_binary(value) do
    if EncryptedString.encrypted?(value) do
      value
    else
      case EncryptedString.encrypt(value) do
        {:ok, encrypted} -> encrypted
        :error -> raise("could not encrypt webhook secret")
      end
    end
  end

  defp plaintext_secret(value) when is_binary(value) do
    case EncryptedString.decrypt(value) do
      {:ok, plaintext} -> plaintext
      :error -> value
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
