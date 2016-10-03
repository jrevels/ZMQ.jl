## Contexts ##
# Provide the same constructor API for version 2 and version 3, even
# though the underlying functions are changing
type Context
    data::Ptr{Void}

    # need to keep a list of sockets for this Context in order to
    # close them before finalizing (otherwise zmq_term will hang)
    sockets::Vector{Socket}

    function Context()
        p = ccall((:zmq_ctx_new, zmq), Ptr{Void},  ())
        if p == C_NULL
            throw(ZMQError(zmq_strerror()))
        end
        zctx = new(p, Array(Socket,0))
        finalizer(zctx, close)
        return zctx
    end
end

@deprecate Context(n::Integer) Context()

function close(ctx::Context)
    if ctx.data != C_NULL # don't close twice!
        data = ctx.data
        ctx.data = C_NULL
        for s in ctx.sockets
            close(s)
        end
        rc = ccall((:zmq_ctx_destroy, zmq), Cint,  (Ptr{Void},), data)
        if rc != 0
            throw(ZMQError(zmq_strerror()))
        end
    end
end
term(ctx::Context) = close(ctx)

function get(ctx::Context, option::Integer)
    val = ccall((:zmq_ctx_get, zmq), Cint, (Ptr{Void}, Cint), ctx.data, option)
    if val < 0
        throw(ZMQError(zmq_strerror()))
    end
    return val
end

function set(ctx::Context, option::Integer, value::Integer)
    rc = ccall((:zmq_ctx_set, zmq), Cint, (Ptr{Void}, Cint, Cint), ctx.data, option, value)
    if rc != 0
        throw(ZMQError(zmq_strerror()))
    end
end
