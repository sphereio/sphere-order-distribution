_ = require('underscore')._
Rest = require('sphere-node-connect').Rest
CommonUpdater = require('sphere-node-sync').CommonUpdater
InventoryUpdater = require('sphere-node-sync').InventoryUpdater
Q = require 'q'

class OrderDistribution extends CommonUpdater

  CHANNEL_ROLES = ['InventorySupply', 'OrderExport', 'OrderImport']

  constructor: (options = {}) ->
    super(options)
    throw new Error 'No base configuration in options!' unless options.baseConfig
    throw new Error 'No master configuration in options!' unless options.master
    throw new Error 'No retailer configuration in options!' unless options.retailer

    masterOpts = _.clone options.baseConfig
    masterOpts.config = options.master
    retailerOpts = _.clone options.baseConfig
    retailerOpts.config = options.retailer

    @retailerRest = new Rest retailerOpts
    @inventoryUpdater = new InventoryUpdater masterOpts
    @masterRest = @inventoryUpdater.rest

  getUnSyncedOrders: (rest, channelId) ->
    deferred = Q.defer()
    sort = encodeURIComponent "createdAt DESC"
    query = ''
#    if channelId?
#      query = "&where=" + encodeURIComponent "lineItems(supplyChannel(id = \"#{channelId}\"))"
    rest.PAGED "/orders?sort=#{sort}#{query}", (error, response, body) ->
      if error?
        deferred.reject "Error on fetching orders: " + error
      else if response.statusCode isnt 200
        humanReadable = JSON.stringify body, null, 2
        deferred.reject "Problem on fetching orders (status: #{response.statusCode}): " + humanReadable
      else
        unsyncedOrders = _.filter body.results, (o) ->
          (not o.syncInfo? or _.isEmpty(o.syncInfo)) and
          (not _.isEmpty(o.lineItems) and o.lineItems[0].supplyChannel? and o.lineItems[0].supplyChannel.id is channelId)
        deferred.resolve unsyncedOrders
    deferred.promise

  getTaxCategory: (rest) ->
    deferred = Q.defer()
    rest.GET "/tax-categories?limit=1", (error, response, body) ->
      if error?
        deferred.reject "Error on fetching tax category: " + error
      else if response.statusCode isnt 200
        humanReadable = JSON.stringify body, null, 2
        deferred.reject "Problem on fetching tax category (status: #{response.statusCode}): " + humanReadable
      else
        if _.size(body.results) is 1
          deferred.resolve body.results[0]
        else
          deferred.reject "Can't find tax category."
    deferred.promise

  getRetailerProductByMasterSKU: (sku) ->
    deferred = Q.defer()
    query = encodeURIComponent "variants.attributes.mastersku:\"#{sku.toLowerCase()}\""
    @retailerRest.GET "/product-projections/search?staged=true&lang=de&filter=#{query}" , (error, response, body) ->
      if error?
        deferred.reject "Error on fetching products: " + error
      else if response.statusCode isnt 200
        deferred.reject "Problem on fetching products (status: #{response.statusCode}): " + body
      else
        if _.size(body.results) is 1
          deferred.resolve body.results[0]
        else
          deferred.reject "Can't find product for sku '#{sku}'."
    deferred.promise

  run: () ->
    @inventoryUpdater.ensureChannelByKey(@masterRest, @retailerRest._options.config.project_key, CHANNEL_ROLES)
    .then (channel) =>
      @getUnSyncedOrders @masterRest, channel.id
    .then (masterOrders) =>
      @distributeOrders masterOrders

  distributeOrders: (masterOrders) ->
    if _.size(masterOrders) is 0
      Q('Nothing to do.')
    else
      [validOrders, badOrders] = _.partition masterOrders, (order) =>
        @validateSameChannel order

      _.each badOrders, (bad) ->
        console.error "The order '#{bad.id}' has different channels set!"

      distributions = _.map validOrders, (order) =>
        @distributeOrder order

      Q.all(distributions)

  distributeOrder: (masterOrder) ->
    masterSKUs = @extractSKUs masterOrder

    @getTaxCategory(@retailerRest)
    .then (taxCategory) =>

      gets = _.map masterSKUs, (sku) =>
        @getRetailerProductByMasterSKU(sku)

      Q.all(gets)
      .then (retailerProducts) =>
        masterSKU2retailerSKU = @matchSKUs retailerProducts

        retailerOrder = @replaceSKUs masterOrder, masterSKU2retailerSKU
        retailerOder = @replaceTaxCategories retailerOrder, taxCategory
        retailerOrder = @removeIdsAndVariantData retailerOrder

        @importOrder(retailerOrder)
      .then (newOrder) =>
        Q.all([
          @inventoryUpdater.ensureChannelByKey @masterRest, @retailerRest._options.config.project_key, CHANNEL_ROLES
          @inventoryUpdater.ensureChannelByKey @retailerRest, 'master', CHANNEL_ROLES
        ])
        .spread (channelInMaster, channelInRetailer) =>
          Q.all([
            @addSyncInfo(@masterRest, masterOrder.id, masterOrder.version, channelInMaster.id, newOrder.id)
            @addSyncInfo(@retailerRest, newOrder.id, newOrder.version, channelInRetailer.id, masterOrder.id)
          ])

  matchSKUs: (retailerProducts) ->
    allVariants = _.flatten _.map(retailerProducts, (p) -> [p.masterVariant].concat(p.variants or []))
    reducefn = (acc, v) ->
      a = _.find v.attributes, (a) -> a.name is 'mastersku'
      if a?
        acc[a.value] = v.sku
      acc
    _.reduce allVariants, reducefn, {}


  addSyncInfo: (rest, orderId, orderVersion, channelId, externalId) ->
    deferred = Q.defer()
    data =
      version: orderVersion
      actions: [
        action: 'updateSyncInfo'
        channel:
          typeId: 'channel'
          id: channelId
        externalId: externalId
      ]
    rest.POST "/orders/#{orderId}", data, (error, response, body) ->
      if error?
        deferred.reject "Error on setting sync info: " + error
      else if response.statusCode isnt 200
        humanReadable = JSON.stringify body, null, 2
        deferred.reject "Problem on setting sync info (status: #{response.statusCode}): " + humanReadable
      else
        deferred.resolve "Order sync info successfully stored."
    deferred.promise

  importOrder: (order) ->
    deferred = Q.defer()
    console.log "IMPORT %j", order
    @retailerRest.POST "/orders/import", order, (error, response, body) ->
      if error?
        deferred.reject "Error on importing order: " + error
      else if response.statusCode isnt 201
        humanReadable = JSON.stringify body, null, 2
        deferred.reject "Problem on importing order (status: #{response.statusCode}): " + humanReadable
      else
        deferred.resolve body
    deferred.promise

  validateSameChannel: (order) ->
    channelID = null
    checkChannelId = (channel) ->
      if channelID is null
        channelID = channel.id
        return true
      return channelID is channel.id
    if order.lineItems?
      for li in order.lineItems
        if li.supplyChannel?
          return false unless checkChannelId li.supplyChannel
        continue unless li.variant
        continue unless li.variant.prices
        for p in li.variant.prices
          if p.channel?
            return false unless checkChannelId p.channel
    true

  extractSKUs: (order) ->
    _.map _.filter(order.lineItems or [], (li) -> li.variant? and li.variant.sku? ), (li) -> li.variant.sku

  replaceSKUs: (order, masterSKU2retailerSKU) ->
    if order.lineItems?
      for li in order.lineItems
        continue unless li.variant
        continue unless li.variant.sku
        masterSKU = li.variant.sku
        li.variant.sku = masterSKU2retailerSKU[masterSKU]

    order

  replaceTaxCategories: (order, taxCategory) ->
    if order.shippingInfo? and order.shippingInfo.taxCategory?
      order.shippingInfo.taxCategory['id'] = taxCategory.id

    order

  removeIdsAndVariantData: (order) ->
    delete order.createdAt if order.createdAt?
    delete order.lastModifiedAt if order.lastModifiedAt?
    delete order.lastMessageSequenceNumber if order.lastMessageSequenceNumber?
    delete order.syncInfo if order.syncInfo?

    _.each order.lineItems or [], (li) ->
      delete li.supplyChannel if li.supplyChannel?
      delete li.id if li.id?
      delete li.productId if li.productId?
      delete li.state if li.state?
      if li.variant?
        delete li.variant.id if li.variant.id?
        delete li.variant.attributes if li.variant.attributes?
        delete li.variant.images if li.variant.images?
        _.each li.variant.prices or [], (price) ->
          delete price.channel if price.channel?

    order

module.exports = OrderDistribution