defmodule SchemaCache.KeyGeneratorTest do
  use ExUnit.Case, async: true

  alias SchemaCache.KeyGenerator
  alias SchemaCache.Test.{FakeCompositeSchema, FakeSchema}

  doctest SchemaCache.KeyGenerator

  describe "cache_key/2" do
    test "generates a key from prefix and params" do
      assert "users:{\"id\":5}" = KeyGenerator.cache_key("users", %{id: 5})
    end

    test "converts order_by keyword list to map for encoding" do
      key = KeyGenerator.cache_key("users", %{order_by: [name: :asc]})
      assert key =~ "order_by"
      assert key =~ "name"
    end

    test "handles empty params" do
      assert "users:{}" = KeyGenerator.cache_key("users", %{})
    end
  end

  describe "schema_cache_key/1" do
    test "generates key from schema module and primary key" do
      user = %FakeSchema{id: 42, name: "test"}
      assert "Elixir.SchemaCache.Test.FakeSchema:42" = KeyGenerator.schema_cache_key(user)
    end

    test "handles composite primary keys" do
      record = %FakeCompositeSchema{tenant_id: 1, resource_id: 2, label: "test"}

      assert "Elixir.SchemaCache.Test.FakeCompositeSchema:1:2" =
               KeyGenerator.schema_cache_key(record)
    end
  end
end
