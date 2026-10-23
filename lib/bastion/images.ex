defmodule Bastion.Images do
  @moduledoc """
  Finds the git revision of the newest image in GitHub Container Registry for every image
  the sites run, so the bastion can tell which sites and agents are behind.
  """

  use GenServer

  require Logger

  alias Bastion.Instances

  @table __MODULE__
  @registry "ghcr.io"
  @refresh_ms :timer.minutes(15)
  @accept Enum.join(
            [
              "application/vnd.oci.image.index.v1+json",
              "application/vnd.docker.distribution.manifest.list.v2+json",
              "application/vnd.oci.image.manifest.v1+json",
              "application/vnd.docker.distribution.manifest.v2+json"
            ],
            ", "
          )

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def refresh, do: GenServer.cast(__MODULE__, :refresh)

  def latest(ref) when is_binary(ref) do
    case :ets.whereis(@table) != :undefined and :ets.lookup(@table, normalize(ref)) do
      [{_ref, revision}] -> revision
      _ -> nil
    end
  end

  def latest(_ref), do: nil

  def put(ref, revision), do: :ets.insert(@table, {normalize(ref), revision})

  @doc "Services of the site whose image has a newer revision in the registry."
  def outdated(%{status: %{"containers" => containers}}) when is_list(containers) do
    for %{"service" => service, "image" => image, "revision" => revision} <- containers,
        newer?(image, revision),
        do: service
  end

  def outdated(_instance), do: []

  # Unknown when the registry was not asked yet or the image is not from it.
  def up_to_date?(%{status: %{"containers" => containers}} = instance) when is_list(containers) do
    known? =
      Enum.any?(containers, fn container ->
        is_binary(container["revision"]) and is_binary(latest(container["image"]))
      end)

    if known?, do: outdated(instance) == [], else: :unknown
  end

  def up_to_date?(_instance), do: :unknown

  def agent_outdated?(%{status: %{"agent" => %{"image" => image, "revision" => revision}}}),
    do: newer?(image, revision)

  def agent_outdated?(_instance), do: false

  defp newer?(image, revision) when is_binary(revision) do
    case latest(image) do
      latest when is_binary(latest) -> latest != revision
      _ -> false
    end
  end

  defp newer?(_image, _revision), do: false

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    if Application.get_env(:bastion, :images_refresh, true), do: send(self(), :refresh)
    {:ok, %{}}
  end

  @impl true
  def handle_cast(:refresh, state) do
    check()
    {:noreply, state}
  end

  @impl true
  def handle_info(:refresh, state) do
    check()
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  def check do
    Instances.list_instances()
    |> Enum.flat_map(&images/1)
    |> Enum.uniq()
    |> Enum.filter(&String.starts_with?(&1, @registry <> "/"))
    |> Task.async_stream(&{&1, fetch_revision(&1)}, timeout: 60_000, on_timeout: :kill_task)
    |> Enum.each(fn
      {:ok, {ref, {:ok, revision}}} ->
        put(ref, revision)

      {:ok, {ref, {:error, reason}}} ->
        Logger.warning("cannot read the newest revision of #{ref}: #{reason}")

      {:exit, reason} ->
        Logger.warning("registry check failed: #{inspect(reason)}")
    end)
  end

  defp images(%{status: %{} = status}) do
    containers =
      for %{"image" => image} when is_binary(image) <- List.wrap(status["containers"]), do: image

    agent =
      case status["agent"] do
        %{"image" => image} when is_binary(image) -> [image]
        _ -> []
      end

    containers ++ agent
  end

  defp images(_instance), do: []

  def fetch_revision(ref) do
    {repo, tag} = parse(ref)

    with {:ok, token} <- token(repo),
         {:ok, manifest} <- get_json("/v2/#{repo}/manifests/#{tag}", token),
         {:ok, manifest} <- platform_manifest(manifest, repo, token),
         %{"config" => %{"digest" => digest}} <- manifest,
         {:ok, config} <- get_json("/v2/#{repo}/blobs/#{digest}", token) do
      case get_in(config, ["config", "Labels", "org.opencontainers.image.revision"]) do
        revision when is_binary(revision) and revision != "" -> {:ok, revision}
        _ -> {:error, "the image has no revision label"}
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, "unexpected manifest"}
    end
  end

  def parse(ref) do
    path = ref |> normalize() |> String.replace_prefix(@registry <> "/", "")

    case Regex.run(~r/^(.+):([^:\/]+)$/, path) do
      [_, repo, tag] -> {repo, tag}
      nil -> {path, "latest"}
    end
  end

  defp platform_manifest(%{"manifests" => manifests}, repo, token) when is_list(manifests) do
    case Enum.find(
           manifests,
           &match?(%{"platform" => %{"os" => "linux", "architecture" => "amd64"}}, &1)
         ) do
      %{"digest" => digest} -> get_json("/v2/#{repo}/manifests/#{digest}", token)
      nil -> {:error, "no linux/amd64 image"}
    end
  end

  defp platform_manifest(manifest, _repo, _token), do: {:ok, manifest}

  defp token(repo) do
    case Req.get(request(), url: "/token", params: [scope: "repository:#{repo}:pull"]) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"token" => token}} -> {:ok, token}
          _ -> {:error, "no token"}
        end

      other ->
        failure(other)
    end
  end

  defp get_json(path, token) do
    case Req.get(request(),
           url: path,
           headers: [authorization: "Bearer " <> token, accept: @accept]
         ) do
      {:ok, %{status: 200, body: body}} -> Jason.decode(body)
      other -> failure(other)
    end
  end

  defp failure({:ok, %{status: status}}), do: {:error, "HTTP #{status}"}
  defp failure({:error, error}), do: {:error, Exception.message(error)}

  defp request do
    Req.new(
      base_url: "https://" <> @registry,
      retry: false,
      decode_body: false,
      receive_timeout: 20_000
    )
    |> Req.merge(Application.get_env(:bastion, :req_options, []))
  end

  defp normalize(ref), do: ref |> String.split("@") |> hd() |> String.downcase()
end
