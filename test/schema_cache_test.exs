defmodule SchemaCacheTest do
  @moduledoc false

  use SchemaCache.Test.DataCase, async: false

  import ExUnit.CaptureLog

  alias SchemaCache.Adapters.ETS
  alias SchemaCache.KeyGenerator
  alias SchemaCache.KeyRegistry
  alias SchemaCache.Test.FakeSchema

  @ets_tables [
    :schema_cache_ets,
    :schema_cache_ets_sets,
    :schema_cache_key_to_id,
    :schema_cache_id_to_key
  ]

  setup do
    for table <- @ets_tables do
      if :ets.whereis(table) != :undefined do
        :ets.delete_all_objects(table)
      end
    end

    Application.put_env(:schema_cache, :adapter, SchemaCache.Adapters.ETS)
    :ok
  end

  defp make_user(id, name) do
    %FakeSchema{id: id, name: name, email: "#{name}@test.com"}
  end

  defp register_key_reference(set_key, cache_key) do
    id = KeyRegistry.register(cache_key)
    ETS.sadd(set_key, id)
    id
  end

  describe "read/4" do
    test "fetches from source on cache miss and caches the result" do
      user = make_user(1, "alice")

      result = SchemaCache.read("find_user", %{id: 1}, nil, fn -> {:ok, user} end)
      assert {:ok, ^user} = result

      # Second call should hit cache (function raises if called)
      assert {:ok, ^user} =
               SchemaCache.read("find_user", %{id: 1}, nil, fn ->
                 raise "should not be called"
               end)
    end

    test "caches and returns list results" do
      users = [make_user(1, "alice"), make_user(2, "bob")]

      result = SchemaCache.read("all_users", %{active: true}, nil, fn -> users end)
      assert ^users = result

      # Second call hits cache
      assert ^users =
               SchemaCache.read("all_users", %{active: true}, nil, fn ->
                 raise "should not be called"
               end)
    end

    test "does not cache empty list results" do
      call_count = :counters.new(1, [:atomics])

      fetch = fn ->
        :counters.add(call_count, 1, 1)
        []
      end

      assert [] = SchemaCache.read("all_users", %{}, nil, fetch)
      assert [] = SchemaCache.read("all_users", %{}, nil, fetch)

      # Function was called twice (not cached)
      assert :counters.get(call_count, 1) == 2
    end

    test "passes through error results without caching" do
      error = {:error, :not_found}

      assert ^error = SchemaCache.read("find_user", %{id: 99}, nil, fn -> error end)
    end

    test "falls back to source when adapter returns an error" do
      defmodule FailAdapter do
        @behaviour SchemaCache.Adapter
        @impl true
        def get(_key), do: {:error, :connection_refused}
        @impl true
        def put(_key, _value, _opts), do: :ok
        @impl true
        def delete(_key), do: :ok
      end

      original = :persistent_term.get(:schema_cache_adapter)
      :persistent_term.put(:schema_cache_adapter, FailAdapter)

      try do
        assert capture_log(fn ->
                 assert {:ok, %{id: 1}} =
                          SchemaCache.read("find_user", %{id: 1}, nil, fn ->
                            {:ok, make_user(1, "user")}
                          end)
               end) =~ "Unable to fetch from cache, falling back to source"
      after
        :persistent_term.put(:schema_cache_adapter, original)
      end
    end

    test "creates key references for singular results" do
      user = make_user(1, "alice")
      schema_key = KeyGenerator.schema_cache_key(user)

      SchemaCache.read("find_user", %{id: 1}, nil, fn -> {:ok, user} end)

      adapter = SchemaCache.Adapters.ETS
      set_key = "__set:#{schema_key}"
      {:ok, refs} = adapter.smembers(set_key)

      cache_key = KeyGenerator.cache_key("find_user", %{id: 1})
      expected_id = KeyRegistry.register(cache_key)
      assert expected_id in refs
    end

    test "creates key references for collection results and schema type" do
      users = [make_user(1, "alice"), make_user(2, "bob")]

      SchemaCache.read("all_users", %{active: true}, nil, fn -> users end)

      adapter = SchemaCache.Adapters.ETS
      cache_key = KeyGenerator.cache_key("all_users", %{active: true})
      expected_id = KeyRegistry.register(cache_key)

      # Each user should have a key reference
      for user <- users do
        schema_key = KeyGenerator.schema_cache_key(user)
        {:ok, refs} = adapter.smembers("__set:#{schema_key}")
        assert expected_id in refs
      end

      # Schema type should also have a key reference
      {:ok, type_refs} = adapter.smembers("__set:Elixir.SchemaCache.Test.FakeSchema")
      assert expected_id in type_refs
    end

    test "caches Repo.get, second call serves from cache" do
      user = insert_user!(%{name: "alice", email: "alice@test.com"})
      call_count = :counters.new(1, [:atomics])

      fetch = fn ->
        :counters.add(call_count, 1, 1)
        {:ok, Repo.get(User, user.id)}
      end

      user_id = user.id
      user_name = user.name

      assert {
               :ok,
               %{
                 id: ^user_id,
                 name: ^user_name
               }
             } = SchemaCache.read("find_user", %{id: user.id}, nil, fetch)

      assert :counters.get(call_count, 1) == 1

      assert {:ok, %{id: ^user_id}} =
               SchemaCache.read("find_user", %{id: user.id}, nil, fetch)

      assert :counters.get(call_count, 1) == 1
    end

    test "caches Repo.all collection, second call serves from cache" do
      user1 = insert_user!(%{name: "alice", email: "alice@test.com"})
      user2 = insert_user!(%{name: "bob", email: "bob@test.com"})
      call_count = :counters.new(1, [:atomics])

      fetch = fn ->
        :counters.add(call_count, 1, 1)
        Repo.all(User)
      end

      assert [_, _] = SchemaCache.read("all_users", %{}, nil, fetch)
      assert :counters.get(call_count, 1) == 1

      result = SchemaCache.read("all_users", %{}, nil, fetch)
      ids = Enum.map(result, & &1.id)
      assert user1.id in ids
      assert user2.id in ids
      assert :counters.get(call_count, 1) == 1
    end

    test "concurrent cache misses preserve all key references" do
      user = make_user(1, "alice")

      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            SchemaCache.read("query_#{i}", %{id: 1}, nil, fn -> {:ok, user} end)
          end)
        end

      Task.await_many(tasks)

      adapter = SchemaCache.Adapters.ETS
      schema_key = KeyGenerator.schema_cache_key(user)
      {:ok, refs} = adapter.smembers("__set:#{schema_key}")

      assert length(refs) == 20
    end

    test "concurrent reads for different schemas build correct key references" do
      users = for i <- 1..10, do: make_user(i, "user_#{i}")

      tasks =
        for user <- users do
          Task.async(fn ->
            SchemaCache.read("find_user", %{id: user.id}, nil, fn -> {:ok, user} end)
          end)
        end

      Task.await_many(tasks)

      adapter = SchemaCache.Adapters.ETS

      for user <- users do
        schema_key = KeyGenerator.schema_cache_key(user)
        expected_cache_key = KeyGenerator.cache_key("find_user", %{id: user.id})
        expected_id = SchemaCache.KeyRegistry.register(expected_cache_key)
        {:ok, refs} = adapter.smembers("__set:#{schema_key}")
        assert expected_id in refs
      end
    end

    test "concurrent reads and creates don't lose data" do
      adapter = SchemaCache.Adapters.ETS

      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            user = make_user(i, "reader_#{i}")
            SchemaCache.read("find_user", %{id: i}, nil, fn -> {:ok, user} end)
          end)
        end ++
          for i <- 11..15 do
            Task.async(fn ->
              new_user = make_user(i, "created_#{i}")
              SchemaCache.create(fn -> {:ok, new_user} end)
            end)
          end

      results = Task.await_many(tasks)
      assert length(results) == 15

      for i <- 1..10 do
        cache_key = KeyGenerator.cache_key("find_user", %{id: i})
        assert {:ok, %{id: ^i}} = adapter.get(cache_key)
      end
    end

    test "concurrent reads and mutations don't corrupt state" do
      user = make_user(1, "alice")
      SchemaCache.read("find_user", %{id: 1}, nil, fn -> {:ok, user} end)

      tasks =
        for _ <- 1..20 do
          Task.async(fn ->
            SchemaCache.read("find_user", %{id: 1}, nil, fn -> {:ok, user} end)
          end)
        end ++
          for i <- 1..5 do
            Task.async(fn ->
              updated = %{user | name: "alice_v#{i}"}
              SchemaCache.update(fn -> {:ok, updated} end)
            end)
          end

      results = Task.await_many(tasks)
      assert length(results) == 25
    end

    test "concurrent reads and write_through updates don't corrupt state" do
      user = make_user(1, "alice")
      SchemaCache.read("find_user", %{id: 1}, nil, fn -> {:ok, user} end)

      tasks =
        for _ <- 1..20 do
          Task.async(fn ->
            SchemaCache.read("find_user", %{id: 1}, nil, fn -> {:ok, user} end)
          end)
        end ++
          for i <- 1..5 do
            Task.async(fn ->
              updated = %{user | name: "alice_v#{i}"}
              SchemaCache.update(fn -> {:ok, updated} end, strategy: :write_through)
            end)
          end

      results = Task.await_many(tasks)
      assert length(results) == 25
    end
  end

  describe "create/1" do
    test "evicts all collection cache keys for the schema type" do
      user = make_user(1, "alice")
      all_key = KeyGenerator.cache_key("all_users", %{active: true})
      find_key = KeyGenerator.cache_key("find_user", %{id: 1})

      adapter = SchemaCache.Adapters.ETS

      adapter.put(all_key, [user], [])
      adapter.put(find_key, user, [])

      # Collection key reference under the schema type
      register_key_reference("__set:Elixir.SchemaCache.Test.FakeSchema", all_key)

      # Instance key references
      schema_key = KeyGenerator.schema_cache_key(user)
      register_key_reference("__set:#{schema_key}", find_key)
      register_key_reference("__set:#{schema_key}", all_key)

      new_user = make_user(2, "bob")

      {:ok, ^new_user} = SchemaCache.create(fn -> {:ok, new_user} end)

      # Collection key should be evicted
      assert {:ok, nil} = adapter.get(all_key)
      # Find key should NOT be evicted (create only targets type-level refs)
      assert {:ok, ^user} = adapter.get(find_key)
    end

    test "passes through error results without cache operations" do
      error = {:error, %{code: :validation, message: "invalid"}}

      assert ^error = SchemaCache.create(fn -> error end)
    end

    test "evicts collection cache so next read includes new record" do
      user1 = insert_user!(%{name: "alice", email: "alice@test.com"})

      SchemaCache.read("all_users", %{}, nil, fn -> Repo.all(User) end)

      assert {:ok, user2} =
               SchemaCache.create(fn ->
                 %User{}
                 |> User.changeset(%{name: "bob", email: "bob@test.com"})
                 |> Repo.insert()
               end)

      call_count = :counters.new(1, [:atomics])

      result =
        SchemaCache.read("all_users", %{}, nil, fn ->
          :counters.add(call_count, 1, 1)
          Repo.all(User)
        end)

      ids = Enum.map(result, & &1.id)
      assert user1.id in ids
      assert user2.id in ids
      assert :counters.get(call_count, 1) == 1
    end

    test "concurrent creates evict collection caches" do
      existing_user = make_user(1, "alice")
      adapter = SchemaCache.Adapters.ETS

      SchemaCache.read("all_users", %{}, nil, fn -> [existing_user] end)

      tasks =
        for i <- 2..11 do
          Task.async(fn ->
            new_user = make_user(i, "new_user_#{i}")
            SchemaCache.create(fn -> {:ok, new_user} end)
          end)
        end

      Task.await_many(tasks)

      assert {:ok, nil} = adapter.get(KeyGenerator.cache_key("all_users", %{}))
    end
  end

  describe "update/2" do
    test "evicts all cache keys referencing the mutated schema" do
      user = make_user(1, "alice")
      schema_key = KeyGenerator.schema_cache_key(user)
      find_key = KeyGenerator.cache_key("find_user", %{id: 1})
      all_key = KeyGenerator.cache_key("all_users", %{active: true})

      adapter = SchemaCache.Adapters.ETS

      # Simulate cached state: user is in both a find and an all result
      adapter.put(find_key, user, [])
      adapter.put(all_key, [user], [])

      # Set up key references via KeyRegistry
      register_key_reference("__set:#{schema_key}", find_key)
      register_key_reference("__set:#{schema_key}", all_key)

      updated_user = %{user | name: "alice_updated"}

      {:ok, ^updated_user} = SchemaCache.update(fn -> {:ok, updated_user} end)

      # Both cache entries should be evicted
      assert {:ok, nil} = adapter.get(find_key)
      assert {:ok, nil} = adapter.get(all_key)
    end

    test "passes through error results without cache operations" do
      error = {:error, %{code: :not_found, message: "not found"}}

      assert ^error = SchemaCache.update(fn -> error end)
    end

    test "write_through updates cached singular values in place" do
      user = make_user(1, "alice")
      schema_key = KeyGenerator.schema_cache_key(user)
      find_key = KeyGenerator.cache_key("find_user", %{id: 1})

      adapter = SchemaCache.Adapters.ETS

      adapter.put(find_key, user, [])
      register_key_reference("__set:#{schema_key}", find_key)

      updated_user = %{user | name: "alice_updated"}

      {:ok, ^updated_user} =
        SchemaCache.update(fn -> {:ok, updated_user} end, strategy: :write_through)

      assert {:ok, ^updated_user} = adapter.get(find_key)
    end

    test "write_through updates cached collections in place" do
      user = make_user(1, "alice")
      schema_key = KeyGenerator.schema_cache_key(user)
      all_key = KeyGenerator.cache_key("all_users", %{active: true})

      adapter = SchemaCache.Adapters.ETS

      adapter.put(all_key, [user], [])
      register_key_reference("__set:#{schema_key}", all_key)

      updated_user = %{user | name: "alice_updated"}

      {:ok, ^updated_user} =
        SchemaCache.update(fn -> {:ok, updated_user} end, strategy: :write_through)

      assert {:ok, [^updated_user]} = adapter.get(all_key)
    end

    test "write_through passes through error results without cache operations" do
      error = {:error, %{code: :conflict, message: "conflict"}}

      assert ^error = SchemaCache.update(fn -> error end, strategy: :write_through)
    end

    test "default eviction against DB, next read gets fresh data" do
      user = insert_user!(%{name: "alice", email: "alice@test.com"})

      {:ok, _} =
        SchemaCache.read("find_user", %{id: user.id}, nil, fn ->
          {:ok, Repo.get(User, user.id)}
        end)

      assert {:ok, %{name: "alice_updated"}} =
               SchemaCache.update(fn ->
                 user
                 |> User.changeset(%{name: "alice_updated"})
                 |> Repo.update()
               end)

      call_count = :counters.new(1, [:atomics])

      assert {:ok, %{name: "alice_updated"}} =
               SchemaCache.read("find_user", %{id: user.id}, nil, fn ->
                 :counters.add(call_count, 1, 1)
                 {:ok, Repo.get(User, user.id)}
               end)

      assert :counters.get(call_count, 1) == 1
    end

    test "write_through singular updates cache in place without re-fetching" do
      user = insert_user!(%{name: "alice", email: "alice@test.com"})

      {:ok, _} =
        SchemaCache.read("find_user", %{id: user.id}, nil, fn ->
          {:ok, Repo.get(User, user.id)}
        end)

      assert {:ok, %{name: "alice_updated"}} =
               SchemaCache.update(
                 fn ->
                   user
                   |> User.changeset(%{name: "alice_updated"})
                   |> Repo.update()
                 end,
                 strategy: :write_through
               )

      call_count = :counters.new(1, [:atomics])

      assert {:ok, %{name: "alice_updated"}} =
               SchemaCache.read("find_user", %{id: user.id}, nil, fn ->
                 :counters.add(call_count, 1, 1)
                 {:ok, Repo.get(User, user.id)}
               end)

      assert :counters.get(call_count, 1) == 0
    end

    test "write_through collection updates cache in place" do
      user = insert_user!(%{name: "alice", email: "alice@test.com"})

      SchemaCache.read("all_users", %{}, nil, fn -> Repo.all(User) end)

      assert {:ok, %{name: "alice_updated"}} =
               SchemaCache.update(
                 fn ->
                   user
                   |> User.changeset(%{name: "alice_updated"})
                   |> Repo.update()
                 end,
                 strategy: :write_through
               )

      call_count = :counters.new(1, [:atomics])

      assert [%{name: "alice_updated"}] =
               SchemaCache.read("all_users", %{}, nil, fn ->
                 :counters.add(call_count, 1, 1)
                 Repo.all(User)
               end)

      assert :counters.get(call_count, 1) == 0
    end

    test "concurrent updates don't lose evictions" do
      users = for i <- 1..10, do: make_user(i, "user_#{i}")
      adapter = SchemaCache.Adapters.ETS

      SchemaCache.read("all_users", %{}, nil, fn -> users end)

      tasks =
        for user <- users do
          Task.async(fn ->
            updated = %{user | name: "#{user.name}_updated"}
            SchemaCache.update(fn -> {:ok, updated} end)
          end)
        end

      Task.await_many(tasks)

      assert {:ok, nil} = adapter.get(KeyGenerator.cache_key("all_users", %{}))
    end
  end

  describe "delete/1" do
    test "evicts all cache keys referencing the deleted schema" do
      user = make_user(1, "alice")
      schema_key = KeyGenerator.schema_cache_key(user)
      find_key = KeyGenerator.cache_key("find_user", %{id: 1})
      all_key = KeyGenerator.cache_key("all_users", %{active: true})
      adapter = SchemaCache.Adapters.ETS

      adapter.put(find_key, user, [])
      adapter.put(all_key, [user], [])

      register_key_reference("__set:#{schema_key}", find_key)
      register_key_reference("__set:#{schema_key}", all_key)

      {:ok, ^user} = SchemaCache.delete(fn -> {:ok, user} end)

      assert {:ok, nil} = adapter.get(find_key)
      assert {:ok, nil} = adapter.get(all_key)
    end

    test "passes through error results without cache operations" do
      error = {:error, %{code: :not_found, message: "not found"}}

      assert ^error = SchemaCache.delete(fn -> error end)
    end

    test "evicts cache, next read reflects deletion from DB" do
      user = insert_user!(%{name: "alice", email: "alice@test.com"})

      {:ok, _} =
        SchemaCache.read("find_user", %{id: user.id}, nil, fn ->
          {:ok, Repo.get(User, user.id)}
        end)

      SchemaCache.read("all_users", %{}, nil, fn -> Repo.all(User) end)

      user_id = user.id

      assert {:ok, %{id: ^user_id}} =
               SchemaCache.delete(fn ->
                 Repo.delete(user)
               end)

      call_count = :counters.new(1, [:atomics])

      assert {:ok, nil} =
               SchemaCache.read("find_user", %{id: user.id}, nil, fn ->
                 :counters.add(call_count, 1, 1)
                 {:ok, Repo.get(User, user.id)}
               end)

      assert :counters.get(call_count, 1) == 1
    end

    test "concurrent deletes evict all referenced keys" do
      users = for i <- 1..5, do: make_user(i, "user_#{i}")
      adapter = SchemaCache.Adapters.ETS

      for user <- users do
        SchemaCache.read("find_user", %{id: user.id}, nil, fn -> {:ok, user} end)
      end

      tasks =
        for user <- users do
          Task.async(fn ->
            SchemaCache.delete(fn -> {:ok, user} end)
          end)
        end

      Task.await_many(tasks)

      for user <- users do
        cache_key = KeyGenerator.cache_key("find_user", %{id: user.id})
        assert {:ok, nil} = adapter.get(cache_key)
      end
    end
  end

  describe "flush/2" do
    test "flushes all key references for a schema instance" do
      user = make_user(1, "alice")
      schema_key = KeyGenerator.schema_cache_key(user)
      key_1 = "cache_key_1"
      key_2 = "cache_key_2"

      adapter = SchemaCache.Adapters.ETS

      adapter.put(key_1, "value_1", [])
      adapter.put(key_2, "value_2", [])
      register_key_reference("__set:#{schema_key}", key_1)
      register_key_reference("__set:#{schema_key}", key_2)

      assert :ok = SchemaCache.flush(user)

      assert {:ok, nil} = adapter.get(key_1)
      assert {:ok, nil} = adapter.get(key_2)
    end

    test "returns :ok when no key references exist" do
      user = make_user(99, "nobody")
      assert :ok = SchemaCache.flush(user)
    end

    test "evicts 101+ cache entries via async_stream branch" do
      user = make_user(1, "alice")
      schema_key = KeyGenerator.schema_cache_key(user)
      set_key = "__set:#{schema_key}"
      adapter = SchemaCache.Adapters.ETS

      # Register 105 key references for a single schema instance
      cache_keys =
        for i <- 1..105 do
          cache_key = "async_test_key_#{i}"
          adapter.put(cache_key, "value_#{i}", [])
          register_key_reference(set_key, cache_key)
          cache_key
        end

      # Verify entries exist before flush
      for key <- cache_keys do
        assert {:ok, value} = adapter.get(key)
        assert value != nil
      end

      assert :ok = SchemaCache.flush(user)

      # All 105 cache entries should be evicted
      for key <- cache_keys do
        assert {:ok, nil} = adapter.get(key)
      end
    end

    test "removes orphaned IDs from the adapter set during eviction" do
      user = make_user(1, "alice")
      schema_key = KeyGenerator.schema_cache_key(user)
      set_key = "__set:#{schema_key}"
      adapter = SchemaCache.Adapters.ETS

      # Register a cache key in KeyRegistry, get its ID
      cache_key = "orphan_test_key"
      id = KeyRegistry.register(cache_key)

      # Add the ID to the adapter set
      adapter.sadd(set_key, id)

      # Put a value so the set has something to track
      adapter.put(cache_key, "some_value", [])

      # Unregister the ID from KeyRegistry to simulate an orphaned ID
      KeyRegistry.unregister_id(id)

      # Trigger eviction
      assert :ok = SchemaCache.flush(user)

      # The orphaned ID should be removed from the adapter set
      case adapter.smembers(set_key) do
        {:ok, nil} -> :ok
        {:ok, members} -> refute id in members
      end
    end

    test "cleans up stale IDs from the set and KeyRegistry after TTL expiration" do
      user = make_user(1, "alice")
      adapter = SchemaCache.Adapters.ETS

      # Cache the value via read/4 to create cache entry + key references
      {:ok, ^user} =
        SchemaCache.read("find_user_stale", %{id: 1}, nil, fn -> {:ok, user} end)

      cache_key = KeyGenerator.cache_key("find_user_stale", %{id: 1})
      schema_key = KeyGenerator.schema_cache_key(user)
      set_key = "__set:#{schema_key}"

      # Verify the cache entry and references exist
      assert {:ok, ^user} = adapter.get(cache_key)
      {:ok, refs} = adapter.smembers(set_key)
      id = KeyRegistry.register(cache_key)
      assert id in refs

      # Manually delete the cached value to simulate TTL expiration
      adapter.delete(cache_key)
      assert {:ok, nil} = adapter.get(cache_key)

      # Trigger eviction
      assert :ok = SchemaCache.flush(user)

      # The stale ID should be cleaned up from the set
      case adapter.smembers(set_key) do
        {:ok, nil} -> :ok
        {:ok, members} -> refute id in members
      end

      # The stale ID should be cleaned up from KeyRegistry
      assert {:ok, nil} = KeyRegistry.lookup(id)
    end

    test "does not crash and logs a warning when mget returns an error" do
      user = make_user(1, "alice")
      schema_key = KeyGenerator.schema_cache_key(user)
      set_key = "__set:#{schema_key}"
      adapter = SchemaCache.Adapters.ETS

      # Set up a cache reference so there are IDs to resolve
      cache_key = "mget_fail_test_key"
      adapter.put(cache_key, "some_value", [])
      register_key_reference(set_key, cache_key)

      original_adapter = :persistent_term.get(:schema_cache_adapter)
      original_caps = :persistent_term.get(:schema_cache_adapter_caps)

      :persistent_term.put(:schema_cache_adapter, SchemaCache.Test.FailMgetAdapter)

      :persistent_term.put(:schema_cache_adapter_caps, %{
        sadd: true,
        srem: true,
        smembers: true,
        mget: true
      })

      try do
        log =
          capture_log(fn ->
            assert :ok = SchemaCache.flush(user)
          end)

        assert log =~ "eviction mget failed"
      after
        :persistent_term.put(:schema_cache_adapter, original_adapter)
        :persistent_term.put(:schema_cache_adapter_caps, original_caps)
      end
    end

    test "evicts all cached queries for a schema instance from DB" do
      user = insert_user!(%{name: "alice", email: "alice@test.com"})

      {:ok, _} =
        SchemaCache.read("find_user", %{id: user.id}, nil, fn ->
          {:ok, Repo.get(User, user.id)}
        end)

      SchemaCache.read("all_users", %{}, nil, fn -> Repo.all(User) end)

      :ok = SchemaCache.flush(user)

      call_count = :counters.new(1, [:atomics])

      {:ok, _} =
        SchemaCache.read("find_user", %{id: user.id}, nil, fn ->
          :counters.add(call_count, 1, 1)
          {:ok, Repo.get(User, user.id)}
        end)

      SchemaCache.read("all_users", %{}, nil, fn ->
        :counters.add(call_count, 1, 1)
        Repo.all(User)
      end)

      assert :counters.get(call_count, 1) == 2
    end
  end

  describe "write_to_cache/2" do
    test "updates all key ref values directly" do
      user = make_user(1, "alice")
      schema_key = KeyGenerator.schema_cache_key(user)
      find_key = KeyGenerator.cache_key("find_user", %{id: 1})
      all_key = KeyGenerator.cache_key("all_users", %{active: true})

      adapter = SchemaCache.Adapters.ETS

      adapter.put(find_key, user, [])
      adapter.put(all_key, [user], [])
      register_key_reference("__set:#{schema_key}", find_key)
      register_key_reference("__set:#{schema_key}", all_key)

      updated = %{user | name: "updated"}
      assert :ok = SchemaCache.write_to_cache(updated)

      assert {:ok, ^updated} = adapter.get(find_key)
      assert {:ok, [^updated]} = adapter.get(all_key)
    end

    test "returns :ok silently when smembers returns {:ok, nil}" do
      user = make_user(99, "no_refs")

      # No references exist for this schema, so smembers returns {:ok, nil}
      assert :ok = SchemaCache.write_to_cache(user)
    end

    test "cleans up stale refs when cache entry has expired" do
      user = make_user(1, "alice")
      adapter = SchemaCache.Adapters.ETS

      # Cache the value via read/4
      {:ok, ^user} =
        SchemaCache.read("find_user_wt", %{id: 1}, nil, fn -> {:ok, user} end)

      cache_key = KeyGenerator.cache_key("find_user_wt", %{id: 1})
      schema_key = KeyGenerator.schema_cache_key(user)
      set_key = "__set:#{schema_key}"

      # Verify references exist
      id = KeyRegistry.register(cache_key)
      {:ok, refs} = adapter.smembers(set_key)
      assert id in refs

      # Simulate cache entry expiration by deleting from adapter
      adapter.delete(cache_key)

      # write_to_cache should clean up the stale ref
      updated_user = %{user | name: "alice_updated"}
      assert :ok = SchemaCache.write_to_cache(updated_user)

      # Stale ID should be removed from the set
      case adapter.smembers(set_key) do
        {:ok, nil} -> :ok
        {:ok, members} -> refute id in members
      end

      # Stale ID should be removed from KeyRegistry
      assert {:ok, nil} = KeyRegistry.lookup(id)
    end

    test "updates cache without DB write, DB still has original" do
      user = insert_user!(%{name: "alice", email: "alice@test.com"})

      {:ok, _} =
        SchemaCache.read("find_user", %{id: user.id}, nil, fn ->
          {:ok, Repo.get(User, user.id)}
        end)

      modified = %{user | name: "cache_only_name"}
      :ok = SchemaCache.write_to_cache(modified)

      assert {:ok, %{name: "cache_only_name"}} =
               SchemaCache.read("find_user", %{id: user.id}, nil, fn ->
                 {:ok, Repo.get(User, user.id)}
               end)

      assert %{name: "alice"} = Repo.get(User, user.id)
    end
  end

  test "full lifecycle: read, create, update (write_through), update (evict), delete" do
    adapter = SchemaCache.Adapters.ETS

    user = make_user(1, "alice")

    # Step 1: Cache a user via read/4 as singular
    {:ok, ^user} =
      SchemaCache.read("find_user", %{id: 1}, nil, fn -> {:ok, user} end)

    find_key = KeyGenerator.cache_key("find_user", %{id: 1})
    assert {:ok, ^user} = adapter.get(find_key)

    # Step 2: Cache a user list via read/4 as collection
    users = [user, make_user(2, "bob")]

    ^users =
      SchemaCache.read("all_users", %{active: true}, nil, fn -> users end)

    all_key = KeyGenerator.cache_key("all_users", %{active: true})
    assert {:ok, ^users} = adapter.get(all_key)

    # Step 3: Create a new user - verify collection cache is evicted
    new_user = make_user(3, "charlie")
    {:ok, ^new_user} = SchemaCache.create(fn -> {:ok, new_user} end)

    # Collection key should be evicted (create evicts type-level refs)
    assert {:ok, nil} = adapter.get(all_key)

    # Singular find key should still be cached (create doesn't evict instance refs)
    assert {:ok, ^user} = adapter.get(find_key)

    # Step 4: Re-read the collection (should re-cache)
    updated_users = [user, make_user(2, "bob"), new_user]

    ^updated_users =
      SchemaCache.read("all_users", %{active: true}, nil, fn -> updated_users end)

    assert {:ok, ^updated_users} = adapter.get(all_key)

    # Step 5: Update the user via update/2 with :write_through
    updated_user = %{user | name: "alice_updated"}

    {:ok, ^updated_user} =
      SchemaCache.update(fn -> {:ok, updated_user} end, strategy: :write_through)

    # Singular cache should be updated in place
    assert {:ok, ^updated_user} = adapter.get(find_key)

    # Collection cache should have the updated user in place
    {:ok, cached_collection} = adapter.get(all_key)
    assert Enum.any?(cached_collection, &(&1.name == "alice_updated"))
    refute Enum.any?(cached_collection, &(&1.name == "alice" and &1.id == 1))

    # Step 6: Update the user via update/2 with :evict (default)
    evicted_user = %{updated_user | name: "alice_evicted"}

    {:ok, ^evicted_user} =
      SchemaCache.update(fn -> {:ok, evicted_user} end)

    # Both caches should be evicted
    assert {:ok, nil} = adapter.get(find_key)
    assert {:ok, nil} = adapter.get(all_key)

    # Step 7: Re-cache the singular entry for delete test
    {:ok, ^evicted_user} =
      SchemaCache.read("find_user", %{id: 1}, nil, fn -> {:ok, evicted_user} end)

    assert {:ok, ^evicted_user} = adapter.get(find_key)

    # Step 8: Delete the user - verify remaining caches are evicted
    {:ok, ^evicted_user} = SchemaCache.delete(fn -> {:ok, evicted_user} end)

    assert {:ok, nil} = adapter.get(find_key)
  end

  defp insert_user!(attrs) do
    defaults = %{
      name: "user_#{System.unique_integer([:positive])}",
      email: "user_#{System.unique_integer([:positive])}@test.com"
    }

    %User{}
    |> User.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end
end
