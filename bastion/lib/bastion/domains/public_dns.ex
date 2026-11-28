defmodule Bastion.Domains.PublicDNS do
  @moduledoc "Public DNS observations; resolver can be replaced in isolated tests."

  @resolvers [{{1, 1, 1, 1}, 53}, {{8, 8, 8, 8}, 53}]

  def check(hostname, expected) do
    resolver = Application.get_env(:bastion, :domain_dns_resolver, __MODULE__)

    with {:ok, observed} <- resolver.addresses(hostname) do
      actual = Enum.map(observed, &canonical_ip/1) |> Enum.sort()
      wanted = Enum.map(expected, &canonical_ip/1) |> Enum.sort()
      result = %{"addresses" => actual, "expected" => wanted}
      if actual == wanted, do: {:ok, result}, else: {:error, {:dns_mismatch, result}}
    end
  end

  def check_txt_hash(hostname, expected_hash) do
    resolver = Application.get_env(:bastion, :domain_dns_resolver, __MODULE__)

    with {:ok, values} <- resolver.txt(hostname) do
      if Enum.any?(values, fn value ->
           Plug.Crypto.secure_compare(expected_hash, :crypto.hash(:sha256, value))
         end),
         do: :ok,
         else: {:error, :ownership_unconfirmed}
    end
  end

  def addresses(hostname) do
    with {:ok, a} <- lookup(hostname, :a),
         {:ok, aaaa} <- lookup(hostname, :aaaa) do
      {:ok, Enum.uniq(Enum.map(a ++ aaaa, &(:inet.ntoa(&1) |> to_string())))}
    end
  end

  def txt(hostname) do
    with {:ok, records} <- lookup(hostname, :txt) do
      {:ok, Enum.map(records, &IO.iodata_to_binary/1)}
    end
  end

  defp lookup(hostname, type) do
    case :inet_res.resolve(String.to_charlist(hostname), :in, type, [
           {:nameservers, @resolvers},
           {:timeout, 3_000},
           {:retry, 2}
         ]) do
      {:ok, {:dns_rec, _header, _queries, answers, _authority, _additional}} ->
        {:ok, for({:dns_rr, _, ^type, :in, _, _, data, _, _, _} <- answers, do: data)}

      {:error, :nxdomain} ->
        {:ok, []}

      {:error, reason} ->
        {:error, {:dns_lookup_failed, reason}}
    end
  end

  defp canonical_ip(value) do
    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, parsed} -> :inet.ntoa(parsed) |> to_string()
      _ -> value
    end
  end
end
