defmodule Elektrine.Repo.Migrations.RenameEarlyAdopterToBetaTester do
  use Ecto.Migration

  def up do
    execute "UPDATE user_badges SET badge_type = 'beta_tester', badge_text = 'Beta Tester', tooltip = 'Beta tester' WHERE badge_type = 'early_adopter'"
  end

  def down do
    execute "UPDATE user_badges SET badge_type = 'early_adopter', badge_text = 'Early Adopter', tooltip = 'Early adopter' WHERE badge_type = 'beta_tester'"
  end
end
