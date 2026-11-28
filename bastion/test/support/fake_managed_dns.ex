defmodule Bastion.FakeManagedDNS do
  def records(_zone), do: {:ok, []}
  def add(_zone, _subdomain, _type, _address), do: {:ok, %{}}
  def remove(_zone, _subdomain, _type, _address), do: {:ok, %{}}
end
