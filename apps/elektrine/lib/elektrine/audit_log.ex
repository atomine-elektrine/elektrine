defmodule Elektrine.AuditLog do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Elektrine.Accounts.User
  alias Elektrine.Repo

  schema "audit_logs" do
    field :action, :string
    field :resource_type, :string
    field :resource_id, :integer
    field :details, :map
    field :ip_address, :string
    field :user_agent, :string

    belongs_to :admin, User, foreign_key: :admin_id
    belongs_to :target_user, User, foreign_key: :target_user_id

    timestamps()
  end

  @doc """
  Creates an audit log entry.
  """
  def log(admin_id, action, resource_type, opts \\ []) do
    attrs = %{
      admin_id: admin_id,
      action: action,
      resource_type: resource_type,
      target_user_id: opts[:target_user_id],
      resource_id: opts[:resource_id],
      details: opts[:details] || %{},
      ip_address: opts[:ip_address],
      user_agent: opts[:user_agent]
    }

    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Gets audit logs with pagination and filtering.
  """
  def list_audit_logs(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 50)
    admin_id = Keyword.get(opts, :admin_id)
    action = Keyword.get(opts, :action)

    offset = (page - 1) * per_page

    query =
      from(a in __MODULE__,
        order_by: [desc: a.inserted_at],
        preload: [:admin, :target_user]
      )

    query = if admin_id, do: where(query, [a], a.admin_id == ^admin_id), else: query
    query = if action, do: where(query, [a], a.action == ^action), else: query

    total_count = Repo.aggregate(query, :count, :id)

    logs =
      query
      |> limit(^per_page)
      |> offset(^offset)
      |> Repo.all()

    {logs, total_count}
  end

  def changeset(audit_log, attrs) do
    audit_log
    |> cast(attrs, [
      :admin_id,
      :target_user_id,
      :action,
      :resource_type,
      :resource_id,
      :details,
      :ip_address,
      :user_agent
    ])
    |> validate_required([:admin_id, :action, :resource_type])
    |> validate_length(:action, max: 100)
    |> validate_length(:resource_type, max: 100)
  end
end
