defmodule Bastion.Domains.RegRuTest do
  use Bastion.DataCase, async: false

  alias Bastion.Domains.{RegRu, ZoneCredential}

  setup do
    Application.put_env(:bastion, :dns_encryption_key, Base.encode64(:binary.copy(<<42>>, 32)))
    on_exit(fn -> Application.delete_env(:bastion, :dns_encryption_key) end)
    :ok
  end

  test "zone check adds and removes only its test TXT record" do
    state =
      start_supervised!(
        {Agent,
         fn -> [%{"subname" => "mail", "rectype" => "MX", "content" => "mail.example.org"}] end}
      )

    Req.Test.stub(Bastion.Http, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      %{"input_data" => encoded} = URI.decode_query(raw)
      payload = Jason.decode!(encoded)
      assert payload["password"] == "api-secret"
      method = List.last(conn.path_info)

      records =
        case method do
          "get_resource_records" ->
            Agent.get(state, & &1)

          "add_txt" ->
            Agent.update(
              state,
              &[
                %{
                  "subname" => payload["subdomain"],
                  "rectype" => "TXT",
                  "content" => payload["text"]
                }
                | &1
              ]
            )

            Agent.get(state, & &1)

          "remove_record" ->
            Agent.update(
              state,
              &Enum.reject(&1, fn record ->
                record["subname"] == payload["subdomain"] and
                  record["rectype"] == payload["record_type"] and
                  record["content"] == payload["content"]
              end)
            )

            Agent.get(state, & &1)
        end

      response = %{
        "result" => "success",
        "answer" => %{
          "domains" => [%{"dname" => "example.org", "result" => "success", "rrs" => records}]
        }
      }

      conn
      |> Plug.Conn.put_resp_content_type("text/plain")
      |> Plug.Conn.send_resp(200, Jason.encode!(response))
    end)

    assert {:ok, _} = RegRu.save_credentials("Example.ORG", "api-user", "api-secret")
    credential = Repo.get_by!(ZoneCredential, zone: "example.org")
    refute credential.secret_ciphertext =~ "api-secret"

    assert {:ok, %{read: true, write: true, preserved: true}} =
             RegRu.connection_check("example.org")

    assert Agent.get(state, & &1) == [
             %{"subname" => "mail", "rectype" => "MX", "content" => "mail.example.org"}
           ]
  end
end
