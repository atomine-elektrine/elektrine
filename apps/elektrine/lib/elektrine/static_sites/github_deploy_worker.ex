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

  @max_archive_size 100 * 1024 * 1024
  @archive_body_key :elektrine_github_archive_body
  @archive_body_size_key :elektrine_github_archive_body_size
  @archive_too_large_key :elektrine_github_archive_too_large

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
    commit = fetch_commit_metadata(deployment)

    with {:ok, archive} <- fetch_archive(deployment),
         {:ok, _count} <-
           StaticSites.replace_with_repo_archive(deployment.user, archive, deployment.site_dir),
         {:ok, _profile} <- ensure_static_profile_mode(deployment),
         {:ok, deployment} <-
           StaticSites.mark_deployment_deployed(
             deployment,
             Map.merge(commit, %{log: "Deployed GitHub archive successfully"})
           ),
         {:ok, _deploy} <-
           StaticSites.snapshot_current_site(
             deployment.user,
             deployment,
             Map.merge(commit, %{
               status: "deployed",
               trigger: "github",
               log: "Deployed GitHub archive successfully"
             })
           ) do
      :ok
    else
      {:error, reason} ->
        _ = StaticSites.mark_deployment_failed(deployment, reason)

        _ =
          StaticSites.record_static_site_deploy(deployment, %{
            status: "failed",
            trigger: "github",
            error: inspect(reason),
            log: "Deploy failed: #{inspect(reason)}",
            deployed_at: DateTime.utc_now() |> DateTime.truncate(:second)
          })

        {:error, reason}
    end
  end

  @doc false
  def fetch_archive(deployment, opts \\ [])

  def fetch_archive(%StaticSiteDeployment{} = deployment, opts) do
    url =
      "https://codeload.github.com/#{deployment.repo_owner}/#{deployment.repo_name}/zip/refs/heads/#{deployment.branch}"

    request_fun = Keyword.get(opts, :request_fun, &Req.get/2)

    case request_fun.(url, archive_request_options()) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
        archive_body(response)

      {:ok, %{status: status, body: body}} when status in 200..299 and is_binary(body) ->
        archive_body(body)

      {:ok, %{status: status}} ->
        {:error, {:github_archive_status, status}}

      {:error, reason} ->
        Logger.warning("GitHub static deploy fetch failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def fetch_archive(_deployment, _opts), do: {:error, :invalid_deployment}

  defp archive_request_options do
    [
      headers: [
        {"accept", "application/zip"},
        {"accept-encoding", "identity"},
        {"user-agent", "Elektrine"}
      ],
      compressed: false,
      decode_body: false,
      raw: true,
      into: bounded_archive_collector(@max_archive_size),
      receive_timeout: :timer.seconds(30)
    ]
  end

  defp bounded_archive_collector(max_archive_size) do
    fn {:data, data}, {request, response} ->
      size = Req.Response.get_private(response, @archive_body_size_key, 0) + byte_size(data)

      response =
        response
        |> Req.Response.update_private(@archive_body_key, [data], &[data | &1])
        |> Req.Response.put_private(@archive_body_size_key, size)

      if size > max_archive_size do
        {:halt, {request, Req.Response.put_private(response, @archive_too_large_key, true)}}
      else
        {:cont, {request, response}}
      end
    end
  end

  defp archive_body(%Req.Response{} = response) do
    if Req.Response.get_private(response, @archive_too_large_key, false) do
      {:error, :archive_too_large}
    else
      body =
        response
        |> Req.Response.get_private(@archive_body_key, [])
        |> Enum.reverse()
        |> IO.iodata_to_binary()

      if byte_size(body) > @max_archive_size do
        {:error, :archive_too_large}
      else
        {:ok, body}
      end
    end
  end

  defp archive_body(body) when is_binary(body) do
    if byte_size(body) > @max_archive_size do
      {:error, :archive_too_large}
    else
      {:ok, body}
    end
  end

  defp fetch_commit_metadata(%StaticSiteDeployment{} = deployment) do
    url =
      "https://api.github.com/repos/#{deployment.repo_owner}/#{deployment.repo_name}/commits/#{deployment.branch}"

    case Req.get(url,
           headers: [
             {"accept", "application/vnd.github+json"},
             {"user-agent", "Elektrine"}
           ],
           receive_timeout: :timer.seconds(10)
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 and is_map(body) ->
        %{
          commit_sha: body["sha"],
          commit_url: body["html_url"],
          commit_message: get_in(body, ["commit", "message"])
        }

      _ ->
        %{}
    end
  rescue
    _ -> %{}
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
