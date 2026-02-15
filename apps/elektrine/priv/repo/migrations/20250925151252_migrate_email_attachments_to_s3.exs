defmodule Elektrine.Repo.Migrations.MigrateEmailAttachmentsToS3 do
  use Ecto.Migration

  def change do
    # This migration doesn't change the database schema
    # It's a marker for when we started using S3/R2 for attachments
    # Existing attachments will continue to work with fallback to database storage
    # New attachments will be stored in S3/R2

    # Optional: Add a column to track migration status per message
    # This is commented out by default to avoid locking the messages table
    # Uncomment if you want to track migration status per message

    # alter table(:email_messages) do
    #   add :attachments_migrated_to_s3, :boolean, default: false
    # end

    # create index(:email_messages, [:attachments_migrated_to_s3])
  end
end
