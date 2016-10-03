bitstype 64 * 8 MsgPadding

type Message <: AbstractArray{UInt8,1}
    # Matching the declaration in the header: char _[64];
    w_padding::MsgPadding
    handle::Ptr{Void} # index into gc_protect, if any

    # Create an empty message (for receive)
    function Message()
        zmsg = new()
        zmsg.handle = C_NULL
        rc = ccall((:zmq_msg_init, zmq), Cint, (Ptr{Message},), &zmsg)
        if rc != 0
            throw(ZMQError(zmq_strerror()))
        end
        finalizer(zmsg, close)
        return zmsg
    end
    # Create a message with a given buffer size (for send)
    function Message(len::Integer)
        zmsg = new()
        zmsg.handle = C_NULL
        rc = ccall((:zmq_msg_init_size, zmq), Cint, (Ptr{Message}, Csize_t), &zmsg, len)
        if rc != 0
            throw(ZMQError(zmq_strerror()))
        end
        finalizer(zmsg, close)
        return zmsg
    end

    # low-level function to create a message (for send) with an existing
    # data buffer, without making a copy.  The origin parameter should
    # be the Julia object that is the origin of the data, so that
    # we can hold a reference to it until zeromq is done with the buffer.
    function Message{T}(origin::Any, m::Ptr{T}, len::Integer)
        zmsg = new()
        zmsg.handle = gc_protect_handle(origin)
        rc = ccall((:zmq_msg_init_data, zmq), Cint, (Ptr{Message}, Ptr{T}, Csize_t, Ptr{Void}, Ptr{Void}), &zmsg, m, len, gc_free_fn_c::Ptr{Void}, zmsg.handle)
        if rc != 0
            throw(ZMQError(zmq_strerror()))
        end
        finalizer(zmsg, close)
        return zmsg
    end

    # Create a message with a given AbstractString or Array as a buffer (for send)
    # (note: now "owns" the buffer ... the Array must not be resized,
    #        or even written to after the message is sent!)
    Message(m::String) = Message(m, unsafe_convert(Ptr{UInt8}, pointer(m)), sizeof(m))
    Message{T<:String}(p::SubString{T}) =
        Message(p, pointer(p.string.data)+p.offset, sizeof(p))
    Message(a::Array) = Message(a, pointer(a), sizeof(a))
    function Message(io::IOBuffer)
        if !io.readable || !io.seekable
            error("byte read failed")
        end
        Message(io.data)
    end
end

# check whether zeromq has called our free-function, i.e. whether
# we are save to reclaim ownership of any buffer object
isfreed(m::Message) = haskey(gc_protect, m.handle)

# AbstractArray behaviors:
similar(a::Message, T, dims::Dims) = Array(T, dims) # ?
length(zmsg::Message) = @compat Int(ccall((:zmq_msg_size, zmq), Csize_t, (Ptr{Message},), &zmsg))
size(zmsg::Message) = (length(zmsg),)
unsafe_convert(::Type{Ptr{UInt8}}, zmsg::Message) = ccall((:zmq_msg_data, zmq), Ptr{UInt8}, (Ptr{Message},), &zmsg)
function getindex(a::Message, i::Integer)
    if i < 1 || i > length(a)
        throw(BoundsError())
    end
    unsafe_load(pointer(a), i)
end
function setindex!(a::Message, v, i::Integer)
    if i < 1 || i > length(a)
        throw(BoundsError())
    end
    unsafe_store(pointer(a), v, i)
end

# Convert message to string (copies data)
unsafe_string(zmsg::Message) = Compat.unsafe_string(pointer(zmsg), length(zmsg))
if VERSION < v"0.5-dev+4341"
    bytestring(zmsg::Message) = unsafe_string(zmsg)
else
    @deprecate bytestring(zmsg::Message) unsafe_string(zmsg::Message)
end

# Build an IOStream from a message
# Copies the data
function convert(::Type{IOStream}, zmsg::Message)
    s = IOBuffer()
    write(s, zmsg)
    return s
end
# Close a message. You should not need to call this manually (let the
# finalizer do it).
function close(zmsg::Message)
    rc = ccall((:zmq_msg_close, zmq), Cint, (Ptr{Message},), &zmsg)
    if rc != 0
        throw(ZMQError(zmq_strerror()))
    end
end

function get(zmsg::Message, property::Integer)
    val = ccall((:zmq_msg_get, zmq), Cint, (Ptr{Message}, Cint), &zmsg, property)
    if val < 0
        throw(ZMQError(zmq_strerror()))
    end
    val
end
function set(zmsg::Message, property::Integer, value::Integer)
    rc = ccall((:zmq_msg_set, zmq), Cint, (Ptr{Message}, Cint, Cint), &zmsg, property, value)
    if rc < 0
        throw(ZMQError(zmq_strerror()))
    end
end

## Send/receive messages
#
# Julia defines two types of ZMQ messages: "raw" and "serialized". A "raw"
# message is just a plain ZeroMQ message, used for sending a sequence
# of bytes. You send these with the following:
#   send(socket, zmsg)
#   zmsg = recv(socket)

#Send/Recv Options
const ZMQ_DONTWAIT = 1
const ZMQ_SNDMORE = 2

function send(socket::Socket, zmsg::Message, SNDMORE::Bool=false)
    while true
        rc = ccall((:zmq_msg_send, zmq), Cint, (Ptr{Message}, Ptr{Void}, Cint),
                    &zmsg, socket.data, (ZMQ_SNDMORE*SNDMORE) | ZMQ_DONTWAIT)
        if rc == -1
            zmq_errno() == EAGAIN || throw(ZMQError(zmq_strerror()))
            while (get_events(socket) & POLLOUT) == 0
                wait(socket)
            end
        else
            get_events(socket) != 0 && notify(socket)
            break
        end
    end
end

# strings are immutable, so we can send them zero-copy by default
send(socket::Socket, msg::AbstractString, SNDMORE::Bool=false) = send(socket, Message(msg), SNDMORE)

# Make a copy of arrays before sending, by default, since it is too
# dangerous to require that the array not change until ZMQ is done with it.
# For zero-copy array messages, construct a Message explicitly.
send(socket::Socket, msg::AbstractArray, SNDMORE::Bool=false) = send(socket, Message(copy(msg)), SNDMORE)

function send(f::Function, socket::Socket, SNDMORE::Bool=false)
    io = IOBuffer()
    f(io)
    send(socket, Message(io), SNDMORE)
end

function recv(socket::Socket)
    zmsg = Message()
    rc = -1
    while true
        rc = ccall((:zmq_msg_recv, zmq), Cint, (Ptr{Message}, Ptr{Void}, Cint),
                    &zmsg, socket.data, ZMQ_DONTWAIT)
        if rc == -1
            zmq_errno() == EAGAIN || throw(ZMQError(zmq_strerror()))
            while (get_events(socket) & POLLIN) == 0
                wait(socket)
            end
        else
            get_events(socket) != 0 && notify(socket)
            break
        end
    end
    return zmsg
end

# in order to support zero-copy messages that share data with Julia
# arrays, we need to hold a reference to the Julia object in a dictionary
# until zeromq is done with the data, to prevent it from being garbage
# collected.  The gc_protect dictionary is keyed by a uv_async_t* pointer,
# used in uv_async_send to tell Julia to when zeromq is done with the data.
const gc_protect = Dict{Ptr{Void},Any}()
# 0.2 compatibility
gc_protect_cb(work, status) = gc_protect_cb(work)
if VERSION < v"0.4.0-dev+3970"
    function close_handle(work)
        Base.disassociate_julia_struct(work.handle)
        ccall(:jl_close_uv,Void,(Ptr{Void},),work.handle)
        Base.unpreserve_handle(work)
    end
else
    close_handle(work) = Base.close(work)
end
gc_protect_cb(work) = (pop!(gc_protect, work.handle, nothing); close_handle(work))

function gc_protect_handle(obj::Any)
    work = Compat.AsyncCondition(gc_protect_cb)
    gc_protect[work.handle] = (work,obj)
    work.handle
end

# Thread-safe zeromq callback when data is freed, passed to zmq_msg_init_data.
# The hint parameter will be a uv_async_t* pointer.
function gc_free_fn(data::Ptr{Void}, hint::Ptr{Void})
    ccall(:uv_async_send,Cint,(Ptr{Void},),hint)
end
