# A server will report most errors to the client over a Socket, but
# errors in ZMQ state can't be reported because the socket may be
# corrupted. Therefore, we need an exception type for errors that
# should be reported locally.

immutable ZMQError <: Exception
    msg::AbstractString
end

show(io, err::ZMQError) = print(io, "ZMQError: ", err.msg)

zmq_errno() = ccall((:zmq_errno, zmq), Cint, ())

function zmq_strerror()
    c_strerror = ccall((:zmq_strerror, zmq), Ptr{UInt8}, (Cint,), zmq_errno())
    if c_strerror != C_NULL
        return unsafe_string(c_strerror)
    else
        return "unknown error"
    end
end
