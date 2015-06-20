ChiptuneAudioContext = AudioContext or webkitAudioContext

exports.ChiptuneJsConfig = class ChiptuneJsConfig
  constructor: (@repeatCount) ->

exports.ChiptuneJsPlayer = class ChiptuneJsPlayer
  constructor: (@config) ->
    @context = new ChiptuneAudioContext
    @currentPlayingNode = null
    @handlers = []

  fireEvent: (eventName, response) ->
    handlers = @handlers
    if handlers.length
      handlers.forEach (handler) ->
        if handler.eventName is eventName
          handler.handler response
        return
    return

  addHandler: (eventName, handler) ->
    @handlers.push
      eventName: eventName
      handler: handler
    return

  onEnded: (handler) ->
    @addHandler 'onEnded', handler
    return

  onError: (handler) ->
    @addHandler 'onError', handler
    return

  duration: ->
    Module._openmpt_module_get_duration_seconds @currentPlayingNode.modulePtr

  metadata: ->
    data = {}
    keys = Module.Pointer_stringify(Module._openmpt_module_get_metadata_keys(@currentPlayingNode.modulePtr)).split(';')
    keyNameBuffer = 0
    i = 0
    while i < keys.length
      keyNameBuffer = Module._malloc(keys[i].length + 1)
      Module.writeStringToMemory keys[i], keyNameBuffer
      data[keys[i]] = Module.Pointer_stringify(Module._openmpt_module_get_metadata(player.currentPlayingNode.modulePtr, keyNameBuffer))
      Module._free keyNameBuffer
      i++
    data

  load: (input, callback) ->
    player = this
    if input instanceof File
      reader = new FileReader
      reader.onload = (->
        callback reader.result
      ).bind(this)
      reader.readAsArrayBuffer input
    else
      xhr = new XMLHttpRequest
      xhr.open 'GET', input, true
      xhr.responseType = 'arraybuffer'
      xhr.onload = ((e) ->
        if xhr.status == 200 and e.total
          return callback(xhr.response)
        else
          player.fireEvent 'onError', type: 'onxhr'
        return
      ).bind(this)

      xhr.onerror = ->
        player.fireEvent 'onError', type: 'onxhr'
        return

      xhr.onabort = ->
        player.fireEvent 'onError', type: 'onxhr'
        return

      xhr.send()
    return

  play: (buffer) ->
    @stop()
    processNode = @createLibopenmptNode buffer, @config
    if processNode == null
      return
    @currentPlayingNode = processNode
    processNode.connect @context.destination
    return

  stop: ->
    if @currentPlayingNode != null
      @currentPlayingNode.disconnect()
      @currentPlayingNode.cleanup()
      @currentPlayingNode = null
    return

  togglePause: ->
    if @currentPlayingNode != null
      @currentPlayingNode.togglePause()
    return

  createLibopenmptNode: (buffer, config) ->
    maxFramesPerChunk = 4096
    processNode = @context.createScriptProcessor 0, 0, 2
    processNode.config = config
    processNode.player = @
    byteArray = new Int8Array buffer
    ptrToFile = Module._malloc byteArray.byteLength
    Module.HEAPU8.set byteArray, ptrToFile
    processNode.modulePtr = Module._openmpt_module_create_from_memory ptrToFile, byteArray.byteLength, 0, 0, 0
    processNode.paused = false
    processNode.leftBufferPtr = Module._malloc 4 * maxFramesPerChunk
    processNode.rightBufferPtr = Module._malloc 4 * maxFramesPerChunk

    processNode.cleanup = ->
      if @modulePtr != 0
        Module._openmpt_module_destroy @modulePtr
        @modulePtr = 0
      if @leftBufferPtr != 0
        Module._free @leftBufferPtr
        @leftBufferPtr = 0
      if @rightBufferPtr != 0
        Module._free @rightBufferPtr
        @rightBufferPtr = 0
      return

    processNode.stop = ->
      @disconnect()
      @cleanup()
      return

    processNode.pause = ->
      @paused = true
      return

    processNode.unpause = ->
      @paused = false
      return

    processNode.togglePause = ->
      @paused = !@paused
      return

    processNode.onaudioprocess = (e) ->
      outputL = e.outputBuffer.getChannelData 0
      outputR = e.outputBuffer.getChannelData 1
      framesToRender = outputL.length
      if @ModulePtr == 0
        i = 0
        while i < framesToRender
          outputL[i] = 0
          outputR[i] = 0
          ++i
        @disconnect()
        @cleanup()
        return
      if @paused
        i = 0
        while i < framesToRender
          outputL[i] = 0
          outputR[i] = 0
          ++i
        return
      framesRendered = 0
      ended = false
      error = false
      while framesToRender > 0
        framesPerChunk = Math.min framesToRender, maxFramesPerChunk
        actualFramesPerChunk = Module._openmpt_module_read_float_stereo @modulePtr, @context.sampleRate, framesPerChunk, @leftBufferPtr, @rightBufferPtr
        if actualFramesPerChunk == 0
          ended = true
          # modulePtr will be 0 on openmpt: error: openmpt_module_read_float_stereo: ERROR: module * not valid or other openmpt error
          error = !@modulePtr
        rawAudioLeft = Module.HEAPF32.subarray @leftBufferPtr / 4, @leftBufferPtr / 4 + actualFramesPerChunk
        rawAudioRight = Module.HEAPF32.subarray @rightBufferPtr / 4, @rightBufferPtr / 4 + actualFramesPerChunk
        i = 0
        while i < actualFramesPerChunk
          outputL[framesRendered + i] = rawAudioLeft[i]
          outputR[framesRendered + i] = rawAudioRight[i]
          ++i
        i = actualFramesPerChunk
        while i < framesPerChunk
          outputL[framesRendered + i] = 0
          outputR[framesRendered + i] = 0
          ++i
        framesToRender -= framesPerChunk
        framesRendered += framesPerChunk
      if ended
        @disconnect()
        @cleanup()
        if error
          processNode.player.fireEvent('onError', type: 'openmpt')
        else
          processNode.player.fireEvent('onEnded')
      return

    processNode
