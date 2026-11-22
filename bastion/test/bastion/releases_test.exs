defmodule Bastion.ReleasesTest do
  use Bastion.DataCase, async: false

  import Bastion.Fixtures

  alias Bastion.Releases

  test "resolves a published manifest once and pins the same version after upstream changes" do
    manifest = release_fixture("1.2.2")
    Req.Test.stub(Bastion.Http, fn conn -> Plug.Conn.send_resp(conn, 500, "changed") end)
    assert {:ok, %{manifest: ^manifest}} = Releases.resolve("1.2.2")
  end

  test "downloads only the expected release asset and validates each digest" do
    manifest = %{
      "version" => "1.2.4",
      "root_sha" => String.duplicate("a", 40),
      "gitlinks" => Map.new(~w(server client agent), &{&1, String.duplicate("b", 40)}),
      "images" => Map.new(~w(server client agent), &{&1, "sha256:" <> String.duplicate("c", 64)})
    }

    Req.Test.stub(Bastion.Http, fn conn ->
      body =
        case conn.request_path do
          "/repos/ShafranovKirill/delivest/releases/tags/v1.2.4" ->
            %{
              "tag_name" => "v1.2.4",
              "draft" => false,
              "published_at" => "2026-11-20T00:00:00Z",
              "assets" => [%{"name" => "release-manifest.json", "id" => 10}]
            }

          "/repos/ShafranovKirill/delivest/releases/assets/10" ->
            manifest
        end

      Plug.Conn.send_resp(conn, 200, Jason.encode!(body))
    end)

    assert {:ok, %{manifest: ^manifest}} = Releases.resolve("1.2.4")
    assert Releases.image_ref("server", manifest["images"]["server"]) =~ "delivest-server@sha256:"
    refute Releases.valid_manifest?(put_in(manifest, ["images", "agent"], nil))
    refute Releases.valid_manifest?(Map.put(manifest, "repository", "other/repo"))
  end

  test "missing manifest and unavailable release stop resolution" do
    Req.Test.stub(Bastion.Http, fn conn ->
      Plug.Conn.send_resp(
        conn,
        200,
        Jason.encode!(%{
          "tag_name" => "v1.2.5",
          "draft" => false,
          "published_at" => "2026-11-20",
          "assets" => []
        })
      )
    end)

    assert {:error, :missing_manifest} = Releases.resolve("1.2.5")

    Req.Test.stub(Bastion.Http, fn conn -> Plug.Conn.send_resp(conn, 503, "unavailable") end)
    assert {:error, :release_unavailable} = Releases.resolve("1.2.6")
  end
end
