defmodule Elektrine.DNS.Query do
  @moduledoc false

  import Bitwise

  alias Elektrine.DNS
  alias Elektrine.DNS.Packet

  def answer(packet, opts \\ []) when is_binary(packet) do
    packet
    |> resolve(opts)
    |> Map.fetch!(:response)
  end

  def resolve(packet, opts \\ []) when is_binary(packet) do
    case Packet.decode_query(packet) do
      {:ok, query} ->
        if any_query?(query) do
          response =
            Packet.encode_response(query, [], :refused,
              transport: Keyword.get(opts, :transport),
              recursion_available: DNS.recursive_enabled?()
            )

          response_meta(query, response, nil, :refused, false)
        else
          route_query(packet, query, opts)
        end

      {:error, :format_error} ->
        %{
          response: Packet.encode_error(packet, :formerr),
          zone: nil,
          qname: nil,
          qtype: nil,
          rcode: :formerr,
          authoritative: false
        }

      _ ->
        %{
          response: Packet.encode_error(packet, :servfail),
          zone: nil,
          qname: nil,
          qtype: nil,
          rcode: :servfail,
          authoritative: false
        }
    end
  end

  defp route_query(packet, query, opts) do
    case fetch_zone(query.qname) do
      {:ok, zone} ->
        answer_for_zone(query, zone, opts)

      {:error, :not_authoritative} ->
        if query_recursion_desired?(packet) and DNS.recursive_enabled?() do
          response = Elektrine.DNS.Recursive.resolve(packet, opts)
          response_meta(query, response, nil, :noerror, false)
        else
          response =
            Packet.encode_response(query, [], :refused, transport: Keyword.get(opts, :transport))

          response_meta(query, response, nil, :refused, false)
        end

      {:error, :name_error, failed_query} ->
        response =
          Packet.encode_response(failed_query, [], :nxdomain,
            transport: Keyword.get(opts, :transport)
          )

        response_meta(failed_query, response, nil, :nxdomain, false)

      {:error, _, failed_query} ->
        response =
          Packet.encode_response(failed_query, [], :servfail,
            transport: Keyword.get(opts, :transport)
          )

        response_meta(failed_query, response, nil, :servfail, false)

      _ ->
        response =
          Packet.encode_response(query, [], :servfail, transport: Keyword.get(opts, :transport))

        response_meta(query, response, nil, :servfail, false)
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
        response =
          Packet.encode_response(query, records, :noerror,
            additional: additional,
            authoritative: true,
            transport: Keyword.get(opts, :transport)
          )

        response_meta(query, response, zone, :noerror, true)

      name_exists?(zone, query.qname) ->
        response =
          Packet.encode_response(query, [], :noerror,
            authority: authority,
            authoritative: true,
            transport: Keyword.get(opts, :transport)
          )

        response_meta(query, response, zone, :noerror, true)

      true ->
        response =
          Packet.encode_response(query, [], :nxdomain,
            authority: authority,
            authoritative: true,
            transport: Keyword.get(opts, :transport)
          )

        response_meta(query, response, zone, :nxdomain, true)
    end
  end

  defp response_meta(query, response, zone, rcode, authoritative) do
    %{
      response: response,
      zone: zone,
      qname: query.qname,
      qtype: query.qtype,
      rcode: rcode,
      authoritative: authoritative
    }
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
        cname_records = cname_records_for_name(zone, fqdn)

        cond do
          cname_records != [] ->
            cname_records

          name_exists?(zone, fqdn) ->
            []

          true ->
            wildcard_records_for_query(zone, fqdn, qtype)
        end
      end
    end
  end

  defp cname_records_for_name(zone, fqdn) do
    zone_records(zone)
    |> Enum.filter(fn record ->
      record_name(zone, record) == fqdn and normalize_type(record.type) == :cname
    end)
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
