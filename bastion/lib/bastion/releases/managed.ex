defmodule Bastion.Releases.Managed do
  @moduledoc "Resolve the deployment package of the latest published stable release."

  @api "https://api.github.com/repos/ShafranovKirill/delivest"
  @digest ~r/\Asha256:([0-9a-f]{64})\z/
  @version ~r/\A[0-9]+\.[0-9]+\.[0-9]+\z/

  def latest do
    with {:ok, release} <- fetch("#{@api}/releases/latest"),
         %{"tag_name" => "v" <> version, "draft" => false, "prerelease" => false} <- release,
         true <- Regex.match?(@version, version) and is_binary(release["published_at"]),
         assets when is_list(assets) <- release["assets"],
         [asset] <- Enum.filter(assets, &package?(&1, version)),
         %{"digest" => digest, "browser_download_url" => url} <- asset,
         [_, sha] <- Regex.run(@digest, digest),
         true <-
           url ==
             "https://github.com/ShafranovKirill/delivest/releases/download/v#{version}/delivest-deploy-#{version}.tar.gz" do
      {:ok, %{version: version, url: url, sha256: sha}}
    else
      {:error, _} = error -> error
      _ -> {:error, :release_package_unavailable}
    end
  end

  defp package?(%{"name" => name}, version),
    do: name == "delivest-deploy-#{version}.tar.gz"

  defp package?(_, _), do: false

  defp fetch(url) do
    case Req.get(
           url,
           [
             headers: [{"accept", "application/vnd.github+json"}],
             retry: false,
             receive_timeout: 10_000
           ] ++
             Application.get_env(:bastion, :req_options, [])
         ) do
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
      _ -> {:error, :release_unavailable}
    end
  end
end
