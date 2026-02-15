defmodule Elektrine.CustomDomains.CustomDomainAddress do
  @moduledoc """
  Schema for email addresses on custom domains.

  Each custom domain can have multiple email addresses (local parts) configured,
  each pointing to a user's mailbox. For example, if a user owns "example.com",
  they can configure:

  - info@example.com -> their mailbox
  - contact@example.com -> their mailbox
  - sales@example.com -> their mailbox

  The catch-all functionality is configured on the CustomDomain itself.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "custom_domain_addresses" do
    field :local_part, :string
    field :enabled, :boolean, default: true
    field :description, :string

    belongs_to :custom_domain, Elektrine.CustomDomains.CustomDomain
    belongs_to :mailbox, {"mailboxes", Elektrine.Email.Mailbox}

    timestamps()
  end

  @doc """
  Changeset for creating a new custom domain address.
  """
  def create_changeset(address, attrs) do
    address
    |> cast(attrs, [:local_part, :custom_domain_id, :mailbox_id, :description])
    |> validate_required([:local_part, :custom_domain_id, :mailbox_id])
    |> validate_local_part()
    |> unique_constraint([:custom_domain_id, :local_part],
      message: "this address already exists on this domain"
    )
  end

  @doc """
  Changeset for updating a custom domain address.
  """
  def update_changeset(address, attrs) do
    address
    |> cast(attrs, [:enabled, :description, :mailbox_id])
    |> validate_required([:mailbox_id])
  end

  @doc """
  Returns the full email address string.
  """
  def full_address(%__MODULE__{local_part: local_part} = address) do
    domain = address.custom_domain.domain
    "#{local_part}@#{domain}"
  end

  # Private functions

  defp validate_local_part(changeset) do
    changeset
    |> validate_length(:local_part, min: 1, max: 64)
    |> validate_format(:local_part, ~r/^[a-z0-9]([a-z0-9._-]*[a-z0-9])?$/i,
      message: "must contain only letters, numbers, dots, underscores, or hyphens"
    )
    |> validate_not_reserved_local_part()
    |> update_change(:local_part, &String.downcase/1)
  end

  defp validate_not_reserved_local_part(changeset) do
    local_part = get_change(changeset, :local_part)

    if local_part do
      local_lower = String.downcase(local_part)

      # Reserved local parts that could be abused or cause confusion
      reserved = ~w(
        postmaster abuse admin administrator hostmaster webmaster
        mailer-daemon no-reply noreply do-not-reply donotreply
        root daemon bin sys mail news uucp proxy www-data
        security support help info sales contact
      )

      if local_lower in reserved do
        add_error(changeset, :local_part, "is a reserved address")
      else
        changeset
      end
    else
      changeset
    end
  end
end
