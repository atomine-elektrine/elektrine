defmodule Elektrine.Repo.Migrations.AddUndergroundThreatIntelligence do
  use Ecto.Migration

  def change do
    # Ransomware group tracking with .onion infrastructure and victims
    create table(:ransomware_groups) do
      # "LockBit", "BlackCat", etc.
      add :name, :string, null: false
      # other known names
      add :aliases, {:array, :string}, default: []
      add :description, :text
      add :first_seen, :utc_datetime, null: false
      add :last_activity, :utc_datetime
      # active, disrupted, dormant
      add :status, :string, default: "active"
      # .onion leak sites
      add :onion_addresses, {:array, :string}, default: []
      # clearnet mirrors
      add :clearnet_addresses, {:array, :string}, default: []
      # TOX, Jabber, etc.
      add :contact_methods, {:array, :string}, default: []
      # crypto wallets
      add :payment_addresses, {:array, :string}, default: []
      # AES, RSA, etc.
      add :encryption_methods, {:array, :string}, default: []
      # .locked, .encrypted
      add :file_extensions, {:array, :string}, default: []
      add :ransom_note_filenames, {:array, :string}, default: []
      add :target_countries, {:array, :string}, default: []
      add :target_sectors, {:array, :string}, default: []
      add :attack_vectors, {:array, :string}, default: []
      add :total_victims, :integer, default: 0
      # total ransom collected
      add :estimated_revenue, :decimal
      # average demand
      add :average_ransom, :decimal
      # MITRE techniques
      add :ttps, {:array, :string}, default: []
      # threat actor attribution
      add :attribution, :string
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps()
    end

    create index(:ransomware_groups, [:user_id])
    create index(:ransomware_groups, [:name])
    create index(:ransomware_groups, [:status])
    create index(:ransomware_groups, [:last_activity])
    create unique_index(:ransomware_groups, [:user_id, :name])

    # Ransomware victims tracked from leak sites
    create table(:ransomware_victims) do
      add :organization_name, :string, null: false
      add :domain, :string
      add :sector, :string
      add :country, :string
      # small, medium, large, enterprise
      add :victim_size, :string
      add :attack_date, :date
      add :leak_date, :date
      # if known
      add :ransom_amount, :decimal
      # if known
      add :paid_ransom, :boolean
      # financial, personal, medical
      add :data_types, {:array, :string}, default: []
      add :estimated_records, :bigint
      # URL to leak post
      add :leak_url, :string
      # active, removed, expired
      add :leak_status, :string, default: "active"
      add :description, :text

      add :ransomware_group_id, references(:ransomware_groups, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps()
    end

    create index(:ransomware_victims, [:user_id])
    create index(:ransomware_victims, [:ransomware_group_id])
    create index(:ransomware_victims, [:organization_name])
    create index(:ransomware_victims, [:sector])
    create index(:ransomware_victims, [:attack_date])
    create index(:ransomware_victims, [:leak_date])
    create unique_index(:ransomware_victims, [:user_id, :organization_name, :attack_date])

    # Underground forums and markets (.onion sites)
    create table(:underground_forums) do
      add :name, :string, null: false
      # "forum", "market", "service", "leak_site"
      add :type, :string, null: false
      add :onion_address, :string
      add :clearnet_mirrors, {:array, :string}, default: []
      add :description, :text
      add :language, :string, default: "en"
      # active, offline, seized, unknown
      add :status, :string, default: "active"
      add :last_checked, :utc_datetime
      add :registration_required, :boolean, default: true
      # btc, xmr, etc.
      add :payment_methods, {:array, :string}, default: []
      # 0.0-1.0 based on reliability
      add :reputation_score, :float
      # if known
      add :member_count, :integer
      # carding, malware, etc.
      add :categories, {:array, :string}, default: []
      # low, medium, high, critical
      add :threat_level, :string, default: "medium"
      add :first_seen, :utc_datetime, null: false
      add :tags, {:array, :string}, default: []
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps()
    end

    create index(:underground_forums, [:user_id])
    create index(:underground_forums, [:type])
    create index(:underground_forums, [:status])
    create index(:underground_forums, [:threat_level])
    create index(:underground_forums, [:last_checked])
    create unique_index(:underground_forums, [:user_id, :name])

    # Malware distribution servers and C2 infrastructure
    create table(:malware_servers) do
      add :ip_address, :string
      add :domain, :string
      add :url, :string
      # "c2", "distribution", "panel", "gate"
      add :server_type, :string, null: false
      # associated malware
      add :malware_family, :string
      add :port, :integer
      # http, https, tcp, udp
      add :protocol, :string
      # active, offline, sinkholed
      add :status, :string, default: "active"
      add :first_seen, :utc_datetime, null: false
      add :last_seen, :utc_datetime
      add :last_checked, :utc_datetime
      add :hosting_provider, :string
      add :country, :string
      add :threat_level, :string, default: "high"
      # confidence in assessment
      add :confidence, :float
      # malware samples count
      add :samples_distributed, :integer, default: 0
      # bot count if C2
      add :infected_hosts, :integer, default: 0
      # SSL cert details if HTTPS
      add :ssl_certificate, :text
      # HTTP headers
      add :response_headers, :map, default: %{}
      add :notes, :text
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps()
    end

    create index(:malware_servers, [:user_id])
    create index(:malware_servers, [:ip_address])
    create index(:malware_servers, [:domain])
    create index(:malware_servers, [:server_type])
    create index(:malware_servers, [:malware_family])
    create index(:malware_servers, [:status])
    create index(:malware_servers, [:last_seen])
    create unique_index(:malware_servers, [:user_id, :ip_address, :port])

    # Breached database intelligence
    create table(:breached_databases) do
      # database name/source
      add :name, :string, null: false
      add :organization, :string
      add :total_records, :bigint, null: false
      add :breach_date, :date
      # when data appeared underground
      add :leak_date, :date
      # when indexed by criminals
      add :indexed_date, :date
      # emails, passwords, etc.
      add :data_types, {:array, :string}, default: []
      # sql, csv, txt, json
      add :file_format, :string
      # in bytes
      add :file_size, :bigint
      # plaintext, md5, bcrypt, etc.
      add :password_format, :string
      # selling price if commercial
      add :price, :decimal
      # usd, btc, etc.
      add :currency, :string
      # underground seller name
      add :seller, :string
      # where it's being sold
      add :marketplace, :string
      # sample data for verification
      add :sample_records, :text
      # verified, unverified, fake
      add :verification_status, :string, default: "unverified"
      # times downloaded
      add :download_count, :integer, default: 0
      add :sectors, {:array, :string}, default: []
      add :countries, {:array, :string}, default: []
      add :severity, :string, default: "high"
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps()
    end

    create index(:breached_databases, [:user_id])
    create index(:breached_databases, [:organization])
    create index(:breached_databases, [:breach_date])
    create index(:breached_databases, [:leak_date])
    create index(:breached_databases, [:indexed_date])
    create index(:breached_databases, [:verification_status])
    create index(:breached_databases, [:severity])
    create unique_index(:breached_databases, [:user_id, :name, :breach_date])

    # Malicious Telegram channels monitoring
    create table(:telegram_channels) do
      # @channelname
      add :channel_name, :string, null: false
      # telegram channel ID
      add :channel_id, :string
      # t.me/channelname
      add :channel_link, :string
      # display title
      add :title, :string
      add :description, :text
      # "ransomware", "malware", "carding", "dumps"
      add :channel_type, :string, null: false
      add :language, :string, default: "en"
      add :member_count, :integer
      # active, banned, private, deleted
      add :status, :string, default: "active"
      add :first_seen, :utc_datetime, null: false
      add :last_activity, :utc_datetime
      add :last_checked, :utc_datetime
      # "high", "medium", "low"
      add :post_frequency, :string
      add :threat_level, :string, default: "medium"
      # ransomware groups
      add :associated_groups, {:array, :string}, default: []
      # what they discuss
      add :topics, {:array, :string}, default: []
      # verified, unverified
      add :verification_status, :string, default: "unverified"
      add :admin_usernames, {:array, :string}, default: []
      add :related_channels, {:array, :string}, default: []
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps()
    end

    create index(:telegram_channels, [:user_id])
    create index(:telegram_channels, [:channel_name])
    create index(:telegram_channels, [:channel_type])
    create index(:telegram_channels, [:status])
    create index(:telegram_channels, [:threat_level])
    create index(:telegram_channels, [:last_activity])
    create unique_index(:telegram_channels, [:user_id, :channel_name])

    # Telegram message logs for threat intelligence
    create table(:telegram_messages) do
      # telegram message ID
      add :message_id, :string, null: false
      add :sender_username, :string
      add :message_text, :text
      add :message_date, :utc_datetime, null: false
      # photo, document, video, etc.
      add :media_type, :string
      # if media file
      add :file_hash, :string
      # extracted keywords
      add :threat_keywords, {:array, :string}, default: []
      # ransomware groups mentioned
      add :mentioned_groups, {:array, :string}, default: []
      # malware mentioned
      add :mentioned_malware, {:array, :string}, default: []
      # URLs in message
      add :urls_extracted, {:array, :string}, default: []
      # crypto wallets mentioned
      add :crypto_addresses, {:array, :string}, default: []
      # positive, negative, neutral
      add :sentiment, :string
      # calculated threat relevance
      add :threat_score, :float
      add :channel_id, references(:telegram_channels, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps()
    end

    create index(:telegram_messages, [:user_id])
    create index(:telegram_messages, [:channel_id])
    create index(:telegram_messages, [:message_date])
    create index(:telegram_messages, [:sender_username])
    create index(:telegram_messages, [:threat_score])
    create unique_index(:telegram_messages, [:channel_id, :message_id])
  end
end
