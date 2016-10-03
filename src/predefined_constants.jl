###########
# Context #
###########

const IO_THREADS = 1
const MAX_SOCKETS = 2

##########
# Socket #
##########

const PAIR = 0
const PUB = 1
const SUB = 2
const REQ = 3
const REP = 4
const DEALER = 5
const ROUTER = 6
const PULL = 7
const PUSH = 8
const XPUB = 9
const XSUB = 10
const XREQ = DEALER
const XREP = ROUTER
const UPSTREAM = PULL
const DOWNSTREAM = PUSH

###########
# Message #
###########

const MORE = 1

###################
# IO Multiplexing #
###################

const POLLIN = 1
const POLLOUT = 2
const POLLERR = 4

####################
# Built-In Devices #
####################

const STREAMER = 1
const FORWARDER = 2
const QUEUE = 3

#####
# ? #
#####

const SNDMORE = true
