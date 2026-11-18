defmodule Bastion.Checks.External do
  @checked ["api", "site"]

  def run(hosts) when is_map(hosts) do
    hosts
    |> Map.take(@checked)
    |> Enum.reject(fn {_kind, host} -> host in [nil, ""] end)
    |> Map.new(fn {kind, host} -> {kind, check(host, kind)} end)
  end

  def check(host), do: check(host, "site")

  def check(host, kind) do
    started = System.monotonic_time(:millisecond)
    path = if kind == "api", do: "/ready", else: "/"

    http =
      case Req.get(
             "https://#{host}#{path}",
             [retry: false, redirect: false, receive_timeout: 10_000] ++ req_options()
           ) do
        {:ok, %{status: 200, body: body}} ->
          if ready?(kind, body),
            do: %{"ok" => true, "status" => 200},
            else: %{"ok" => false, "status" => 200, "error" => "приложение не готово"}

        {:ok, %{status: status}} ->
          %{"ok" => false, "status" => status}

        {:error, error} ->
          %{"ok" => false, "error" => Exception.message(error)}
      end

    http
    |> Map.put("ms", System.monotonic_time(:millisecond) - started)
    |> Map.put("cert_expires_at", cert_expires_at(host))
  end

  # An answer is not readiness: the API has to confirm its status, and the site
  # has to return the application document instead of an error or maintenance page.
  defp ready?("api", body) when is_map(body), do: body["status"] == "ok"

  defp ready?("api", body) when is_binary(body),
    do: match?({:ok, %{"status" => "ok"}}, Jason.decode(body))

  defp ready?("site", body) when is_binary(body), do: String.contains?(body, ~s(id="app"))
  defp ready?(_kind, _body), do: false

  def cert_expires_at(host) do
    if Application.get_env(:bastion, :check_certs, true) do
      fetch_cert_expiry(host)
    end
  end

  defp fetch_cert_expiry(host) do
    charlist = String.to_charlist(host)

    opts = [
      verify: :verify_none,
      server_name_indication: charlist,
      versions: [:"tlsv1.3", :"tlsv1.2"]
    ]

    with {:ok, socket} <- :ssl.connect(charlist, 443, opts, 5_000),
         {:ok, der} <- peercert(socket) do
      der
      |> :public_key.pkix_decode_cert(:otp)
      |> then(fn cert -> elem(elem(cert, 1), 5) end)
      |> elem(2)
      |> parse_time()
    else
      _ -> nil
    end
  end

  defp peercert(socket) do
    result = :ssl.peercert(socket)
    :ssl.close(socket)
    result
  end

  defp parse_time({:utcTime, time}), do: parse_time(~c"20" ++ time)
  defp parse_time({:generalTime, time}), do: parse_time(time)

  defp parse_time(time) do
    <<y::binary-4, mo::binary-2, d::binary-2, h::binary-2, mi::binary-2, s::binary-2, _::binary>> =
      to_string(time)

    "#{y}-#{mo}-#{d}T#{h}:#{mi}:#{s}Z"
  end

  defp req_options, do: Application.get_env(:bastion, :req_options, [])
end
