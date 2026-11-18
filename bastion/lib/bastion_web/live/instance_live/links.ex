defmodule BastionWeb.InstanceLive.Links do
  @moduledoc "Safe URLs for the instance's server administration and client site."

  def server_url(host), do: url(host, :server)
  def client_url(host), do: url(host, :client)

  def display(host) do
    case parse(host) do
      {:ok, uri} -> uri.authority <> (uri.path || "")
      :error -> "Не настроен"
    end
  end

  defp url(host, kind) do
    case parse(host) do
      {:ok, uri} ->
        path = if kind == :server, do: "/staff", else: client_path(uri.path)
        URI.to_string(%{uri | path: path})

      :error ->
        nil
    end
  end

  defp client_path(path) when path in [nil, ""], do: "/"
  defp client_path(path), do: path

  defp parse(host) when is_binary(host) do
    value = String.trim(host)

    if value == "" or String.match?(value, ~r/[\s\x00-\x1f\x7f]/u) do
      :error
    else
      value = if String.contains?(value, "://"), do: value, else: "https://" <> value
      uri = URI.parse(value)

      if uri.scheme in ["http", "https"] and valid_host?(uri.host) and
           valid_authority?(uri.authority, uri.host) and is_nil(uri.userinfo) and
           is_nil(uri.query) and
           is_nil(uri.fragment) and (is_nil(uri.path) or String.starts_with?(uri.path, "/")) and
           valid_port?(uri.port) do
        {:ok, uri}
      else
        :error
      end
    end
  end

  defp parse(_host), do: :error

  defp valid_host?(host) when is_binary(host) do
    byte_size(host) <= 253 and
      (match?({:ok, _}, :inet.parse_address(String.to_charlist(host))) or
         Enum.all?(String.split(host, "."), fn label ->
           label != "" and byte_size(label) <= 63 and
             Regex.match?(~r/^[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?$/, label)
         end))
  end

  defp valid_host?(_host), do: false

  defp valid_authority?(authority, host) when is_binary(authority) and is_binary(host) do
    base = if String.contains?(host, ":"), do: "[#{host}]", else: host
    authority == base or Regex.match?(~r/^#{Regex.escape(base)}:\d+$/, authority)
  end

  defp valid_authority?(_authority, _host), do: false
  defp valid_port?(port), do: is_integer(port) and port in 1..65_535
end
