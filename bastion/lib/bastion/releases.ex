defmodule Bastion.Releases do
  @moduledoc "Resolves a published Delivest release once and keeps its immutable image bundle."

  alias Bastion.Releases.Bundle
  alias Bastion.Repo

  @repo "ShafranovKirill/delivest"
  @api "https://api.github.com/repos/#{@repo}"
  @version ~r/\A[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?\z/
  @sha ~r/\A[0-9a-f]{40}\z/
  @digest ~r/\Asha256:[0-9a-f]{64}\z/
  @components ~w(server client agent)

  def list_cached, do: Repo.all(Bundle) |> Enum.sort_by(& &1.version, :desc)

  def get(version) when is_binary(version), do: Repo.get(Bundle, version)
  def get(_), do: nil

  def resolve(version) when is_binary(version) do
    with :ok <- valid_version(version) do
      case get(version) do
        %Bundle{} = bundle -> {:ok, bundle}
        nil -> download(version)
      end
    end
  end

  def resolve(_), do: {:error, :invalid_version}

  def valid_manifest?(
        %{"version" => version, "root_sha" => root, "gitlinks" => gitlinks, "images" => images} =
          manifest
      )
      when is_map(gitlinks) and is_map(images) do
    map_size(manifest) == 4 and valid_version(version) == :ok and sha?(root) and
      Enum.all?(@components, fn component ->
        sha?(gitlinks[component]) and digest?(images[component])
      end) and map_size(gitlinks) == 3 and map_size(images) == 3
  end

  def valid_manifest?(_), do: false

  def image_ref(component, digest) when component in @components,
    do: "ghcr.io/shafranovkirill/delivest-#{component}@#{digest}"

  defp sha?(value), do: is_binary(value) and Regex.match?(@sha, value)
  defp digest?(value), do: is_binary(value) and Regex.match?(@digest, value)

  defp valid_version(version) when is_binary(version) do
    if Regex.match?(@version, version), do: :ok, else: {:error, :invalid_version}
  end

  defp valid_version(_), do: {:error, :invalid_version}

  defp download(version) do
    with {:ok, release} <- fetch_json("#{@api}/releases/tags/v#{version}"),
         true <-
           (release["tag_name"] == "v#{version}" and release["draft"] == false and
              is_binary(release["published_at"])) or {:error, :unpublished},
         assets when is_list(assets) <- release["assets"],
         [%{"id" => id}] <-
           Enum.filter(assets, &(is_map(&1) and &1["name"] == "release-manifest.json")),
         true <- is_integer(id) or {:error, :missing_manifest},
         {:ok, manifest} <- fetch_manifest("#{@api}/releases/assets/#{id}"),
         true <-
           (valid_manifest?(manifest) and manifest["version"] == version) or
             {:error, :invalid_manifest} do
      case Repo.insert(%Bundle{version: version, manifest: manifest}, on_conflict: :nothing) do
        {:ok, _} -> {:ok, get(version)}
        {:error, reason} -> {:error, reason}
      end
    else
      [] -> {:error, :missing_manifest}
      {:error, _} = error -> error
      _ -> {:error, :invalid_release}
    end
  end

  defp fetch_json(url) do
    case Req.get(url, request_options("application/vnd.github+json")) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: 200, body: body}} when is_binary(body) and byte_size(body) <= 65_536 ->
        case Jason.decode(body) do
          {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
          _ -> {:error, :release_unavailable}
        end

      {:ok, _} ->
        {:error, :release_unavailable}

      {:error, _} ->
        {:error, :release_unavailable}
    end
  end

  defp fetch_manifest(url) do
    case Req.get(url, request_options("application/octet-stream")) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: 200, body: body}} when is_binary(body) and byte_size(body) <= 16_384 ->
        case Jason.decode(body) do
          {:ok, decoded} -> {:ok, decoded}
          _ -> {:error, :invalid_manifest}
        end

      _ ->
        {:error, :manifest_unavailable}
    end
  end

  defp request_options(accept) do
    [headers: [{"accept", accept}], retry: false, receive_timeout: 10_000] ++
      Application.get_env(:bastion, :req_options, [])
  end
end
