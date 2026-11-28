defmodule Bastion.DomainsTest do
  use Bastion.DataCase, async: false

  import Bastion.Fixtures

  alias Bastion.Domains

  test "canonical domain is reserved for only one franchise" do
    first = instance_fixture()
    second = instance_fixture()

    assert {:ok, domain} = Domains.create_domain(%{"hostname" => "Cafe.Example.COM."})
    assert domain.hostname == "cafe.example.com"
    assert {:error, changeset} = Domains.create_domain(%{"hostname" => "cafe.example.com"})
    assert errors_on(changeset).hostname

    assert {:ok, binding} = Domains.reserve(domain.id, first.id, "site", true)
    assert binding.instance_id == first.id
    assert {:error, :already_bound} = Domains.reserve(domain.id, second.id, "site", true)
  end

  test "invalid labels and unconverted Unicode names are rejected" do
    assert {:error, _} = Domains.create_domain(%{"hostname" => "-invalid.example"})
    assert {:error, _} = Domains.create_domain(%{"hostname" => "пример.рф"})
  end
end
