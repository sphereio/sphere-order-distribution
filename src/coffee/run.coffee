package_json = require '../package.json'
Config = require '../config'
Logger = require './logger'
OrderDistribution = require '../lib/orderdistribution'
{ProjectCredentialsConfig} = require 'sphere-node-utils'

argv = require('optimist')
  .usage('Usage: $0 --projectKey key --clientId id --clientSecret secret --logDir dir --logLevel level --timeout timeout')
  .describe('projectKey', 'your SPHERE.IO project-key')
  .describe('clientId', 'your SPHERE.IO OAuth client id')
  .describe('clientSecret', 'your SPHERE.IO OAuth client secret')
  .describe('fetchHours', 'how many hours of modification should be fetched')
  .describe('timeout', 'timeout for requests')
  .describe('sphereHost', 'SPHERE.IO API host to connecto to')
  .describe('logLevel', 'log level for file logging')
  .describe('logDir', 'directory to store logs')
  .default('fetchHours', 24)
  .default('timeout', 60000)
  .default('logLevel', 'info')
  .default('logDir', '.')
  .demand(['projectKey'])
  .argv

logger = new Logger
  streams: [
    { level: 'error', stream: process.stderr }
    { level: argv.logLevel, path: "#{argv.logDir}/sphere-order-distribution_#{argv.projectKey}.log" }
  ]

process.on 'SIGUSR2', ->
  logger.reopenFileStreams()

credentialsConfig = ProjectCredentialsConfig.create()
.then (credentials) ->
  options =
    baseConfig:
      fetchHours: argv.fetchHours
      timeout: argv.timeout
      user_agent: "#{package_json.name} - #{package_json.version}"
      logConfig:
        logger: logger
    master: credentials.enrichCredentials
      project_key: Config.config.project_key
      client_id: Config.config.client_id
      client_secret: Config.config.client_secret
    retailer: credentials.enrichCredentials
      project_key: argv.projectKey
      client_id: argv.clientId
      client_secret: argv.clientSecret

  options.baseConfig.host = argv.sphereHost if argv.sphereHost?

  impl = new OrderDistribution options
  impl.run()
  .then (msg) ->
    logger.info info: msg, msg
    process.exit 0

.fail (err) ->
  logger.error error: err, err
  process.exit 1
.done()