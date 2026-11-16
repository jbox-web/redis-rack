# frozen_string_literal: true

require 'spec_helper'
require 'connection_pool'
require 'redis/rack/connection'

RSpec.describe Redis::Rack::Connection do
  let(:defaults) do
    {
      host: 'localhost'
    }
  end

  it "can create it's own pool" do
    conn = described_class.new defaults.merge(pool_size: 5, pool_timeout: 10)

    expect(conn.pooled?).to be(true)
    expect(conn.pool).to be_instance_of(ConnectionPool)
    expect(conn.pool.instance_variable_get(:@size)).to eq(5)
  end

  it "can create it's own pool using default Redis server" do
    conn = described_class.new defaults.merge(pool_size: 5, pool_timeout: 10)

    expect(conn.pooled?).to be(true)
    expect(conn.with(&:to_s)).to match(/localhost:6379 against DB 0$/)
  end

  it "can create it's own pool using provided Redis server" do
    conn = described_class.new(redis_server: 'redis://127.0.0.1:6380/1', pool_size: 5, pool_timeout: 10)

    expect(conn.pooled?).to be(true)
    expect(conn.with(&:to_s)).to match(/127\.0\.0\.1:6380 against DB 1$/)
  end

  it 'can establish a new connection pool with the provided Redis server' do
    pool_size = 5
    conn = described_class.new(redis_server: 'redis://127.0.0.1:6380/1', pool_size: pool_size)

    clients = []
    mutex = Mutex.new
    Array.new(pool_size) do |i|
      Thread.new do
        conn.with do |connection|
          mutex.synchronize do
            clients[i] = connection
          end

          # Wait for all clients to be established
          loop do
            break if clients.size == pool_size && clients.all?

            sleep(0.01)
          end
        end
      end
    end.each(&:join)

    expect(conn.pooled?).to be(true)
    expect(clients.map(&:object_id).uniq.size).to eq(pool_size)
  end

  it 'can use a supplied pool' do
    pool = ConnectionPool.new size: 1, timeout: 1 do
      Redis::Store::Factory.create('redis://127.0.0.1:6380/1')
    end
    conn = described_class.new pool: pool

    expect(conn.pooled?).to be(true)
    expect(conn.pool).to be_instance_of(ConnectionPool)
    expect(conn.pool.instance_variable_get(:@size)).to eq(1)
  end

  it 'uses the specified Redis store when provided' do
    store = Redis::Store::Factory.create('redis://127.0.0.1:6380/1')
    conn = described_class.new(redis_store: store)

    expect(conn.pooled?).to be(false)
    expect(conn.store.to_s).to match(/127\.0\.0\.1:6380 against DB 1$/)
    expect(conn.store).to eq(store)
  end

  it 'throws an error when provided Redis store is not the expected type' do
    expect do
      described_class.new(redis_store: Redis.new)
    end.to raise_error(ArgumentError)
  end

  it 'uses the specified Redis server when provided' do
    conn = described_class.new(redis_server: 'redis://127.0.0.1:6380/1')

    expect(conn.pooled?).to be(false)
    expect(conn.store.to_s).to match(/127\.0\.0\.1:6380 against DB 1$/)
  end

  it 'does not include nil options for the connection pool' do
    conn = described_class.new

    expect(conn.pool_options).to be_empty

    conn = described_class.new(pool_size: nil)

    expect(conn.pool_options).to be_empty

    conn = described_class.new(pool_timeout: nil)

    expect(conn.pool_options).to be_empty
  end
end
