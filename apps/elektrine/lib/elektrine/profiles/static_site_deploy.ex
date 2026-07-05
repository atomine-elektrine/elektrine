defmodule Elektrine.Profiles.StaticSiteDeploy do
  @moduledoc """
  Immutable deploy history entry for a linked static site.
  Successful rows can carry a snapshot ZIP for rollback.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "static_site_deploys" do
    field :status, :string
    field :trigger, :string, default: "manual"
    field :repo_owner, :string
    field :repo_name, :string
    field :branch, :string
    field :site_dir, :string
    field :commit_sha, :string
    field :commit_url, :string
    field :commit_message, :string
    field :log, :string
    field :error, :string
    field :snapshot_storage_key, :string
    field :file_count, :integer, default: 0
    field :storage_bytes, :integer, default: 0
    field :deployed_at, :utc_datetime

    belongs_to :user, Elektrine.Accounts.User
    belongs_to :deployment, Elektrine.Profiles.StaticSiteDeployment

    timestamps()
  end

  def changeset(deploy, attrs) do
    deploy
    |> cast(attrs, [
      :user_id,
      :deployment_id,
      :status,
      :trigger,
      :repo_owner,
      :repo_name,
      :branch,
      :site_dir,
      :commit_sha,
      :commit_url,
      :commit_message,
      :log,
      :error,
      :snapshot_storage_key,
      :file_count,
      :storage_bytes,
      :deployed_at
    ])
    |> validate_required([:user_id, :deployment_id, :status, :trigger])
    |> validate_inclusion(:status, ["queued", "deploying", "deployed", "failed", "rolled_back"])
    |> validate_inclusion(:trigger, ["manual", "github", "webhook", "rollback"])
    |> validate_length(:commit_sha, max: 80)
    |> validate_number(:file_count, greater_than_or_equal_to: 0)
    |> validate_number(:storage_bytes, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:deployment_id)
  end
end
