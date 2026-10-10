# frozen_string_literal: true

module RubyReactor
  module Storage
    class ActiveRecordAdapter
      # Redis-shaped key/value state for the coordination primitives (011
      # R-03–R-07): one `ruby_reactor_coordination` row per Redis key, each with
      # its own TTL. `atomically` runs a block over a fixed key set inside one
      # transaction with those rows locked, which is what makes a Lua script
      # atomic — so each script ports to Ruby line for line against `KV`.
      module Coordination
        RETRIES = 3
        RETRYABLE = [::ActiveRecord::Deadlocked, ::ActiveRecord::SerializationFailure].freeze

        # The database's own clock, in epoch ms: one clock for every process, as
        # Redis's server clock is for its TTLs (R-06).
        NOW_MS_SQL = {
          "PostgreSQL" => "SELECT CAST(EXTRACT(EPOCH FROM clock_timestamp()) * 1000 AS BIGINT)",
          "Mysql2" => "SELECT CAST(UNIX_TIMESTAMP(NOW(3)) * 1000 AS UNSIGNED)",
          "Trilogy" => "SELECT CAST(UNIX_TIMESTAMP(NOW(3)) * 1000 AS UNSIGNED)",
          "SQLite" => "SELECT CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)"
        }.freeze

        module_function

        def digest(key) = Digest::SHA256.hexdigest(key.to_s)

        def now_ms(conn) = conn.select_value(NOW_MS_SQL.fetch(conn.adapter_name)).to_i

        # Locks `keys` (creating absent rows first: FOR UPDATE on a missing row
        # locks nothing) in digest order — deadlock-free — then yields a `KV`
        # and writes back what changed. Retried whole on deadlock/serialization
        # failure; the block must be pure over its `kv` (R-05).
        def atomically(keys, op: "atomically")
          attempts = 0
          begin
            attempts += 1
            Record.connection_pool.with_connection do |conn|
              Record.transaction do
                rows = lock_rows(keys)
                kv = KV.new(rows, now_ms(conn))
                result = yield kv
                kv.dirty_rows.each do |row|
                  CoordinationEntry.where(key_digest: row[:digest])
                                   .update_all(value: row[:value], expires_at_ms: row[:expires_at_ms])
                end
                result
              end
            end
          rescue *RETRYABLE => e
            if attempts < RETRIES
              sleep(rand(0.01..0.05))
              retry
            end
            log_failure(op, keys.size, e)
            raise
          rescue ::ActiveRecord::ActiveRecordError => e
            log_failure(op, keys.size, e)
            raise
          end
        end

        # Read-only view: no insert, no lock, no transaction (R-04). For the
        # inspectors, so polling never competes with workers for row locks.
        def peek(keys)
          Record.connection_pool.with_connection do |conn|
            by_digest = CoordinationEntry.where(key_digest: keys.map { |k| digest(k) }).index_by(&:key_digest)
            rows = keys.map { |key| row_for(key, by_digest[digest(key)]) }
            yield KV.new(rows, now_ms(conn), read_only: true)
          end
        end

        # Deletes up to `limit` expired or emptied rows; returns how many.
        def purge_expired(limit: 1000)
          Record.connection_pool.with_connection do |conn|
            now = now_ms(conn)
            stale = CoordinationEntry.where("value IS NULL OR expires_at_ms <= ?", now).limit(limit).pluck(:key_digest)
            stale.empty? ? 0 : CoordinationEntry.where(key_digest: stale).delete_all
          end
        end

        def lock_rows(keys)
          digests = keys.to_h { |key| [digest(key), key] }
          locked = {}
          # A concurrent purge can delete a placeholder between our insert and
          # our select, so re-ensure until every key is locked.
          3.times do
            missing = digests.keys - locked.keys
            break if missing.empty?

            CoordinationEntry.insert_all(missing.map { |d| { key_digest: d, key: digests[d] } })
            CoordinationEntry.where(key_digest: missing).order(:key_digest).lock.each do |row|
              locked[row.key_digest] = row
            end
          end
          raise ::ActiveRecord::StatementInvalid, "coordination rows vanished while locking" if locked.size < digests.size

          keys.map { |key| row_for(key, locked[digest(key)]) }
        end

        def row_for(key, record)
          { key: key.to_s, digest: digest(key), value: record&.value, expires_at_ms: record&.expires_at_ms }
        end

        def log_failure(op, key_count, error)
          engine = begin
            Record.connection_db_config.adapter
          rescue ::ActiveRecord::ActiveRecordError
            "unknown"
          end
          RubyReactor.configuration.logger.error(
            "ruby_reactor.storage op=#{op} engine=#{engine} keys=#{key_count} error=#{error.class}"
          )
        end

        # The Redis verbs the coordination scripts use, over the locked rows.
        # Values are Redis-typed: strings for strings/integers, Hash for hashes,
        # Array for lists and sets. An empty hash/list/set deletes its key, as in
        # Redis; an expired key reads as absent.
        class KV # rubocop:disable Metrics/ClassLength
          attr_reader :now_ms

          def initialize(rows, now_ms, read_only: false)
            @now_ms = now_ms
            @read_only = read_only
            @rows = rows.to_h do |row|
              live = row[:value] && (row[:expires_at_ms].nil? || row[:expires_at_ms] > now_ms)
              [row[:key], row.merge(value: live ? JSON.parse(row[:value]) : nil,
                                    expires_at_ms: live ? row[:expires_at_ms] : nil, dirty: false)]
            end
          end

          def dirty_rows
            @rows.values.select { |row| row[:dirty] }.map do |row|
              row.merge(value: row[:value].nil? ? nil : JSON.generate(row[:value]))
            end
          end

          # -- keys

          def exists(key) = !value(key).nil?

          def del(key)
            return 0 unless exists(key)

            write(key, nil, nil)
            1
          end

          def expire(key, seconds)
            return false unless exists(key)

            write(key, value(key), @now_ms + (seconds.to_f * 1000).to_i)
            true
          end

          # Redis TTL: -2 absent, -1 no expiry, else whole seconds remaining.
          def ttl(key)
            return -2 unless exists(key)

            expires = row(key)[:expires_at_ms]
            expires.nil? ? -1 : ((expires - @now_ms) / 1000.0).round
          end

          # -- strings

          def get(key) = value(key)

          def set(key, val, nx: false, ex: nil, keepttl: false)
            return false if nx && exists(key)

            expires = if ex then @now_ms + (ex.to_f * 1000).to_i
                      elsif keepttl then row(key)[:expires_at_ms]
                      end
            write(key, val.to_s, expires)
            true
          end

          def incrby(key, amount)
            updated = value(key).to_i + amount.to_i
            write(key, updated.to_s, row(key)[:expires_at_ms])
            updated
          end

          def incr(key) = incrby(key, 1)
          def decr(key) = incrby(key, -1)
          def decrby(key, amount) = incrby(key, -amount.to_i)

          # -- hashes

          def hget(key, field) = (value(key) || {})[field.to_s]
          def hgetall(key) = (value(key) || {}).dup
          def hexists(key, field) = (value(key) || {}).key?(field.to_s)
          def hkeys(key) = (value(key) || {}).keys
          def hlen(key) = (value(key) || {}).size

          def hset(key, field, val)
            hash = hgetall(key)
            added = hash.key?(field.to_s) ? 0 : 1
            hash[field.to_s] = val.to_s
            write(key, hash, row(key)[:expires_at_ms])
            added
          end

          def hdel(key, field)
            hash = hgetall(key)
            return 0 unless hash.delete(field.to_s)

            write_collection(key, hash)
            1
          end

          def hincrby(key, field, amount)
            updated = hget(key, field).to_i + amount.to_i
            hset(key, field, updated)
            updated
          end

          # -- lists

          def llen(key) = (value(key) || []).size
          def lrange(key) = (value(key) || []).dup

          def rpush(key, *vals)
            list = lrange(key) + vals.flatten.map(&:to_s)
            write(key, list, row(key)[:expires_at_ms])
            list.size
          end

          def lpop(key)
            list = lrange(key)
            head = list.shift
            write_collection(key, list) unless head.nil?
            head
          end

          # -- sets

          def smembers(key) = (value(key) || []).dup
          def sismember(key, member) = smembers(key).include?(member.to_s)
          def scard(key) = smembers(key).size

          def sadd(key, member)
            return 0 if sismember(key, member)

            write(key, smembers(key) << member.to_s, row(key)[:expires_at_ms])
            1
          end

          def srem(key, member)
            set = smembers(key)
            return 0 unless set.delete(member.to_s)

            write_collection(key, set)
            1
          end

          private

          def row(key) = @rows.fetch(key.to_s) { raise ArgumentError, "key #{key} was not locked" }
          def value(key) = row(key)[:value]

          def write_collection(key, collection)
            collection.empty? ? write(key, nil, nil) : write(key, collection, row(key)[:expires_at_ms])
          end

          def write(key, val, expires_at_ms)
            raise ::ActiveRecord::ReadOnlyError, "peek is read-only" if @read_only

            r = row(key)
            r[:value] = val
            r[:expires_at_ms] = val.nil? ? nil : expires_at_ms
            r[:dirty] = true
          end
        end
      end
    end
  end
end
