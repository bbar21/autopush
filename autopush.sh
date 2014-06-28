#!/bin/sh
#

#-----------------------------------------------
# Setup environment and source config file
#-----------------------------------------------

#assign command line params to variables
AUTOPUSH_INPUT=$1

# get directory of autopush script and load the config file
AUTOPUSH_HOME=$(readlink -f $0 | xargs dirname)
cd ${AUTOPUSH_HOME}
source ./autopush.cfg

#change to autopush home and load defaults for variables if config variables not set
cd ${AUTOPUSH_HOME}
: ${AUTOPUSH_QUEUE:=${AUTOPUSH_HOME}/queue}
: ${AUTOPUSH_LOG:=${AUTOPUSH_HOME}/autopush.log}
: ${AUTOPUSH_PUSHDEFNAME:=pushdef}
: ${AUTOPUSH_LOCKTIMEOUT:=60}
: ${AUTOPUSH_FOLDERPERMISSIONS:=755}
: ${AUTOPUSH_FILEPERMISSIONS:=644}

: ${AUTOPUSH_MODE:=scp}
: ${AUTOPUSH_HOST:=}
: ${AUTOPUSH_PORT:=}
: ${AUTOPUSH_SCP_OPTIONS:="-C"}

: ${AUTOPUSH_TUNNEL_ENABLE:=false}
: ${AUTOPUSH_TUNNEL_LOCALPORT:=25777}
: ${AUTOPUSH_TUNNEL_HOST:=}
: ${AUTOPUSH_TUNNEL_HOSTPORT:=22}
: ${AUTOPUSH_TUNNEL_GATEWAY:=}
: ${AUTOPUSH_TUNNEL_GATEWAYPORT:=}
: ${AUTOPUSH_TUNNEL_OPTIONS:="-NT"}
: ${AUTOPUSH_TUNNEL_WAITTIME:=30}

: ${AUTOPUSH_NOTIFYPATH:=}

#set some internal variables that cannot be changed by the config file
AUTOPUSH_LOCKFILE="${AUTOPUSH_HOME}/.autopush.lock"
AUTOPUSH_QUEUELOCKFILE="${AUTOPUSH_HOME}/.queue.lock"

# if the port is set, add it to the SSH tunel options
[ -n "${AUTOPUSH_TUNNEL_GATEWAYPORT}" ] && AUTOPUSH_TUNNEL_OPTIONS="${AUTOPUSH_TUNNEL_OPTIONS} -p ${AUTOPUSH_TUNNEL_GATEWAYPORT}"

# if a notifypath is set, make sure to turn the notify path into an absolute path
[ -n "${AUTOPUSH_NOTIFYPATH}" ] && AUTOPUSH_NOTIFYPATH="$(readlink -f ${AUTOPUSH_NOTIFYPATH})"

#----------------------------------------------
# Helper functions
#----------------------------------------------

# Logs output and calls the external notify script (if it exists)
# $1: 1 if the function should call the notify script (if it exists), 0 otherwise
# $2: 0 or 1 for success or failure, respectively
# $3: Filepath of the target file (the file being transfered), or empty string if n/a
# $4: Message to log
# $5: Integer indicating action that is reporting success/failure
#		0: Transfer
#		1: Enqueue
#		2: Dequeue
#		3: SSH Tunnel
#		4: General Info
function log {
	echo -e "[$(date '+%Y/%m/%d - %T.%N')] $4" | tee -a ${AUTOPUSH_LOG}

	if [ $1 -eq 1 ]; then
		[ -n "${AUTOPUSH_NOTIFYPATH}" ] && $(${AUTOPUSH_NOTIFYPATH} $2 $3 $4 $5 &)
	fi
}

# Takes a filepath and safely appends it into the queue file
#	$1: File to enqueue
function enqueue {
	#get lock on queue lock file
	exec 200>${AUTOPUSH_QUEUELOCKFILE}
	flock -x -w ${AUTOPUSH_LOCKTIMEOUT} 200 || { log 1 1 $1 "FAIL: Could not obtain lock on queue file. ${1} not enqueued." 1; return 1; }

	#successful, so enqueue
	echo "${1}" >> ${AUTOPUSH_QUEUE}

	log 0 0 ${AUTOPUSH_INPUT} "INFO: Enqueued ${AUTOPUSH_INPUT}" 1

	#unlock and then drop file handle
	flock -u 200
	exec 200>&-
}

# Sets the AUTOPUSH_TARGET variable to be the first filepath in the queue, and removes that entry from the queue
function dequeue {
	#get lock on queue lock file
	exec 201>${AUTOPUSH_QUEUELOCKFILE}
	flock -x -w ${AUTOPUSH_LOCKTIMEOUT} 201 || { log 1 1 "" "FAIL: Could not obtain lock on queue file. Nothing dequeued." 2; return 1; }

	#successful, so grab the first line and set it as the target
	AUTOPUSH_TARGET=$(head -n 1 ${AUTOPUSH_QUEUE})

	#remove first line from file
	sed -i '1,1d' ${AUTOPUSH_QUEUE}

	log 0 0 ${AUTOPUSH_TARGET} "INFO: Dequeued ${AUTOPUSH_INPUT}" 1

	#unlock and then drop file handle
	flock -u 201
	exec 201>&-
}

# Opens an SSH tunnel and binds it to a local port
function setupTunnel {
	log 0 0 ${AUTOPUSH_INPUT} "INFO: Openning an SSH tunnel." 3

	#create SSH tunnel using the config options
	ssh -L localhost:${AUTOPUSH_TUNNEL_LOCALPORT}:${AUTOPUSH_HOST}:${AUTOPUSH_PORT} ${AUTOPUSH_TUNNEL_OPTIONS} ${AUTOPUSH_TUNNEL_GATEWAY} &

	#sleep to allow time for the tunnel to be negotiated
	sleep ${AUTOPUSH_TUNNEL_WAITTIME}

	#capture PID
	AUTOPUSH_TUNNEL_PID=$!

	#now set variables to point to the local port that is the tunnels entry point
	AUTOPUSH_HOST=localhost
	AUTOPUSH_PORT=${AUTOPUSH_TUNNEL_LOCALPORT}
}

# Core subroutine that handles transerring a single file
function transfer {
	log 0 0 ${AUTOPUSH_TARGET} "INFO: Attempting to transfer ${AUTOPUSH_TARGET}" 0

	local pushdef="$(dirname ${AUTOPUSH_INPUT})/${AUTOPUSH_PUSHDEFNAME}"
	if [ -x ${pushdef} ]; then
		#source the pushdef file in order to set the push definition variables
		source ${pushdef}

		if [ -d ${AUTOPUSH_TARGET} ]; then
			find $file -type d -exec chmod ${AUTOPUSH_FOLDERPERMISSIONS} {} \;
            find $file -type f -exec chmod ${AUTOPUSH_FILEPERMISSIONS} {} \;
        else
        	chmod ${AUTOPUSH_FILEPERMISSIONS} ${AUTOPUSH_TARGET}
        fi

        # if the port is set, add it to the SCP options
		[ -n "${AUTOPUSH_PORT}" ] && AUTOPUSH_SCP_OPTIONS="${AUTOPUSH_SCP_OPTIONS} -P ${AUTOPUSH_PORT}"

        local result=
        if [ "${AUTOPUSH_MODE}" = "scp" ]; then
        	result=$(scp -r ${AUTOPUSH_SCP_OPTIONS} "${AUTOPUSH_TARGET}" ${AUTOPUSH_HOST}:${AUTOPUSH_DEST} 2>&1)
        elif [ "${AUTOPUSH_MODE}" = "rsync" ]; then
        	#TODO
        	echo "TODO"
        fi

        if [ "$?" -eq 0 ]; then
        	#success
        	log 1 0 ${AUTOPUSH_TARGET} "  OK: Successfully pushed $(basename ${AUTOPUSH_TARGET})" 0
        else
        	#failure
        	log 1 1 ${AUTOPUSH_TARGET} "FAIL: Error pushing $(basename ${AUTOPUSH_TARGET})\n\t\t\t        STDERR: ${result}" 0
        fi
	else
		#log the fact that an entry made it into the queue file but did not have a valid pushdef file
		log 1 1 ${AUTOPUSH_TARGET} "FAIL: Problem reading or executing associated pushdef file for ${AUTOPUSH_TARGET}." 0

		return 1
	fi
}

# Main process loop. This loops through the queue file and transfers each item sequentially
function process {
	exec 202>${AUTOPUSH_LOCKFILE}
	flock -n 202 || { log 0 0 ${AUTOPUSH_INPUT} "INFO: Instance running (lock on autopush lock file could not be obtained)" 4; exit 1; }

	log 0 0 ${AUTOPUSH_INPUT} "INFO: Starting the process singleton." 4

	echo "$$" > ${AUTOPUSH_LOCKFILE}

	local AUTOPUSH_TARGET=
	local AUTOPUSH_TUNNEL_PID=

	#setup tunnel if needed
	if [ "${AUTOPUSH_TUNNEL_ENABLE}" = "true" ]; then
		setupTunnel
	fi

	#while the linecount of the queue file is greater than zero
	while [ $(wc -l ${AUTOPUSH_QUEUE} | awk '{print $1}') -gt 0 ]; do
		#dequeue next transfer and do transfer; if dequeue failed exit the process loop (this prevents infinite loops if the queue file has stuff in it but cannot dequeue entries for some reason)
		dequeue || { log 0 1 "" "FAIL: Error dequeueing file." 2; break; }
		transfer
	done

	#if the tunnel PID is set then kill that process
	[ -n "${AUTOPUSH_TUNNEL_PID}" ] && kill ${AUTOPUSH_TUNNEL_PID}

	log 0 0 ${AUTOPUSH_INPUT} "INFO: All done. Process singleton stopping." 4

	#remove PID from lock file, unlock, and then drop file handle
	echo "" > ${AUTOPUSH_LOCKFILE}
	flock -u 202
	exec 202>&-
}

#-------------------------------------------
# MAIN
#-------------------------------------------

#test for existence of required variables
[ -z "${AUTOPUSH_HOST}" ] && log 0 1 ${AUTOPUSH_INPUT} "FAIL: AUTOPUSH_HOST must be defined in the autopush.cfg file." 4

#TODO test ssh tunnel options

#if a file was actually passed to the script
if [ -n "${AUTOPUSH_INPUT}" ]; then
	#determine if push def file exists in the folder that the input file is in
	if [ -r "$(dirname ${AUTOPUSH_INPUT})/${AUTOPUSH_PUSHDEFNAME}" ]; then
		#if push def file exists and is readable then queue the input file and start the process loop
		enqueue $AUTOPUSH_INPUT && process
	else
		log 0 1 ${AUTOPUSH_INPUT} "INFO: Cannot find or read pushdef file for ${AUTOPUSH_INPUT}" 4
	fi
fi

#exit successful
exit 0
