defmodule BastionWeb.SnapshotController do
  use BastionWeb, :controller

  alias Bastion.{ManagedSnapshots, Snapshots}

  @max_size 20 * 1024 * 1024 * 1024

  def upload(conn, %{"id" => id}) do
    with {:ok, snapshot} <- authorize(id, bearer(conn)),
         {:ok, path, conn} <- receive_file(conn) do
      try do
        case store(snapshot, path) do
          {:ok, snapshot} ->
            json(conn, %{ok: true, size: snapshot.size})

          {:error, :unauthorized} ->
            conn |> put_status(:forbidden) |> json(%{error: "forbidden"})

          {:error, _reason} ->
            conn |> put_status(:bad_gateway) |> json(%{error: "snapshot not stored"})
        end
      after
        File.rm(path)
      end
    else
      {:error, :unauthorized} ->
        conn |> put_status(:forbidden) |> json(%{error: "forbidden"})

      {:error, :too_large} ->
        conn |> put_status(:request_entity_too_large) |> json(%{error: "too large"})

      {:error, _reason} ->
        conn |> put_status(:bad_gateway) |> json(%{error: "upload interrupted"})
    end
  end

  def download(conn, %{"id" => id}) do
    case Snapshots.get(id) do
      %{status: "ok"} = snapshot -> send_snapshot(conn, snapshot)
      _ -> conn |> put_status(:not_found) |> text("Слепок не найден")
    end
  end

  defp send_snapshot(conn, snapshot) do
    path = Plug.Upload.random_file!("snapshot-download")

    try do
      case fetch(snapshot, path) do
        :ok ->
          send_download(conn, {:file, path},
            filename: Snapshots.filename(snapshot),
            content_type: "application/octet-stream"
          )

        {:error, _reason} ->
          conn |> put_status(:bad_gateway) |> text("Хранилище недоступно")
      end
    after
      File.rm(path)
    end
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _ -> nil
    end
  end

  defp authorize(id, token) do
    case Snapshots.get(id) do
      %{node_operation_id: operation_id} when not is_nil(operation_id) ->
        ManagedSnapshots.authorize_upload(id, token)

      _ ->
        Snapshots.authorize_upload(id, token)
    end
  end

  defp store(%{node_operation_id: id} = snapshot, path) when not is_nil(id),
    do: ManagedSnapshots.store(snapshot, path)

  defp store(snapshot, path), do: Snapshots.store(snapshot, path)

  defp fetch(%{node_operation_id: id} = snapshot, path) when not is_nil(id),
    do: ManagedSnapshots.fetch(snapshot, path)

  defp fetch(snapshot, path), do: Snapshots.fetch(snapshot, path)

  defp receive_file(conn) do
    path = Plug.Upload.random_file!("snapshot-upload")
    file = File.open!(path, [:write, :binary, :raw])

    result =
      try do
        read(conn, file, 0)
      after
        File.close(file)
      end

    case result do
      {:ok, conn} ->
        {:ok, path, conn}

      error ->
        File.rm(path)
        error
    end
  end

  defp read(conn, file, size) do
    case Plug.Conn.read_body(conn,
           length: 1_048_576,
           read_length: 1_048_576,
           read_timeout: 60_000
         ) do
      {status, data, conn} when status in [:ok, :more] ->
        size = size + byte_size(data)

        cond do
          size > @max_size -> {:error, :too_large}
          status == :ok -> with :ok <- IO.binwrite(file, data), do: {:ok, conn}
          true -> with :ok <- IO.binwrite(file, data), do: read(conn, file, size)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
