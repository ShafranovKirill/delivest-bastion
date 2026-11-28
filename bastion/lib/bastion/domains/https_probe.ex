defmodule Bastion.Domains.HttpsProbe do
  @moduledoc "Independent TLS and HTTP check after Node reports a route ready."

  def check(hostname, binding_id, expected_addresses, purpose) do
    options = Application.get_env(:bastion, :req_options, [])

    try do
      with {:ok, _} <- Bastion.Domains.PublicDNS.check(hostname, expected_addresses) do
        path = if purpose in ~w(api admin), do: "/ready", else: "/"

        case Req.get(
               "https://" <> hostname <> path,
               Keyword.merge(options,
                 redirect: false,
                 retry: false,
                 receive_timeout: 8_000,
                 connect_options: [timeout: 5_000]
               )
             ) do
          {:ok, %Req.Response{status: status} = response}
          when status in 200..299 or (purpose == "media" and status == 403) ->
            if Req.Response.get_header(response, "x-delivest-binding-id") == [binding_id] do
              {:ok,
               %{"status" => status, "checked_at" => DateTime.utc_now() |> DateTime.to_iso8601()}}
            else
              {:error, :wrong_route}
            end

          {:ok, %Req.Response{status: status}} ->
            {:error, {:http_status, status}}

          {:error, _} ->
            {:error, :https_failed}
        end
      end
    rescue
      _ -> {:error, :https_failed}
    end
  end
end
