type Socket
    data::Ptr{Void}
    pollfd::_FDWatcher

    # ctx should be ::Context, but forward type references are not allowed
    function Socket(ctx, typ::Integer)
        p = ccall((:zmq_socket, zmq), Ptr{Void}, (Ptr{Void}, Cint), ctx.data, typ)
        if p == C_NULL
            throw(ZMQError(zmq_strerror()))
        end
        socket = new(p)
        if _have_good_fdwatcher
            socket.pollfd = _FDWatcher(fd(socket), #=readable=#true, #=writable=#false)
        else
            socket.pollfd = _FDWatcher(fd(socket))
        end
        finalizer(socket, close)
        push!(ctx.sockets, socket)
        return socket
    end
end

function close(socket::Socket)
    if socket.data != C_NULL
        data = socket.data
        socket.data = C_NULL
        if _have_good_fdwatcher
            close(socket.pollfd, #=readable=#true, #=writable=#false)
        else
            notify(socket.pollfd.notify)
            Base.stop_watching(socket.pollfd)
        end
        rc = ccall((:zmq_close, zmq), Cint,  (Ptr{Void},), data)
        if rc != 0
            throw(ZMQError(zmq_strerror()))
        end
    end
end

# Getting and setting socket options
# Socket options of integer type
const u64p = zeros(UInt64, 1)
const i64p = zeros(Int64, 1)
const ip = zeros(Cint, 1)
const u32p = zeros(UInt32, 1)
const sz = zeros(UInt, 1)
const pp = fill(C_NULL, 1)

for (fset, fget, k, p) in [
    (:set_affinity,                :get_affinity,                 4, u64p)
    (:set_type,                    :get_type,                    16,   ip)
    (:set_linger,                  :get_linger,                  17,   ip)
    (:set_reconnect_ivl,           :get_reconnect_ivl,           18,   ip)
    (:set_backlog,                 :get_backlog,                 19,   ip)
    (:set_reconnect_ivl_max,       :get_reconnect_ivl_max,       21,   ip)
    (:set_rate,                    :get_rate,                     8,   ip)
    (:set_recovery_ivl,            :get_recovery_ivl,             9,   ip)
    (:set_sndbuf,                  :get_sndbuf,                  11,   ip)
    (:set_rcvbuf,                  :get_rcvbuf,                  12,   ip)
    (nothing,                      :_zmq_getsockopt_rcvmore,     13,   ip)
    (nothing,                      :get_events,                  15,   ip)
    (:set_maxmsgsize,              :get_maxmsgsize,              22,   ip)
    (:set_sndhwm,                  :get_sndhwm,                  23,   ip)
    (:set_rcvhwm,                  :get_rcvhwm,                  24,   ip)
    (:set_multicast_hops,          :get_multicast_hops,          25,   ip)
    (:set_ipv4only,                :get_ipv4only,                31,   ip)
    (:set_tcp_keepalive,           :get_tcp_keepalive,           34,   ip)
    (:set_tcp_keepalive_idle,      :get_tcp_keepalive_idle,      35,   ip)
    (:set_tcp_keepalive_cnt,       :get_tcp_keepalive_cnt,       36,   ip)
    (:set_tcp_keepalive_intvl,     :get_tcp_keepalive_intvl,     37,   ip)
    (:set_rcvtimeo,                :get_rcvtimeo,                27,   ip)
    (:set_sndtimeo,                :get_sndtimeo,                28,   ip)
    (nothing,                      :get_fd,                      14, is_windows() ? pp : ip)
    ]
    if fset != nothing
        @eval function ($fset)(socket::Socket, option_val::Integer)
            ($p)[1] = option_val
            rc = ccall((:zmq_setsockopt, zmq), Cint,
                       (Ptr{Void}, Cint, Ptr{Void}, UInt),
                       socket.data, $k, $p, sizeof(eltype($p)))
            if rc != 0
                throw(ZMQError(zmq_strerror()))
            end
        end
    end
    if fget != nothing
        @eval function ($fget)(socket::Socket)
            ($sz)[1] = sizeof(eltype($p))
            rc = ccall((:zmq_getsockopt, zmq), Cint,
                       (Ptr{Void}, Cint, Ptr{Void}, Ptr{UInt}),
                       socket.data, $k, $p, $sz)
            if rc != 0
                throw(ZMQError(zmq_strerror()))
            end
            return @compat Int(($p)[1])
        end
    end
end

# For some functions, the publicly-visible versions should require &
# return boolean:
get_rcvmore(socket::Socket) = @compat Bool(_zmq_getsockopt_rcvmore(socket))
# And a convenience function
ismore(socket::Socket) = get_rcvmore(socket)

# subscribe/unsubscribe options take an arbitrary byte array
for (f,k) in ((:subscribe,6), (:unsubscribe,7))
    f_ = @compat Symbol(string(f, "_"))
    @eval begin
        function $f_{T}(socket::Socket, filter::Ptr{T}, len::Integer)
            rc = ccall((:zmq_setsockopt, zmq), Cint,
                       (Ptr{Void}, Cint, Ptr{T}, UInt),
                       socket.data, $k, filter, len)
            if rc != 0
                throw(ZMQError(zmq_strerror()))
            end
        end
        @compat $f(socket::Socket, filter::Union{Array,AbstractString}) =
            $f_(socket, pointer(filter), sizeof(filter))
        $f(socket::Socket) = $f_(socket, C_NULL, 0)
    end
end

# Raw FD access
if is_unix()
    fd(socket::Socket) = RawFD(get_fd(socket))
end
if is_windows()
    fd(socket::Socket) = WindowsRawSocket(convert(Ptr{Void}, get_fd(socket)))
end

if _have_good_fdwatcher
    wait(socket::Socket) = wait(socket.pollfd, readable=true, writable=false)
    notify(socket::Socket) = uv_pollcb(socket.pollfd.handle, Int32(0),
                                       Int32(UV_READABLE))
else
    wait(socket::Socket) = Base._wait(socket.pollfd, #=readable=#true, #=writable=#false)
    notify(socket::Socket) = Base._uv_hook_pollcb(socket.pollfd, int32(0),
                                                  int32(UV_READABLE))
end

# Socket options of string type
const u8ap = zeros(UInt8, 255)
for (fset, fget, k) in [
    (:set_identity,                :get_identity,                5)
    (:set_subscribe,               nothing,                      6)
    (:set_unsubscribe,             nothing,                      7)
    (nothing,                      :get_last_endpoint,          32)
    (:set_tcp_accept_filter,       nothing,                     38)
    ]
    if fset != nothing
        @eval function ($fset)(socket::Socket, option_val::String)
            if length(option_val) > 255
                throw(ZMQError("option value too large"))
            end
            rc = ccall((:zmq_setsockopt, zmq), Cint,
                       (Ptr{Void}, Cint, Ptr{UInt8}, UInt),
                       socket.data, $k, option_val, length(option_val))
            if rc != 0
                throw(ZMQError(zmq_strerror()))
            end
        end
    end
    if fget != nothing
        @eval function ($fget)(socket::Socket)
            ($sz)[1] = length($u8ap)
            rc = ccall((:zmq_getsockopt, zmq), Cint,
                       (Ptr{Void}, Cint, Ptr{UInt8}, Ptr{UInt}),
                       socket.data, $k, $u8ap, $sz)
            if rc != 0
                throw(ZMQError(zmq_strerror()))
            end
            return unsafe_string(unsafe_convert(Ptr{UInt8}, $u8ap), @compat Int(($sz)[1]))
        end
    end
end

function bind(socket::Socket, endpoint::AbstractString)
    rc = ccall((:zmq_bind, zmq), Cint, (Ptr{Void}, Ptr{UInt8}), socket.data, endpoint)
    if rc != 0
        throw(ZMQError(zmq_strerror()))
    end
end

function connect(socket::Socket, endpoint::AbstractString)
    rc=ccall((:zmq_connect, zmq), Cint, (Ptr{Void}, Ptr{UInt8}), socket.data, endpoint)
    if rc != 0
        throw(ZMQError(zmq_strerror()))
    end
end
