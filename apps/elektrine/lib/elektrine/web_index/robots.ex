defmodule Elektrine.WebIndex.Robots do
  @moduledoc "Parses and evaluates the robots.txt directives used by PaigeBot."

  def parse(body) when is_binary(body) do
    lines =
      body
      |> String.split(~r/\r?\n/u)
      |> Enum.map(&parse_line/1)
      |> Enum.reject(&is_nil/1)

    %{
      groups: parse_groups(lines),
      sitemaps: for({"sitemap", value} <- lines, do: value)
    }
  end

  def parse(_body), do: %{groups: [], sitemaps: []}

  def allowed?(policy, url) do
    path = request_path(url)

    policy
    |> matching_group()
    |> Map.get(:rules, [])
    |> Enum.filter(fn {_kind, pattern} -> matches?(pattern, path) end)
    |> Enum.max_by(fn {kind, pattern} -> {rule_length(pattern), kind == :allow} end, fn -> nil end)
    |> case do
      {:disallow, _pattern} -> false
      _rule -> true
    end
  end

  def crawl_delay_ms(policy, default \\ 1_000) do
    case matching_group(policy) do
      %{crawl_delay: delay} when is_number(delay) ->
        delay |> Kernel.*(1_000) |> round() |> max(250) |> min(30_000)

      _group ->
        default
    end
  end

  def sitemaps(policy), do: Map.get(policy, :sitemaps, [])

  defp parse_groups(lines) do
    {groups, current} =
      Enum.reduce(lines, {[], empty_group()}, fn
        {"user-agent", value}, {groups, %{rules: [], crawl_delay: nil} = current} ->
          {groups, %{current | agents: current.agents ++ [String.downcase(value)]}}

        {"user-agent", value}, {groups, current} ->
          {[current | groups], %{empty_group() | agents: [String.downcase(value)]}}

        {"allow", value}, {groups, current} ->
          {groups, %{current | rules: current.rules ++ [{:allow, value}]}}

        {"disallow", ""}, accumulator ->
          accumulator

        {"disallow", value}, {groups, current} ->
          {groups, %{current | rules: current.rules ++ [{:disallow, value}]}}

        {"crawl-delay", value}, {groups, current} ->
          {groups, %{current | crawl_delay: parse_delay(value)}}

        _directive, accumulator ->
          accumulator
      end)

    [current | groups]
    |> Enum.reverse()
    |> Enum.reject(&(&1.agents == []))
  end

  defp matching_group(%{groups: groups}) do
    Enum.find(groups, &("paigebot" in &1.agents)) ||
      Enum.find(groups, &("*" in &1.agents)) || empty_group()
  end

  defp matching_group(_policy), do: empty_group()

  defp parse_line(line) do
    line = line |> String.split("#", parts: 2) |> hd() |> String.trim()

    case String.split(line, ":", parts: 2) do
      [name, value] ->
        name = name |> String.trim() |> String.downcase()

        if name in ["user-agent", "allow", "disallow", "crawl-delay", "sitemap"],
          do: {name, String.trim(value)}

      _parts ->
        nil
    end
  end

  defp parse_delay(value) do
    case Float.parse(value) do
      {delay, ""} when delay >= 0 -> delay
      _invalid -> nil
    end
  end

  defp matches?(pattern, path) do
    end_anchored? = String.ends_with?(pattern, "$")
    pattern = String.trim_trailing(pattern, "$")

    source =
      pattern
      |> Regex.escape()
      |> String.replace("\\*", ".*")

    suffix = if end_anchored?, do: "$", else: ".*"
    Regex.match?(Regex.compile!("^#{source}#{suffix}"), path)
  end

  defp rule_length(pattern), do: pattern |> String.replace(["*", "$"], "") |> String.length()

  defp request_path(url) do
    uri = URI.parse(url)
    path = if uri.path in [nil, ""], do: "/", else: uri.path
    if uri.query in [nil, ""], do: path, else: "#{path}?#{uri.query}"
  end

  defp empty_group, do: %{agents: [], rules: [], crawl_delay: nil}
end
