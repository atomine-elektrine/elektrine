defmodule Elektrine.Search.DomainRule do
  @moduledoc """
  A per-user ranking rule for a web-search domain: block it entirely, lower
  or raise its ranking, or pin it to the top of results.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @actions [:block, :lower, :raise, :pin]

  schema "search_domain_rules" do
    field :domain, :string
    field :action, Ecto.Enum, values: @actions

    belongs_to :user, Elektrine.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def actions, do: @actions

  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [:domain, :action])
    |> update_change(:domain, &normalize_domain/1)
    |> validate_required([:domain, :action])
    |> validate_length(:domain, max: 253)
    |> validate_format(:domain, ~r/^(?!-)[a-z0-9-]{1,63}(?<!-)(\.(?!-)[a-z0-9-]{1,63}(?<!-))+$/,
      message: "must be a valid domain"
    )
    |> unique_constraint([:user_id, :domain])
  end

  @doc "Lowercases and strips a leading `www.`/trailing dot so rules match hosts."
  def normalize_domain(domain) when is_binary(domain) do
    domain
    |> String.trim()
    |> String.downcase()
    |> String.replace_prefix("www.", "")
    |> String.trim_trailing(".")
  end

  def normalize_domain(domain), do: domain
end
