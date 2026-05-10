defmodule Elektrine.Email.MimeBodyExtractor do
  @moduledoc """
  Extracts displayable text and HTML bodies from parsed RFC822 messages.

  The `mail` library handles the common paths, but some desktop clients emit nested or
  differently-cased MIME structures that can parse successfully while `Mail.get_text/1` or
  `Mail.get_html/1` return nil. This module keeps the fast path and falls back to walking all
  non-attachment parts case-insensitively.
  """

  def text_body(message) do
    message
    |> mail_body(&Mail.get_text/1)
    |> first_present(fn -> find_part_body(message, "text/plain") end)
  end

  def html_body(message) do
    message
    |> mail_body(&Mail.get_html/1)
    |> first_present(fn -> find_part_body(message, "text/html") end)
  end

  defp mail_body(nil, _fun), do: nil

  defp mail_body(%Mail.Message{} = message, fun) when is_function(fun, 1) do
    case fun.(message) do
      %Mail.Message{body: body} = part ->
        if attachment?(part), do: nil, else: present_body(body)

      _ ->
        nil
    end
  end

  defp first_present(body, _fallback) when is_binary(body), do: body
  defp first_present(_body, fallback) when is_function(fallback, 0), do: fallback.()

  defp find_part_body(nil, _content_type), do: nil

  defp find_part_body(%Mail.Message{} = message, content_type) do
    message
    |> flatten_parts()
    |> Enum.reverse()
    |> Enum.find_value(fn part ->
      if body_part?(part, content_type) do
        present_body(part.body)
      end
    end)
  end

  defp flatten_parts(%Mail.Message{multipart: true, parts: parts}) when is_list(parts) do
    Enum.flat_map(parts, &flatten_parts/1)
  end

  defp flatten_parts(%Mail.Message{} = message), do: [message]
  defp flatten_parts(_), do: []

  defp body_part?(%Mail.Message{} = message, expected_type) do
    not attachment?(message) and content_type_matches?(message, expected_type)
  end

  defp attachment?(%Mail.Message{} = message) do
    message
    |> Mail.Message.get_header(:content_disposition)
    |> List.wrap()
    |> List.first()
    |> case do
      value when is_binary(value) -> String.downcase(value) == "attachment"
      value when is_atom(value) -> value == :attachment
      _ -> false
    end
  end

  defp content_type_matches?(%Mail.Message{} = message, expected_type) do
    message
    |> Mail.Message.get_content_type()
    |> List.first()
    |> case do
      value when is_binary(value) -> String.downcase(value) == expected_type
      _ -> false
    end
  end

  defp present_body(body) when is_binary(body) do
    if String.trim(body) == "", do: nil, else: body
  end

  defp present_body(_), do: nil
end
