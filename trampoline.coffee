arrayFrom = (argumentsObject) ->
  arg for arg in argumentsObject

module.exports = ({args,fn,done}, callback) ->
  trampoline = (args) ->
    fn.apply this, args.concat [ (err, result...) ->
      if err 
        callback err
      else
        if done.apply this, result
          callback.apply this, arguments
        else 
          trampoline result
    ]
  trampoline args