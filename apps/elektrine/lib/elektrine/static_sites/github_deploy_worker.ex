defmodule Elektrine.StaticSites.GitHubDeployWorker do
  @moduledoc """
  Deploys a linked static site from a GitHub repository archive.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  alias Elektrine.Profiles
  alias Elektrine.Profiles.StaticSiteDeployment
  alias Elektrine.Repo
  alias Elektrine.StaticSites

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"deployment_id" => deployment_id}}) do
    deployment =
      StaticSiteDeployment
      |> Repo.get(deployment_id)
      |> Repo.preload(:user)

    case deployment do
      %StaticSiteDeployment{} = deployment -> deploy(deployment)
      nil -> {:error, :deployment_not_found}
    end
  end

  defp deploy(%StaticSiteDeployment{} = deployment) do
    _ = StaticSites.mark_deployment_deploying(deployment)

    with {:ok, archive} <- fetch_archive(deployment),
         {:ok, _count} <-
           StaticSites.replace_with_repo_archive(deployment.user, archive, deployment.site_dir),
         {:ok, _profile} <- ensure_static_profile_mode(deployment),
         {:ok, _deployment} <- StaticSites.mark_deployment_deployed(deployment) do
      :ok
    else
      {:error, reason} ->
        _ = StaticSites.mark_deployment_failed(deployment, reason)
        {:error, reason}
    end
  end

  defp fetch_archive(%StaticSiteDeployment{} = deployment) do
    url =
      "https://codeload.github.com/#{deployment.repo_owner}/#{deployment.repo_name}/zip/refs/heads/#{deployment.branch}"

    case Req.get(url,
           headers: [
             {"accept", "application/zip"},
             {"user-agent", "Elektrine"}
           ],
           receive_timeout: :timer.seconds(30)
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_binary(body) ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, {:github_archive_status, status}}

      {:error, reason} ->
        Logger.warning("GitHub static deploy fetch failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp ensure_static_profile_mode(%StaticSiteDeployment{user: user}) do
    case StaticSites.enable_static_mode(user.id) do
      {:ok, profile} ->
        {:ok, profile}

      {:error, :profile_not_found} ->
        Profiles.create_user_profile(user.id, %{
          profile_mode: "static",
          display_name: user.username
        })

      {:error, reason} ->
        {:error, reason}
    end
  end
end
