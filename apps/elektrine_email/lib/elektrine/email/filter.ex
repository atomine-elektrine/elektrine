defmodule Elektrine.Email.Filter do
  @moduledoc """
  Schema for email filters/rules.
  Allows users to automatically process incoming emails based on conditions.

  ## Conditions Structure
  ```
  %{
    "match_type" => "all" | "any",
    "rules" => [
      %{
        "field" => "from" | "to" | "subject" | "body" | "has_attachment",
        "operator" => "contains" | "not_contains" | "equals" | "starts_with" | "ends_with",
        "value" => "search term"
      }
    ]
  }
  ```

  ## Actions Structure
  ```
  %{
    "move_to_folder" => folder_id,
    "add_label" => label_id,
    "mark_as_read" => true,
    "mark_as_spam" => true,
    "archive" => true,
    "delete" => true,
    "star" => true,
    "set_priority" => "high" | "normal" | "low",
    "forward_to" => "email@example.com"
  }
  ```
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "email_filters" do
    field :name, :string
    field :enabled, :boolean, default: true
    field :priority, :integer, default: 0
    field :stop_processing, :boolean, default: false
    field :conditions, :map, default: %{}
    field :actions, :map, default: %{}

    belongs_to :user, Elektrine.Accounts.User

    timestamps()
  end

  @valid_fields ~w(from to cc subject body has_attachment size)
  @valid_operators ~w(
    contains not_contains equals not_equals starts_with ends_with
    matches_regex not_matches_regex
    greater_than less_than
  )
  @valid_actions ~w(move_to_folder add_label remove_label mark_as_read mark_as_unread mark_as_spam archive delete star unstar set_priority forward_to)
  @valid_priorities ~w(high normal low)

  @doc """
  Creates a changeset for an email filter.
  """
  def changeset(filter, attrs) do
    filter
    |> cast(attrs, [:name, :enabled, :priority, :stop_processing, :conditions, :actions, :user_id])
    |> validate_required([:name, :conditions, :actions, :user_id])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_conditions()
    |> validate_actions()
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:user_id, :name])
  end

  defp validate_conditions(changeset) do
    case get_field(changeset, :conditions) do
      nil ->
        add_error(changeset, :conditions, "is required")

      %{"rules" => rules} when is_list(rules) and rules != [] ->
        if Enum.all?(rules, &valid_rule?/1) do
          changeset
        else
          add_error(changeset, :conditions, "contains invalid rules")
        end

      _ ->
        add_error(changeset, :conditions, "must contain at least one rule")
    end
  end

  defp valid_rule?(%{"field" => field, "operator" => operator, "value" => _value}) do
    field in @valid_fields && operator in @valid_operators
  end

  defp valid_rule?(%{"field" => "has_attachment", "operator" => operator}) do
    operator in ["equals", "not_equals"]
  end

  defp valid_rule?(_), do: false

  defp validate_actions(changeset) do
    case get_field(changeset, :actions) do
      nil ->
        add_error(changeset, :actions, "is required")

      actions when is_map(actions) and map_size(actions) > 0 ->
        if valid_actions?(actions) do
          changeset
        else
          add_error(changeset, :actions, "contains invalid actions")
        end

      _ ->
        add_error(changeset, :actions, "must contain at least one action")
    end
  end

  defp valid_actions?(actions) do
    Enum.all?(actions, fn {key, value} ->
      key in @valid_actions && valid_action_value?(key, value)
    end)
  end

  defp valid_action_value?("set_priority", value), do: value in @valid_priorities

  defp valid_action_value?("forward_to", value),
    do: is_binary(value) && String.contains?(value, "@")

  defp valid_action_value?("move_to_folder", value), do: is_integer(value) || is_binary(value)
  defp valid_action_value?("add_label", value), do: is_integer(value) || is_binary(value)
  defp valid_action_value?("remove_label", value), do: is_integer(value) || is_binary(value)
  defp valid_action_value?(_, value), do: is_boolean(value)

  @doc """
  Checks if a message matches this filter's conditions.
  """
  def matches?(filter, message) do
    match_type = Map.get(filter.conditions, "match_type", "all")
    rules = Map.get(filter.conditions, "rules", [])

    case match_type do
      "all" -> Enum.all?(rules, &rule_matches?(&1, message))
      "any" -> Enum.any?(rules, &rule_matches?(&1, message))
      _ -> false
    end
  end

  defp rule_matches?(%{"field" => field, "operator" => operator, "value" => value}, message) do
    field_value = get_message_field(message, field)
    apply_operator(operator, field_value, value)
  end

  defp rule_matches?(_, _), do: false

  defp get_message_field(message, "from"), do: message.from || ""
  defp get_message_field(message, "to"), do: message.to || ""
  defp get_message_field(message, "cc"), do: message.cc || ""
  defp get_message_field(message, "subject"), do: message.subject || ""
  defp get_message_field(message, "body"), do: message.text_body || message.html_body || ""
  defp get_message_field(message, "has_attachment"), do: message.has_attachments

  defp get_message_field(message, "size"),
    do: byte_size(message.text_body || "") + byte_size(message.html_body || "")

  defp get_message_field(_, _), do: ""

  defp apply_operator("contains", field_value, value) when is_binary(field_value) do
    String.contains?(String.downcase(field_value), String.downcase(value))
  end

  defp apply_operator("not_contains", field_value, value) when is_binary(field_value) do
    !String.contains?(String.downcase(field_value), String.downcase(value))
  end

  defp apply_operator("equals", field_value, value) when is_binary(field_value) do
    String.downcase(field_value) == String.downcase(value)
  end

  defp apply_operator("equals", field_value, value) when is_boolean(field_value) do
    field_value == (value == "true" || value == true)
  end

  defp apply_operator("not_equals", field_value, value) when is_binary(field_value) do
    String.downcase(field_value) != String.downcase(value)
  end

  defp apply_operator("starts_with", field_value, value) when is_binary(field_value) do
    String.starts_with?(String.downcase(field_value), String.downcase(value))
  end

  defp apply_operator("ends_with", field_value, value) when is_binary(field_value) do
    String.ends_with?(String.downcase(field_value), String.downcase(value))
  end

  defp apply_operator("matches_regex", field_value, value) when is_binary(field_value) do
    case Regex.compile(value) do
      {:ok, regex} -> Regex.match?(regex, field_value)
      {:error, _} -> false
    end
  end

  defp apply_operator("not_matches_regex", field_value, value) when is_binary(field_value) do
    !apply_operator("matches_regex", field_value, value)
  end

  defp apply_operator("greater_than", field_value, value) when is_integer(field_value) do
    case parse_integer(value) do
      {:ok, int_value} -> field_value > int_value
      :error -> false
    end
  end

  defp apply_operator("less_than", field_value, value) when is_integer(field_value) do
    case parse_integer(value) do
      {:ok, int_value} -> field_value < int_value
      :error -> false
    end
  end

  defp apply_operator(_, _, _), do: false

  defp parse_integer(value) when is_integer(value), do: {:ok, value}

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _ -> :error
    end
  end

  defp parse_integer(_), do: :error
end
