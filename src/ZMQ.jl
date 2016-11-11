isdefined(Base, :__precompile__) && __precompile__(true)

module ZMQ

#########################
# imports/compatibility #
#########################

using Compat

import Compat: String, unsafe_string

if VERSION >= v"0.4.0-dev+3710"
    import Base.unsafe_convert
else
    const unsafe_convert = Base.convert
end

if VERSION >= v"0.4.0-dev+3844"
    using Base.Libdl, Base.Libc
    using Base.Libdl: dlopen_e
    using Base.Libc: EAGAIN
else
    using Base: EAGAIN
end

if VERSION >= v"0.5.0-dev+1229"
    import Base.Filesystem: UV_READABLE, uv_pollcb
else
    import Base: UV_READABLE
    if isdefined(Base, :uv_pollcb)
        import Base: uv_pollcb
    end
end

import Base: convert, get, bytestring, length, size, stride, similar,
             getindex, setindex!, fd, wait, notify, close, connect,
             bind, send, recv

################
# dependencies #
################

const depfile = joinpath(dirname(@__FILE__), "..", "deps", "deps.jl")

if isfile(depfile)
    include(depfile)
else
    error("ZMQ not properly installed. Please run Pkg.build(\"ZMQ\")")
end

################
# package code #
################

include("predefined_constants.jl")
include("ZMQError.jl")
include("Socket.jl")
include("Context.jl")
include("Message.jl")

###########
# exports #
###########

# types
export ZMQError, Context, Socket, Message

# functions
export set, subscribe, unsubscribe

# constants
export IO_THREADS, MAX_SOCKETS, PAIR, PUB, SUB, REQ, REP, ROUTER, DEALER,
       PULL, PUSH, XPUB, XSUB, XREQ, XREP, UPSTREAM, DOWNSTREAM, MORE,
       POLLIN, POLLOUT, POLLERR, STREAMER, FORWARDER, QUEUE, SNDMORE

#########################
# module initialization #
#########################

function __init__()
    major = Array(Cint,1)
    minor = Array(Cint,1)
    patch = Array(Cint,1)
    ccall((:zmq_version, zmq), Void, (Ptr{Cint}, Ptr{Cint}, Ptr{Cint}), major, minor, patch)
    global const version = VersionNumber(major[1], minor[1], patch[1])
    if version < v"3"
        error("ZMQ version $version < 3 is not supported")
    end
    global const gc_free_fn_c = cfunction(gc_free_fn, Cint, (Ptr{Void}, Ptr{Void}))
end

end
