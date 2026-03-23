defmodule Elektrine.Repo.Migrations.RemoveDnsVerificationFields do
  use Ecto.Migration

  def change do
    alter table(:dns_zones) do
      remove :verification_method, :string
      remove :verification_token, :string
    end
  end
end
