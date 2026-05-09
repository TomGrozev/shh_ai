defmodule ShhAi.ProviderName do
  @moduledoc """
  Generates human-friendly provider names from configuration URLs.

  Known providers are matched by hostname pattern. Unknown providers
  get a humanized hostname.
  """

  @type url() :: String.t()
  @type config() :: map()

  @known_providers %{
    "api.openai.com" => "OpenAI",
    "api.openai.org" => "OpenAI",
    "api.anthropic.com" => "Anthropic",
    "api.anthropic.ai" => "Anthropic",
    "localhost" => "Ollama",
    "127.0.0.1" => "Ollama"
  }

  @doc """
  Generates a display name for a provider configuration.

  Includes index suffix for disambiguating multiple providers of the same type.
  """
  @spec for_provider(integer(), config()) :: String.t()
  def for_provider(idx, config) do
    hostname = URI.parse(config.base_url).host || ""
    known_name = @known_providers |> Map.get(hostname)
    name = if known_name, do: known_name, else: custom_name(hostname, config.base_url)

    if idx > 1 do
      "#{name} (#{idx})"
    else
      name
    end
  end

  defp custom_name(hostname, url) when is_nil(hostname) or hostname == "" do
    base =
      url |> String.replace(~r/^https?:\/\//, "") |> String.split("/") |> Enum.at(0, "unknown")

    "Unknown [#{humanize(base)}]"
  end

  defp custom_name(hostname, _url) do
    case String.split(hostname, ".") |> Enum.reverse() do
      [_tld, base | _rest] ->
        humanize(base)

      _ ->
        "Unknown"
    end
  end

  defp humanize(string) when is_binary(string) do
    string
    |> String.replace("-", "_")
    |> Phoenix.Naming.humanize()
    |> capitalize_known()
  end

  @known_caps ~w(gpt ai)

  defp capitalize_known(str) do
    Enum.reduce(@known_caps, str, fn known, acc ->
      String.replace(acc, known, String.upcase(known))
    end)
  end
end
