defmodule Bastion.Storage do
  def configured?,
    do:
      match?(
        %{access_key: key, secret_key: secret} when is_binary(key) and is_binary(secret),
        config()
      )

  def put_file(key, path) do
    with :ok <- ensure_bucket() do
      size = File.stat!(path).size

      request()
      |> Req.put(
        url: object_path(key),
        headers: [content_length: size],
        body: File.stream!(path, 1_048_576),
        receive_timeout: 600_000
      )
      |> ok()
    end
  end

  def download(key, path) do
    result =
      request()
      |> Req.get(url: object_path(key), into: File.stream!(path), receive_timeout: 600_000)
      |> ok()

    if result != :ok, do: File.rm(path)
    result
  end

  def delete(key) do
    case Req.delete(request(), url: object_path(key)) do
      {:ok, %{status: status}} when status in [200, 204, 404] -> :ok
      other -> ok(other)
    end
  end

  defp ensure_bucket do
    case Req.put(request(), url: "/" <> bucket()) do
      {:ok, %{status: status}} when status in [200, 409] -> :ok
      other -> ok(other)
    end
  end

  defp ok({:ok, %{status: status}}) when status in 200..299, do: :ok
  defp ok({:ok, %{status: status}}), do: {:error, "S3 HTTP #{status}"}
  defp ok({:error, error}), do: {:error, Exception.message(error)}

  defp request do
    config = config()

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

  defp object_path(key), do: "/" <> bucket() <> "/" <> key

  defp bucket, do: config().bucket

  defp config do
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
end
