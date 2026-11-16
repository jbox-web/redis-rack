# frozen_string_literal: true

require 'spec_helper'
require 'rack/mock'
require 'connection_pool'

RSpec.describe Rack::Session::Redis do
  let(:session_key) { described_class::DEFAULT_OPTIONS[:key] }
  let(:session_match) { /#{session_key}=([0-9a-fA-F]+);/ }
  let(:incrementor) do
    lambda do |env|
      env['rack.session']['counter'] ||= 0
      env['rack.session']['counter'] += 1
      Rack::Response.new(env['rack.session'].inspect).to_a
    end
  end

  def app_with_session_option(option)
    proc do |env|
      env['rack.session.options'][option] = true
      incrementor.call(env)
    end
  end

  def inspected_counter(value)
    if RUBY_VERSION >= '3.4'
      %({"counter" => #{value}})
    else
      %({"counter"=>#{value}})
    end
  end

  def with_pool_management(*args)
    yield simple(*args)
    yield pooled(*args)
    yield external_pooled(*args)
  end

  def simple(app, options = {})
    described_class.new(app, options)
  end

  def pooled(app, options = {})
    described_class.new(app, options)
    described_class.new(app, options.merge(pool_size: 5, pool_timeout: 10))
  end

  def external_pooled(app, options = {})
    pool = ConnectionPool.new(size: 1, timeout: 1) do
      Redis::Store::Factory.create('redis://127.0.0.1:6380/1')
    end
    described_class.new(app, options.merge(pool: pool))
  end

  # # test Redis connection
  # Rack::Session::Redis.new(incrementor)
  #
  # it "faults on no connection" do
  #   lambda{
  #     Rack::Session::Redis.new(incrementor, :redis_server => 'nosuchserver')
  #   }.must_raise(Exception)
  # end

  it "can create it's own pool" do
    session_store = described_class.new(incrementor, pool_size: 5, pool_timeout: 10)
    conn = session_store.instance_variable_get(:@conn)

    expect(conn.pool).to be_instance_of(ConnectionPool)
    expect(conn.pool.instance_variable_get(:@size)).to eq(5)
  end

  it "can create it's own pool using default Redis server" do
    session_store = described_class.new(incrementor, pool_size: 5, pool_timeout: 10)

    expect(session_store.with(&:to_s)).to match(/127\.0\.0\.1:6379 against DB 0 with namespace rack:session$/)
  end

  it "can create it's own pool using provided Redis server" do
    session_store = described_class.new(incrementor, redis_server: 'redis://127.0.0.1:6380/1', pool_size: 5,
                                                     pool_timeout: 10)

    expect(session_store.with(&:to_s)).to match(/127\.0\.0\.1:6380 against DB 1$/)
  end

  it 'can use a supplied pool' do
    session_store = described_class.new(incrementor, pool: ConnectionPool.new(size: 1, timeout: 1) do
      Redis::Store::Factory.create('redis://127.0.0.1:6380/1')
    end)
    conn = session_store.instance_variable_get(:@conn)

    expect(conn.pool).to be_instance_of(ConnectionPool)
    expect(conn.pool.instance_variable_get(:@size)).to eq(1)
  end

  it 'uses the specified Redis store when provided' do
    store = Redis::Store::Factory.create('redis://127.0.0.1:6380/1')
    pool = described_class.new(incrementor, redis_store: store)

    expect(pool.with(&:to_s)).to match(/127\.0\.0\.1:6380 against DB 1$/)
    expect(pool.with(&:itself)).to eq(store)
  end

  it 'uses the default Redis server and namespace when not provided' do
    pool = described_class.new(incrementor)

    expect(pool.with(&:to_s)).to match(/127\.0\.0\.1:6379 against DB 0 with namespace rack:session$/)
  end

  it 'uses the specified namespace when provided' do
    pool = described_class.new(incrementor, redis_server: { namespace: 'test:rack:session' })

    expect(pool.with(&:to_s)).to match(/namespace test:rack:session$/)
  end

  it 'uses the specified Redis server when provided' do
    pool = described_class.new(incrementor, redis_server: 'redis://127.0.0.1:6380/1')

    expect(pool.with(&:to_s)).to match(/127\.0\.0\.1:6380 against DB 1$/)
  end

  it 'is threadsafe by default' do
    sesion_store = described_class.new(incrementor)

    expect(sesion_store.threadsafe?).to be(true)
  end

  it 'does not store a blank session' do
    session_store = described_class.new(incrementor)
    sid = session_store.generate_unique_sid({})

    expect(session_store.with { |c| c.get(sid.private_id) }).to be_nil
  end

  it 'locks the store mutex' do
    mutex = Mutex.new
    allow(mutex).to receive(:lock)
    sesion_store = described_class.new(incrementor)
    sesion_store.instance_variable_set(:@mutex, mutex)
    was_yielded = false
    request = instance_double(Rack::Request)
    sesion_store.with_lock(request) { was_yielded = true }

    expect(mutex).to have_received(:lock).once
    expect(was_yielded).to be(true)
  end

  describe 'threadsafe disabled' do
    it 'can have the global lock disabled' do
      sesion_store = described_class.new(incrementor, threadsafe: false)

      expect(sesion_store.threadsafe?).to be(false)
    end

    it 'does not lock the store mutex' do
      mutex = Mutex.new
      allow(mutex).to receive(:lock)
      sesion_store = described_class.new(incrementor, threadsafe: false)
      sesion_store.instance_variable_set(:@mutex, mutex)
      was_yielded = false
      request = instance_double(Rack::Request)
      sesion_store.with_lock(request) { was_yielded = true }

      expect(mutex).not_to have_received(:lock)
      expect(was_yielded).to be(true)
    end
  end

  it 'creates a new cookie' do
    with_pool_management(incrementor) do |pool|
      res = Rack::MockRequest.new(pool).get('/')

      expect(res['Set-Cookie']).to include("#{session_key}=")
      expect(res.body).to eq(inspected_counter(1))
    end
  end

  it 'determines session from a cookie' do
    with_pool_management(incrementor) do |pool|
      req = Rack::MockRequest.new(pool)
      res = req.get('/')
      cookie = res['Set-Cookie']

      expect(req.get('/', 'HTTP_COOKIE' => cookie).body).to eq(inspected_counter(2))
      expect(req.get('/', 'HTTP_COOKIE' => cookie).body).to eq(inspected_counter(3))
    end
  end

  it 'determines session only from a cookie by default' do
    with_pool_management(incrementor) do |pool|
      req = Rack::MockRequest.new(pool)
      res = req.get('/')
      sid = res['Set-Cookie'][session_match, 1]

      expect(req.get("/?rack.session=#{sid}").body).to eq(inspected_counter(1))
      expect(req.get("/?rack.session=#{sid}").body).to eq(inspected_counter(1))
    end
  end

  it 'determines session from params' do
    with_pool_management(incrementor, cookie_only: false) do |pool|
      req = Rack::MockRequest.new(pool)
      res = req.get('/')
      sid = res['Set-Cookie'][session_match, 1]

      expect(req.get("/?rack.session=#{sid}").body).to eq(inspected_counter(2))
      expect(req.get("/?rack.session=#{sid}").body).to eq(inspected_counter(3))
    end
  end

  it 'survives nonexistant cookies' do
    bad_cookie = 'rack.session=blarghfasel'
    with_pool_management(incrementor) do |pool|
      res = Rack::MockRequest.new(pool)
                             .get('/', 'HTTP_COOKIE' => bad_cookie)

      expect(res.body).to eq(inspected_counter(1))
      cookie = res['Set-Cookie'][session_match]

      expect(cookie).not_to match(/#{bad_cookie}/)
    end
  end

  it 'maintains freshness' do
    with_pool_management(incrementor, expire_after: 3) do |pool|
      res = Rack::MockRequest.new(pool).get('/')

      expect(res.body).to include(inspected_counter(1))
      cookie = res['Set-Cookie']
      sid = cookie[session_match, 1]
      res = Rack::MockRequest.new(pool).get('/', 'HTTP_COOKIE' => cookie)

      expect(res['Set-Cookie'][session_match, 1]).to eq(sid)
      expect(res.body).to include(inspected_counter(2))
      warn 'Sleeping to expire session' if $DEBUG
      sleep 4
      res = Rack::MockRequest.new(pool).get('/', 'HTTP_COOKIE' => cookie)

      expect(res['Set-Cookie'][session_match, 1]).not_to eq(sid)
      expect(res.body).to include(inspected_counter(1))
    end
  end

  it 'does not send the same session id if it did not change' do
    with_pool_management(incrementor) do |pool|
      req = Rack::MockRequest.new(pool)

      res0 = req.get('/')
      cookie = res0['Set-Cookie']

      expect(res0.body).to eq(inspected_counter(1))

      res1 = req.get('/', 'HTTP_COOKIE' => cookie)

      expect(res1['Set-Cookie']).to be_nil
      expect(res1.body).to eq(inspected_counter(2))

      res2 = req.get('/', 'HTTP_COOKIE' => cookie)

      expect(res2['Set-Cookie']).to be_nil
      expect(res2.body).to eq(inspected_counter(3))
    end
  end

  it 'deletes cookies with :drop option' do
    with_pool_management(incrementor) do |pool|
      req = Rack::MockRequest.new(pool)
      drop = Rack::Utils::Context.new(pool, app_with_session_option(:drop))
      dreq = Rack::MockRequest.new(drop)

      res1 = req.get('/')
      session = (cookie = res1['Set-Cookie'])[session_match]

      expect(res1.body).to eq(inspected_counter(1))

      res2 = dreq.get('/', 'HTTP_COOKIE' => cookie)

      expect(res2['Set-Cookie']).to be_nil
      expect(res2.body).to eq(inspected_counter(2))

      res3 = req.get('/', 'HTTP_COOKIE' => cookie)

      expect(res3['Set-Cookie'][session_match]).not_to eq(session)
      expect(res3.body).to eq(inspected_counter(1))
    end
  end

  it 'provides new session id with :renew option' do
    with_pool_management(incrementor) do |pool|
      req = Rack::MockRequest.new(pool)
      renew = Rack::Utils::Context.new(pool, app_with_session_option(:renew))
      rreq = Rack::MockRequest.new(renew)

      res1 = req.get('/')
      session = (cookie = res1['Set-Cookie'])[session_match]

      expect(res1.body).to eq(inspected_counter(1))

      res2 = rreq.get('/', 'HTTP_COOKIE' => cookie)
      new_cookie = res2['Set-Cookie']
      new_session = new_cookie[session_match]

      expect(new_session).not_to eq(session)
      expect(res2.body).to eq(inspected_counter(2))

      res3 = req.get('/', 'HTTP_COOKIE' => new_cookie)

      expect(res3.body).to eq(inspected_counter(3))

      # Old cookie was deleted
      res4 = req.get('/', 'HTTP_COOKIE' => cookie)

      expect(res4.body).to eq(inspected_counter(1))
    end
  end

  it 'omits cookie with :defer option' do
    with_pool_management(incrementor) do |pool|
      defer = Rack::Utils::Context.new(pool, app_with_session_option(:defer))
      dreq = Rack::MockRequest.new(defer)

      res0 = dreq.get('/')

      expect(res0['Set-Cookie']).to be_nil
      expect(res0.body).to eq(inspected_counter(1))
    end
  end

  it 'does not hit with :skip option' do
    with_pool_management(incrementor) do |session_store|
      skip = Rack::Utils::Context.new(session_store, app_with_session_option(:skip))
      sreq = Rack::MockRequest.new(skip)

      res0 = sreq.get('/')

      expect(res0.body).to eq(inspected_counter(1))
    end
  end

  it 'updates deep hashes correctly' do
    hash_check = proc do |env|
      session = env['rack.session']
      if session.include? 'test'
        session[:f][:g][:h] = :j
      else
        session.update :a => :b, :c => { d: :e },
                       :f => { g: { h: :i } }, 'test' => true
      end
      [200, {}, [session.inspect]]
    end
    with_pool_management(hash_check) do |pool|
      req = Rack::MockRequest.new(pool)

      res0 = req.get('/')
      session_id = (cookie = res0['Set-Cookie'])[session_match, 1]
      sid = Rack::Session::SessionId.new(session_id)
      ses0 = pool.with { |c| c.get(sid.private_id) }

      req.get('/', 'HTTP_COOKIE' => cookie)
      ses1 = pool.with { |c| c.get(sid.private_id) }

      expect(ses1).not_to eq(ses0)
    end
  end

  # anyone know how to do this better?
  it 'cleanly merges sessions when multithreaded' do
    skip 'only runs in debug mode (ruby -d)' unless $DEBUG

    warn 'Running multithread test for Session::Redis'
    with_pool_management(incrementor) do |pool|
      req = Rack::MockRequest.new(pool)
      res = req.get('/')

      expect(res.body).to eq(inspected_counter(1))

      cookie = res['Set-Cookie']
      session_id = cookie[session_match, 1]
      sid = Rack::Session::SessionId.new(session_id)

      delta_incrementor = lambda do |env|
        # emulate disconjoinment of threading
        env['rack.session'] = env['rack.session'].dup
        Thread.stop
        env['rack.session'][(Time.now.usec * rand).to_i] = true
        incrementor.call(env)
      end

      tses = Rack::Utils::Context.new pool, delta_incrementor
      treq = Rack::MockRequest.new(tses)
      tnum = rand(7).to_i + 5

      r = Array.new(tnum) do
        Thread.new(treq) do |run|
          run.get('/', 'HTTP_COOKIE' => cookie, 'rack.multithread' => true)
        end
      end.reverse.map { |t| t.run.join.value } # rubocop:disable Style/MultilineBlockChain

      r.each do |request|
        expect(request['Set-Cookie']).to eq(cookie)
        expect(request.body).to include(inspected_counter(2))
      end

      session = pool.with { |c| c.get(sid.private_id) }

      expect(session.size).to eq(tnum + 1) # counter
      expect(session['counter']).to eq(2) # meeeh

      tnum = rand(7).to_i + 5
      r = Array.new(tnum) do |_i|
        app = Rack::Utils::Context.new pool, time_delta
        req = Rack::MockRequest.new app
        Thread.new(req) do |run|
          run.get('/', 'HTTP_COOKIE' => cookie, 'rack.multithread' => true)
        end
      end.reverse.map { |t| t.run.join.value } # rubocop:disable Style/MultilineBlockChain

      r.each do |request|
        expect(request['Set-Cookie']).to eq(cookie)
        expect(request.body).to include('"counter"=>3')
      end

      session = pool.with { |c| c.get(sid.private_id) }

      expect(session.size).to eq(tnum + 1)
      expect(session['counter']).to eq(3)

      drop_counter = proc do |env|
        env['rack.session'].delete 'counter'
        env['rack.session']['foo'] = 'bar'
        [200, { 'Content-Type' => 'text/plain' }, env['rack.session'].inspect]
      end

      tses = Rack::Utils::Context.new pool, drop_counter
      treq = Rack::MockRequest.new(tses)
      tnum = rand(7).to_i + 5

      r = Array.new(tnum) do
        Thread.new(treq) do |run|
          run.get('/', 'HTTP_COOKIE' => cookie, 'rack.multithread' => true)
        end
      end.reverse.map { |t| t.run.join.value } # rubocop:disable Style/MultilineBlockChain

      r.each do |request|
        expect(request['Set-Cookie']).to eq(cookie)
        expect(request.body).to include('"foo"=>"bar"')
      end

      session = pool.with { |c| c.get(sid.private_id) }

      expect(session.size).to eq(r.size + 1)
      expect(session['counter']).to be_nil
      expect(session['foo']).to eq('bar')
    end
  end
end
