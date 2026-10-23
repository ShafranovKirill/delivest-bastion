defmodule BastionWeb.SessionControllerTest do
  use BastionWeb.ConnCase, async: false

  setup do
    Application.put_env(:bastion, :telegram_bot_token, "bot")
    Application.put_env(:bastion, :telegram_chat_id, "42")
    test_pid = self()

    Req.Test.stub(Bastion.Http, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:telegram, Jason.decode!(body)})
      Req.Test.json(conn, %{"ok" => true, "result" => %{}})
    end)

    on_exit(fn ->
      Application.delete_env(:bastion, :telegram_chat_id)
      Application.delete_env(:bastion, :telegram_login_chat_id)
      Application.put_env(:bastion, :telegram_bot_token, nil)
    end)
  end

  defp log_in_with_password(conn) do
    conn =
      conn
      |> put_req_header("x-forwarded-for", "10.0.0.1, 203.0.113.7")
      |> post(~p"/login", %{"session" => %{"login" => "admin", "password" => "secret"}})

    assert redirected_to(conn) == ~p"/login/code"
    assert_received {:telegram, %{"chat_id" => "42", "text" => text}}
    assert text =~ "203.0.113.7"
    [_, code] = Regex.run(~r/<code>(\d{6})<\/code>/, text)
    {recycle(conn), code}
  end

  test "the password alone does not log in, the code from telegram does", %{conn: conn} do
    {conn, code} = log_in_with_password(conn)

    assert html_response(get(conn, ~p"/login/code"), 200) =~ "login-code-form"
    assert redirected_to(get(recycle(conn), ~p"/")) == ~p"/login"

    conn = post(recycle(conn), ~p"/login/code", %{"code" => %{"code" => code}})
    assert redirected_to(conn) == ~p"/"
    assert get_session(conn, :admin) == "admin"

    conn = post(recycle(conn), ~p"/login/code", %{"code" => %{"code" => code}})
    assert redirected_to(conn) == ~p"/login"
  end

  test "a wrong code is refused and five of them end the attempt", %{conn: conn} do
    {conn, code} = log_in_with_password(conn)
    wrong = if code == "000000", do: "111111", else: "000000"

    conn =
      Enum.reduce(1..4, conn, fn _, conn ->
        conn = post(conn, ~p"/login/code", %{"code" => %{"code" => wrong}})
        assert html_response(conn, 200) =~ "Неверный код"
        recycle(conn)
      end)

    conn = post(conn, ~p"/login/code", %{"code" => %{"code" => wrong}})
    assert redirected_to(conn) == ~p"/login"

    conn = post(recycle(conn), ~p"/login/code", %{"code" => %{"code" => code}})
    assert redirected_to(conn) == ~p"/login"
    refute get_session(conn, :admin)
  end

  test "the code goes to a separate login chat when it is set", %{conn: conn} do
    Application.put_env(:bastion, :telegram_login_chat_id, "777")
    post(conn, ~p"/login", %{"session" => %{"login" => "admin", "password" => "secret"}})
    assert_received {:telegram, %{"chat_id" => "777"}}
  end

  test "the login fails when telegram does not take the code", %{conn: conn} do
    Req.Test.stub(
      Bastion.Http,
      &Req.Test.json(Plug.Conn.put_status(&1, 400), %{
        "ok" => false,
        "description" => "chat not found"
      })
    )

    conn = post(conn, ~p"/login", %{"session" => %{"login" => "admin", "password" => "secret"}})
    assert html_response(conn, 200) =~ "chat not found"
    refute get_session(conn, :login_code_id)
  end

  test "the code is sent again when a stale connection times out", %{conn: conn} do
    test_pid = self()
    Process.put(:attempts, 0)

    Req.Test.stub(Bastion.Http, fn conn ->
      if Process.get(:attempts) == 0 do
        Process.put(:attempts, 1)
        Req.Test.transport_error(conn, :timeout)
      else
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:telegram, Jason.decode!(body)})
        Req.Test.json(conn, %{"ok" => true, "result" => %{}})
      end
    end)

    conn = post(conn, ~p"/login", %{"session" => %{"login" => "admin", "password" => "secret"}})
    assert redirected_to(conn) == ~p"/login/code"
    assert_received {:telegram, %{"text" => "🔐" <> _}}
  end
end
