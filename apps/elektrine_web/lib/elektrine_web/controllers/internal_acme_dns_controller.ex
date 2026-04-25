defmodule ElektrineWeb.InternalACMEDNSController do
  use ElektrineWeb, :controller

  alias Elektrine.DNS

  def add_txt(conn, %{"domain" => domain, "value" => value}) do
    with {:ok, normalized_domain} <- normalize_domain(domain),
         :ok <- validate_acme_challenge_name(normalized_domain),
         {:ok, zone} <- matching_zone(normalized_domain),
         {:ok, record_name} <- relative_record_name(normalized_domain, zone.domain),
         {:ok, record} <- create_txt_record(zone, record_name, value) do
      json(conn, %{record: %{id: record.id, zone_id: zone.id, name: record.name}})
    else
      {:error, :invalid_domain} -> bad_request(conn, "invalid_domain")
      {:error, :invalid_challenge_name} -> bad_request(conn, "invalid_challenge_name")
      {:error, :missing_zone} -> not_found(conn, "zone_not_found")
      {:error, changeset} -> unprocessable_entity(conn, changeset)
    end
  end

  def add_txt(conn, _params), do: bad_request(conn, "missing_domain_or_value")

  def remove_txt(conn, %{"domain" => domain, "value" => value}) do
    with {:ok, normalized_domain} <- normalize_domain(domain),
         :ok <- validate_acme_challenge_name(normalized_domain),
         {:ok, zone} <- matching_zone(normalized_domain),
         {:ok, record_name} <- relative_record_name(normalized_domain, zone.domain) do
      zone.records
      |> Enum.filter(&matching_txt_record?(&1, record_name, value))
      |> Enum.each(&DNS.delete_record/1)

      json(conn, %{removed: true})
    else
      {:error, :invalid_domain} -> bad_request(conn, "invalid_domain")
      {:error, :invalid_challenge_name} -> bad_request(conn, "invalid_challenge_name")
      {:error, :missing_zone} -> json(conn, %{removed: false})
    end
  end

  def remove_txt(conn, _params), do: bad_request(conn, "missing_domain_or_value")

  defp validate_acme_challenge_name("_acme-challenge." <> rest) when rest != "", do: :ok
  defp validate_acme_challenge_name(_), do: {:error, :invalid_challenge_name}

  defp create_txt_record(zone, name, value) do
    DNS.create_record(zone, %{
      "name" => name,
      "type" => "TXT",
      "ttl" => 60,
      "content" => to_string(value)
    })
  end

  defp matching_zone(domain) do
    domain
    |> candidate_domains()
    |> Enum.find_value(fn candidate ->
      case DNS.get_zone_by_domain(candidate) do
        %{id: _id} = zone -> {:ok, zone}
        nil -> nil
      end
    end)
    |> case do
      {:ok, zone} -> {:ok, zone}
      nil -> {:error, :missing_zone}
    end
  end

  defp candidate_domains(domain) do
    labels = String.split(domain, ".", trim: true)

    0..(length(labels) - 1)
    |> Enum.map(fn index -> labels |> Enum.drop(index) |> Enum.join(".") end)
  end

  defp relative_record_name(domain, zone_domain) do
    cond do
      domain == zone_domain ->
        {:ok, "@"}

      String.ends_with?(domain, "." <> zone_domain) ->
        {:ok, String.trim_trailing(domain, "." <> zone_domain)}

      true ->
        {:error, :invalid_domain}
    end
  end

  defp matching_txt_record?(record, name, value) do
    record.name == name and record.type == "TXT" and record.content == to_string(value)
  end

  defp normalize_domain(domain) when is_binary(domain) do
    domain =
      domain
      |> String.trim()
      |> String.trim_trailing(".")
      |> String.downcase()

    if domain != "" and String.match?(domain, ~r/^[a-z0-9_][a-z0-9._-]*[a-z0-9]$/) do
      {:ok, domain}
    else
      {:error, :invalid_domain}
    end
  end

  defp normalize_domain(_), do: {:error, :invalid_domain}

  defp bad_request(conn, code) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: code})
  end

  defp not_found(conn, code) do
    conn
    |> put_status(:not_found)
    |> json(%{error: code})
  end

  defp unprocessable_entity(conn, changeset) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "validation_failed", details: errors_on(changeset)})
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
