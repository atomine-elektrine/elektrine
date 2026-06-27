defmodule Elektrine.IMAP.Folders do
  @moduledoc false

  alias Elektrine.IMAP.Helpers

  @system_folders [
    {"INBOX", "\\HasNoChildren"},
    {"Sent", "\\HasNoChildren \\Sent"},
    {"Drafts", "\\HasNoChildren \\Drafts"},
    {"Trash", "\\HasNoChildren \\Trash"},
    {"Spam", "\\HasNoChildren \\Junk"}
  ]

  def all_for_user(user_id) do
    custom_folders = Elektrine.Email.list_custom_folders(user_id)

    custom_folder_rows =
      Enum.map(custom_folders, fn folder ->
        attrs =
          if Enum.any?(custom_folders, &(&1.parent_id == folder.id)) do
            "\\HasChildren"
          else
            "\\HasNoChildren"
          end

        {folder.name, attrs}
      end)

    @system_folders ++ custom_folder_rows
  end

  def system_folder_name?(folder_name) when is_binary(folder_name) do
    normalized = folder_name |> Helpers.canonical_system_folder_name() |> String.upcase()
    Enum.any?(@system_folders, fn {name, _attrs} -> String.upcase(name) == normalized end)
  end

  def system_folder_name?(_folder_name), do: false

  def parse_folder_name_argument(args) do
    case String.trim(args || "") do
      "" ->
        {:error, :missing_folder_name}

      trimmed ->
        case Regex.run(~r/"([^"]+)"/, trimmed) do
          [_, folder_name] -> {:ok, String.trim(folder_name)}
          _ -> {:ok, trimmed |> String.trim("\"") |> String.trim()}
        end
    end
  end

  def parse_rename_arguments(args) do
    trimmed = String.trim(args || "")

    case Regex.run(~r/"([^"]+)"\s+"([^"]+)"/, trimmed) do
      [_, old_name, new_name] ->
        {:ok, String.trim(old_name), String.trim(new_name)}

      _ ->
        case String.split(trimmed, ~r/\s+/, parts: 2) do
          [old_name, new_name] -> {:ok, String.trim(old_name, "\""), String.trim(new_name, "\"")}
          _ -> {:error, :invalid_rename_args}
        end
    end
  end

  def parse_list_command_args(args) do
    trimmed = String.trim(args || "")

    {prefix, return_clause} =
      case Regex.run(~r/^(.*?)(?:\s+RETURN\s+\((.*)\))?\s*$/i, trimmed) do
        [_, prefix, return_clause] -> {String.trim(prefix), return_clause}
        [_, prefix] -> {String.trim(prefix), nil}
        _ -> {trimmed, nil}
      end

    return_status_items =
      case return_clause && Regex.run(~r/STATUS\s*\(([^)]*)\)/i, return_clause) do
        [_, items] ->
          items
          |> String.split(~r/\s+/, trim: true)
          |> Enum.map(&String.upcase/1)

        _ ->
          []
      end

    {list_args, select_options} = parse_list_select_options(prefix)

    {_reference, pattern} =
      if list_args == "" do
        {"", "*"}
      else
        Helpers.parse_list_args(list_args)
      end

    %{
      pattern: pattern,
      return_status_items: return_status_items,
      select_subscribed: Enum.member?(select_options, "SUBSCRIBED")
    }
  end

  def filter_by_pattern(all_folders, pattern) do
    case pattern do
      "*" ->
        all_folders

      "%" ->
        all_folders

      pattern_str ->
        Enum.filter(all_folders, fn {name, _attrs} ->
          Helpers.matches_pattern?(String.downcase(name), String.downcase(pattern_str))
        end)
    end
  end

  def seed_subscriptions_if_needed(user_id, folder_names) do
    Elektrine.Email.ImapSubscriptions.ensure_seeded(user_id, folder_names)
  end

  def maybe_subscribe_new_folder(user_id, folder_name) do
    if Elektrine.Email.ImapSubscriptions.has_records?(user_id) do
      case Elektrine.Email.ImapSubscriptions.subscribe_folder(user_id, folder_name) do
        {:ok, _subscription} -> :ok
        {:error, _reason} -> :ok
      end
    else
      :ok
    end
  end

  def canonical_folder_name(folder_name, all_folders) do
    normalized = String.downcase(String.trim(folder_name))

    case Enum.find(all_folders, fn {name, _attrs} -> String.downcase(name) == normalized end) do
      {canonical_name, _attrs} -> canonical_name
      nil -> String.trim(folder_name)
    end
  end

  def subscribed_folder_set(user_id, all_folders) do
    default_folders = Enum.map(all_folders, fn {folder, _attrs} -> folder end)
    Elektrine.Email.ImapSubscriptions.subscribed_folder_set(user_id, default_folders)
  end

  def duplicate_folder_name_error?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:name, {_message, metadata}} -> metadata[:constraint] == :unique
      _ -> false
    end)
  end

  def find_custom_folder_by_name(user_id, folder_name)
      when is_integer(user_id) and is_binary(folder_name) do
    target_name = String.downcase(String.trim(folder_name))

    user_id
    |> Elektrine.Email.list_custom_folders()
    |> Enum.find(fn folder -> String.downcase(folder.name) == target_name end)
  end

  def find_custom_folder_by_name(_user_id, _folder_name), do: nil

  def destination_folder_exists?(folder_name, user_id) when is_binary(folder_name) do
    system_folder_name?(folder_name) or
      (is_integer(user_id) and not is_nil(find_custom_folder_by_name(user_id, folder_name)))
  end

  def destination_folder_exists?(_folder_name, _user_id), do: false

  defp parse_list_select_options(list_args) do
    case Regex.run(~r/^\(([^)]*)\)\s*(.*)$/s, list_args) do
      [_, options, remaining] ->
        parsed_options =
          options
          |> String.split(~r/\s+/, trim: true)
          |> Enum.map(&String.upcase/1)

        {String.trim(remaining), parsed_options}

      _ ->
        {list_args, []}
    end
  end
end
