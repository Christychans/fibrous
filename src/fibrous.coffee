require 'fibers'
Future = require 'fibers/future'

#We replace Future's version of Function.prototype.future with our own, but use theirs later.
functionWithFiberReturningFuture = Function::future

module.exports = fibrous = (f) ->
  fiberFn = functionWithFiberReturningFuture.call(f) # handles all the heavy lifting of inheriting an existing fiber when appropriate
  asyncFn = (args...) ->
    callback = args.pop()
    throw new Error("Fibrous method expects a callback") unless callback instanceof Function
    future = fiberFn.apply(@, args)
    future.resolve callback
  asyncFn.__fibrousFutureFn__ = fiberFn
  asyncFn


futureize = (asyncFn) ->
  (args...) ->
    fnThis = @ is asyncFn and global or @

    #don't create unnecessary fibers and futures
    return asyncFn.__fibrousFutureFn__.apply(fnThis, args) if asyncFn.__fibrousFutureFn__

    future = new Future
    args.push(future.resolver())
    asyncFn.apply(fnThis, args)
    future

synchronize = (asyncFn) ->
  (args...) ->
    asyncFn.future.apply(@, args).wait()

proxyAll = (src, target, proxyFn) ->
  for key in Object.keys(src) # Gives back the keys on this object, not on prototypes
    do (key) ->
      try
        return if typeof src[key] isnt 'function' # getter methods may throw an exception in some contexts
      catch e
        return

      target[key] = proxyFn(key)

  target

buildFuture = (that) ->
  result =
    if typeof(that) is 'function'
      futureize(that)
    else
      Object.create(Object.getPrototypeOf(that) and Object.getPrototypeOf(that).future or null)

  result.that = that

  proxyAll that, result, (key) ->
    (args...) ->
        #relookup the method every time to pick up reassignments of key on obj or an instance
        @that[key].future.apply(@that, args)

buildSync = (that) ->
  result =
    if typeof(that) is 'function'
      synchronize(that)
    else
      Object.create(Object.getPrototypeOf(that) and Object.getPrototypeOf(that).sync or null)

  result.that = that

  proxyAll that, result, (key) ->
    (args...) ->
        #relookup the method every time to pick up reassignments of key on obj or an instance
        @that[key].sync.apply(@that, args)


defineMemoizedPerInstanceProperty = (target, propertyName, factory) ->
  cacheKey = "__fibrous#{propertyName}__"
  Object.defineProperty target, propertyName,
    enumerable: false
    get: ->
      unless @hasOwnProperty(cacheKey) and @[cacheKey]
        Object.defineProperty @, cacheKey, value: factory(@), enumerable: false # ensure the cached version is not enumerable
      @[cacheKey]


for base in [Object::, Function::]
  defineMemoizedPerInstanceProperty(base, 'future', buildFuture)
  defineMemoizedPerInstanceProperty(base, 'sync', buildSync)


fibrous.wait = (futures...) ->
  getResults = (futureOrArray) ->
    return futureOrArray.get() if (futureOrArray instanceof Future)
    getResults(i) for i in futureOrArray

  Future.wait(futures...)
  result = getResults(futures) # return an array of the results
  result = result[0] if result.length == 1
  result


# Run the subsequent steps in a Fiber (at least until some non-cooperative async operation)
fibrous.middleware = (req, res, next) ->
  process.nextTick ->
    Fiber ->
      try
        next()
      catch e
        # We expect any errors which bubble up the fiber will be handled by the router
        console.error('Unexpected error bubble up to the top of the fiber:', e?.stack or e)
    .run()

fibrous.specHelper = require('./fiber_spec_helper')
