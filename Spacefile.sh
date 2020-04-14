# TODO:
# logile should be -o switch.
# Logging sohuld be as nice as for the pods?
# can we reduce the iterative priv drop with sh, it keeps logging a lot into sys logs.
#
SNTD_CMDLINE()
{
    SPACE_SIGNATURE="[action args]"
    SPACE_DEP="USAGE VERSION DAEMON_MAIN _GETOPTS"

    local _out_rest=""
    local _out_h="false"
    local _out_V="false"

    local _out_o=""

    if ! _GETOPTS "h V" "o" 0 1 "$@"; then
        printf "Usage: sntd [clusterHome]  [-o logfile] \\n" >&2
        return 1
    fi

    if [ "${_out_h}" = "true" ]; then
        USAGE
        return
    fi

    if [ "${_out_V}" = "true" ]; then
        VERSION
        return
    fi

    local logfile="${_out_o}"

    if [ -n "${logfile}" ]; then
        DAEMON_MAIN "${_out_rest}" 2>>"${logfile}"
    else
        DAEMON_MAIN "${_out_rest}"
    fi
}

USAGE()
{
    printf "%s\\n" "Usage:

    sntd -h
        Output this help

    sntd -V
        Output version

    sntd [hosthome] [-o logfile]

        hosthome (optional)
            Path to directory of the cluster root directory.
            If provided the program will run pods only for that cluster project,
            if the process is run as root then ramdisks will be available.

            If the hosthome argument is left out then the process must be run as root and it
            will then search for cluster directories for all users and manage the lifecycles
            for all the cluster projects on the host.

        -o logfile
            Path to logfile to append output.
            In left out then output to stderr.


" >&2
}

VERSION()
{
    printf "%s\\n" "Simplenetes daemon version 0.1."
}

_GETOPTS()
{
    SPACE_SIGNATURE="simpleSwitches richSwitches minPositional maxPositional [args]"
    SPACE_DEP="PRINT STRING_SUBSTR STRING_INDEXOF STRING_ESCAPE"

    local simpleSwitches="${1}"
    shift

    local richSwitches="${1}"
    shift

    local minPositional="${1:-0}"
    shift

    local maxPositional="${1:-0}"
    shift

    _out_rest=""

    local options=""
    local option=
    for option in ${richSwitches}; do
        options="${options}${option}:"
    done

    local posCount="0"
    while [ "$#" -gt 0 ]; do
        local flag="${1#-}"
        if [ "${flag}" = "${1}" ]; then
            # Non switch
            posCount="$((posCount+1))"
            if [ "${posCount}" -gt "${maxPositional}" ]; then
                PRINT "Too many positional argumets, max ${maxPositional}" "error" 0
                return 1
            fi
            _out_rest="${_out_rest}${_out_rest:+ }${1}"
            shift
            continue
        fi
        local flag2=
        STRING_SUBSTR "${flag}" 0 1 "flag2"
        if STRING_ITEM_INDEXOF "${simpleSwitches}" "${flag2}"; then
            if [ "${#flag}" -gt 1 ]; then
                PRINT "Invalid option: -${flag}" "error" 0
                return 1
            fi
            eval "_out_${flag}=\"true\""
            shift
            continue
        fi

        local OPTIND=1
        getopts ":${options}" "flag"
        case "${flag}" in
            \?)
                PRINT "Unknown option ${1-}" "error" 0
                return 1
                ;;
            :)
                PRINT "Option -${OPTARG-} requires an argument" "error" 0
                return 1
                ;;
            *)
                STRING_ESCAPE "OPTARG"
                eval "_out_${flag}=\"${OPTARG}\""
                ;;
        esac
        shift $((OPTIND-1))
    done

    if [ "${posCount}" -lt "${minPositional}" ]; then
        PRINT "Too few positional argumets, min ${minPositional}" "error" 0
        return 1
    fi
}

DAEMON_MAIN()
{
    SPACE_SIGNATURE="[hostHome]"
    SPACE_DEP="_LOG _DAEMON_RUN _TRAP_TERM_MAIN STRING_ITEM_INDEXOF FILE_REALPATH"

    local hostHome="${1:-}"

    local _LOGFILETAGS="$(mktemp 2>/dev/null || mktemp -t 'sometmpdir')"

    # If not root and no dir given then exit.
    if [ "$(id -u)" != 0 ]; then
        if [ -z "${hostHome}" ]; then
            _LOG "The daemon has to be run as root, unless it is meant to be run for a single cluster project then provide the HOSTHOME dir as first argument" "fatal"
            return 1
        fi
    fi

    local _EXIT=0
    local main_pids=""
    trap _TRAP_TERM_MAIN TERM INT

    # If directory given as argument then don't run this in Daemon mode,
    # pass it directly to _DAEMON_RUN to run for single user.
    # Regardless if running as root or not.
    if [ -n "${hostHome}" ]; then
        # Run for single user
        hostHome="$(FILE_REALPATH "${hostHome}")"
        _LOG "hostHome is ${hostHome}" "info"
        if [ ! -d "${hostHome}/pods" ]; then
            _LOG "The specified hostHome is lacking a 'pods' dir" "fatal"
            return 1
        fi
        _LOG "Running for single user in foreground (dev mode). PID: $$" "info"
        _LOG "Adding watch to ${hostHome}" "info"
        local pid=
        _DAEMON_RUN "${hostHome}" &
        pid=$!
        main_pids="${main_pids}${main_pids:+ }${pid}"
        while true; do
            sleep 1
            # This loop will end if the single sub process exists.
            if kill -0 ${main_pids} 2>/dev/null && [ "${_EXIT}" -eq 0 ]; then
                continue
            fi
            # Wait for sub processes to exit
            wait ${main_pids} 2>/dev/null >&2
            break
        done

        # Set the exit status to error if this was not a user triggered shutdown.
        [ "${_EXIT}" -eq 1 ]
        return
    fi

    _LOG "Running as a system daemon for all users. PID: $$" "info"

    local clustersDone=""

    while [ "${_EXIT}" -eq 0 ]; do
        local file=
        for file in $(find /home -mindepth 3 -maxdepth 3 -type f -name cluster-id.txt); do
            local hostHome="${file%/*}"
            if [ ! -d "${hostHome}/pods" ]; then
                continue
            fi
            # Check if we already have this cluster.
            if STRING_ITEM_INDEXOF "${clustersDone}" "${hostHome}"; then
                continue
            fi

            clustersDone="${clustersDone}${clustersDone:+ }${hostHome}"
            _LOG "Adding watch to ${hostHome}" "info"

            local pid=
            _DAEMON_RUN "${hostHome}" &
            pid=$!
            main_pids="${main_pids}${main_pids:+ }${pid}"
        done
        sleep 3
    done

    # Wait for sub processes to exit
    wait ${main_pids} 2>/dev/null >&2
}

_TRAP_TERM_MAIN()
{
    SPACE_DEP="_LOG"

    trap - TERM INT


    local pid=
    for pid in ${main_pids}; do
        _LOG "Kill off daemon process: ${pid}" "info"
        kill -s HUP "${pid}"
    done

    # This will trigger the loop to end.
    _EXIT=1
}

# Run for single user and hostHome.
# The username is used when creating ramdisks and chowning them,
# also when dropping priviligies for when running pods.
_DAEMON_RUN()
{
    SPACE_SIGNATURE="hostHome"
    SPACE_DEP="_DAEMON_ITERATE _UPDATE_BUSY_LIST _LOG _TRAP_TERM FILE_STAT"

    local hostHome="${1}"
    shift

    # Declaring some shared variables here:
    local _USER=
    if ! _USER="$(FILE_STAT "${hostHome}" "%U")"; then
        _LOG "Could not stat owner of directory ${hostHome}, will not run this instance" "error"
        return 1
    fi
    local _USERUID=
    if ! _USERUID="$(FILE_STAT "${hostHome}" "%u")"; then
        _LOG "Could not stat owner of directory ${hostHome}, will not run this instance" "error"
        return 1
    fi

    local _USERGID=
    if ! _USERGID="$(FILE_STAT "${hostHome}" "%g")"; then
        _LOG "Could not stat owner group of directory ${hostHome}, will not run this instance" "error"
        return 1
    fi

    local _PODPATTERNS="${hostHome}/pods,.*/release/[^.].*/.*.state"
    local _PROXYCONF="${hostHome}/proxy.conf"
    local _SUBPROCESS_LOG_LEVEL="${SPACE_LOG_LEVEL:-2}"  # The SPACE_LOG_LEVEL of the subprocesses pod scripts.
    local _BUSYLIST=""
    local _PODS=""
    local _CONFIGCHKSUMS=""
    local _CONFIGSCHANGED=""
    local _TMPDIR=
    local _STARTTS="$(date +%s)"
    local _CURRENT_STATES=""

    # Global in this process:
    _PHASE="normal"

    trap _TRAP_TERM HUP

    while true; do
        if [ "${_PHASE}" = "normal" ]; then
            if ! _DAEMON_ITERATE; then
                _PHASE="shutdown"
                continue
            fi
            sleep 6
        elif [ "${_PHASE}" = "shutdown" ]; then
            # Perform graceful shutdown.
            # Wait for all subprocesses to exit.
            _LOG "Initiating graceful shutdown for ${hostHome}" "info"
            _UPDATE_BUSY_LIST
            if [ -z "${_BUSYLIST}" ]; then
                _LOG "Shutdown done for ${hostHome}" "info"
                return 1
            fi
            sleep 2
        fi
    done
}

_TRAP_TERM()
{
    _PHASE="shutdown"
}

# Check which pods has come out of busy mode, update the busy list.
# Fetch all existing state files (pods).
# Check if their configs have changed (for first time pods that is a No).
# Iterate the full list of pods, check if that pod is busy, otherwie
_DAEMON_ITERATE()
{
    SPACE_DEP="_LOG _UPDATE_BUSY_LIST _FETCH_POD_FILES _CHECK_CONFIG_CHANGES _SPAWN_PROCESSES _WRITE_PROXY_CONFIG"

    # We recreate the tmpdir if it has been removed, since this is a long running usage of tmp it might get removed at some point.
    if [ -z "${_TMPDIR}" ] || [ ! -d "${_TMPDIR}" ]; then
        _TMPDIR="$(mktemp -d 2>/dev/null || mktemp -d -t 'sometmpdir')"
    fi

    if ! _FETCH_POD_FILES; then
        _LOG "Error in fetching pod files" "error"
        return 1
    fi

    if ! _UPDATE_BUSY_LIST; then
        _LOG "Cannot update busy list" "error"
        return 1
    fi

    if ! _CHECK_CONFIG_CHANGES; then
        _LOG "Could not check pod config changes" "error"
        return 1
    fi

    if ! _SPAWN_PROCESSES; then
       _LOG "Could not spawn process" "error"
        return 1
    fi

    # Initially wait at least 10 seconds before updating the proxy.conf since it may flicker to empty otherwise on startup.
    local ts="$(date +%s)"
    if [ $((ts-_STARTTS >10)) ]; then
        if ! _WRITE_PROXY_CONFIG; then
            _LOG "Could not write proxy config" "error"
            return 1
        fi
    fi
}

# For all basedirs and patterns provided
# find all pods with a state file.
# Populate _PODS as "path_to_pod_naked_file etc".
# The path is the full pod path.
_FETCH_POD_FILES()
{
    local tuple=
    for tuple in ${_PODPATTERNS}; do
        local basedir="${tuple%%,*}"
        local pattern="${tuple##*,}"
        local stateFiles=
        if ! stateFiles="$(find "${basedir}" -regex "${pattern}" 2>/dev/null)"; then
            return 1
        fi
        local stateFile=
        _PODS=""
        for stateFile in ${stateFiles}; do
            local nakedFile="${stateFile%.state}"
            # Check so that the state file has a pod buddie file,
            # if so store it.
            if [ -f "${nakedFile}" ]; then
                _PODS="${_PODS}${_PODS:+ }${nakedFile}"
            fi
        done
    done
}

# Check the pids of pod interaction subprocesses to see which ones are done
# and move them out of the busy list.
# The busy list format is "nakedFile,pid etc"
_UPDATE_BUSY_LIST()
{
    SPACE_DEP="_DESTROY_RAMDISKS _LOG"

    local newList=""
    local tuple=
    for tuple in ${_BUSYLIST}; do
        local nakedFile="${tuple%%,*}"
        local pid="${tuple##*,}"
        # Check if the process is still alive.
        if kill -0 "${pid}" 2>/dev/null; then
            newList="${newList}${newList:+ }${nakedFile},${pid}"
        else
            # The process ended, check if the state is stopped or removed,
            # if so then remove any ramdisks this process has created.
            _LOG "Process exited for ${nakedFile} with PID ${pid}" "debug"
            if [ "$(id -u)" = "0" ]; then
                local stateFile="${nakedFile}.state"
                local state="$(cat "${stateFile}")"
                if [ "${state}" != "running" ]; then
                    local podDir="${nakedFile%/*}"
                    _DESTROY_RAMDISKS "${podDir}"
                fi
            fi
        fi
    done
    _BUSYLIST="${newList}"
}

# Check if any configs have changed for the given pods.
_CHECK_CONFIG_CHANGES()
{
    SPACE_DEP="FILE_DIR_CHECKSUM STRING_ITEM_INDEXOF STRING_ITEM_GET"

    local changedList=""
    local newList=""

    local nakedFile=
    for nakedFile in ${_PODS}; do
        local podDir="${nakedFile%/*}"
        local configsDir="${podDir}/config"
        if [ ! -d "${podDir}" ]; then
            continue
        fi

        local isBusy=0
        local tuple=
        for tuple in ${_BUSYLIST}; do
            local nakedFile2="${tuple%%,*}"
            if [ "${nakedFile}" = "${nakedFile2}" ]; then
                # Pod is in busy list.
                isBusy=1
                break
            fi
        done

        # Get the checksum of each config dir in the pod dir.
        local configDir=
        #for configDir in ${configsDir}/*; do
        for configDir in $(cd "${configsDir}" 2>/dev/null && find . -maxdepth 1 -type d |cut -b3-); do
            if [ ! -d "${configDir}" ]; then
                continue
            fi

            # Get previous checksum, if any
            local chksumPrevious=
            local index=
            if STRING_ITEM_INDEXOF "${_CONFIGCHKSUMS}" "${configDir}" "index"; then
                STRING_ITEM_GET "${_CONFIGCHKSUMS}" "$((index+1))" "chksumPrevious"
            fi

            # If this pod is in busy list, just transfer the previous checksum over,
            # because if config has changed we don't want to burn that notification already.
            if [ "${isBusy}" = "1" ]; then
                newList="${newList}${newList:+ }${configDir} ${chksumPrevious}"
                continue
            fi

            local chksum=
            if ! chksum=$(FILE_DIR_CHECKSUM "${configDir}"); then
                return 1
            fi

            if ! [ "${chksum}" = "${chksumPrevious}" ]; then
                # Mismatch, store it in changed list, unless this was the first time
                if [ -n "${chksumPrevious}" ]; then
                    changedList="${changedList}${changedList:+ }${configDir}"
                fi
            fi
            newList="${newList}${newList:+ }${configDir} ${chksum}"
        done
    done

    _CONFIGCHKSUMS="${newList}"
    _CONFIGSCHANGED="${changedList}"
}

# Go through the state files list,
# for each state file which is not in the busy list
# check if its configs has changed
# and spawn a update process with state and potential config updates.
_SPAWN_PROCESSES()
{
    SPACE_DEP="_SPAWN_PROCESS _SPAWN_STATE_CHANGED _LOG_CLEAR _LOG STRING_IS_ALL"

    local nakedFile=
    for nakedFile in ${_PODS}; do
        local podDir="${nakedFile%/*}"
        local tuple=
        for tuple in ${_BUSYLIST}; do
            local nakedFile2="${tuple%%,*}"
            if [ "${nakedFile}" = "${nakedFile2}" ]; then
                # Pod is in busy list.
                continue 2
            fi
        done

        local actionFile="${nakedFile}.action"
        local action=
        if [ -f "${actionFile}" ]; then
            action="$(cat "${actionFile}")"
            rm "${actionFile}"
            # Check the action so it is valid:
            if [ "${action%[ ]*}" = "rerun" ]; then
                if ! STRING_IS_ALL "${action}" "a-z0-9_ "; then
                    action=
                fi
            else
                action=
            fi
            if [ -z "${action}" ]; then
                _LOG "Action not recognized for ${nakedFile}" "error" 0
            fi
        fi

        local stateFile="${nakedFile}.state"
        local state="$(cat "${stateFile}")"
        local changedConfigs=""
        if [ "${state}" = "running" ]; then
            # Check for changed configs
            local configDir=
            for configDir in ${_CONFIGSCHANGED}; do
                # Check if this config dir is for the current pod
                local config="${configDir##${podDir}/config/}"
                if [ "${config}" != "${configDir}" ]; then
                    changedConfigs="${changedConfigs}${changedConfigs:+ }${config}"
                fi
            done
            if [ -n "${action}" ]; then
                _LOG "Action '${action}' provided for ${nakedFile}" "info" 0
            fi
        else
            if [ -n "${action}" ]; then
                _LOG "Action '${action}' provided but pod is not in 'running' state for ${nakedFile}" "info" 0
            fi
        fi

        local stateChanged="false"
        if _SPAWN_STATE_CHANGED "${nakedFile}" "${state}"; then
            stateChanged="true"
            _LOG "State changed. Exec ${nakedFile} ${state}" "info" 0
            _LOG_CLEAR "exec:${nakedFile}"
        fi

        if [ -n "${changedConfigs}" ]; then
            _LOG "Configs changed. Reload configs for ${nakedFile}" "info" 0
            _LOG_CLEAR "config:${nakedFile}"
        fi

        if [ "${stateChanged}" = "true" ] ||
           [ "${state}" = "running" ] ||
           [ -n "${changedConfigs}" ]; then
            if ! _SPAWN_PROCESS "${nakedFile}" "${state}" "${changedConfigs}" "${action}"; then
                _LOG "Could not spawn process for ${nakedFile}" "error" "spawn:${nakedFile}"
                return 0
            fi
        fi
    done
}

# Save the given state and return 0 if the state did change.
_SPAWN_STATE_CHANGED()
{
    SPACE_SIGNATURE="nakedFile state"

    local nakedFile="${1}"
    shift

    local state="${1}"
    shift

    local prevState=""
    local line="$(printf "%s\\n" "${_CURRENT_STATES}" |grep -m1 "^${nakedFile} ")"

    if [ -n "${line}" ]; then
        prevState="${line##*[ ]}"
        _CURRENT_STATES="$(printf "%s\\n" "${_CURRENT_STATES}" |grep -v "^${nakedFile} ")"
    fi

    # Save state
    local nl="
"
    _CURRENT_STATES="${_CURRENT_STATES}${_CURRENT_STATES:+$nl}${nakedFile} ${state}"

    # Set return status
    [ "${prevState}" != "${state}" ]
}

# Spawn a subprocess and put it in the busy list.
_SPAWN_PROCESS()
{
    SPACE_SIGNATURE="nakedfile state changedConfigs action"
    SPACE_DEP="STRING_HASH _CREATE_RAMDISK _LOG"

    local nakedFile="${1}"
    shift

    local state="${1}"
    shift

    local changedConfigs="${1}"
    shift

    local action="${1}"
    shift

    local podFile="${nakedFile}"

    local _HOME="${HOME}"
    local exec="sh -c"
    if [ "$(id -u)" = "0" ]; then
        # Drop priviligies
        exec="setpriv --reuid ${_USERUID} --regid ${_USERGID} --init-groups sh -c"
        _HOME="/home/${_USER}"
    fi

    local command=

    if [ "${state}" = "running" ]; then
        command="run"
        if [ "$(id -u)" = "0" ]; then
            # Check if to create ramdisks for this pod
            local ramdisks=
            ramdisks="$(USER="${_USER}" HOME="${_HOME}" SPACE_LOG_LEVEL="${_SUBPROCESS_LOG_LEVEL}" ${exec} "${podFile} ramdisk-config")"
            if [ -n "${ramdisks}" ]; then
                local podDir="${nakedFile%/*}"
                local ramdisk=
                for ramdisk in ${ramdisks}; do
                    local name="${ramdisk%:*}"
                    local size="${ramdisk#*:}"
                    local error=
                    if ! error="$(_CREATE_RAMDISK "${podDir}" "${name}" "${size}" 2>&1)"; then
                        _LOG "Could not create ramdisk ${name}:${size} in ${podDir}, Error: ${error}" "error" "ramdisk:${podDir}:${name}:${size}"
                        return 1
                    else
                        _LOG "Created ramdisk ${name}:${size} in ${podDir}" "info" "ramdisk:${podDir}:${name}:${size}"
                    fi
                done
            fi
        fi
    elif [ "${state}" = "stopped" ]; then
        command="stop"
    elif [ "${state}" = "removed" ]; then
        command="rm"
    else
        _LOG "State file has unknown state." "debug"
        return 0
    fi

    # If we have a action given, then we hijack the command at this point.
    if [ "${state}" = "running" ] && [ -n "${action}" ]; then
        command="${action}"
    fi

    local hash=
    if ! STRING_HASH "${nakedFile}" "hash"; then
        return 1
    fi

    local proxyConfigFragment="${_TMPDIR}/proxy.${hash}.conf"

    local pid=
    (
        local error=
        # If running as root we will drop privileges here, thanks to ${exec}.
        if ! error="$(USER="${_USER}" HOME="${_HOME}" SPACE_LOG_LEVEL="${_SUBPROCESS_LOG_LEVEL}" ${exec} "${podFile} ${command}" 2>&1)"; then
            _LOG "Could not exec ${podFile} ${command}. Error: ${error}" "error" "exec:${podFile}"
        fi
        if [ -n "${changedConfigs}" ]; then
            if ! error="$(USER="${_USER}" HOME="${_HOME}" SPACE_LOG_LEVEL="${_SUBPROCESS_LOG_LEVEL}" ${exec} "${podFile} reload-configs ${changedConfigs}" 2>&1)"; then
                _LOG "Could not exec ${podFile} reload-configs. Error: ${error}" "error" "config:${podFile}"
            fi
        fi

        # We mute stderr for the remaining ${exec} invocations by setting: SPACE_LOG_LEVEL="0"
        if [ "${state}" = "running" ]; then
            local cc=
            if [ -f "${podFile}.proxy.conf" ]; then
                cc="$(cat "${podFile}.proxy.conf")"
            fi
            if [ -n "${cc}" ]; then
                # Run ReadinessProbe and write proxy config fragment.
                if USER="${_USER}" HOME="${_HOME}" SPACE_LOG_LEVEL="0" ${exec} "${podFile} readiness"; then
                    printf "%s\\n" "${cc}" >"${proxyConfigFragment}.tmp"
                else
                    # Reset
                    printf "# Not ready: %s\\n" "${podFile}" >"${proxyConfigFragment}.tmp"
                fi
                mv -f "${proxyConfigFragment}.tmp" "${proxyConfigFragment}"
            fi

            # Run LivenessProbe
            USER="${_USER}" HOME="${_HOME}" SPACE_LOG_LEVEL="0" ${exec} "${podFile} liveness"
        fi
    )&
    pid=$!

    _BUSYLIST="${_BUSYLIST}${_BUSYLIST:+ }${nakedFile},${pid}"
}

# Concat all proxy config fragments into a whole and compare it to the existing config.
# If they differ then update the actual config.
_WRITE_PROXY_CONFIG()
{
    if [ -z "${_PROXYCONF}" ]; then
        return 0
    fi

    local proxyConf="${_TMPDIR}/proxy.conf"

    local file=
    cat "${_TMPDIR}"/proxy.*.conf 2>/dev/null |sort >"${proxyConf}"
    printf "%s\\n" "### EOF" >>"${proxyConf}"

    if diff "${_PROXYCONF}" "${proxyConf}" >/dev/null 2>&1; then
        return 0
    fi

    cp "${proxyConf}" "${_PROXYCONF}"
}

# This function must be run as root
_CREATE_RAMDISK()
{
    SPACE_SIGNATURE="podDir name size"

    if [ ! -d "${podDir}/ramdisk" ]; then
        mkdir "${podDir}/ramdisk"
        chown "${_USERUID}:${_USERGID}" "${podDir}/ramdisk"
    fi

    if [ ! -d "${podDir}/ramdisk/${name}" ]; then
        mkdir "${podDir}/ramdisk/${name}"
        chown "${_USERUID}:${_USERGID}" "${podDir}/ramdisk/${name}"
    fi

    if mountpoint -q "${podDir}/ramdisk/${name}"; then
        # Already exists.
        return 0
    fi

    if ! mount -t tmpfs -o size="${size}" tmpfs "${podDir}/ramdisk/${name}"; then
        return 1
    fi

    chown "${_USERUID}:${_USERGID}" "${podDir}/ramdisk/${name}"
    chmod 700 "${podDir}/ramdisk/${name}"
}

# This function must be run as root
_DESTROY_RAMDISKS()
{
    SPACE_SIGNATURE="podDir"
    SPACE_DEP="_LOG"

    if [ -d "${podDir}/ramdisk" ]; then
        local dir=
        #for dir in "${podDir}/ramdisk/"*; do
        for dir in $(cd "${podDir}/ramdisk" 2>/dev/null && find . -maxdepth 1 -type d |cut -b3-); do
            if mountpoint -q "${dir}"; then
                _LOG "Unmount ramdisk ${dir}" "info"
                umount "${dir}"
            fi
        done
    fi
}

# Depends on that _LOGFILETAGS is a path to a tmp file.
_LOG()
{
    SPACE_SIGNATURE="message level tag"
    SPACE_DEP="PRINT STRING_HASH"

    local message="${1}"
    shift

    local level="${1}"
    shift

    # The tag can be used to have different formatted messages group together.
    # If no tag provided the message is the tag which means it won't repeat it self.
    local tag="${1:-${message}}"

    if [ "${tag}" = "0" ]; then
        PRINT "${message}" "${level}" 0
        return
    fi

    # Check if this tag already exists, of so check if the level is the same.
    local hash=
    STRING_HASH "${tag}" "hash"

    # Check if hash is present
    local row=
    local level2=
    if row="$(grep "^${hash}\>" "${_LOGFILETAGS}" 2>/dev/null)"; then
        level2="${row#*[ ]}"
    fi

    if [ "${level}" != "${level2}" ]; then
        local logtext="$(grep -v "^${hash}\>" "${_LOGFILETAGS}")"
        printf "%s\\n%s\\n" "${logtext}" "${hash} ${level}" >"${_LOGFILETAGS}"
        if [ "${level}" = "fatal" ]; then
            level="error"
        fi
        PRINT "${message}" "${level}" 0
    fi
}

_LOG_CLEAR()
{
    SPACE_SIGNATURE="tag"
    SPACE_DEP="STRING_HASH"

    local tag="${1}"
    shift

    local hash=
    STRING_HASH "${tag}" "hash"

    local logtext="$(grep -v "^${hash}\>" "${_LOGFILETAGS}")"
    printf "%s\\n" "${logtext}" >"${_LOGFILETAGS}"
}
