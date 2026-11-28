defmodule Bastion.Domains do
  import Ecto.Query

  alias Bastion.Domains.{Binding, Domain}
  alias Bastion.Repo

  def list_domains,
    do: Repo.all(from d in Domain, preload: [:bindings], order_by: [asc: d.hostname])

  def create_domain(attrs) do
    %Domain{} |> Domain.changeset(attrs) |> Repo.insert()
  end

  def reserve(domain_id, instance_id, purpose, primary \\ false) do
    Repo.transaction(fn ->
      domain =
        Repo.one(from d in Domain, where: d.id == ^domain_id, lock: "FOR UPDATE") ||
          Repo.rollback(:domain_not_found)

      if Repo.exists?(
           from b in Binding, where: b.domain_id == ^domain.id and b.state != "released"
         ),
         do: Repo.rollback(:already_bound)

      changeset =
        %Binding{domain_id: domain.id, instance_id: instance_id}
        |> Binding.changeset(%{purpose: purpose, primary: primary, state: "reserved"})

      case Repo.insert(changeset) do
        {:ok, binding} -> binding
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end
end
