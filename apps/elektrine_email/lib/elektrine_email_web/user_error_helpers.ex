defmodule ElektrineEmailWeb.UserErrorHelpers do
  @moduledoc false

  def join_changeset_errors(%Ecto.Changeset{} = changeset, opts \\ []) do
    fallback = Keyword.get(opts, :fallback, "Please review the highlighted fields.")
    separator = Keyword.get(opts, :separator, " ")

    case changeset_errors(changeset) do
      [] -> normalize_sentence(fallback)
      messages -> Enum.join(messages, separator)
    end
  end

  def changeset_errors(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.flat_map(fn {field, messages} ->
      Enum.map(messages, &format_message(field, &1))
    end)
    |> Enum.map(&normalize_sentence/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def reason_message(%Ecto.Changeset{} = changeset, fallback) do
    join_changeset_errors(changeset, fallback: fallback)
  end

  def reason_message({_, message}, _fallback) when is_binary(message) do
    normalize_sentence(message)
  end

  def reason_message(message, _fallback) when is_binary(message) do
    normalize_sentence(message)
  end

  def reason_message(_reason, fallback) do
    normalize_sentence(fallback)
  end

  defp normalize_sentence(nil), do: ""

  defp normalize_sentence(message) when is_binary(message) do
    message
    |> String.trim()
    |> case do
      "" ->
        ""

      trimmed ->
        trimmed = capitalize(trimmed)

        if String.ends_with?(trimmed, ".") do
          trimmed
        else
          trimmed <> "."
        end
    end
  end

  defp format_message(field, message) when is_binary(message) do
    if generic_validation_message?(message) do
      "#{field_label(field)} #{message}"
    else
      message
    end
  end

  defp generic_validation_message?(message) do
    String.match?(message, ~r/^(can't|cannot|has|is|must|should)\b/)
  end

  defp field_label(field) do
    case field do
      :alias_email -> "Email address"
      :target_email -> "Forwarding address"
      :forward_to -> "Forwarding address"
      _ -> Phoenix.Naming.humanize(field)
    end
  end

  defp capitalize(message) do
    case String.next_grapheme(message) do
      nil -> message
      {first, rest} -> String.upcase(first) <> rest
    end
  end
end
