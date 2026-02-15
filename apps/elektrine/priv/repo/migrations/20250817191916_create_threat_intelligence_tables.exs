defmodule Elektrine.Repo.Migrations.CreateThreatIntelligenceTables do
  use Ecto.Migration

  def change do
    # Threat intelligence feeds - external sources of threat data
    create table(:threat_feeds) do
      add :name, :string, null: false
      # malware, ip_reputation, domain_reputation, ioc, ransomware
      add :type, :string, null: false
      add :url, :string
      add :description, :text
      add :active, :boolean, default: true
      # seconds
      add :update_frequency, :integer, default: 3600
      add :last_updated, :utc_datetime
      # success, failure, pending
      add :last_sync_status, :string, default: "pending"
      # feed-specific configuration
      add :config, :map, default: %{}
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps()
    end

    create index(:threat_feeds, [:user_id])
    create index(:threat_feeds, [:type])
    create index(:threat_feeds, [:active])
    create unique_index(:threat_feeds, [:user_id, :name])

    # Threat indicators - specific threat intelligence data points
    create table(:threat_indicators) do
      # ip, domain, url, file_hash, email, user_agent
      add :type, :string, null: false
      # the actual indicator value
      add :value, :string, null: false
      # malware, ransomware, phishing, botnet, c2, etc.
      add :threat_type, :string, null: false
      # critical, high, medium, low
      add :severity, :string, null: false
      # confidence score 0.0-1.0
      add :confidence, :float
      add :first_seen, :utc_datetime, null: false
      add :last_seen, :utc_datetime, null: false
      # active, expired, false_positive
      add :status, :string, default: "active"
      add :description, :text
      # e.g., "Emotet", "Ryuk", "Conti"
      add :malware_family, :string
      # e.g., "email", "web", "usb"
      add :attack_vector, :string
      # healthcare, finance, government
      add :target_sector, {:array, :string}, default: []
      # affected countries
      add :countries, {:array, :string}, default: []
      add :tags, {:array, :string}, default: []
      # URLs to reports/analysis
      add :references, {:array, :string}, default: []
      # MITRE ATT&CK TTPs
      add :ttps, {:array, :string}, default: []
      # reconnaissance, weaponization, delivery, etc.
      add :kill_chain_phase, :string
      # when this indicator expires
      add :expires_at, :utc_datetime
      # manually whitelisted
      add :whitelisted, :boolean, default: false
      add :feed_id, references(:threat_feeds, on_delete: :delete_all), null: false

      timestamps()
    end

    create index(:threat_indicators, [:feed_id])
    create index(:threat_indicators, [:type])
    create index(:threat_indicators, [:value])
    create index(:threat_indicators, [:threat_type])
    create index(:threat_indicators, [:severity])
    create index(:threat_indicators, [:status])
    create index(:threat_indicators, [:first_seen])
    create index(:threat_indicators, [:expires_at])
    create index(:threat_indicators, [:malware_family])
    create unique_index(:threat_indicators, [:feed_id, :type, :value])

    # Threat campaigns - organized threat actor campaigns
    create table(:threat_campaigns) do
      add :name, :string, null: false
      add :description, :text
      # APT group, criminal organization, etc.
      add :threat_actor, :string
      # financial, espionage, disruption, etc.
      add :motivation, :string
      # low, medium, high, nation_state
      add :sophistication, :string
      add :first_activity, :utc_datetime
      add :last_activity, :utc_datetime
      # active, dormant, disrupted
      add :status, :string, default: "active"
      add :target_sectors, {:array, :string}, default: []
      add :target_countries, {:array, :string}, default: []
      add :ttps, {:array, :string}, default: []
      add :malware_families, {:array, :string}, default: []
      add :attack_vectors, {:array, :string}, default: []
      # other names for this campaign
      add :aliases, {:array, :string}, default: []
      add :references, {:array, :string}, default: []
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps()
    end

    create index(:threat_campaigns, [:user_id])
    create index(:threat_campaigns, [:threat_actor])
    create index(:threat_campaigns, [:status])
    create index(:threat_campaigns, [:first_activity])
    create unique_index(:threat_campaigns, [:user_id, :name])

    # Junction table linking campaigns to indicators
    create table(:threat_campaign_indicators) do
      add :campaign_id, references(:threat_campaigns, on_delete: :delete_all), null: false
      add :indicator_id, references(:threat_indicators, on_delete: :delete_all), null: false
      # primary, secondary, infrastructure, tool
      add :role, :string

      timestamps()
    end

    create unique_index(:threat_campaign_indicators, [:campaign_id, :indicator_id])

    # Threat matches - when SIEM events match threat intelligence
    create table(:threat_matches) do
      add :matched_at, :utc_datetime, null: false
      # exact, partial, behavioral
      add :match_type, :string, null: false
      # match confidence score
      add :confidence, :float
      # additional context about the match
      add :context, :text
      # blocked, alerted, logged, investigated
      add :action_taken, :string
      add :false_positive, :boolean, default: false
      add :notes, :text
      add :event_id, references(:siem_events, on_delete: :delete_all), null: false
      add :indicator_id, references(:threat_indicators, on_delete: :delete_all), null: false
      # created alert if any
      add :alert_id, references(:siem_alerts, on_delete: :nilify_all)

      timestamps()
    end

    create index(:threat_matches, [:event_id])
    create index(:threat_matches, [:indicator_id])
    create index(:threat_matches, [:alert_id])
    create index(:threat_matches, [:matched_at])
    create index(:threat_matches, [:match_type])
    create unique_index(:threat_matches, [:event_id, :indicator_id])

    # Data breach tracking - track known data breaches and compromised credentials
    create table(:data_breaches) do
      # e.g., "Equifax 2017", "LinkedIn 2012"
      add :name, :string, null: false
      add :organization, :string, null: false
      add :breach_date, :date
      add :discovery_date, :date
      add :disclosure_date, :date
      add :records_affected, :bigint
      # emails, passwords, ssn, cc_numbers
      add :data_types, {:array, :string}, default: []
      # hack, insider, lost_device, misconfiguration
      add :breach_type, :string
      # phishing, malware, sql_injection, etc.
      add :attack_vector, :string
      # healthcare, finance, retail, etc.
      add :sector, :string
      add :country, :string
      add :description, :text
      # critical, high, medium, low
      add :severity, :string
      # active, contained, resolved
      add :status, :string, default: "active"
      add :references, {:array, :string}, default: []
      add :estimated_cost, :decimal
      add :regulatory_action, :text
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps()
    end

    create index(:data_breaches, [:user_id])
    create index(:data_breaches, [:organization])
    create index(:data_breaches, [:breach_date])
    create index(:data_breaches, [:severity])
    create index(:data_breaches, [:sector])
    create unique_index(:data_breaches, [:user_id, :name])

    # Compromised credentials from breaches
    create table(:compromised_credentials) do
      add :email, :string, null: false
      add :password_hash, :string
      add :domain, :string
      # which breach this came from
      add :source_breach, :string
      add :breach_date, :date
      # phone, address, etc.
      add :additional_data, :map, default: %{}
      # verified as genuine
      add :verified, :boolean, default: false
      add :severity, :string, default: "medium"
      add :breach_id, references(:data_breaches, on_delete: :delete_all)
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps()
    end

    create index(:compromised_credentials, [:user_id])
    create index(:compromised_credentials, [:email])
    create index(:compromised_credentials, [:domain])
    create index(:compromised_credentials, [:breach_id])
    create index(:compromised_credentials, [:breach_date])
    create unique_index(:compromised_credentials, [:user_id, :email, :source_breach])

    # Ransomware tracking - specific ransomware threat tracking
    create table(:ransomware_threats) do
      # Ryuk, Conti, LockBit, etc.
      add :family, :string, null: false
      # specific variant or version
      add :variant, :string
      add :description, :text
      add :first_seen, :utc_datetime, null: false
      add :last_activity, :utc_datetime
      # active, disrupted, dormant
      add :status, :string, default: "active"
      # .locked, .encrypted, etc.
      add :file_extensions, {:array, :string}, default: []
      # HOW_TO_DECRYPT.txt
      add :ransom_note_names, {:array, :string}, default: []
      # AES, RSA, etc.
      add :encryption_algorithm, :string
      # bitcoin, monero
      add :payment_methods, {:array, :string}, default: []
      # average ransom amount in USD
      add :average_ransom, :decimal
      # email, rdp, web, etc.
      add :attack_vectors, {:array, :string}, default: []
      add :target_sectors, {:array, :string}, default: []
      # threat actor or group
      add :attribution, :string
      # file hashes, C2 domains
      add :iocs, {:array, :string}, default: []
      # MITRE techniques
      add :ttps, {:array, :string}, default: []
      add :references, {:array, :string}, default: []
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps()
    end

    create index(:ransomware_threats, [:user_id])
    create index(:ransomware_threats, [:family])
    create index(:ransomware_threats, [:status])
    create index(:ransomware_threats, [:first_seen])
    create unique_index(:ransomware_threats, [:user_id, :family, :variant])

    # Junction table linking ransomware to indicators
    create table(:ransomware_indicators) do
      add :ransomware_id, references(:ransomware_threats, on_delete: :delete_all), null: false
      add :indicator_id, references(:threat_indicators, on_delete: :delete_all), null: false
      # payload, c2, dropper, lateral_movement
      add :indicator_role, :string

      timestamps()
    end

    create unique_index(:ransomware_indicators, [:ransomware_id, :indicator_id])
  end
end
