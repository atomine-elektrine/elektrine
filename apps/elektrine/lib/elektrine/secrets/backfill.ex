defmodule Elektrine.Secrets.Backfill do
  @moduledoc false

  alias Elektrine.Repo
  alias Elektrine.Secrets.EncryptedString

  @spec run(keyword()) :: %{updated: non_neg_integer(), scanned: non_neg_integer(), fields: map()}
  def run(opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, true)

    field_results =
      Enum.map(secret_fields(), fn field ->
        {field.name, backfill_field(field, dry_run?)}
      end)

    %{
      updated: total(field_results, :updated),
      scanned: total(field_results, :scanned),
      fields: Map.new(field_results)
    }
  end

  defp backfill_field(field, dry_run?) do
    if field[:update] == :actor_metadata_private_key do
      backfill_actor_metadata_private_key(field, dry_run?)
    else
      backfill_scalar_field(field, dry_run?)
    end
  end

  defp backfill_scalar_field(field, dry_run?) do
    rows = Repo.query!(select_sql(field), []).rows

    updated =
      if dry_run? do
        0
      else
        Enum.reduce(rows, 0, fn [id, plaintext], count ->
          case EncryptedString.encrypt(plaintext) do
            {:ok, encrypted} ->
              Repo.query!(update_sql(field), [encrypted, id])
              count + 1

            :error ->
              count
          end
        end)
      end

    %{scanned: length(rows), updated: updated}
  end

  defp backfill_actor_metadata_private_key(_field, dry_run?) do
    rows =
      Repo.query!(
        "SELECT id, metadata::text FROM activitypub_actors WHERE metadata::text LIKE '%private_key%'",
        []
      ).rows
      |> Enum.filter(fn [_id, metadata_text] ->
        metadata_text
        |> decode_json_map()
        |> Map.get("private_key")
        |> case do
          private_key when is_binary(private_key) -> not EncryptedString.encrypted?(private_key)
          _ -> false
        end
      end)

    updated =
      if dry_run? do
        0
      else
        Enum.reduce(rows, 0, fn [id, metadata_text], count ->
          encrypted_metadata =
            metadata_text
            |> decode_json_map()
            |> Map.update("private_key", nil, fn private_key ->
              case EncryptedString.encrypt(private_key) do
                {:ok, encrypted} -> encrypted
                :error -> private_key
              end
            end)

          Repo.query!(
            "UPDATE activitypub_actors SET metadata = $1, updated_at = NOW() WHERE id = $2",
            [Jason.encode!(encrypted_metadata), id]
          )

          count + 1
        end)
      end

    %{scanned: length(rows), updated: updated}
  end

  defp total(field_results, key) do
    Enum.reduce(field_results, 0, fn {_name, result}, acc -> acc + Map.fetch!(result, key) end)
  end

  defp select_sql(field) do
    "SELECT #{field.pk}, #{field.column} FROM #{field.table} WHERE #{field.column} IS NOT NULL AND #{field.column} NOT LIKE 'enc:v1:%'"
  end

  defp update_sql(field) do
    "UPDATE #{field.table} SET #{field.column} = $1, updated_at = NOW() WHERE #{field.pk} = $2"
  end

  defp decode_json_map(value) when is_binary(value) do
    case Jason.decode!(value) do
      decoded when is_map(decoded) -> decoded
      decoded when is_binary(decoded) -> Jason.decode!(decoded)
    end
  end

  defp secret_fields do
    [
      %{
        name: :users_activitypub_private_key,
        table: "users",
        pk: "id",
        column: "activitypub_private_key"
      },
      %{
        name: :users_bluesky_app_password,
        table: "users",
        pk: "id",
        column: "bluesky_app_password"
      },
      %{
        name: :signing_keys_private_key,
        table: "signing_keys",
        pk: "key_id",
        column: "private_key"
      },
      %{
        name: :email_custom_domains_dkim_private_key,
        table: "email_custom_domains",
        pk: "id",
        column: "dkim_private_key"
      },
      %{
        name: :activitypub_actors_metadata_private_key,
        update: :actor_metadata_private_key
      }
    ]
  end
end
