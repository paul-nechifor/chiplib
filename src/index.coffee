exports.NodeWrapper = class NodeWrapper
  constructor: (@context, @tune) ->
    @maxFramesPerChunk = 4096
    @node = null
    @paused = false
    @modulePtr = 0
    @leftBufferPtr = 0
    @rightBufferPtr = 0
    @cb = null

  start: (@cb) ->
    @node = @context.createScriptProcessor 0, 0, 2
    byteArray = new Int8Array @tune
    ptrToFile = Module._malloc byteArray.byteLength
    Module.HEAPU8.set byteArray, ptrToFile
    @modulePtr = Module._openmpt_module_create_from_memory \
        ptrToFile, byteArray.byteLength, 0, 0, 0
    @leftBufferPtr = Module._malloc 4 * @maxFramesPerChunk
    @rightBufferPtr = Module._malloc 4 * @maxFramesPerChunk
    @node.onaudioprocess = @onAudioProcess.bind @
    @node.connect @context.destination

  stop: (err) ->
    return unless @cb
    @node.disconnect()
    @cleanup()
    @cb err
    @cb = null

  pause: ->
    @paused = true

  unpause: ->
    @paused = false

  togglePause: ->
    @paused = !@paused

  cleanup: ->
    unless @modulePtr is 0
      Module._openmpt_module_destroy @modulePtr
      @modulePtr = 0

    unless @leftBufferPtr is 0
      Module._free @leftBufferPtr
      @leftBufferPtr = 0

    unless @rightBufferPtr is 0
      Module._free @rightBufferPtr
      @rightBufferPtr = 0

  onAudioProcess: (e) ->
    outputL = e.outputBuffer.getChannelData 0
    outputR = e.outputBuffer.getChannelData 1
    framesToRender = outputL.length

    if @paused
      for i in [0 ... framesToRender] by 1
        outputL[i] = outputR[i] = 0
      return

    framesRendered = 0
    ended = false
    error = false

    while framesToRender > 0
      framesPerChunk = Math.min framesToRender, @maxFramesPerChunk
      actualFramesPerChunk = Module._openmpt_module_read_float_stereo \
        @modulePtr,
        @context.sampleRate,
        framesPerChunk,
        @leftBufferPtr,
        @rightBufferPtr

      if actualFramesPerChunk == 0
        ended = true
        # modulePtr will be 0 on errors
        error = !@modulePtr

      rawAudioLeft = Module.HEAPF32.subarray \
        @leftBufferPtr / 4,
        @leftBufferPtr / 4 + actualFramesPerChunk
      rawAudioRight = Module.HEAPF32.subarray \
        @rightBufferPtr / 4,
        @rightBufferPtr / 4 + actualFramesPerChunk

      i = 0
      while i < actualFramesPerChunk
        outputL[framesRendered + i] = rawAudioLeft[i]
        outputR[framesRendered + i] = rawAudioRight[i]
        i++
      i = actualFramesPerChunk
      while i < framesPerChunk
        outputL[framesRendered + i] = 0
        outputR[framesRendered + i] = 0
        i++
      framesToRender -= framesPerChunk
      framesRendered += framesPerChunk

    if ended
      @stop 'openmpt error' if error
      @stop()

    return

  getDuration: ->
    Module._openmpt_module_get_duration_seconds @modulePtr
