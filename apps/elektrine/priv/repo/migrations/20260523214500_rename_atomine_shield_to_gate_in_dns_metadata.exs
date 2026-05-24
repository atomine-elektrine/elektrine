defmodule Elektrine.Repo.Migrations.RenameAtomineShieldToGateInDNSMetadata do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE dns_records
    SET metadata = jsonb_set(
      metadata #- '{proxy,atomine_shield}',
      '{proxy,atomine_gate}',
      metadata #> '{proxy,atomine_shield}',
      true
    )
    WHERE metadata #> '{proxy,atomine_shield}' IS NOT NULL
    """)
  end

  def down do
    execute("""
    UPDATE dns_records
    SET metadata = jsonb_set(
      metadata #- '{proxy,atomine_gate}',
      '{proxy,atomine_shield}',
      metadata #> '{proxy,atomine_gate}',
      true
    )
    WHERE metadata #> '{proxy,atomine_gate}' IS NOT NULL
    """)
  end
end
