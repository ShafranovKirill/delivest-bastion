defmodule Bastion.Repo.Migrations.AddManagedNodes do
  use Ecto.Migration

  def change do
    alter table(:instances) do
      add :transport, :string, null: false, default: "agent"
      add :desired_state, :string
      add :desired_release, :string
    end

    create constraint(:instances, :instances_transport_check,
             check: "transport IN ('agent', 'node')"
           )

    create table(:nodes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :registration_token_hash, :binary
      add :credential_hash, :binary
      add :credential_revision, :integer, null: false, default: 0
      add :credential_revoked_at, :utc_datetime_usec
      add :maintenance, :boolean, null: false, default: false
      add :version, :string
      add :last_seen_at, :utc_datetime_usec
      add :sampled_at, :utc_datetime_usec
      add :metrics, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:nodes, [:registration_token_hash])
    create unique_index(:nodes, [:credential_hash])

    create table(:placements, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :instance_id, references(:instances, type: :binary_id, on_delete: :restrict),
        null: false

      add :node_id, references(:nodes, type: :binary_id, on_delete: :restrict), null: false
      add :revision, :integer, null: false
      add :project_name, :string, null: false
      add :gateway_port, :integer, null: false
      add :state, :string, null: false, default: "reserved"
      add :observed_state, :string
      add :observed_release, :string
      add :observed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:placements, :placements_revision_positive, check: "revision > 0")

    create constraint(:placements, :placements_gateway_port_range,
             check: "gateway_port BETWEEN 1024 AND 65535"
           )

    create constraint(:placements, :placements_state_check,
             check: "state IN ('reserved', 'active', 'retired')"
           )

    create unique_index(:placements, [:instance_id, :revision])
    create unique_index(:placements, [:instance_id], where: "state = 'active'")
    create unique_index(:placements, [:node_id, :project_name], where: "state != 'retired'")
    create unique_index(:placements, [:node_id, :gateway_port], where: "state != 'retired'")
    create index(:placements, [:node_id])

    create table(:domains, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :hostname, :string, null: false
      add :zone, :string
      add :owner, :string
      add :dns_mode, :string
      add :dns_observation, :map, null: false, default: %{}
      add :https_observation, :map, null: false, default: %{}
      add :observed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:domains, [:hostname])

    create table(:domain_bindings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :domain_id, references(:domains, type: :binary_id, on_delete: :restrict), null: false

      add :instance_id, references(:instances, type: :binary_id, on_delete: :restrict),
        null: false

      add :purpose, :string, null: false
      add :primary, :boolean, null: false, default: false
      add :routing, :string, null: false, default: "serve"
      add :state, :string, null: false, default: "reserved"
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:domain_bindings, [:domain_id], where: "state != 'released'")

    create unique_index(:domain_bindings, [:instance_id],
             where: "purpose = 'site' AND \"primary\" = true AND state = 'active'",
             name: :domain_bindings_one_primary_site
           )

    create table(:node_operations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :node_id, references(:nodes, type: :binary_id, on_delete: :restrict), null: false
      add :instance_id, references(:instances, type: :binary_id, on_delete: :restrict)
      add :placement_id, references(:placements, type: :binary_id, on_delete: :restrict)
      add :placement_revision, :integer
      add :action, :string, null: false
      add :args, :map, null: false, default: %{}
      add :status, :string, null: false, default: "pending"
      add :progress, :map, null: false, default: %{}
      add :result, :map, null: false, default: %{}
      add :requested_by, :string
      add :acknowledged_at, :utc_datetime_usec
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:node_operations, :node_operations_status_check,
             check:
               "status IN ('pending', 'running', 'waiting_external', 'ok', 'error', 'unknown')"
           )

    create constraint(:node_operations, :node_operations_target_check,
             check:
               "(instance_id IS NULL AND placement_id IS NULL AND placement_revision IS NULL) OR " <>
                 "(instance_id IS NOT NULL AND placement_id IS NOT NULL AND placement_revision IS NOT NULL)"
           )

    create unique_index(:node_operations, [:instance_id],
             where:
               "instance_id IS NOT NULL AND status IN ('pending', 'running', 'waiting_external', 'unknown')",
             name: :node_operations_one_unresolved_per_instance
           )

    create index(:node_operations, [:node_id, :inserted_at])

    create table(:node_metric_samples, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :node_id, references(:nodes, type: :binary_id, on_delete: :delete_all), null: false
      add :sample_id, :string, null: false
      add :sampled_at, :utc_datetime_usec, null: false
      add :received_at, :utc_datetime_usec, null: false
      add :metrics, :map, null: false, default: %{}
    end

    create unique_index(:node_metric_samples, [:node_id, :sample_id])
    create index(:node_metric_samples, [:node_id, :sampled_at])

    alter table(:snapshots) do
      add :node_operation_id,
          references(:node_operations, type: :binary_id, on_delete: :nilify_all)

      add :checksum, :string
      add :release_compatibility, :map, null: false, default: %{}
      add :integrity_checked_at, :utc_datetime_usec
      add :restore_checked_at, :utc_datetime_usec
    end

    create unique_index(:snapshots, [:node_operation_id])
  end
end
