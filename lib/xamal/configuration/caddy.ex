defmodule Xamal.Configuration.Caddy do
  @moduledoc """
  Caddy reverse proxy configuration.

  `extra_config` is raw Caddyfile text spliced into the generated site block
  alongside `reverse_proxy` — the escape hatch for anything xamal doesn't
  model directly (request blocking by header/path, custom matchers, etc.).
  """

  defstruct [
    :host,
    :hosts,
    :app_port,
    :ssl,
    :extra_config
  ]

  def new(config) when is_map(config) do
    %__MODULE__{
      host: Map.get(config, "host"),
      hosts: Map.get(config, "hosts", []),
      app_port: Map.get(config, "app_port", 4000),
      ssl: Map.get(config, "ssl", true),
      extra_config: Map.get(config, "extra_config")
    }
  end

  def new(_), do: %__MODULE__{app_port: 4000, hosts: [], ssl: true}

  @doc """
  Returns all configured hostnames for the Caddyfile.
  """
  def hostnames(%__MODULE__{host: host, hosts: hosts}) do
    all = if host, do: [host | hosts], else: hosts
    Enum.uniq(all)
  end

  @doc """
  The alternate port used during blue-green deploy.
  """
  def alt_port(%__MODULE__{app_port: port}), do: port + 1

  @doc """
  Generate a Caddyfile for the given upstream port.

  `extra_config`, if set, is spliced in verbatim alongside `reverse_proxy` —
  e.g. matchers and `respond`/`abort` directives to block by header or path.
  Caddy orders recognized directives by its own fixed priority regardless of
  where they appear in the block, so exact placement here is cosmetic; wrap
  in an explicit `route { }` in `extra_config` if strict textual order matters.
  """
  def generate_caddyfile(%__MODULE__{} = caddy, upstream_port) do
    caddyfile_block(caddy, site_directives(caddy, upstream_port))
  end

  @doc """
  Generate a maintenance mode Caddyfile.
  """
  def maintenance_caddyfile(%__MODULE__{} = caddy) do
    caddyfile_block(caddy, ~s(respond "Service under maintenance" 503))
  end

  defp site_directives(%__MODULE__{extra_config: extra}, upstream_port) when is_binary(extra) do
    "#{String.trim(extra)}\n    reverse_proxy localhost:#{upstream_port}"
  end

  defp site_directives(%__MODULE__{}, upstream_port) do
    "reverse_proxy localhost:#{upstream_port}"
  end

  defp http_hostnames(hosts) do
    Enum.map_join(hosts, ", ", fn host -> URI.to_string(%URI{scheme: "http", host: host}) end)
  end

  defp caddyfile_block(caddy, directive) do
    matcher =
      case hostnames(caddy) do
        [] -> ":80"
        hosts when caddy.ssl == false -> http_hostnames(hosts)
        hosts -> Enum.join(hosts, ", ")
      end

    """
    #{matcher} {
        #{directive}
    }
    """
  end
end
