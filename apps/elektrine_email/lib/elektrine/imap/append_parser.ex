defmodule Elektrine.IMAP.AppendParser do
  @moduledoc false

  require Logger

  alias Elektrine.Email.AttachmentStorage
  alias Elektrine.Email.MimeBodyExtractor

  def parse_email_data(data) do
    message = Mail.Parsers.RFC2822.parse(data)

    headers =
      message.headers
      |> Enum.into(%{}, fn {key, value} -> {to_string(key), stringify_header_value(value)} end)
      |> Map.new(fn {key, value} -> {String.downcase(key), value} end)

    body = message.body || ""
    {headers, body, message}
  rescue
    e in MatchError ->
      Logger.error("Failed to parse email data. size=#{byte_size(data)} error=#{inspect(e)}")
      {%{"subject" => "(Parse Error)", "from" => "", "to" => ""}, data, nil}
  end

  def extract_text_body(_body, _headers, message \\ nil) do
    if message do
      MimeBodyExtractor.text_body(message)
    end
  end

  def extract_html_body(_body, _headers, message \\ nil) do
    if message do
      MimeBodyExtractor.html_body(message)
    end
  end

  def extract_attachments(_body, _headers, message \\ nil) do
    if message do
      extract_attachments_from_message(message)
    else
      %{}
    end
  end

  def validate_extracted_attachments(attachments) do
    allowed_types = [
      "image/jpeg",
      "image/png",
      "image/gif",
      "image/webp",
      "application/pdf",
      "application/msword",
      "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
      "application/vnd.ms-excel",
      "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      "text/plain"
    ]

    attachments
    |> Enum.filter(fn {_key, attachment} ->
      content_type = attachment["content_type"] || ""
      filename = attachment["filename"] || ""

      has_dangerous_ext =
        Enum.any?(dangerous_extensions(), fn ext ->
          String.ends_with?(String.downcase(filename), ext)
        end)

      type_allowed =
        Enum.any?(allowed_types, fn allowed -> String.starts_with?(content_type, allowed) end)

      cond do
        has_dangerous_ext ->
          Logger.warning("IMAP: Blocked dangerous attachment: #{filename} (#{content_type})")
          false

        not type_allowed ->
          Logger.warning(
            "IMAP: Blocked non-allowed attachment type: #{filename} (#{content_type})"
          )

          false

        true ->
          true
      end
    end)
    |> Enum.into(%{})
  end

  def replace_cid_with_data_urls(nil, _attachments), do: nil

  def replace_cid_with_data_urls(html_body, attachments) do
    Enum.reduce(attachments, html_body, fn {_attachment_id, attachment}, html ->
      replace_attachment_cid(html, attachment)
    end)
  end

  defp stringify_header_value(value) when is_binary(value), do: value

  defp stringify_header_value({name, email}) when is_binary(name) and is_binary(email) do
    if Elektrine.Strings.present?(name) do
      "#{name} <#{email}>"
    else
      email
    end
  end

  defp stringify_header_value({email}) when is_binary(email), do: email
  defp stringify_header_value([first | _rest]) when is_binary(first), do: first

  defp stringify_header_value([first | rest]) when is_tuple(first) do
    [first | rest] |> Enum.map_join(", ", &stringify_header_value/1)
  end

  defp stringify_header_value(value) when is_list(value), do: inspect(value)
  defp stringify_header_value(value) when is_tuple(value), do: inspect(value)
  defp stringify_header_value(value), do: to_string(value)

  defp extract_attachments_from_message(message) do
    {attachments, _counter} = walk_parts(message, %{}, 0)
    attachments
  end

  defp walk_parts(%Mail.Message{multipart: true, parts: parts}, acc, counter) do
    Enum.reduce(parts, {acc, counter}, fn part, {inner_acc, inner_counter} ->
      walk_parts(part, inner_acc, inner_counter)
    end)
  end

  defp walk_parts(%Mail.Message{} = message, acc, counter) do
    if Mail.Message.is_attachment?(message) do
      fallback_filename = "attachment_#{:rand.uniform(10_000)}"

      filename =
        message |> get_attachment_filename() |> sanitize_attachment_filename(fallback_filename)

      content_type = get_content_type(message)
      raw_body = message.body || ""

      attachment_map =
        %{
          "filename" => filename,
          "content_type" => content_type,
          "data" => Base.encode64(raw_body),
          "encoding" => "base64",
          "size" => if(message.body, do: byte_size(raw_body), else: 0)
        }
        |> maybe_put_content_id(message)

      {Map.put(acc, "#{counter}_#{filename}", attachment_map), counter + 1}
    else
      {acc, counter}
    end
  end

  defp maybe_put_content_id(attachment_map, message) do
    case Mail.Message.get_header(message, :content_id) do
      nil -> attachment_map
      cid -> Map.put(attachment_map, "content_id", String.trim(cid, "<>"))
    end
  end

  defp get_attachment_filename(message) do
    case Mail.Message.get_header(message, :content_disposition) do
      nil ->
        random_attachment_filename()

      disposition when is_list(disposition) ->
        Enum.find_value(disposition, fn
          {"filename", filename} when is_binary(filename) -> filename
          _ -> nil
        end) || random_attachment_filename()

      disposition when is_binary(disposition) ->
        case Regex.run(~r/filename[*]?=\s*"?([^";]+)"?/i, disposition) do
          [_, filename] -> filename
          _ -> random_attachment_filename()
        end

      _ ->
        random_attachment_filename()
    end
  end

  defp sanitize_attachment_filename(filename, fallback) when is_binary(filename) do
    case Elektrine.Email.Sanitizer.sanitize_utf8(filename) |> String.trim() do
      "" -> fallback
      sanitized -> sanitized
    end
  end

  defp sanitize_attachment_filename(_, fallback), do: fallback

  defp get_content_type(message) do
    case Mail.Message.get_content_type(message) do
      [type | _] when is_binary(type) -> type
      [type, _ | _] when is_binary(type) -> type
      _ -> "application/octet-stream"
    end
  end

  defp dangerous_extensions do
    [
      ".exe",
      ".bat",
      ".sh",
      ".cmd",
      ".com",
      ".scr",
      ".vbs",
      ".js",
      ".jar",
      ".app",
      ".dmg",
      ".apk",
      ".msi",
      ".php",
      ".py",
      ".rb",
      ".zip",
      ".tar",
      ".gz",
      ".7z",
      ".rar"
    ]
  end

  defp replace_attachment_cid(html, %{"content_id" => content_id} = attachment) do
    case attachment_data(attachment) do
      nil ->
        html

      data ->
        content_type = attachment["content_type"] || "application/octet-stream"
        clean_content_type = content_type |> String.split(";") |> List.first() |> String.trim()
        data_url = "data:#{clean_content_type};base64,#{Base.encode64(data)}"
        String.replace(html, "cid:#{content_id}", data_url)
    end
  end

  defp replace_attachment_cid(html, _attachment), do: html

  defp attachment_data(attachment) do
    raw_data =
      case attachment do
        %{"storage_type" => storage_type} when storage_type in ["local", "s3"] ->
          case AttachmentStorage.download_attachment(attachment) do
            {:ok, content} -> content
            {:error, _} -> attachment["data"]
          end

        _ ->
          attachment["data"]
      end

    decode_attachment_data(raw_data, attachment["encoding"])
  end

  defp decode_attachment_data(nil, _encoding), do: nil

  defp decode_attachment_data(raw_data, "base64") do
    case Base.decode64(raw_data, ignore: :whitespace) do
      {:ok, decoded} -> decoded
      :error -> raw_data
    end
  end

  defp decode_attachment_data(raw_data, _encoding), do: raw_data

  defp random_attachment_filename, do: "attachment_#{:rand.uniform(10_000)}"
end
