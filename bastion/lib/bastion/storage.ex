defmodule Bastion.Storage do
  @moduledoc """
  S3 storage for backups: `:primary` is the bastion's own SeaweedFS and `:offsite` an
  optional bucket on another server that keeps a copy of every backup.
  """

  def configured?(target \\ :primary),
    do:
      match?(
        %{access_key: key, secret_key: secret, url: url}
        when is_binary(key) and is_binary(secret) and is_binary(url),
        config(target)
      )

  def put_file(key, path, target \\ :primary) do
    with :ok <- ensure_bucket(target) do
      size = File.stat!(path).size

      target
      |> request()
      |> Req.put(
        url: object_path(key, target),
        headers: [content_length: size],
        body: File.stream!(path, 1_048_576),
        receive_timeout: 600_000
      )
      |> ok()
    end
  end

  def download(key, path, target \\ :primary) do
    result =
      target
      |> request()
      |> Req.get(
        url: object_path(key, target),
        into: File.stream!(path),
        receive_timeout: 600_000
      )
      |> ok()

    if result != :ok, do: File.rm(path)
    result
  end

  def delete(key, target \\ :primary) do
    case Req.delete(request(target), url: object_path(key, target)) do
      {:ok, %{status: status}} when status in [200, 204, 404] -> :ok
      other -> ok(other)
    end
  end

  # The bastion creates its own bucket; an offsite bucket is made by whoever rents it.
  defp ensure_bucket(:offsite), do: :ok

  defp ensure_bucket(target) do
    case Req.put(request(target), url: "/" <> config(target).bucket) do
      {:ok, %{status: status}} when status in [200, 409] -> :ok
      other -> ok(other)
    end
  end

  defp ok({:ok, %{status: status}}) when status in 200..299, do: :ok
  defp ok({:ok, %{status: status}}), do: {:error, "S3 HTTP #{status}"}
  defp ok({:error, error}), do: {:error, Exception.message(error)}

  defp request(target) do
    config = config(target)

    Req.new(
      base_url: config.url,
      retry: false,
      decode_body: false,
      aws_sigv4: [
        access_key_id: config.access_key,
        secret_access_key: config.secret_key,
        service: :s3,
        region: config.region
      ]
    )
    |> Req.merge(Application.get_env(:bastion, :req_options, []))
  end

  defp object_path(key, target), do: "/" <> config(target).bucket <> "/" <> key

  defp config(:primary) do
    Map.merge(
      %{
        url: "http://s3:8333",
        bucket: "backups",
        region: "us-east-1",
        access_key: nil,
        secret_key: nil
      },
      Map.new(Application.get_env(:bastion, :storage, []))
    )
  end

  defp config(:offsite) do
    Map.merge(
      %{
        url: nil,
        bucket: "bastion-backups",
        region: "us-east-1",
        access_key: nil,
        secret_key: nil
      },
      Map.new(Application.get_env(:bastion, :offsite_storage, []))
    )
  end
end
