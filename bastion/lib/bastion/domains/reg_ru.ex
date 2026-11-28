defmodule Bastion.Domains.RegRu do
  @moduledoc "REG.API 2 DNS adapter; only owned record tuples may be deleted."
  alias Bastion.Domains.{Secrets, ZoneCredential}
  alias Bastion.Repo

  @endpoint "https://api.reg.ru/api/regru2/zone/"
  @record_methods %{
    "A" => "add_alias",
    "AAAA" => "add_aaaa",
    "CNAME" => "add_cname",
    "TXT" => "add_txt"
  }

  def save_credentials(zone, username, password)
      when is_binary(zone) and is_binary(username) and is_binary(password) do
    zone = Bastion.Domains.Domain.normalize(zone)

    with {:ok, ciphertext} <- Secrets.encrypt(password) do
      record = Repo.get_by(ZoneCredential, zone: zone, provider: "regru") || %ZoneCredential{}

      record
      |> ZoneCredential.changeset(%{
        zone: zone,
        provider: "regru",
        username: username,
        secret_ciphertext: ciphertext
      })
      |> Repo.insert_or_update()
    end
  end

  def connection_check(zone) do
    token = "delivest-check-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

    subdomain =
      "_delivest-api-check-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

    with {:ok, before} <- records(zone),
         {:ok, _} <- add(zone, subdomain, "TXT", token),
         {:ok, after_records} <- records(zone),
         true <- tuple_present?(after_records, subdomain, "TXT", token),
         {:ok, _} <- remove(zone, subdomain, "TXT", token),
         {:ok, final} <- records(zone),
         true <- not tuple_present?(final, subdomain, "TXT", token),
         true <- Enum.all?(before, &(&1 in final)) do
      {:ok, %{read: true, write: true, preserved: true}}
    else
      _ ->
        _ = remove(zone, subdomain, "TXT", token)
        {:error, :zone_check_failed}
    end
  end

  def records(zone) do
    with {:ok, domain} <- call(zone, "get_resource_records", %{}) do
      {:ok, domain["rrs"] || []}
    end
  end

  def add(zone, subdomain, type, content) when type in ["A", "AAAA", "CNAME", "TXT"] do
    field =
      case type do
        "A" -> "ipaddr"
        "AAAA" -> "ipaddr"
        "CNAME" -> "canonical_name"
        "TXT" -> "text"
      end

    with {:ok, existing} <- records(zone),
         false <- tuple_present?(existing, subdomain, type, content),
         {:ok, response} <-
           call(zone, @record_methods[type], %{"subdomain" => subdomain, field => content}) do
      {:ok, response}
    else
      true ->
        {:ok, :already_present}

      {:error, _} = error ->
        case records(zone) do
          {:ok, records} when is_list(records) ->
            if tuple_present?(records, subdomain, type, content),
              do: {:error, :write_outcome_uncertain},
              else: error

          _ ->
            error
        end
    end
  end

  def remove(zone, subdomain, type, content)
      when type in ["A", "AAAA", "CNAME", "TXT"] and is_binary(content) do
    result =
      call(zone, "remove_record", %{
        "subdomain" => subdomain,
        "record_type" => type,
        "content" => content
      })

    case records(zone) do
      {:ok, records} ->
        if tuple_present?(records, subdomain, type, content),
          do: {:error, :record_still_present},
          else: if(match?({:ok, _}, result), do: result, else: {:ok, :reconciled})

      _ ->
        {:error, :remove_outcome_uncertain}
    end
  end

  defp tuple_present?(records, subdomain, type, content) do
    Enum.any?(records, fn record ->
      record["subname"] == subdomain and record["rectype"] == type and
        record["content"] == content
    end)
  end

  defp call(zone, method, params) do
    zone = Bastion.Domains.Domain.normalize(zone)

    with %ZoneCredential{} = credential <-
           Repo.get_by(ZoneCredential, zone: zone, provider: "regru"),
         {:ok, password} <- Secrets.decrypt(credential.secret_ciphertext) do
      body =
        Map.merge(params, %{
          "username" => credential.username,
          "password" => password,
          "domains" => [%{"dname" => zone}],
          "output_content_type" => "plain",
          "output_format" => "json"
        })

      options = Application.get_env(:bastion, :req_options, [])

      with :ok <- rate_limit(),
           {:ok, %Req.Response{status: 200, body: response_body}} <-
             Req.post(
               @endpoint <> method,
               Keyword.merge(options,
                 form: [input_format: "json", input_data: Jason.encode!(body)],
                 redirect: false,
                 retry: false,
                 receive_timeout: 8_000,
                 connect_options: [timeout: 5_000]
               )
             ),
           {:ok, %{"result" => "success", "answer" => %{"domains" => domains}}} <-
             decode(response_body) do
        case Enum.find(domains, &(&1["dname"] == zone)) do
          %{"result" => "success"} = domain -> {:ok, domain}
          _ -> {:error, :zone_rejected}
        end
      else
        {:error, :rate_limited} = error -> error
        _ -> {:error, :provider_unavailable}
      end
    else
      _ -> {:error, :credentials_unavailable}
    end
  end

  defp decode(%{} = body), do: {:ok, body}
  defp decode(body) when is_binary(body), do: Jason.decode(body)
  defp decode(_), do: {:error, :invalid_response}

  defp rate_limit do
    if Bastion.Domains.RegRuRateLimiter.allow?(), do: :ok, else: {:error, :rate_limited}
  end
end
