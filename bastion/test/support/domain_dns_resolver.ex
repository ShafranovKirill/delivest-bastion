defmodule Bastion.TestDomainDNS do
  def addresses(_hostname), do: Application.fetch_env!(:bastion, :test_domain_addresses)
  def txt(_hostname), do: Application.fetch_env!(:bastion, :test_domain_txt)
end
