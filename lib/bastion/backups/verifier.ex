defmodule Bastion.Backups.Verifier do
  @moduledoc """
  Reads a whole pg_dump archive with pg_restore without a database: the table of contents
  must list the orders data and every data block must unpack.
  """

  @required_table "orders"

  def run(path) do
    case System.find_executable(Application.get_env(:bastion, :pg_restore, "pg_restore")) do
      nil ->
        :skipped

      pg_restore ->
        with {:ok, toc} <- cmd(pg_restore, ["--list", path]),
             :ok <- required_data(toc),
             {:ok, _sql} <- cmd(pg_restore, ["--file", "/dev/null", path]) do
          :ok
        end
    end
  end

  defp required_data(toc) do
    if Regex.match?(~r/TABLE DATA \S+ #{@required_table} /, toc),
      do: :ok,
      else: {:error, "в бэкапе нет данных таблицы #{@required_table}"}
  end

  defp cmd(executable, args) do
    case System.cmd(executable, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _status} -> {:error, output |> String.trim() |> String.slice(0, 1000)}
    end
  end
end
