#!/usr/bin/env iced
#
# iced radio.iced "http://prem1.di.fm/progressive?$DIFMKEY#/di-progressive" "http://212.7.196.96:8000/#/pure-progressive"
#
# TODO buffering issues: perhaps send some backlog?
# TODO port from command line switches
# TODO merge with archiver; differentiate mode with subcommands

stream = require 'stream'
util   = require 'util'
koa    = require 'koa'
route  = require 'koa-route'
icy    = require 'icy'

port = 8000


once = (fn) ->
    (args...) ->
        fn_ = fn
        fn = undefined
        fn_?(args...)


class NullWriter extends stream.Writable
    _write: (chunk, encoding, cb) ->
        cb()


class Repeater
    metadataInterval: 4096
    breather:         3000

    constructor: (@inboundURL) ->
        @inbound       = null
        @metadata      = null
        @httpPrefix    = null

    run: ->
        do =>
            loop
                await @connect defer err
                await
                    done = once defer()
                    @inbound?.on 'close', ->
                        console.log "closed"
                        done()
                    @inbound?.on 'end', ->
                        console.log "ended"
                        done()
                console.log "retrying #{@inboundURL}"
                await setTimeout(defer(), @breather)
        return this

    connect: (cb) =>
        await
            @metadata = null
            #done = defer err, @inbound
            #console.log "connecting to #{@inboundURL}"
            #icy.get(@inboundURL, (inbound) => done(null, inbound))
            #    .on('error', done)
            console.log "connecting to #{@inboundURL}"
            icy.get(@inboundURL, defer @inbound)
        #return cb?(err) if err
        @inbound.on 'metadata', (metadata) =>
            @metadata = icy.parse(metadata)
        @inbound.on 'error', (err) =>
            console.log "#{@inboundURL} error #{err}"
        # HACK: inbound should not pause if nobody is listening; discard instead
        @inbound.pipe(new NullWriter)
        cb()
        
    handler: =>
        channel = this
        return (next) ->
            ua = @headers['user-agent']
            console.log("connection from #{@ip} (#{ua})")
            # warning: if inbound disconnects, so do all clients
            {inbound} = channel
            ih = inbound.headers
            @status = 200
            @set
                'accept-ranges':   'none'
                'content-type':    ih['content-type'] or 'audio/mpeg'
                'icy-br':          ih['icy-br'] or ''
                'icy-bitrate':     ih['icy-bitrate'] or ''
                'icy-audio-info':  ih['icy-audio-info'] or ''
                'icy-description': ih['icy-description'] or ''
                'icy-genre':       ih['icy-genre'] or ''
                'icy-name':        ih['icy-name'] or ''
                'icy-pub':         ih['icy-pub'] or 0
                'icy-url':         @request.href or ih['icy-url'] or ''
                'icy-metaint':     channel.metadataInterval
            if @headers['icy-metadata']
                outbound = icy.Writer(channel.metadataInterval)
                # send initial metadata, before next title change
                metadata = =>
                    if channel.metadata
                        outbound.queue(channel.metadata)
                metadata()
                inbound.on('metadata', metadata)
            else
                outbound = stream.PassThrough()
            close = =>
                inbound.unpipe(outbound)
                inbound.removeListener('metadata', metadata or ->)
                @socket.removeListener('close', close)
            @socket.on('close', close)
            inbound.pipe(outbound)
            #@body = outbound
            # HACK: buffer output
            @body = outbound.pipe(new stream.PassThrough)
            yield return


if require.main is module
    [_, _, argv...] = process.argv

    app = koa()

    httpPrefixes = []
    for channel, i in argv
        [inboundURL, httpPrefix] = channel.split('#')
        httpPrefix ?= "/channel-#{i}"
        httpPrefixes.push(httpPrefix)
        c = new Repeater(inboundURL).run()
        app.use(route.get(httpPrefix, c.handler()))

    app.use route.get '/', (next) ->
        if @headers.accepts is 'application/json'
            @body = httpPrefixes
        else
            yield next

    app.listen(port)


module.exports = {Repeater}
