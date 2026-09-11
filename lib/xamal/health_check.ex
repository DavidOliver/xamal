defmodule Xamal.HealthCheck do
  @moduledoc """
  HTTP health check polling for deployment readiness.

  Polls a health check endpoint until it returns 200, or times out.
  """

  alias Xamal.Configuration

  @doc """
  Poll a health check endpoint until it returns 200.

  Options:
  - path: the HTTP path (default "/health")
  - interval: seconds between checks (default 1)
  - timeout: max seconds to wait (default 30)
  - port: the port to check

  Returns :ok or {:error, :timeout}
  """
  def wait_until_ready(host, port, opts \\ []) do
    path = Keyword.get(opts, :path, "/health")
    interval = Keyword.get(opts, :interval, 1)
    timeout = Keyword.get(opts, :timeout, 30)

    deadline = System.monotonic_time(:second) + timeout
    do_poll(url(host, port, path), interval, deadline)
  end

  @doc """
  Check health by requesting the endpoint from the remote server itself.
  Returns a command that can be executed remotely.
  """
  def check_command(config, port, path \\ "/health") do
    url = url("localhost", port, path)

    if Configuration.freebsd?(config) do
      # curl is not in FreeBSD's base system. On a host that has never had
      # it installed every poll fails with "command not found", which is
      # indistinguishable here from an app that never became healthy: the
      # blue-green swap times out and rolls back a release that was fine.
      # fetch(1) is in base. It cannot report a status code, so map its exit
      # status - non-zero on any HTTP error - onto the "200" that
      # do_poll_remote/5 compares against.
      ["fetch", "-q", "-o", "/dev/null", url, "&&", "echo", "200"]
    else
      ["curl", "-sf", "-o", "/dev/null", "-w", "%{http_code}", url]
    end
  end

  @doc """
  Poll health check via SSH on a remote host.
  """
  def wait_until_ready_remote(host, port, config, opts \\ []) do
    path = Keyword.get(opts, :path, "/health")
    interval = Keyword.get(opts, :interval, 1)
    timeout = Keyword.get(opts, :timeout, 30)
    ssh_config = config.ssh

    deadline = System.monotonic_time(:second) + timeout
    cmd = check_command(config, port, path)

    do_poll_remote(host, cmd, ssh_config, interval, deadline)
  end

  defp url(host, port, path) do
    %URI{scheme: "http", host: host, port: port, path: normalize_path(path)}
    |> URI.to_string()
  end

  defp normalize_path("/" <> _ = path), do: path
  defp normalize_path(path), do: "/#{path}"

  defp do_poll(url, interval, deadline) do
    if System.monotonic_time(:second) > deadline do
      {:error, :timeout}
    else
      case http_get(url) do
        {:ok, 200} ->
          :ok

        _ ->
          Process.sleep(interval * 1000)
          do_poll(url, interval, deadline)
      end
    end
  end

  defp do_poll_remote(host, cmd, ssh_config, interval, deadline) do
    if System.monotonic_time(:second) > deadline do
      {:error, :timeout}
    else
      case Xamal.SSH.execute_command(host, cmd, ssh_config: ssh_config) do
        {:ok, "200"} ->
          :ok

        _ ->
          Process.sleep(interval * 1000)
          do_poll_remote(host, cmd, ssh_config, interval, deadline)
      end
    end
  end

  defp http_get(url) do
    case :httpc.request(:get, {String.to_charlist(url), []}, [timeout: 5000], []) do
      {:ok, {{_, status, _}, _headers, _body}} -> {:ok, status}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> {:error, :connection_failed}
  end
end
