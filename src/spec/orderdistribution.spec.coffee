OrderDistribution = require('../main').OrderDistribution

describe 'OrderDistribution', ->
  it 'should throw error that there is no config', ->
    expect(-> new OrderDistribution()).toThrow new Error 'No configuration in options!'
    expect(-> new OrderDistribution({})).toThrow new Error 'No configuration in options!'

describe '#run', ->
  beforeEach ->
    c =
      project_key: 'x'
      client_id: 'y'
      client_secret: 'z'
    @distribution = new OrderDistribution { config: c }

  it 'should throw error if callback is passed', ->
    expect(=> @distribution.run()).toThrow new Error 'Callback must be a function!'

describe '#extractSKUs', ->
  beforeEach ->
    c =
      project_key: 'x'
      client_id: 'y'
      client_secret: 'z'
    @distribution = new OrderDistribution { config: c }

  it 'should extract line item skus', ->
    o =
      lineItems: [
        { variant:
          sku: 'mySKU1' }
        { variant:
          sku: 'mySKU2' }
      ]
    skus = @distribution.extractSKUs o
    expect(skus.length).toBe 2
    expect(skus[0]).toBe 'mySKU1'
    expect(skus[1]).toBe 'mySKU2'