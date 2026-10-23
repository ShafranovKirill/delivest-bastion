defmodule Bastion.ImagesTest do
  use ExUnit.Case, async: false

  alias Bastion.Images

  test "reads the revision label through the multi-platform index" do
    Req.Test.stub(Bastion.Http, fn conn ->
      body =
        case conn.request_path do
          "/token" ->
            assert conn.query_string =~ "repository%3Aowner%2Fdelivest-server%3Apull"
            %{"token" => "t"}

          "/v2/owner/delivest-server/manifests/latest" ->
            assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer t"]

            %{
              "manifests" => [
                %{
                  "digest" => "sha256:att",
                  "platform" => %{"os" => "unknown", "architecture" => "unknown"}
                },
                %{
                  "digest" => "sha256:amd",
                  "platform" => %{"os" => "linux", "architecture" => "amd64"}
                }
              ]
            }

          "/v2/owner/delivest-server/manifests/sha256:amd" ->
            %{"config" => %{"digest" => "sha256:cfg"}}

          "/v2/owner/delivest-server/blobs/sha256:cfg" ->
            %{"config" => %{"Labels" => %{"org.opencontainers.image.revision" => "abc999"}}}
        end

      Plug.Conn.send_resp(conn, 200, Jason.encode!(body))
    end)

    assert {:ok, "abc999"} = Images.fetch_revision("ghcr.io/Owner/delivest-server:latest")
  end

  test "registry errors are reported" do
    Req.Test.stub(Bastion.Http, &Plug.Conn.send_resp(&1, 401, "denied"))
    assert {:error, "HTTP 401"} = Images.fetch_revision("ghcr.io/owner/private:latest")
  end

  test "a site is behind when its revision differs from the newest image" do
    Images.put("ghcr.io/test/images-server:latest", "new")
    Images.put("ghcr.io/test/images-agent:latest", "new")

    instance = %{
      status: %{
        "containers" => [
          %{
            "service" => "server",
            "image" => "ghcr.io/test/images-server:latest",
            "revision" => "old"
          },
          %{"service" => "postgres", "image" => "postgres:16-alpine", "revision" => nil}
        ],
        "agent" => %{"image" => "ghcr.io/test/images-agent:latest", "revision" => "new"}
      }
    }

    assert Images.outdated(instance) == ["server"]
    assert Images.up_to_date?(instance) == false
    refute Images.agent_outdated?(instance)
    assert Images.up_to_date?(%{status: %{"containers" => []}}) == :unknown
  end

  test "image references are split into the repository and the tag" do
    assert Images.parse("ghcr.io/owner/app:v1") == {"owner/app", "v1"}
    assert Images.parse("ghcr.io/owner/app") == {"owner/app", "latest"}
    assert Images.parse("ghcr.io/owner/app@sha256:abc") == {"owner/app", "latest"}
  end
end
