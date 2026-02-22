defmodule Elektrine.Email.Exports do
  @moduledoc """
  Context module for managing email exports.
  """
  import Ecto.Query
  alias Elektrine.Email.Export
  alias Elektrine.Email.Message
  alias Elektrine.Repo

  require Logger

  # Export directory - configurable via :elektrine, :export_dir
  defp export_dir, do: Application.get_env(:elektrine, :export_dir, "/tmp/elektrine/exports")

  @doc """
  Lists all exports for a user.
  """
  def list_exports(user_id) do
    Export
    |> where(user_id: ^user_id)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  @doc """
  Gets an export by ID for a user.
  """
  def get_export(id, user_id) do
    Export
    |> where(id: ^id, user_id: ^user_id)
    |> Repo.one()
  end

  @doc """
  Creates an export job.
  """
  def create_export(attrs) do
    %Export{}
    |> Export.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Starts an export job asynchronously.
  """
  def start_export(user_id, format \\ "mbox", filters \\ %{}) do
    case create_export(%{user_id: user_id, format: format, filters: filters}) do
      {:ok, export} ->
        # Start async processing
        Task.start(fn -> process_export(export) end)
        {:ok, export}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Processes an export job.
  """
  def process_export(%Export{} = export) do
    # Mark as processing
    {:ok, export} = update_export(export, Export.start_changeset(export))

    try do
      # Get user's mailbox
      mailbox = Elektrine.Email.get_user_mailbox(export.user_id)

      if mailbox do
        # Get messages based on filters
        messages = get_export_messages(mailbox.id, export.filters)

        # Generate export file
        {file_path, file_size} = generate_export_file(export, messages, mailbox)

        # Mark as completed
        {:ok, updated_export} =
          update_export(
            export,
            Export.complete_changeset(export, file_path, file_size, length(messages))
          )

        # Broadcast completion to LiveView
        Phoenix.PubSub.broadcast(
          Elektrine.PubSub,
          "email:exports:#{export.user_id}",
          {:export_completed, updated_export}
        )
      else
        {:ok, updated_export} =
          update_export(export, Export.fail_changeset(export, "No mailbox found"))

        Phoenix.PubSub.broadcast(
          Elektrine.PubSub,
          "email:exports:#{export.user_id}",
          {:export_failed, updated_export}
        )
      end
    rescue
      e ->
        Logger.error("Export failed: #{inspect(e)}")
        {:ok, updated_export} = update_export(export, Export.fail_changeset(export, inspect(e)))

        Phoenix.PubSub.broadcast(
          Elektrine.PubSub,
          "email:exports:#{export.user_id}",
          {:export_failed, updated_export}
        )
    end
  end

  @doc """
  Updates an export.
  """
  def update_export(%Export{} = export, changeset_or_attrs) do
    changeset =
      if is_map(changeset_or_attrs) and not match?(%Ecto.Changeset{}, changeset_or_attrs) do
        Export.changeset(export, changeset_or_attrs)
      else
        changeset_or_attrs
      end

    Repo.update(changeset)
  end

  @doc """
  Deletes an export and its file.
  """
  def delete_export(%Export{} = export) do
    # Delete file if exists
    if export.file_path && File.exists?(export.file_path) do
      File.rm(export.file_path)
    end

    Repo.delete(export)
  end

  @doc """
  Gets the download path for an export.
  """
  def get_download_path(%Export{file_path: file_path, status: "completed"})
      when is_binary(file_path) do
    if File.exists?(file_path) do
      {:ok, file_path}
    else
      {:error, :file_not_found}
    end
  end

  def get_download_path(_), do: {:error, :not_ready}

  # Private functions

  defp get_export_messages(mailbox_id, filters) do
    query =
      Message
      |> where(mailbox_id: ^mailbox_id)
      |> order_by(desc: :inserted_at)

    query = apply_export_filters(query, filters)
    Repo.all(query)
  end

  defp apply_export_filters(query, filters) when is_map(filters) do
    query
    |> maybe_filter_by_folder(filters)
    |> maybe_filter_by_date_range(filters)
    |> maybe_filter_by_status(filters)
  end

  defp apply_export_filters(query, _), do: query

  defp maybe_filter_by_folder(query, %{"folder" => folder})
       when folder in ["inbox", "sent", "spam", "archive", "trash"] do
    case folder do
      "inbox" ->
        where(
          query,
          [m],
          m.spam == false and m.archived == false and m.deleted == false and m.status != "sent"
        )

      "sent" ->
        where(query, [m], m.status == "sent" and m.deleted == false)

      "spam" ->
        where(query, [m], m.spam == true and m.deleted == false)

      "archive" ->
        where(query, [m], m.archived == true and m.deleted == false)

      "trash" ->
        where(query, [m], m.deleted == true)
    end
  end

  defp maybe_filter_by_folder(query, _), do: query

  defp maybe_filter_by_date_range(query, %{"start_date" => start_date, "end_date" => end_date}) do
    query
    |> where([m], m.inserted_at >= ^start_date)
    |> where([m], m.inserted_at <= ^end_date)
  end

  defp maybe_filter_by_date_range(query, _), do: query

  defp maybe_filter_by_status(query, %{"include_deleted" => false}) do
    where(query, [m], m.deleted == false)
  end

  defp maybe_filter_by_status(query, _), do: query

  defp generate_export_file(export, messages, mailbox) do
    # Ensure export directory exists
    File.mkdir_p!(export_dir())

    filename =
      "export_#{export.user_id}_#{export.id}_#{System.system_time(:second)}.#{export.format}"

    file_path = Path.join(export_dir(), filename)

    case export.format do
      "mbox" -> generate_mbox(file_path, messages, mailbox)
      "eml" -> generate_eml_zip(file_path, messages, mailbox)
      "zip" -> generate_eml_zip(file_path, messages, mailbox)
      _ -> generate_mbox(file_path, messages, mailbox)
    end
  end

  defp generate_mbox(file_path, messages, mailbox) do
    content =
      messages
      |> Enum.map_join("\n", &message_to_mbox(&1, mailbox))

    File.write!(file_path, content)
    {file_path, byte_size(content)}
  end

  defp message_to_mbox(message, mailbox) do
    # Decrypt content if needed
    message = Message.decrypt_content(message, mailbox.user_id)

    date = format_mbox_date(message.inserted_at)
    from_addr = extract_email(message.from)

    """
    From #{from_addr} #{date}
    From: #{message.from}
    To: #{message.to}
    #{if message.cc, do: "Cc: #{message.cc}\n", else: ""}Subject: #{message.subject}
    Date: #{format_rfc2822_date(message.inserted_at)}
    Message-ID: #{message.message_id}
    Content-Type: text/plain; charset=UTF-8

    #{message.text_body || strip_html(message.html_body || "")}

    """
  end

  defp generate_eml_zip(file_path, messages, mailbox) do
    # Create a zip file containing individual .eml files
    zip_path = String.replace(file_path, ~r/\.(eml|zip)$/, ".zip")

    eml_files =
      messages
      |> Enum.with_index()
      |> Enum.map(fn {message, index} ->
        message = Message.decrypt_content(message, mailbox.user_id)
        filename = "message_#{String.pad_leading(to_string(index + 1), 5, "0")}.eml"
        content = message_to_eml(message)
        {String.to_charlist(filename), content}
      end)

    {:ok, zip_path} = :zip.create(String.to_charlist(zip_path), eml_files)
    file_size = File.stat!(zip_path).size
    {to_string(zip_path), file_size}
  end

  defp message_to_eml(message) do
    """
    From: #{message.from}
    To: #{message.to}
    #{if message.cc, do: "Cc: #{message.cc}\n", else: ""}Subject: #{message.subject}
    Date: #{format_rfc2822_date(message.inserted_at)}
    Message-ID: #{message.message_id}
    MIME-Version: 1.0
    Content-Type: text/plain; charset=UTF-8

    #{message.text_body || strip_html(message.html_body || "")}
    """
  end

  defp format_mbox_date(datetime) do
    Calendar.strftime(datetime, "%a %b %d %H:%M:%S %Y")
  end

  defp format_rfc2822_date(datetime) do
    Calendar.strftime(datetime, "%a, %d %b %Y %H:%M:%S +0000")
  end

  defp extract_email(email_string) when is_binary(email_string) do
    case Regex.run(~r/<([^>]+)>/, email_string) do
      [_, email] -> String.trim(email)
      nil -> String.trim(email_string)
    end
  end

  defp extract_email(_), do: "unknown@unknown"

  defp strip_html(html) do
    html
    |> String.replace(~r/<br\s*\/?>/i, "\n")
    |> String.replace(~r/<\/p>/i, "\n\n")
    |> String.replace(~r/<[^>]+>/, "")
    |> String.trim()
  end
end
