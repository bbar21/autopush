#!/bin/bash
#

#-----------------------------------------------
# Setup environment and source config file
#-----------------------------------------------

#assign command line params to variables
local AUTOPUSH_INPUT=$1

# get directory of autopush script and load the config file
AUTOPUSH_HOME=$(readlink -f $(dirname "$0"))
cd ${AUTOPUSH_HOME}
source autopush.cfg

#change to autopush home and load defaults for variables if config variables not set
cd ${AUTOPUSH_HOME}
: ${AUTOPUSH_QUEUE:=queue.txt}
: ${AUTOPUSH_LOG:=autopush.log}
: ${AUTOPUSH_PUSHDEFNAME:=pushdef}
: ${AUTOPUSH_LOCKTIMEOUT:=60}
: ${AUTOPUSH_FOLDERPERMISSIONS:=755}
: ${AUTOPUSH_FILEPERMISSIONS:=644}

: ${AUTOPUSH_MODE:=scp}
: ${AUTOPUSH_PORT:=22}
: ${AUTOPUSH_SCP_OPTIONS:="-C"}

: ${AUTOPUSH_TUNNEL_ENABLE:=false}
: ${AUTOPUSH_TUNNEL_PORT:=22}
: ${AUTOPUSH_TUNNEL_WAITTIME:=30}

#set some internal variables that cannot be changed by the config file
AUTOPUSH_LOCKFILE=.autopush.lock

#----------------------------------------------
# Define helper functions
#----------------------------------------------

# Logs output
function log {
	echo "[$(date '+%D - %T.%N')] $1" >> ${AUTOPUSH_LOG}
}

# Takes a filepath and safely appends it into the queue file
function enqueue {
	#get lock on queue lock file
	exec 200>${AUTOPUSH_QUEUE}
	flock -x -w ${AUTOPUSH_LOCKTIMEOUT} 200

	if [ "$?" -eq 0 ]; then
		#successful, so enqueue
		echo "${1}" >> ${AUTOPUSH_QUEUE}

		return 0
	else
		#log enqueue failure
		log "FAIL: Could not obtain lock on queue file. ${1} not enqueued."

		return 1
	fi
}

# Sets the AUTOPUSH_TARGET variable to be the first filepath in the queue, and removes that entry from the queue
function dequeue {
	#get lock on queue lock file
	exec 201<>${AUTOPUSH_QUEUE}
	flock -x -w ${AUTOPUSH_LOCKTIMEOUT} 201

	if [ "$?" -eq 0 ]; then
		#successful, so grab the first line and set it as the target
		AUTOPUSH_TARGET=$(head -n 1 ${AUTOPUSH_QUEUE})

		#remove first line from file
		sed -i '1,1d' ${AUTOPUSH_QUEUE}

		return 0
	else
		#log dequeue failure
		log "FAIL: Could not obtain lock on queue file. Nothing dequeued."

		return 1
	fi
}

function transfer {
	local pushdef="$(dirname ${AUTOPUSH_INPUT})/${AUTOPUSH_PUSHDEFNAME}"
	if [ -x ${pushdef} ]; then
		#source the pushdef file in order to set the push definition variables
		source ${pushdef}

		if [[ -d ${AUTOPUSH_TARGET} ]]; then
			find $file -type d -exec chmod ${AUTOPUSH_FOLDERPERMISSIONS} {} \;
            find $file -type f -exec chmod ${AUTOPUSH_FILEPERMISSIONS} {} \;
        else
        	chmod ${AUTOPUSH_FILEPERMISSIONS} ${AUTOPUSH_TARGET}
        fi

        if [ ${AUTOPUSH_MODE} -eq "scp" ]; then
        	result=$(scp -r ${AUTOPUSH_SCP_OPTIONS} -P ${AUTOPUSH_PORT} "${AUTOPUSH_TARGET}" ${AUTOPUSH_HOST}:${AUTOPUSH_DEST} 2>&1)
        else if [ ${AUTOPUSH_MODE} -eq "rsync" ]; then
        	#TODO
        fi

        if [ "$?" -eq 0 ]; then
        	#success
        	log "  OK: Successfully pushed $(filename ${AUTOPUSH_TARGET})"
        else
        	#failure
        	log "FAIL: Error pushing $(filename ${AUTOPUSH_TARGET})\n\t\t\t      STDERR: ${result}"
        fi
	else
		#log the fact that an entry made it into the queue file but did not have a valid pushdef file
		log "FAIL: Problem reading or executing associated pushdef file for ${1}."

		return 1
	fi
	
}

# Opens an SSH tunnel and binds it to a local port
function setupTunnel {
	ssh -N -L localhost:25777:${AUTOPUSH_HOST}:${AUTOPUSH_PORT} ${AUTOPUSH_TUNNEL_GATEWAY} -p ${AUTOPUSH_TUNNEL_PORT} &
	sleep ${AUTOPUSH_TUNNEL_WAITTIME}

	AUTOPUSH_TUNNEL_PID=$!
}

function process {
	(
		flock -n 202 || exit 1
		echo "$$" > ${AUTOPUSH_LOCKFILE}

		local AUTOPUSH_TUNNEL_PID=-1

		#setup tunnel if needed
		if [ ${AUTOPUSH_TUNNEL_ENABLE} -eq "true" ]; then
			setupTunnel
		fi

		#while the linecount of the queue file is greater than zero
		while [ $(wc -l ${AUTOPUSH_QUEUE} | awk '{print $1}') -gt 0 ]; do
			#dequeue next transfer and do transfer; if dequeue failed exit the process loop (this prevents infinite loops if the queue file has stuff in it but cannot dequeue entries for some reason)
			dequeue && transfer || exit 1
		done

		if [ ${AUTOPUSH_TUNNEL_PID} -ne -1 ]; then
			kill ${AUTOPUSH_TUNNEL_PID}
		fi
	) 202>${AUTOPUSH_LOCKFILE}
}

#-------------------------------------------
# MAIN
#-------------------------------------------

#determine if push def file exists in the folder that the input file is in
if [ -x "$(dirname ${AUTOPUSH_INPUT})/${AUTOPUSH_PUSHDEFNAME}" ]; then
	#if push def file exists and is readable then queue the input file and start the process loop
	enqueue $AUTOPUSH_INPUT && (process || log "Instance running (lock on autopush lock file could not be obtained)")
fi

#exit successful
exit 0
