defmodule Xamal.EnvFile do
  @moduledoc """
  Generates env files for deployment.

  Encodes an env map as `KEY="value"` lines.

  Every consumer sources this file with `sh` (see `Xamal.Commands.RcD` and
  `Xamal.Commands.App`), so values are double-quoted and anything the shell
  would otherwise act on inside quotes - `\\`, `"`, `$`, a backtick - is
  escaped. Unquoted, a value containing a space would end at the space and
  the remainder would be run as a command.

  Modelled on Kamal's env file format, which is read by Docker's `--env-file`
  rather than by a shell, and so needs no quoting.
  """

  @doc """
  Generate env file content from a map of key-value pairs.
  Returns a string with one `KEY="value"` per line.
  """
  def encode(env) when map_size(env) == 0, do: "\n"

  def encode(env) when is_map(env) do
    env
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> [to_string(key), "=\"", escape_value(value), "\"\n"] end)
    |> IO.iodata_to_binary()
  end

  @doc """
  Write env file content to a path.
  """
  def write!(env, path) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, encode(env))
  end

  # Escape a value for use inside the double quotes `encode/1` wraps it in.
  # Handles special characters, preserves non-ASCII (UTF-8).
  defp escape_value(value) when is_binary(value) do
    value
    |> String.to_charlist()
    |> Enum.chunk_by(&ascii?/1)
    |> Enum.map(&escape_chunk/1)
    |> IO.iodata_to_binary()
  end

  defp escape_value(value), do: escape_value(to_string(value))

  defp escape_chunk(chunk) do
    string = List.to_string(chunk)
    if Enum.all?(chunk, &ascii?/1), do: escape_ascii(string), else: string
  end

  defp ascii?(char), do: char <= 127

  # Backslash first, so the escapes added below are not escaped again. `$` and
  # the backtick are the two characters the shell still acts on inside double
  # quotes, and would otherwise expand a variable or run a command substitution
  # when the file is sourced.
  defp escape_ascii(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "\\r")
    |> String.replace("\t", "\\t")
    |> String.replace("\"", "\\\"")
    |> String.replace("$", "\\$")
    |> String.replace("`", "\\`")
  end
end
