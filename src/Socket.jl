#############
# FDWatcher #
#############

if VERSION >= v"0.5-" && isdefined(Base, :Filesystem)
    if is_windows()
        using Base.Libc: WindowsRawSocket
    end
    const FDWatcher = Base.Filesystem._FDWatcher
    const HAVE_GOOD_FDWATCHER = true
elseif VERSION >= v"0.4-" && isdefined(Base, :_FDWatcher)
    if is_windows()
        using Base.Libc: WindowsRawSocket
    end
    const FDWatcher = Base._FDWatcher
    const HAVE_GOOD_FDWATCHER = true
else
    if is_windows()
        using Base: WindowsRawSocket
    end
    const FDWatcher = Base.FDWatcher
    const HAVE_GOOD_FDWATCHER = false
end

if HAVE_GOOD_FDWATCHER
    create_fdwatcher(fd) = FDWatcher(fd, #=readable=#true, #=writable=#false)
    close_fdwatcher(fdw::FDWatcher) = close(fdw, #=readable=#true, #=writable=#false)
    wait_fdwatcher(fdw::FDWatcher) = wait(fdw, readable=true, writable=false)
    notify_fdwatcher(fdw::FDWatcher) = uv_pollcb(fdw.handle, @compat(Int32(0)), @compat(Int32(UV_READABLE)))
else
    create_fdwatcher(fd) = FDWatcher(fd)
    close_fdwatcher(fdw::FDWatcher) = (notify(fdw.notify); Base.stop_watching(fdw))
    wait_fdwatcher(fdw::FDWatcher) = Base._wait(fdw, #=readable=#true, #=writable=#false)
    notify_fdwatcher(fdw::FDWatcher) = Base._uv_hook_pollcb(fdw, @compat(Int32(0)), @compat(Int32(UV_READABLE)))
end

##########
# Socket #
##########

type Socket
    data::Ptr{Void}
    pollfd::FDWatcher
    function Socket(ctx#=::Context=#, kind::Integer)
        ptr = ccall((:zmq_socket, zmq), Ptr{Void}, (Ptr{Void}, Cint), ctx.data, kind)
        ptr == C_NULL && throw(ZMQError())
        socket = new(ptr)
        socket.pollfd = create_fdwatcher(fd(socket))
        finalizer(socket, close)
        push!(ctx.sockets, socket)
        return socket
    end
end

function Base.close(socket::Socket)
    if socket.data != C_NULL
        data = socket.data
        socket.data = C_NULL
        close_fdwatcher(socket.pollfd)
        rc = ccall((:zmq_close, zmq), Cint,  (Ptr{Void},), data)
        rc != 0 && throw(ZMQError())
    end
    return nothing
end

#################################
# Socket Option Getters/Setters #
#################################

for (fset, fget, k, T) in [
        (:set_affinity,                :get_affinity,                 4,   UInt64)
        (:set_type,                    :get_type,                    16,   Cint)
        (:set_linger,                  :get_linger,                  17,   Cint)
        (:set_reconnect_ivl,           :get_reconnect_ivl,           18,   Cint)
        (:set_backlog,                 :get_backlog,                 19,   Cint)
        (:set_reconnect_ivl_max,       :get_reconnect_ivl_max,       21,   Cint)
        (:set_rate,                    :get_rate,                     8,   Cint)
        (:set_recovery_ivl,            :get_recovery_ivl,             9,   Cint)
        (:set_sndbuf,                  :get_sndbuf,                  11,   Cint)
        (:set_rcvbuf,                  :get_rcvbuf,                  12,   Cint)
        (nothing,                      :_zmq_getsockopt_rcvmore,     13,   Cint)
        (nothing,                      :get_events,                  15,   Cint)
        (:set_maxmsgsize,              :get_maxmsgsize,              22,   Cint)
        (:set_sndhwm,                  :get_sndhwm,                  23,   Cint)
        (:set_rcvhwm,                  :get_rcvhwm,                  24,   Cint)
        (:set_multicast_hops,          :get_multicast_hops,          25,   Cint)
        (:set_ipv4only,                :get_ipv4only,                31,   Cint)
        (:set_tcp_keepalive,           :get_tcp_keepalive,           34,   Cint)
        (:set_tcp_keepalive_idle,      :get_tcp_keepalive_idle,      35,   Cint)
        (:set_tcp_keepalive_cnt,       :get_tcp_keepalive_cnt,       36,   Cint)
        (:set_tcp_keepalive_intvl,     :get_tcp_keepalive_intvl,     37,   Cint)
        (:set_rcvtimeo,                :get_rcvtimeo,                27,   Cint)
        (:set_sndtimeo,                :get_sndtimeo,                28,   Cint)
        (nothing,                      :get_fd,                      14,   is_windows() ? C_NULL : Cint)
    ]
    if fset != nothing
        @eval function ($fset)(socket::Socket, option::Integer)
            p = @compat $(T)(option)
            rc = ccall((:zmq_setsockopt, zmq), Cint,
                       (Ptr{Void}, Cint, Ptr{Void}, UInt),
                       socket.data, $k, &p, $(sizeof(T)))
            rc != 0 && throw(ZMQError())
            return nothing
        end
    end
    if fget != nothing
        @eval function ($fget)(socket::Socket)
            p = $(zero(T))
            sz = $(sizeof(T))
            rc = ccall((:zmq_getsockopt, zmq), Cint,
                       (Ptr{Void}, Cint, Ptr{Void}, Ptr{UInt}),
                       socket.data, $k, &p, &sz)
            rc != 0 && throw(ZMQError())
            return p
        end
    end
end

get_rcvmore(socket::Socket) = @compat Bool(_zmq_getsockopt_rcvmore(socket))
ismore(socket::Socket) = get_rcvmore(socket)

# subscribe/unsubscribe options take an arbitrary byte array
for (f, k) in ((:subscribe, 6), (:unsubscribe, 7))
    _f = @compat Symbol(string("_", f))
    @eval begin
        function $_f{T}(socket::Socket, filter::Ptr{T}, len::Integer)
            rc = ccall((:zmq_setsockopt, zmq), Cint,
                       (Ptr{Void}, Cint, Ptr{T}, UInt),
                       socket.data, $k, filter, len)
            rc != 0 && throw(ZMQError())
        end

        @compat function $f(socket::Socket, filter::Union{Array,AbstractString})
            return $_f(socket, pointer(filter), sizeof(filter))
        end

        $f(socket::Socket) = $_f(socket, C_NULL, 0)
    end
end

# Raw FD access
if is_unix()
    fd(socket::Socket) = RawFD(get_fd(socket))
elseif is_windows()
    fd(socket::Socket) = WindowsRawSocket(convert(Ptr{Void}, get_fd(socket)))
end

wait(socket::Socket) = wait_fdwatcher(socket.pollfd)
notify(socket::Socket) = notify_fdwatcher(socket.pollfd)

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
                throw(ZMQError())
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
                throw(ZMQError())
            end
            return unsafe_string(unsafe_convert(Ptr{UInt8}, $u8ap), @compat Int(($sz)[1]))
        end
    end
end

function bind(socket::Socket, endpoint::AbstractString)
    rc = ccall((:zmq_bind, zmq), Cint, (Ptr{Void}, Ptr{UInt8}), socket.data, endpoint)
    if rc != 0
        throw(ZMQError())
    end
end

function connect(socket::Socket, endpoint::AbstractString)
    rc=ccall((:zmq_connect, zmq), Cint, (Ptr{Void}, Ptr{UInt8}), socket.data, endpoint)
    if rc != 0
        throw(ZMQError())
    end
end
