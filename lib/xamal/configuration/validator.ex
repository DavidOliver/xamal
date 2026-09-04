defmodule Xamal.Configuration.Validator do
  @moduledoc """
  Validates the configuration.
  """

  alias Xamal.Configuration

  def validate!(%Configuration{} = config) do
    validate_service!(config)
    validate_servers!(config)
    validate_retain_releases!(config)
    validate_destination!(config)
    validate_os!(config)
    :ok
  end

  defp validate_service!(config) do
    service = Configuration.service(config)

    unless Regex.match?(~r/^[a-z0-9_-]+$/i, service) do
      raise ArgumentError,
            "Service name can only include alphanumeric characters, hyphens, and underscores"
    end
  end

  defp validate_servers!(config) do
    if config.roles == [] do
      raise ArgumentError, "No servers specified"
    end

    primary_name = Configuration.primary_role_name(config)

    unless Configuration.role(config, primary_name) do
      raise ArgumentError, "The primary_role '#{primary_name}' isn't defined"
    end

    primary = Configuration.primary_role(config)

    if primary.hosts == [] do
      raise ArgumentError, "No servers specified for the #{primary.name} primary_role"
    end
  end

  defp validate_retain_releases!(config) do
    if Configuration.retain_releases(config) < 1 do
      raise ArgumentError, "Must retain at least 1 release"
    end
  end

  defp validate_destination!(config) do
    if Configuration.require_destination?(config) and config.destination == nil do
      raise ArgumentError, "You must specify a destination"
    end
  end

  defp validate_os!(config) do
    os = Configuration.os(config)

    unless os in ["linux", "freebsd"] do
      raise ArgumentError, "Unsupported os: #{inspect(os)}. Must be \"linux\" or \"freebsd\""
    end
  end
end
