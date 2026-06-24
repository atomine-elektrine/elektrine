defmodule Elektrine.Profiles.StaticSiteDeployment do
  @moduledoc """
  Linked repository allowed to deploy a user's static site.
  """

  use Ecto.Schema
  import Ecto.Changeset
  alias Elektrine.Secrets.EncryptedString

  schema "static_site_deployments" do
    field :provider, :string, default: "github"
    field :repo_owner, :string
    field :repo_name, :string
    field :branch, :string, default: "main"
    field :site_dir, :string, default: "auto"
    field :build_command, :string
    field :webhook_secret, EncryptedString
    field :webhook_id, :string
    field :deploy_status, :string, default: "idle"
    field :last_deploy_error, :string
    field :last_deployed_at, :utc_datetime

    belongs_to :user, Elektrine.Accounts.User

    timestamps()
  end

  def changeset(deployment, attrs) do
    deployment
    |> cast(attrs, [
      :user_id,
      :provider,
      :repo_owner,
      :repo_name,
      :branch,
      :site_dir,
      :build_command,
      :webhook_secret,
      :webhook_id,
      :deploy_status,
      :last_deploy_error,
      :last_deployed_at
    ])
    |> update_change(:provider, &normalize/1)
    |> update_change(:repo_owner, &normalize/1)
    |> update_change(:repo_name, &normalize_repo/1)
    |> update_change(:branch, &normalize_branch/1)
    |> update_change(:site_dir, &normalize_site_dir/1)
    |> maybe_generate_webhook_secret()
    |> validate_required([
      :user_id,
      :provider,
      :repo_owner,
      :repo_name,
      :branch,
      :site_dir,
      :webhook_secret,
      :deploy_status
    ])
    |> validate_inclusion(:provider, ["github"])
    |> validate_inclusion(:deploy_status, ["idle", "queued", "deploying", "deployed", "failed"])
    |> validate_format(:repo_owner, ~r/^[a-z0-9_.-]+$/)
    |> validate_format(:repo_name, ~r/^[a-z0-9_.-]+$/)
    |> validate_format(:branch, ~r/^[A-Za-z0-9._\/-]+$/)
    |> validate_change(:branch, &validate_branch_path/2)
    |> validate_length(:build_command, max: 2_000)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:provider, :repo_owner, :repo_name])
  end

  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize(value), do: value

  defp normalize_repo(value) when is_binary(value) do
    value |> normalize() |> String.replace_suffix(".git", "")
  end

  defp normalize_repo(value), do: value

  defp normalize_branch(value) when is_binary(value) do
    case String.trim(value) do
      "" -> "main"
      branch -> branch
    end
  end

  defp normalize_branch(value), do: value

  defp validate_branch_path(:branch, branch) when is_binary(branch) do
    if valid_branch_segments?(branch) do
      []
    else
      [branch: "contains invalid path segment"]
    end
  end

  defp validate_branch_path(:branch, _branch), do: [branch: "is invalid"]

  defp valid_branch_segments?(branch) do
    branch
    |> String.split("/")
    |> Enum.all?(&(&1 not in ["", ".", ".."]))
  end

  defp normalize_site_dir(value) when is_binary(value) do
    case String.trim(value) do
      "" -> "auto"
      dir -> dir
    end
  end

  defp normalize_site_dir(value), do: value

  defp maybe_generate_webhook_secret(changeset) do
    case get_field(changeset, :webhook_secret) do
      secret when is_binary(secret) and secret != "" ->
        changeset

      _ ->
        put_change(
          changeset,
          :webhook_secret,
          Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
        )
    end
  end
end
