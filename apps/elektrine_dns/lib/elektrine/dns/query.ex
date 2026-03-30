defmodule Elektrine.DNS.Query do
  @moduledoc false

  import Bitwise

  alias Elektrine.DNS
  alias Elektrine.DNS.Packet

  def answer(packet, opts \\ []) when is_binary(packet) do
    case Packet.decode_query(packet) do
      {:ok, query} ->
        cond do
          any_query?(query) ->
            Packet.encode_response(query, [], :refused,
              transport: Keyword.get(opts, :transport),
              recursion_available: DNS.recursive_enabled?()
            )

          true ->
            route_query(packet, query, opts)
        end

      {:error, :format_error} ->
        Packet.encode_error(packet, :formerr)

      _ ->
        Packet.encode_error(packet, :servfail)
    end
  end

  defp route_query(packet, query, opts) do
    with {:ok, zone} <- fetch_zone(query.qname) do
      answer_for_zone(query, zone, opts)
    else
      {:error, :not_authoritative} ->
        if query_recursion_desired?(packet) and DNS.recursive_enabled?() do
          Elektrine.DNS.Recursive.resolve(packet, opts)
        else
          Packet.encode_response(query, [], :refused, transport: Keyword.get(opts, :transport))
        end

      {:error, :name_error, failed_query} ->
        Packet.encode_response(failed_query, [], :nxdomain,
          transport: Keyword.get(opts, :transport)
        )

      {:error, _, failed_query} ->
        Packet.encode_response(failed_query, [], :servfail,
          transport: Keyword.get(opts, :transport)
        )

      _ ->
        Packet.encode_response(query, [], :servfail, transport: Keyword.get(opts, :transport))
    end
  end

  defp query_recursion_desired?(<<_id::16, flags::16, _rest::binary>>),
    do: (flags &&& 0x0100) != 0

  defp query_recursion_desired?(_), do: false

  defp fetch_zone(qname) do
    qname = normalize_name(qname)

    qname
    |> candidate_domains()
    |> Enum.find_value(fn domain ->
      case DNS.ZoneCache.lookup(domain) do
        {:ok, zone} -> {:ok, zone}
        :error -> nil
      end
    end)
    |> case do
      nil -> {:error, :not_authoritative}
      result -> result
    end
  end

  defp answer_for_zone(query, zone, opts) do
    records = records_for_query(zone, query.qname, query.qtype)
    authority = [Elektrine.DNS.Zone.soa_record(zone)]
    additional = additional_records(zone, records)

    cond do
      records != [] ->
        Packet.encode_response(query, records, :noerror,
          additional: additional,
          authoritative: true,
          transport: Keyword.get(opts, :transport)
        )

      name_exists?(zone, query.qname) ->
        Packet.encode_response(query, [], :noerror,
          authority: authority,
          authoritative: true,
          transport: Keyword.get(opts, :transport)
        )

      true ->
        Packet.encode_response(query, [], :nxdomain,
          authority: authority,
          authoritative: true,
          transport: Keyword.get(opts, :transport)
        )
    end
  end

  defp records_for_query(zone, qname, qtype) do
    fqdn = normalize_name(qname)

    if qtype == :soa and fqdn == normalize_name(zone.domain) do
      [Elektrine.DNS.Zone.soa_record(zone)]
    else
      exact_records =
        zone_records(zone)
        |> Enum.filter(fn record ->
          record_name(zone, record) == fqdn and
            (qtype == :any or normalize_type(record.type) == qtype)
        end)

      if exact_records != [] do
        exact_records
      else
        if name_exists?(zone, fqdn) do
          []
        else
          wildcard_records_for_query(zone, fqdn, qtype)
        end
      end
    end
  end

  defp name_exists?(zone, qname) do
    fqdn = normalize_name(qname)
    Enum.any?(zone_records(zone), &(record_name(zone, &1) == fqdn))
  end

  defp zone_records(zone) do
    bootstrap = DNS.zone_onboarding_records(zone)
    persisted = zone.records || []
    bootstrap ++ persisted
  end

  defp additional_records(zone, answers) do
    targets =
      answers
      |> Enum.flat_map(fn
        %{type: type, content: content} when type in ["MX", "NS", "CNAME", :mx, :ns, :cname] ->
          [normalize_name(content)]

        %{type: type, value: value} when type in ["MX", "NS", "CNAME", :mx, :ns, :cname] ->
          [normalize_name(value)]

        _ ->
          []
      end)
      |> Enum.uniq()

    zone_records(zone)
    |> Enum.filter(fn record ->
      record_name(zone, record) in targets and normalize_type(record.type) in [:a, :aaaa]
    end)
  end

  defp record_name(_zone, %{host: host}), do: normalize_name(host)

  defp record_name(zone, %{name: name}) when is_binary(name) do
    zone_domain = normalize_name(zone.domain)
    normalized_name = normalize_name(name)

    cond do
      normalized_name in ["", "@"] ->
        zone_domain

      normalized_name == zone_domain ->
        zone_domain

      String.ends_with?(normalized_name, "." <> zone_domain) ->
        normalized_name

      true ->
        normalize_name(normalized_name <> "." <> zone.domain)
    end
  end

  defp candidate_domains(qname) do
    labels = String.split(qname, ".", trim: true)

    0..(length(labels) - 1)
    |> Enum.map(fn idx -> labels |> Enum.drop(idx) |> Enum.join(".") end)
  end

  defp wildcard_records_for_query(zone, fqdn, qtype) do
    wildcard_candidates(fqdn, zone.domain)
    |> Enum.find_value([], fn wildcard_name ->
      records =
        zone_records(zone)
        |> Enum.filter(fn record ->
          record_name(zone, record) == wildcard_name and
            (qtype == :any or normalize_type(record.type) == qtype)
        end)

      if records == [], do: nil, else: records
    end)
  end

  defp wildcard_candidates(fqdn, zone_domain) do
    qlabels = String.split(fqdn, ".", trim: true)
    zlabels = String.split(zone_domain, ".", trim: true)

    host_labels = Enum.take(qlabels, max(length(qlabels) - length(zlabels), 0))

    1..max(length(host_labels), 1)
    |> Enum.map(fn depth ->
      ["*" | Enum.drop(host_labels, depth)] ++ zlabels
    end)
    |> Enum.map(&Enum.join(&1, "."))
    |> Enum.uniq()
  end

  defp normalize_name(name) do
    name
    |> String.downcase()
    |> String.trim_trailing(".")
  end

  defp normalize_type(type) when is_binary(type),
    do: type |> String.downcase() |> String.to_atom()

  defp normalize_type(type), do: type

  defp any_query?(%{qtype: :any}), do: true
  defp any_query?(_query), do: false
end
