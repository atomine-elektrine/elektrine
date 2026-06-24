defmodule Elektrine.Security.FilePath do
  @moduledoc """
  Helpers for constraining stored filesystem paths to an expected directory.
  """

  @doc """
  Returns `{:ok, expanded_path}` only when `path` is a regular file inside
  `base_dir`.
  """
  def validate_existing_file(path, base_dir) do
    with {:ok, expanded_path} <- validate_child_path(path, base_dir),
         {:ok, %File.Stat{type: :regular}} <- File.lstat(expanded_path) do
      {:ok, expanded_path}
    else
      {:ok, %File.Stat{type: :symlink}} -> {:error, :unsafe_path}
      {:ok, %File.Stat{}} -> {:error, :not_file}
      {:error, :enoent} -> {:error, :file_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns `{:ok, expanded_path}` only when `path` expands below `base_dir`.
  """
  def validate_child_path(path, base_dir) when is_binary(path) and is_binary(base_dir) do
    if String.contains?(path, "\0") or String.contains?(base_dir, "\0") do
      {:error, :unsafe_path}
    else
      expanded_path = Path.expand(path)
      expanded_base = Path.expand(base_dir)

      if child_path?(expanded_path, expanded_base) do
        {:ok, expanded_path}
      else
        {:error, :unsafe_path}
      end
    end
  end

  def validate_child_path(_path, _base_dir), do: {:error, :unsafe_path}

  @doc """
  Returns true when `path` expands below `base_dir`.
  """
  def safe_child_path?(path, base_dir) do
    match?({:ok, _path}, validate_child_path(path, base_dir))
  end

  defp child_path?(expanded_path, expanded_base) do
    expanded_path != expanded_base and
      String.starts_with?(expanded_path, base_prefix(expanded_base))
  end

  defp base_prefix("/"), do: "/"
  defp base_prefix(base), do: base <> "/"
end
