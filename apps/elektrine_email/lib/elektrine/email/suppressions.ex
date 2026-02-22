defmodule Elektrine.Email.Suppressions do
  @moduledoc "Context for outbound recipient suppressions.\n"
  import Ecto.Query
  alias Elektrine.Email.Suppression
  alias Elektrine.Repo
  @doc "Upserts an active suppression entry for a recipient and user.\n"
  def suppress_recipient(user_id, email, opts \\ [])

  def suppress_recipient(user_id, email, opts) when is_integer(user_id) and is_binary(email) do
    with {:ok, normalized_email} <- normalize_email(email) do
      reason = normalize_reason(Keyword.get(opts, :reason, "manual"))
      source = normalize_source(Keyword.get(opts, :source, "manual"))
      metadata = normalize_metadata(Keyword.get(opts, :metadata, %{}))
      note = Keyword.get(opts, :note)
      last_event_at = Keyword.get(opts, :last_event_at, DateTime.utc_now())
      expires_at = Keyword.get(opts, :expires_at)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      attrs = %{
        user_id: user_id,
        email: normalized_email,
        reason: reason,
        source: source,
        note: note,
        metadata: metadata,
        last_event_at: truncate_datetime(last_event_at),
        expires_at: truncate_datetime(expires_at)
      }

      %Suppression{}
      |> Suppression.changeset(attrs)
      |> Repo.insert(
        conflict_target: [:user_id, :email],
        on_conflict: [
          set: [
            reason: attrs.reason,
            source: attrs.source,
            note: attrs.note,
            metadata: attrs.metadata,
            last_event_at: attrs.last_event_at,
            expires_at: attrs.expires_at,
            updated_at: now
          ]
        ],
        returning: true
      )
    end
  end

  def suppress_recipient(_, _, _) do
    {:error, :invalid_params}
  end

  @doc "Deletes a suppression entry for a recipient and user.\n"
  def unsuppress_recipient(user_id, email) when is_integer(user_id) and is_binary(email) do
    case normalize_email(email) do
      {:ok, normalized_email} ->
        from(s in Suppression, where: s.user_id == ^user_id and s.email == ^normalized_email)
        |> Repo.delete_all()

      {:error, _} = error ->
        error
    end
  end

  def unsuppress_recipient(_, _) do
    {:error, :invalid_params}
  end

  @doc "Returns true when an active suppression exists for the user/recipient pair.\n"
  def suppressed?(user_id, email) when is_integer(user_id) and is_binary(email) do
    not is_nil(get_active_suppression(user_id, email))
  end

  def suppressed?(_, _) do
    false
  end

  @doc "Returns the active suppression for a user/recipient if present.\n"
  def get_active_suppression(user_id, email) when is_integer(user_id) and is_binary(email) do
    case normalize_email(email) do
      {:ok, normalized_email} ->
        now = DateTime.utc_now()

        from(s in Suppression,
          where: s.user_id == ^user_id and s.email == ^normalized_email,
          where: is_nil(s.expires_at) or s.expires_at > ^now,
          order_by: [desc: s.last_event_at, desc: s.updated_at],
          limit: 1
        )
        |> Repo.one()

      {:error, _} ->
        nil
    end
  end

  def get_active_suppression(_, _) do
    nil
  end

  @doc "Lists active suppressions for a user.\n"
  def list_active_suppressions(user_id, opts \\ [])

  def list_active_suppressions(user_id, opts) when is_integer(user_id) do
    now = DateTime.utc_now()
    limit = Keyword.get(opts, :limit, 100)

    from(s in Suppression,
      where: s.user_id == ^user_id,
      where: is_nil(s.expires_at) or s.expires_at > ^now,
      order_by: [desc: s.last_event_at, desc: s.updated_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  def list_active_suppressions(_, _) do
    []
  end

  @doc "Filters recipient list using active suppressions.\n\nReturns `%{allowed: [...], suppressed: [...], reasons: %{email => reason}}`.\n"
  def filter_suppressed_recipients(user_id, recipients, opts \\ [])

  def filter_suppressed_recipients(user_id, recipients, opts)
      when is_integer(user_id) and is_list(recipients) do
    external_only = Keyword.get(opts, :external_only, true)

    normalized =
      recipients |> Enum.map(&normalize_email_value/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    candidate_emails =
      if external_only do
        Enum.reject(normalized, &internal_email?/1)
      else
        normalized
      end

    if candidate_emails == [] do
      %{allowed: normalized, suppressed: [], reasons: %{}}
    else
      now = DateTime.utc_now()

      suppressions =
        from(s in Suppression,
          where: s.user_id == ^user_id and s.email in ^candidate_emails,
          where: is_nil(s.expires_at) or s.expires_at > ^now
        )
        |> Repo.all()

      suppressed_set = suppressions |> Enum.map(& &1.email) |> MapSet.new()
      suppressed = Enum.filter(normalized, &MapSet.member?(suppressed_set, &1))
      allowed = Enum.reject(normalized, &MapSet.member?(suppressed_set, &1))

      reasons =
        suppressions
        |> Enum.group_by(& &1.email)
        |> Enum.into(%{}, fn {email, rows} ->
          latest =
            Enum.max_by(rows, fn row ->
              row.last_event_at || row.updated_at || ~U[1970-01-01 00:00:00Z]
            end)

          {email, latest.reason}
        end)

      %{allowed: allowed, suppressed: suppressed, reasons: reasons}
    end
  end

  def filter_suppressed_recipients(_, recipients, _) when is_list(recipients) do
    normalized =
      recipients |> Enum.map(&normalize_email_value/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    %{allowed: normalized, suppressed: [], reasons: %{}}
  end

  @doc "Deletes expired suppressions and returns number of deleted rows.\n"
  def prune_expired do
    now = DateTime.utc_now()

    from(s in Suppression, where: not is_nil(s.expires_at) and s.expires_at <= ^now)
    |> Repo.delete_all()
  end

  defp normalize_email(email) do
    normalized = normalize_email_value(email)

    if is_binary(normalized) do
      {:ok, normalized}
    else
      {:error, :invalid_email}
    end
  end

  defp normalize_email_value(email) when is_binary(email) do
    email = email |> String.trim() |> String.downcase()

    if Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, email) do
      email
    else
      nil
    end
  end

  defp normalize_email_value(_) do
    nil
  end

  defp normalize_reason(reason) when is_binary(reason) do
    reason |> String.trim() |> String.downcase()
  end

  defp normalize_reason(reason) when is_atom(reason) do
    reason |> Atom.to_string() |> normalize_reason()
  end

  defp normalize_reason(_) do
    "manual"
  end

  defp normalize_source(source) when is_binary(source) do
    source |> String.trim() |> String.downcase()
  end

  defp normalize_source(source) when is_atom(source) do
    source |> Atom.to_string() |> normalize_source()
  end

  defp normalize_source(_) do
    "manual"
  end

  defp normalize_metadata(metadata) when is_map(metadata) do
    metadata
  end

  defp normalize_metadata(_) do
    %{}
  end

  defp truncate_datetime(nil) do
    nil
  end

  defp truncate_datetime(%DateTime{} = value) do
    DateTime.truncate(value, :second)
  end

  defp truncate_datetime(value) do
    value
  end

  defp internal_email?(email) do
    case String.split(email, "@", parts: 2) do
      [_local, domain] -> String.downcase(domain) in supported_domains()
      _ -> false
    end
  end

  defp supported_domains do
    Application.get_env(:elektrine, :email)[:supported_domains] || ["elektrine.com", "z.org"]
  end
end
