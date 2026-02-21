defmodule SchemaCache.Adapter do
  @moduledoc """
  Behaviour for cache adapter implementations.

  SchemaCache is adapter-agnostic. Implement this behaviour to use
  your preferred caching backend (Nebulex, ConCache, ETS, etc.).
  """
end
