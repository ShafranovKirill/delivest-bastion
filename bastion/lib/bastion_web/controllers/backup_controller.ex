defmodule BastionWeb.BackupController do
  use BastionWeb, :controller

  alias Bastion.Backups

  @max_size 20 * 1024 * 1024 * 1024

  def upload(conn, %{"id" => id}) do
    with {:ok, backup} <- Backups.authorize(:upload, id, bearer(conn)),
         {:ok, path, conn} <- receive_file(conn),
         {:ok, backup} <- Backups.store(backup, path) do
      json(conn, %{ok: true, size: backup.size})
    else
      {:error, :unauthorized} ->
        conn |> put_status(:forbidden) |> json(%{error: "forbidden"})

      {:error, :too_large} ->
        conn |> put_status(:request_entity_too_large) |> json(%{error: "too large"})

      {:error, reason} ->
        conn |> put_status(:bad_gateway) |> json(%{error: to_string(reason)})
    end
  end

  def file(conn, %{"id" => id}) do
    case Backups.authorize(:download, id, bearer(conn)) do
      {:ok, backup} -> send_backup(conn, backup)
      {:error, :unauthorized} -> conn |> put_status(:forbidden) |> json(%{error: "forbidden"})
    end
  end

  def download(conn, %{"id" => id}) do
    case Backups.get(id) do
      %{status: "ok"} = backup -> send_backup(conn, backup)
      _ -> conn |> put_status(:not_found) |> text("Бэкап не найден")
    end
  end

  defp send_backup(conn, backup) do
    path = Plug.Upload.random_file!("backup")

    case Backups.fetch(backup, path) do
      :ok ->
        send_download(conn, {:file, path},
          filename: Backups.filename(backup),
          content_type: "application/octet-stream"
        )

      {:error, reason} ->
        conn |> put_status(:bad_gateway) |> text("Хранилище недоступно: #{reason}")
    end
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _ -> nil
    end
  end

  defp receive_file(conn) do
    path = Plug.Upload.random_file!("backup")
    file = File.open!(path, [:write, :binary, :raw])

    try do
      read(conn, file, 0)
    after
      File.close(file)
    end
    |> case do
      {:ok, conn} -> {:ok, path, conn}
      error -> error
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
        {:error, "upload interrupted: #{inspect(reason)}"}
    end
  end
end
