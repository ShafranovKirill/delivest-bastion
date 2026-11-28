defmodule Bastion.BlockingDomainDNS do
  def addresses(_hostname) do
    send(Application.fetch_env!(:bastion, :dns_block_pid), {:dns_waiting, self()})

    receive do
      :continue -> {:ok, ["8.8.8.8"]}
    after
      5_000 -> {:error, :test_timeout}
    end
  end

  def txt(_hostname), do: Application.fetch_env!(:bastion, :test_domain_txt)
end
