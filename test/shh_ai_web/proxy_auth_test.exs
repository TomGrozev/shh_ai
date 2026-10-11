defmodule ShhAiWeb.ProxyAuthTest do
  use ShhAiWeb.ConnCase, async: false

  import Plug.Conn

  alias ShhAi.Config
  alias ShhAiWeb.ProxyAuth

  setup do
    ShhAi.AuditCase.snapshot_env(["PROXY_API_KEYS"])
    :ok
  end

  defp configure_gate(keys) do
    System.put_env("PROXY_API_KEYS", keys)
    Config.load()
  end

  defp call(conn), do: ProxyAuth.call(conn, [])

  defp json_error(conn) do
    assert {"content-type", "application/json" <> _} =
             List.keyfind(conn.resp_headers, "content-type", 0)

    Jason.decode!(conn.resp_body)
  end

  defp assert_proxy_error(body) do
    assert %{"error" => %{"message" => message, "type" => "proxy_error"}} = body
    assert is_binary(message)
    assert message != ""
  end

  describe "when PROXY_API_KEYS is unconfigured" do
    test "refuses every request with 503" do
      System.delete_env("PROXY_API_KEYS")
      Config.load()

      conn = call(build_conn())

      assert conn.status == 503
      assert conn.halted
      assert_proxy_error(json_error(conn))
    end
  end

  describe "when PROXY_API_KEYS is configured" do
    setup do
      configure_gate("gate-key")
      :ok
    end

    test "passes a request carrying a valid Bearer token" do
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer gate-key")
        |> call()

      refute conn.halted
      assert conn.status == nil
    end

    test "accepts a case-insensitive Bearer scheme" do
      conn =
        build_conn()
        |> put_req_header("authorization", "bearer gate-key")
        |> call()

      refute conn.halted
    end

    test "rejects a request with no authorization header" do
      conn = call(build_conn())

      assert conn.status == 401
      assert conn.halted
      assert_proxy_error(json_error(conn))
    end

    test "rejects a non-Bearer scheme" do
      conn =
        build_conn()
        |> put_req_header("authorization", "Token gate-key")
        |> call()

      assert conn.status == 401
      assert conn.halted
    end

    test "rejects an empty Bearer token" do
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer ")
        |> call()

      assert conn.status == 401
      assert conn.halted
    end

    test "rejects a Bearer scheme with no token" do
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer")
        |> call()

      assert conn.status == 401
      assert conn.halted
    end

    test "rejects a wrong token" do
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer not-the-key")
        |> call()

      assert conn.status == 401
      assert conn.halted
    end
  end

  describe "with multiple configured keys" do
    setup do
      configure_gate("key-one, key-two")
      :ok
    end

    test "passes when any configured key matches" do
      for key <- ["key-one", "key-two"] do
        conn =
          build_conn()
          |> put_req_header("authorization", "Bearer #{key}")
          |> call()

        refute conn.halted, "expected #{key} to be accepted"
      end
    end

    test "rejects a token matching no configured key" do
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer key-three")
        |> call()

      assert conn.status == 401
      assert conn.halted
    end
  end
end
