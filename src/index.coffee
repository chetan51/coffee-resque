exports.version    = "0.1.0"

# Sets up a new Resque Connection.  This Connection can either be used to 
# queue new Resque jobs, or be passed into a worker through a `connection` 
# option.
#
# options - Optional Hash of options.
#           host      - String Redis host.  (Default: Redis' default)
#           port      - Integer Redis port.  (Default: Redis' default)
#           namespace - String namespace prefix for Redis keys.  
#                       (Default: resque).
#           timeout   - Integer timeout in milliseconds to pause polling if 
#                       the queue is empty.
#           database  - Optional Integer of the Redis database to select.
#
# Returns a Connection instance.
exports.connect = (options) ->
  new exports.Connection options || {}

EventEmitter = require('events').EventEmitter

# Handles the connection to the Redis server.  Connections also spawn worker
# instances for processing jobs.
class Connection extends EventEmitter
  constructor: (options) ->
    @redis     = options.redis     || connectToRedis options
    @redis_sub = options.redis_sub || connectToRedis options
    @namespace = options.namespace || 'resque'
    @jobs      = options.jobs      || {}
    @timeout   = options.timeout   || 5000
    @redis.select options.database if options.database?

  # Public: Queues a job in a given queue to be run.
  #
  # queue    - String queue name.
  # func     - String name of the function to run.
  # args     - Optional Array of arguments to pass.
  # callback - Optional function to be called with results of job.
  #
  # Returns nothing.
  enqueue: (queue, func, args, callback) ->
    @jobID (err, id) =>
      if err
        throw err
      else
        @watchKey id, callback if callback
        @redis.sadd  @key('queues'), queue
        @redis.rpush @key('queue', queue),
          JSON.stringify class: func, args: args || [], id: id

  # Public: Creates a single Worker from this Connection.
  #
  # queues    - Either a comma separated String or Array of queue names.
  # jobs      - Optional Object that has the job functions defined.  This will
  #             be taken from the Connection by default.
  #
  # Returns a Worker instance.
  worker: (queues, jobs) ->
    new exports.Worker @, queues, jobs or @jobs

  # Public: Quits the connection to the Redis server.
  #
  # Returns nothing.
  end: ->
    @redis.quit()
    @redis_sub.quit()

  # Builds a namespaced Redis key with the given arguments.
  #
  # args - Array of Strings.
  #
  # Returns an assembled String key.
  key: (args...) ->
    args.unshift @namespace
    args.join ":"

  # Generates a unique job id.
  #
  # Returns a unique job id.
  jobID: (callback) ->
    job_id = Math.floor(Math.random() * 1000000)
    @redis.get job_id, (err, value) ->
      if err
        callback err
      else if value
        jobID callback
      else
        callback null, job_id

  # Watches a key for changes
  #
  # key - name of key
  #
  # Calls callback with value of key on change.
  watchKey: (key, callback) ->
    @redis_sub.on 'message', (channel, message) =>
      if channel is @key(key) and message is 'key changed'
        @redis.get @key(key), (err, value) =>
          if err
            callback err
          else
            callback JSON.parse(value)...
          @redis.del @key(key)
    @redis_sub.subscribe @key(key)
    
  # Sets a key value and publishes an update to Redis.
  #
  # key   - name of key
  # value - the value to set it to
  #
  # Returns nothing.
  setKey: (key, value) ->
    @redis.set @key(key), JSON.stringify(value)
    @redis.publish @key(key), 'key changed'

# Handles the queue polling and job running.
class Worker
  # See Connection#worker
  constructor: (connection, queues, jobs) ->
    @conn      = connection
    @redis     = connection.redis
    @queues    = queues
    @jobs      = jobs or {}
    @running   = false
    @ready     = false
    @checkQueues()

  # Public: Tracks the worker in Redis and starts polling.
  #
  # Returns nothing.
  start: ->
    if @ready
      @init => @poll()
    else
      @running = true

  # Public: Stops polling and purges this Worker's stats from Redis.
  # 
  # cb - Optional Function callback.
  #
  # Returns nothing.
  end: (cb) ->
    @running = false
    @untrack()
    @redis.del [
      @conn.key('worker', @name, 'started')
      @conn.key('stat', 'failed', @name)
      @conn.key('stat', 'processed', @name)
    ], cb

  # EVENT EMITTER PROXY

  # Public: Attaches an event listener to the Connection instance.
  #
  # event    - String event name.
  # listener - A Function callback for the emitted event.
  #
  # Emits 'poll' each time Redis is checked.
  #   err    - The caught exception.
  #   worker - This Worker instance.
  #   queue  - The String queue that is being checked.
  #
  # Emits 'job' before attempting to run any job.
  #   worker - This Worker instance.
  #   queue  - The String queue that is being checked.
  #   job    - The parsed Job object that was being run.
  #
  # Emits 'success' after a successful job completion.
  #   worker - This Worker instance.
  #   queue  - The String queue that is being checked.
  #   job    - The parsed Job object that was being run.
  #
  # Emits 'error' if there is an error fetching or running the job.
  #   err    - The caught exception.
  #   worker - This Worker instance.
  #   queue  - The String queue that is being checked.
  #   job    - The parsed Job object that was being run.
  #
  # Returns nothing.
  on: (event, listener) ->
    @conn.on event, listener

  # PRIVATE METHODS

  # Polls the next queue for a job.  Events are emitted directly on the 
  # Connection instance.
  #
  # Returns nothing.
  poll: ->
    return if !@running
    @queue = @queues.shift()
    @queues.push @queue
    @conn.emit 'poll', @, @queue
    @redis.lpop @conn.key('queue', @queue), (err, resp) =>
      if !err && resp
        @perform JSON.parse(resp.toString())
      else
        @conn.emit 'error', err, @, @queue if err
        @pause()

  # Handles the actual running of the job.
  #
  # job - The parsed Job object that is being run.
  #
  # Returns nothing.
  perform: (job) ->
    old_title = process.title
    @conn.emit 'job', @, @queue, job
    @procline "#{@queue} job since #{(new Date).toString()}"
    try
      if j = @jobs[job.class]
        j job.args..., (results...) =>
          @conn.setKey job.id, results
          @succeed job
      else
        throw "Missing Job: #{job.class}"
    catch err
      @fail err, job
    finally
      process.title = old_title
      @poll()

  # Tracks stats for successfully completed jobs.
  #
  # job - The parsed Job object that is being run.
  #
  # Returns nothing.
  succeed: (job) ->
    @redis.incr @conn.key('stat', 'processed')
    @redis.incr @conn.key('stat', 'processed', @name)
    @conn.emit 'success', @, @queue, job

  # Tracks stats for failed jobs, and tracks them in a Redis list.
  #
  # err - The caught Exception.
  # job - The parsed Job object that is being run.
  #
  # Returns nothing.
  fail: (err, job) ->
    @redis.incr  @conn.key('stat', 'failed')
    @redis.incr  @conn.key('stat', 'failed', @name)
    @redis.rpush @conn.key('failed'),
      JSON.stringify(@failurePayload(err, job))
    @conn.emit 'error', err, @, @queue, job

  # Pauses polling if no jobs are found.  Polling is resumed after the timeout
  # has passed.
  #
  # Returns nothing.
  pause: ->
    @untrack()
    @procline "Sleeping for #{@conn.timeout/1000}s"
    setTimeout =>
      return if !@running
      @track()
      @poll()
    , @conn.timeout

  # Tracks this worker's name in Redis.
  #
  # Returns nothing.
  track: ->
    @running = true
    @redis.sadd @conn.key('workers'), @name

  # Removes this worker's name from Redis.
  #
  # Returns nothing.
  untrack: ->
    @redis.srem @conn.key('workers'), @name

  # Initializes this Worker's start date in Redis.
  #
  # Returns nothing.
  init: (cb) ->
    @track()
    args = [@conn.key('worker', @name, 'started'), (new Date).toString()]
    @procline "Processing #{@queues.toString} since #{args.last}"
    args.push cb if cb
    @redis.set args...

  # Ensures that the given @queues value is in the right format.
  #
  # Returns nothing.
  checkQueues: ->
    return if @queues.shift?
    if @queues == '*'
      @redis.smembers @conn.key('queues'), (err, resp) =>
        @queues = if resp then resp.sort() else []
        @ready  = true
        @name   = @_name
        @start() if @running
    else
      @queues = @queues.split(',')
      @ready  = true
      @name   = @_name

  # Sets the process title.
  #
  # msg - The String message for the title.
  #
  # Returns nothing.
  procline: (msg) ->
    process.title = "resque-#{exports.version}: #{msg}"

  # Builds a payload for the Resque failed list.
  #
  # err - The caught Exception.
  # job - The parsed Job object that is being run.
  #
  # Returns a Hash.
  failurePayload: (err, job) ->
    worker:    @name
    error:     err.error or 'unspecified'
    payload:   job
    exception: err.exception or 'generic'
    backtrace: err.backtrace or ['unknown']
    failed_at: (new Date).toString()

  Object.defineProperty @prototype, 'name',
    get: -> @_name
    set: (name) ->
      @_name = if @ready
        [name or 'node', process.pid, @queues].join(":")
      else
        name

connectToRedis = (options) ->
  require('redis').createClient options.port, options.host
  
exports.Connection = Connection
exports.Worker     = Worker