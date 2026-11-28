defmodule Bastion.Repo.Migrations.AddDomainOnboarding do
  use Ecto.Migration

  def change do
    alter table(:nodes) do
      add :public_ipv4, :string
      add :public_ipv6, :string
      add :ssh_host, :string
      add :ssh_port, :integer
      add :ssh_login, :string
      add :ssh_fingerprint, :string
      add :install_status, :string, null: false, default: "not_started"
      add :install_progress, :map, null: false, default: %{}
      add :install_error, :string
      add :infrastructure, :map, null: false, default: %{}
    end

    create unique_index(:nodes, [:ssh_host, :ssh_port],
             where: "ssh_host IS NOT NULL",
             name: :nodes_one_ssh_target
           )

    alter table(:domains) do
      add :state, :string, null: false, default: "free"
      add :failure_reason, :string
      add :next_step, :string
    end

    alter table(:domain_bindings) do
      add :verification_token_hash, :binary
      add :verification_name, :string
      add :expected_records, :map, null: false, default: %{}
      add :observed_records, :map, null: false, default: %{}
      add :owned_records, :map, null: false, default: %{}
      add :active_operation_id, :binary_id
      add :certificate_expires_at, :utc_datetime_usec
      add :last_checked_at, :utc_datetime_usec
      add :failure_reason, :string
      add :next_step, :string
    end

    create table(:dns_zone_credentials, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :zone, :string, null: false
      add :provider, :string, null: false
      add :username, :string, null: false
      add :secret_ciphertext, :binary, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:dns_zone_credentials, [:zone, :provider])

    create unique_index(:node_operations, [:node_id],
             where:
               "action = 'provision_node' AND status IN ('pending', 'running', 'waiting_external')",
             name: :node_operations_one_install_per_node
           )

    create unique_index(:domain_bindings, [:instance_id, :purpose],
             where: "\"primary\" = true AND state != 'released'",
             name: :domain_bindings_one_primary_live
           )
  end
end
