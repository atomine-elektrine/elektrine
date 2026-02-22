defmodule Elektrine.Email.VCard do
  @moduledoc "vCard parser and generator for CardDAV support.\nSupports vCard 3.0 (RFC 2426) and vCard 4.0 (RFC 6350).\n"
  alias Elektrine.Email.Contact
  @doc "Parse a vCard string into a map of contact fields.\n"
  def parse(vcard_string) when is_binary(vcard_string) do
    if String.contains?(String.upcase(vcard_string), "BEGIN:VCARD") do
      unfolded = unfold_lines(vcard_string)

      lines =
        String.split(unfolded, ~r/\r?\n/) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

      parsed_lines = Enum.map(lines, &parse_line/1)
      contact_map = build_contact_map(parsed_lines)
      {:ok, contact_map}
    else
      {:error, :invalid_vcard}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc "Generate a vCard string from a Contact struct or map.\n"
  def generate(%Contact{} = contact) do
    generate(Map.from_struct(contact))
  end

  def generate(contact) when is_map(contact) do
    version = Map.get(contact, :vcard_version, "3.0")
    uid = Map.get(contact, :uid) || generate_uid()
    fn_value = Map.get(contact, :formatted_name) || Map.get(contact, :name) || "Unknown"

    lines = [
      "BEGIN:VCARD",
      "VERSION:#{version}",
      "UID:#{uid}",
      "FN:#{escape_value(fn_value)}",
      build_n_property(contact)
    ]

    lines = maybe_add(lines, :nickname, contact, &"NICKNAME:#{escape_value(&1)}")
    lines = lines ++ build_email_properties(contact)
    lines = lines ++ build_tel_properties(contact)
    lines = lines ++ build_adr_properties(contact)
    lines = maybe_add(lines, :organization, contact, &"ORG:#{escape_value(&1)}")
    lines = maybe_add(lines, :title, contact, &"TITLE:#{escape_value(&1)}")
    lines = maybe_add(lines, :role, contact, &"ROLE:#{escape_value(&1)}")
    lines = maybe_add(lines, :notes, contact, &"NOTE:#{escape_value(&1)}")
    lines = lines ++ build_url_properties(contact)
    lines = maybe_add_date(lines, :birthday, contact, "BDAY")
    lines = maybe_add_date(lines, :anniversary, contact, "ANNIVERSARY")
    lines = maybe_add_categories(lines, contact)
    lines = lines ++ build_photo_property(contact)
    lines = maybe_add_geo(lines, contact)
    lines = lines ++ build_social_properties(contact)
    rev = Map.get(contact, :revision) || DateTime.utc_now()
    lines = lines ++ ["REV:#{format_datetime(rev)}"]
    lines = lines ++ ["END:VCARD"]
    folded = Enum.map(lines, &fold_line/1)
    {:ok, Enum.join(folded, "\r\n") <> "\r\n"}
  end

  @doc "Generate a unique UID for a vCard.\n"
  def generate_uid do
    uuid =
      :crypto.strong_rand_bytes(16)
      |> Base.encode16(case: :lower)
      |> String.replace(~r/(.{8})(.{4})(.{4})(.{4})(.{12})/, "\\1-\\2-\\3-\\4-\\5")

    "#{uuid}@elektrine.com"
  end

  defp maybe_add(lines, key, contact, formatter) do
    case Map.get(contact, key) do
      nil -> lines
      "" -> lines
      value -> lines ++ [formatter.(value)]
    end
  end

  defp maybe_add_date(lines, key, contact, prop_name) do
    case Map.get(contact, key) do
      nil -> lines
      date -> lines ++ ["#{prop_name}:#{format_date(date)}"]
    end
  end

  defp maybe_add_categories(lines, contact) do
    case Map.get(contact, :categories, []) do
      [] -> lines
      categories -> lines ++ ["CATEGORIES:#{Enum.join(categories, ",")}"]
    end
  end

  defp maybe_add_geo(lines, contact) do
    case Map.get(contact, :geo) do
      nil ->
        lines

      geo ->
        lat = Map.get(geo, :latitude) || Map.get(geo, "latitude")
        lon = Map.get(geo, :longitude) || Map.get(geo, "longitude")

        if lat && lon do
          lines ++ ["GEO:#{lat};#{lon}"]
        else
          lines
        end
    end
  end

  defp unfold_lines(text) do
    text |> String.replace(~r/\r?\n[ \t]/, "")
  end

  defp parse_line(line) do
    case String.split(line, ":", parts: 2) do
      [property_part, value] ->
        {property, params} = parse_property_and_params(property_part)
        {property, params, value}

      [_property_only] ->
        {line, %{}, ""}
    end
  end

  defp parse_property_and_params(property_part) do
    parts = String.split(property_part, ";")
    property = List.first(parts) |> String.upcase()
    params = parts |> Enum.drop(1) |> Enum.map(&parse_param/1) |> Map.new()
    {property, params}
  end

  defp parse_param(param_str) do
    case String.split(param_str, "=", parts: 2) do
      [key, value] -> {String.upcase(key), value}
      [key] -> {String.upcase(key), true}
    end
  end

  defp build_contact_map(parsed_lines) do
    Enum.reduce(parsed_lines, %{}, fn {property, params, value}, acc ->
      case property do
        "VERSION" ->
          Map.put(acc, :vcard_version, value)

        "UID" ->
          Map.put(acc, :uid, value)

        "FN" ->
          Map.put(acc, :formatted_name, unescape_value(value))

        "N" ->
          parse_n_property(value, acc)

        "NICKNAME" ->
          Map.put(acc, :nickname, unescape_value(value))

        "EMAIL" ->
          add_to_list(acc, :emails, parse_email(value, params))

        "TEL" ->
          add_to_list(acc, :phones, parse_tel(value, params))

        "ADR" ->
          add_to_list(acc, :addresses, parse_adr(value, params))

        "ORG" ->
          Map.put(acc, :organization, unescape_value(value))

        "TITLE" ->
          Map.put(acc, :title, unescape_value(value))

        "ROLE" ->
          Map.put(acc, :role, unescape_value(value))

        "NOTE" ->
          Map.put(acc, :notes, unescape_value(value))

        "URL" ->
          add_to_list(acc, :urls, parse_url(value, params))

        "BDAY" ->
          Map.put(acc, :birthday, parse_date(value))

        "ANNIVERSARY" ->
          Map.put(acc, :anniversary, parse_date(value))

        "CATEGORIES" ->
          categories = String.split(value, ",") |> Enum.map(&String.trim/1)
          Map.put(acc, :categories, categories)

        "PHOTO" ->
          parse_photo(value, params, acc)

        "GEO" ->
          parse_geo(value, acc)

        "X-SOCIALPROFILE" ->
          add_to_list(acc, :social_profiles, parse_social(value, params))

        "REV" ->
          Map.put(acc, :revision, parse_datetime(value))

        _ ->
          acc
      end
    end)
  end

  defp parse_n_property(value, acc) do
    parts = String.split(value, ";") |> Enum.map(&unescape_value/1)

    acc
    |> Map.put(:last_name, Enum.at(parts, 0))
    |> Map.put(:first_name, Enum.at(parts, 1))
    |> Map.put(:middle_name, Enum.at(parts, 2))
    |> Map.put(:prefix, Enum.at(parts, 3))
    |> Map.put(:suffix, Enum.at(parts, 4))
  end

  defp parse_email(value, params) do
    type = get_type(params, "other")
    pref = Map.has_key?(params, "PREF") || Map.get(params, "TYPE", "") =~ ~r/pref/i
    %{"type" => type, "value" => unescape_value(value), "primary" => pref}
  end

  defp parse_tel(value, params) do
    type = get_type(params, "other")
    pref = Map.has_key?(params, "PREF") || Map.get(params, "TYPE", "") =~ ~r/pref/i
    %{"type" => type, "value" => unescape_value(value), "primary" => pref}
  end

  defp parse_adr(value, params) do
    parts = String.split(value, ";") |> Enum.map(&unescape_value/1)
    type = get_type(params, "other")

    %{
      "type" => type,
      "pobox" => Enum.at(parts, 0),
      "extended" => Enum.at(parts, 1),
      "street" => Enum.at(parts, 2),
      "city" => Enum.at(parts, 3),
      "region" => Enum.at(parts, 4),
      "postal_code" => Enum.at(parts, 5),
      "country" => Enum.at(parts, 6)
    }
  end

  defp parse_url(value, params) do
    type = get_type(params, "other")
    %{"type" => type, "value" => unescape_value(value)}
  end

  defp parse_social(value, params) do
    type = Map.get(params, "TYPE", "other") |> String.downcase()
    %{"type" => type, "value" => unescape_value(value)}
  end

  defp parse_photo(value, params, acc) do
    encoding = Map.get(params, "ENCODING", "")
    type = Map.get(params, "TYPE", Map.get(params, "MEDIATYPE", ""))

    cond do
      String.upcase(encoding) == "B" || String.upcase(encoding) == "BASE64" ->
        acc
        |> Map.put(:photo_type, "base64")
        |> Map.put(:photo_data, value)
        |> Map.put(:photo_content_type, normalize_photo_type(type))

      String.starts_with?(value, "http") ->
        acc |> Map.put(:photo_type, "url") |> Map.put(:photo_data, value)

      true ->
        acc
    end
  end

  defp normalize_photo_type(type) do
    upcase_type = String.upcase(type)

    cond do
      upcase_type == "JPEG" -> "image/jpeg"
      upcase_type == "PNG" -> "image/png"
      upcase_type == "GIF" -> "image/gif"
      String.starts_with?(upcase_type, "IMAGE/") -> String.downcase(upcase_type)
      true -> "image/jpeg"
    end
  end

  defp parse_geo(value, acc) do
    case String.split(value, ";") do
      [lat, lon] ->
        Map.put(acc, :geo, %{"latitude" => parse_float(lat), "longitude" => parse_float(lon)})

      _ ->
        acc
    end
  end

  defp parse_float(str) do
    case Float.parse(str) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp parse_date(value) do
    cleaned = String.replace(value, "-", "")

    if String.length(cleaned) == 8 do
      case Date.from_iso8601(String.slice(value, 0..9)) do
        {:ok, date} ->
          date

        _ ->
          year = String.slice(cleaned, 0..3)
          month = String.slice(cleaned, 4..5)
          day = String.slice(cleaned, 6..7)

          case Date.from_iso8601("#{year}-#{month}-#{day}") do
            {:ok, date} -> date
            _ -> nil
          end
      end
    else
      nil
    end
  end

  defp parse_datetime(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} ->
        dt

      _ ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, ndt} -> DateTime.from_naive!(ndt, "Etc/UTC")
          _ -> nil
        end
    end
  end

  defp get_type(params, default) do
    type_value = Map.get(params, "TYPE", default)

    types =
      String.split(type_value, ",") |> Enum.map(&String.trim/1) |> Enum.map(&String.downcase/1)

    Enum.find(types, default, fn t ->
      t in ["work", "home", "cell", "fax", "pager", "main", "other"]
    end)
  end

  defp add_to_list(map, key, value) do
    current = Map.get(map, key, [])
    Map.put(map, key, current ++ [value])
  end

  defp unescape_value(value) when is_binary(value) do
    value
    |> String.replace("\\n", "\n")
    |> String.replace("\\N", "\n")
    |> String.replace("\\,", ",")
    |> String.replace("\\;", ";")
    |> String.replace("\\\\", "\\")
  end

  defp unescape_value(nil) do
    nil
  end

  defp escape_value(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace(",", "\\,")
    |> String.replace(";", "\\;")
    |> String.replace("\n", "\\n")
  end

  defp escape_value(nil) do
    ""
  end

  defp build_n_property(contact) do
    family = Map.get(contact, :last_name, "")
    given = Map.get(contact, :first_name, "")
    additional = Map.get(contact, :middle_name, "")
    prefix = Map.get(contact, :prefix, "")
    suffix = Map.get(contact, :suffix, "")

    {family, given} =
      if family == "" && given == "" do
        parse_name(Map.get(contact, :formatted_name) || Map.get(contact, :name) || "")
      else
        {family, given}
      end

    parts = [family, given, additional, prefix, suffix] |> Enum.map(&(escape_value(&1) || ""))
    "N:#{Enum.join(parts, ";")}"
  end

  defp parse_name(full_name) do
    parts = String.split(full_name, " ", parts: 2)

    case parts do
      [first, last] -> {last, first}
      [single] -> {"", single}
      [] -> {"", ""}
    end
  end

  defp build_email_properties(contact) do
    emails = Map.get(contact, :emails, [])
    single_email = Map.get(contact, :email)

    emails =
      if emails == [] && single_email do
        [%{"type" => "work", "value" => single_email, "primary" => true}]
      else
        emails
      end

    Enum.map(emails, fn email ->
      type = Map.get(email, "type", Map.get(email, :type, "other"))
      value = Map.get(email, "value", Map.get(email, :value, ""))
      primary = Map.get(email, "primary", Map.get(email, :primary, false))
      params = ["TYPE=#{String.upcase(type)}"]

      params =
        if primary do
          params ++ ["PREF"]
        else
          params
        end

      "EMAIL;#{Enum.join(params, ";")}:#{value}"
    end)
  end

  defp build_tel_properties(contact) do
    phones = Map.get(contact, :phones, [])
    single_phone = Map.get(contact, :phone)

    phones =
      if phones == [] && single_phone do
        [%{"type" => "cell", "value" => single_phone, "primary" => true}]
      else
        phones
      end

    Enum.map(phones, fn phone ->
      type = Map.get(phone, "type", Map.get(phone, :type, "other"))
      value = Map.get(phone, "value", Map.get(phone, :value, ""))
      primary = Map.get(phone, "primary", Map.get(phone, :primary, false))
      params = ["TYPE=#{String.upcase(type)}"]

      params =
        if primary do
          params ++ ["PREF"]
        else
          params
        end

      "TEL;#{Enum.join(params, ";")}:#{value}"
    end)
  end

  defp build_adr_properties(contact) do
    addresses = Map.get(contact, :addresses, [])

    Enum.map(addresses, fn addr ->
      type = Map.get(addr, "type", Map.get(addr, :type, "other"))

      parts =
        [
          Map.get(addr, "pobox", Map.get(addr, :pobox, "")),
          Map.get(addr, "extended", Map.get(addr, :extended, "")),
          Map.get(addr, "street", Map.get(addr, :street, "")),
          Map.get(addr, "city", Map.get(addr, :city, "")),
          Map.get(addr, "region", Map.get(addr, :region, "")),
          Map.get(addr, "postal_code", Map.get(addr, :postal_code, "")),
          Map.get(addr, "country", Map.get(addr, :country, ""))
        ]
        |> Enum.map(&(escape_value(&1) || ""))

      "ADR;TYPE=#{String.upcase(type)}:#{Enum.join(parts, ";")}"
    end)
  end

  defp build_url_properties(contact) do
    urls = Map.get(contact, :urls, [])

    Enum.map(urls, fn url ->
      type = Map.get(url, "type", Map.get(url, :type, "other"))
      value = Map.get(url, "value", Map.get(url, :value, ""))
      "URL;TYPE=#{String.upcase(type)}:#{value}"
    end)
  end

  defp build_photo_property(contact) do
    photo_type = Map.get(contact, :photo_type)
    photo_data = Map.get(contact, :photo_data)
    content_type = Map.get(contact, :photo_content_type, "image/jpeg")

    cond do
      photo_type == "base64" && photo_data ->
        type_short = content_type |> String.split("/") |> List.last() |> String.upcase()
        ["PHOTO;ENCODING=B;TYPE=#{type_short}:#{photo_data}"]

      photo_type == "url" && photo_data ->
        ["PHOTO;VALUE=URI:#{photo_data}"]

      true ->
        []
    end
  end

  defp build_social_properties(contact) do
    social = Map.get(contact, :social_profiles, [])

    Enum.map(social, fn profile ->
      type = Map.get(profile, "type", Map.get(profile, :type, "other"))
      value = Map.get(profile, "value", Map.get(profile, :value, ""))
      "X-SOCIALPROFILE;TYPE=#{type}:#{value}"
    end)
  end

  defp format_date(%Date{} = date) do
    Date.to_iso8601(date)
  end

  defp format_date(_) do
    nil
  end

  defp format_datetime(%DateTime{} = dt) do
    dt
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601(:basic)
    |> String.replace("+00:00", "Z")
  end

  defp format_datetime(%NaiveDateTime{} = ndt) do
    ndt |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_iso8601(:basic) |> Kernel.<>("Z")
  end

  defp format_datetime(_) do
    nil
  end

  defp fold_line(line) when byte_size(line) <= 75 do
    line
  end

  defp fold_line(line) do
    do_fold(line, []) |> Enum.reverse() |> Enum.join("\r\n ")
  end

  defp do_fold(<<>>, acc) do
    acc
  end

  defp do_fold(line, []) do
    {chunk, rest} = safe_split(line, 75)
    do_fold(rest, [chunk])
  end

  defp do_fold(line, acc) do
    {chunk, rest} = safe_split(line, 74)
    do_fold(rest, [chunk | acc])
  end

  defp safe_split(binary, max_bytes) do
    if byte_size(binary) <= max_bytes do
      {binary, <<>>}
    else
      safe_point = find_safe_split(binary, max_bytes)
      {String.slice(binary, 0, safe_point), String.slice(binary, safe_point..-1//1)}
    end
  end

  defp find_safe_split(binary, max) do
    Enum.reduce_while(max..1//-1, max, fn pos, _acc ->
      chunk = :binary.part(binary, 0, pos)

      if String.valid?(chunk) do
        {:halt, pos}
      else
        {:cont, pos - 1}
      end
    end)
  end
end
