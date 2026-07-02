defmodule ElektrineWeb.API.RelationshipImportController do
  @moduledoc """
  Relationship import API for client compatibility.
  """
  use ElektrineWeb, :controller

  alias Elektrine.Accounts

  @max_import_upload_bytes 2_000_000

  action_fallback ElektrineWeb.FallbackController

  def follow_import(conn, params), do: create(conn, Map.put(params, "type", "follow"))
  def mutes_import(conn, params), do: create(conn, Map.put(params, "type", "mute"))
  def blocks_import(conn, params), do: create(conn, Map.put(params, "type", "block"))

  def create(conn, params) do
    user = conn.assigns[:current_user]

    with {:ok, identifiers} <- parse_identifiers(params),
         {:ok, type} <- normalize_type(Map.get(params, "type", params["list"])),
         {:ok, jobs} <- Accounts.import_relationships(user.id, type, identifiers) do
      json(conn, %{type: type, queued: length(jobs)})
    else
      {:error, :invalid_import_type} ->
        invalid_import_type(conn)

      {:error, :too_many_import_identifiers} ->
        invalid_upload(conn, "too many accounts in import")

      {:error, :import_upload_too_large} ->
        invalid_upload(conn, "import file is too large")

      {:error, :invalid_import_upload} ->
        invalid_upload(conn, "import file could not be read")
    end
  end

  defp normalize_type(nil), do: {:ok, "follow"}
  defp normalize_type(type) when type in ["follow", "follows", "following"], do: {:ok, "follow"}
  defp normalize_type(type) when type in ["mute", "mutes"], do: {:ok, "mute"}
  defp normalize_type(type) when type in ["block", "blocks"], do: {:ok, "block"}

  defp normalize_type(type) when type in ["domain_block", "domain_blocks", "domain"],
    do: {:ok, "domain_block"}

  defp normalize_type(type) when type in ["domains", "blocked_domains"], do: {:ok, "domain_block"}
  defp normalize_type(_), do: {:error, :invalid_import_type}

  defp parse_identifiers(%{"accounts" => accounts}) when is_list(accounts) do
    {:ok, Enum.filter(accounts, &is_binary/1)}
  end

  defp parse_identifiers(%{"accounts" => %Plug.Upload{} = upload}), do: parse_upload(upload)

  defp parse_identifiers(%{"accounts" => accounts}) when is_binary(accounts) do
    {:ok, split_accounts(accounts)}
  end

  defp parse_identifiers(%{"data" => %Plug.Upload{} = upload}), do: parse_upload(upload)

  defp parse_identifiers(%{"data" => data}) when is_binary(data), do: {:ok, split_accounts(data)}

  defp parse_identifiers(%{"csv" => %Plug.Upload{} = upload}), do: parse_upload(upload)

  defp parse_identifiers(%{"csv" => data}) when is_binary(data), do: {:ok, split_accounts(data)}

  defp parse_identifiers(%{"file" => %Plug.Upload{} = upload}), do: parse_upload(upload)

  defp parse_identifiers(_), do: {:ok, []}

  defp parse_upload(%Plug.Upload{path: path}) when is_binary(path) do
    with {:ok, %File.Stat{size: size}} <- File.stat(path),
         :ok <- validate_upload_size(size),
         {:ok, data} <- File.read(path) do
      {:ok, split_accounts(data)}
    else
      {:error, :import_upload_too_large} -> {:error, :import_upload_too_large}
      _ -> {:error, :invalid_import_upload}
    end
  end

  defp parse_upload(_), do: {:error, :invalid_import_upload}

  defp validate_upload_size(size) when size <= @max_import_upload_bytes, do: :ok
  defp validate_upload_size(_), do: {:error, :import_upload_too_large}

  defp split_accounts(data) do
    data
    |> strip_utf8_bom()
    |> String.split(~r/\r\n|\n|\r/, trim: true)
    |> Enum.flat_map(&identifiers_from_line/1)
    |> Enum.map(&normalize_identifier/1)
    |> Enum.reject(&is_nil/1)
  end

  defp identifiers_from_line(line) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        []

      csv_header?(trimmed) ->
        []

      String.contains?(trimmed, ",") ->
        csv_identifiers(trimmed)

      true ->
        String.split(trimmed, ~r/\s+/, trim: true)
    end
  end

  defp csv_identifiers(line) do
    fields = csv_fields(line)

    cond do
      fields == [] ->
        []

      csv_header?(List.first(fields)) ->
        []

      Enum.any?(Enum.drop(fields, 1), &csv_metadata_field?/1) ->
        [List.first(fields)]

      true ->
        fields
    end
  end

  defp csv_fields(line) do
    ~r/"((?:[^"]|"")*)"|([^,]+)/
    |> Regex.scan(line)
    |> Enum.map(fn
      [_, quoted, ""] -> String.replace(quoted, ~s(""), ~s("))
      [_, "", unquoted] -> unquoted
      [_, value] -> value
    end)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_identifier(identifier) when is_binary(identifier) do
    identifier =
      identifier
      |> strip_utf8_bom()
      |> String.trim()
      |> String.trim_leading("acct:")
      |> String.trim_leading("@")

    cond do
      identifier == "" -> nil
      csv_header?(identifier) -> nil
      String.contains?(identifier, "@") -> identifier
      true -> identifier
    end
  end

  defp normalize_identifier(_), do: nil

  defp strip_utf8_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_utf8_bom(value), do: value

  defp csv_header?(line) when is_binary(line) do
    line
    |> String.downcase()
    |> String.trim()
    |> then(fn header ->
      header in ["account address", "account", "accounts", "domain", "domains"] or
        String.starts_with?(header, "account address,")
    end)
  end

  defp csv_header?(_), do: false

  defp csv_metadata_field?(field) when is_binary(field) do
    field
    |> String.downcase()
    |> String.trim()
    |> then(&(&1 in ["true", "false", "yes", "no", "0", "1"]))
  end

  defp csv_metadata_field?(_), do: false

  defp invalid_import_type(conn) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "type must be one of follows, mutes, blocks, or domain_blocks"})
  end

  defp invalid_upload(conn, message) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: message})
  end
end
