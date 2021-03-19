# Note: possibly add functionality to keep track of pod daemon processes to see if they
# disappear and then respawn the pod.
SNTD_CMDLINE()
{
    SPACE_SIGNATURE="[args]"
    SPACE_DEP="USAGE VERSION DAEMON_MAIN"

    if [ "${1:-}" = "help" ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
        USAGE
        return
    fi

    if [ "${1:-}" = "version" ] || [ "${1:-}" = "-V" ]; then
        VERSION
        return
    fi

    DAEMON_MAIN "$@"
}

USAGE()
{
    printf "%s\\n" "Usage:

    simplenetesd -h
        Output this help

    simplenetesd -V|--version
        Output version

    simplenetesd [hosthome]

        hosthome (optional)
            Path to directory of the cluster root directory.
            If provided the program will run pods only for that cluster project,
            if the process is run as root then ramdisks will be available.

            If the hosthome argument is left out then the process must be run as root and it
            will then search for cluster directories for all users and manage the lifecycles
            for all the cluster projects on the host.

"
}

VERSION()
{
    printf "%s\\n" "Simplenetesd 0.3.0"
}

DAEMON_MAIN()
{
    SPACE_SIGNATURE="[hostHome]"
    SPACE_DEP="PRINT _DAEMON_RUN _TRAP_TERM_MAIN STRING_ITEM_INDEXOF FILE_REALPATH"

    local hostHome="${1:-}"

    # If not root and no dir given then exit.
    if [ "$(id -u)" != 0 ]; then
        if [ -z "${hostHome}" ]; then
            PRINT "The daemon has to be run as root, unless it is meant to be run for a single cluster project then provide the HOSTHOME dir as first argument" "error" 0
            return 1
        fi
    fi

    local _EXIT=0
    local main_pids=""
    trap _TRAP_TERM_MAIN TERM INT HUP

    # If directory given as argument then don't run this in Daemon mode,
    # pass it directly to _DAEMON_RUN to run for single user.
    # Regardless if running as root or not.
    if [ -n "${hostHome}" ]; then
        # Run for single user
        hostHome="$(FILE_REALPATH "${hostHome}")"
        if [ ! -d "${hostHome}/pods" ]; then
            PRINT "The specified hostHome '${hostHome}' is lacking a 'pods' dir" "error" 0
            return 1
        fi
        PRINT "Running service for single host home. PID: $$" "info" 0
        PRINT "Adding watch to ${hostHome}" "info" 0
        local pid=
        _DAEMON_RUN "${hostHome}" &
        pid=$!
        main_pids="${main_pids}${main_pids:+ }${pid}"

        # Wait until signalled to exit.
        while [ "${_EXIT}" -eq 0 ]; do
            sleep 1
        done
    else
        PRINT "Running service for all users. PID: $$" "info" 0

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
                PRINT "Adding watch to ${hostHome}" "info" 0

                local pid=
                _DAEMON_RUN "${hostHome}" &
                pid=$!
                main_pids="${main_pids}${main_pids:+ }${pid}"
            done
            sleep 3
        done
    fi

    trap - TERM INT HUP

    # Kill subprocesses, if not already killed.
    local pid=
    for pid in ${main_pids}; do
        kill -s HUP "${pid}" 2>/dev/null
    done

    # Wait for sub processes to exit
    wait ${main_pids} 2>/dev/null >&2

    # Set the exit status to error if this was not a user triggered shutdown.
    [ "${_EXIT}" -eq 1 ]
    return
}

_TRAP_TERM_MAIN()
{
    _EXIT=1
}

# Run for single user and hostHome.
# The username is used when creating ramdisks and chowning them,
# also when dropping privileges for when querying pods about ramdisk configurations.
_DAEMON_RUN()
{
    SPACE_SIGNATURE="hostHome"
    SPACE_DEP="_DAEMON_ITERATE _UPDATE_BUSY_LIST PRINT _TRAP_TERM FILE_STAT"

    local hostHome="${1}"
    shift

    # Declaring some shared variables here:
    local _USER=
    if ! _USER="$(FILE_STAT "${hostHome}" "%U")"; then
        PRINT "Could not stat owner of directory ${hostHome}, will not run this instance" "error" 0
        return 1
    fi
    local _USERUID=
    if ! _USERUID="$(FILE_STAT "${hostHome}" "%u")"; then
        PRINT "Could not stat owner of directory ${hostHome}, will not run this instance" "error" 0
        return 1
    fi

    local _USERGID=
    if ! _USERGID="$(FILE_STAT "${hostHome}" "%g")"; then
        PRINT "Could not stat owner group of directory ${hostHome}, will not run this instance" "error" 0
        return 1
    fi

    if [ "$(id -u)" = 0 ]; then
        # If running as root make sure /run/user/UID exists properly, podman can throw errors otherwise.
        local runDir="/run/user/${_USERUID}"
        if [ ! -d "${runDir}" ]; then
            mkdir -p "${runDir}"
            chown "${_USERUID}:${_USERGID}" "${runDir}"
            chmod 700 "${runDir}"
        fi
        unset runDir
    fi

    local _PODPATTERNS="${hostHome}/pods,.*/release/[^.].*/.*.state"
    local _PROXYCONF="${hostHome}/portmappings.conf"
    local _SUBPROCESS_LOG_LEVEL="${SPACE_LOG_LEVEL:-2}"  # The SPACE_LOG_LEVEL of the subprocesses pod scripts.
    local _BUSYLIST=""
    local _PODS=""
    local _CURRENT_STATES=""

    local _PHASE="normal"

    # Bash needs INT to be ignored in subprocesses.
    trap '' INT

    trap _TRAP_TERM HUP

    while [ "${_PHASE}" = "normal" ]; do
        if ! _DAEMON_ITERATE; then
            _PHASE="shutdown"
            continue
        fi
        sleep 6
    done

    trap - HUP

    # Perform graceful shutdown.
    # Wait for all subprocesses to exit.
    PRINT "Initiating graceful shutdown for ${hostHome}" "info" 0
    while [ -n "${_BUSYLIST}" ]; do
        _UPDATE_BUSY_LIST
        sleep 2
    done

    PRINT "Shutdown done for ${hostHome}" "info" 0
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
    SPACE_DEP="PRINT _UPDATE_BUSY_LIST _FETCH_POD_FILES _SPAWN_PROCESSES _WRITE_PROXY_CONFIG"

    if ! _FETCH_POD_FILES; then
        PRINT "Error in fetching pod files" "error" 0
        return 1
    fi

    if ! _UPDATE_BUSY_LIST; then
        PRINT "Cannot update busy list" "error" 0
        return 1
    fi

    if ! _SPAWN_PROCESSES; then
       PRINT "Could not spawn process" "error" 0
        return 1
    fi

    if ! _WRITE_PROXY_CONFIG; then
        PRINT "Could not write proxy config" "error" 0
        return 1
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
# For those pods which the process ended and their state is not running, remove their ramdisks (if root).
# The busy list format is "nakedFile,pid etc"
_UPDATE_BUSY_LIST()
{
    SPACE_DEP="_DESTROY_RAMDISKS PRINT"

    local newList=""
    local tuple=
    for tuple in ${_BUSYLIST}; do
        local nakedFile="${tuple%%,*}"
        local pid="${tuple##*,}"
        # Check if the process is still alive.
        if kill -0 "${pid}" 2>/dev/null; then
            newList="${newList}${newList:+ }${nakedFile},${pid}"
        else
            # The process ended, check if it should be running and exit code was > 0, then put it back for retry.
            # Otherwise if the state is not "running" remove any ramdisks this process has created.
            # Get exit code
            local exitCode=
            wait "${pid}"
            exitCode="$?"
            PRINT "Spawn process exited for ${nakedFile} with PID ${pid}, exit code: ${exitCode}." "debug" 0
            local stateFile="${nakedFile}.state"
            local state="$(cat "${stateFile}")"
            if [ "${state}" = "running" ]; then
                if [ "${exitCode}" -gt 0 ]; then
                    # Retry running this.
                    PRINT "Retry running ${nakedFile}" "info" 0
                    local actionFile="${nakedFile}.action"
                    printf "%s\\n" "rerun" >"${actionFile}"
                fi
            else
                # Remove ramdisks, if simplenetesd running as root.
                if [ "$(id -u)" = "0" ]; then
                    local podDir="${nakedFile%/*}"
                    _DESTROY_RAMDISKS "${podDir}"
                fi
            fi
        fi
    done
    _BUSYLIST="${newList}"
}

# Go through the state files list,
# for each state file which is not in the busy list check if there has been a state change.
# If there is an pod.action file present, we process that action instead of looking at state changes.
# The action operation is used for rerunning the pod or some containers.
_SPAWN_PROCESSES()
{
    SPACE_DEP="_SPAWN_PROCESS _SPAWN_STATE_CHANGED PRINT STRING_IS_ALL"

    local nakedFile=
    for nakedFile in ${_PODS}; do
        local podDir="${nakedFile%/*}"
        local tuple=
        for tuple in ${_BUSYLIST}; do
            local nakedFile2="${tuple%%,*}"
            if [ "${nakedFile}" = "${nakedFile2}" ]; then
                # Pod is in busy list, skip for now
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
                PRINT "Action not recognized for ${nakedFile}" "error" 0
            fi
        fi

        local stateFile="${nakedFile}.state"
        local state="$(cat "${stateFile}")"
        local stateChanged="false"

        if _SPAWN_STATE_CHANGED "${nakedFile}" "${state}"; then
            stateChanged="true"
            PRINT "State changed. Exec ${nakedFile} ${state}" "info" 0
        fi

        if [ "${stateChanged}" = "true" ] && [ -n "${action}" ]; then
            PRINT "Action '${action}' provided but pod state did also change, so ignoring action. For ${nakedFile}" "warning" 0
            action=""
        fi

        if [ "${state}" = "running" ]; then
            if [ -n "${action}" ]; then
                PRINT "Action '${action}' provided for ${nakedFile}" "info" 0
            fi
        else
            if [ -n "${action}" ]; then
                PRINT "Action '${action}' provided but pod is not in 'running' state for ${nakedFile}" "warning" 0
                # Do not perform actions on non running containers
                action=""
            fi
        fi

        if [ "${stateChanged}" = "true" ] ||
           [ -n "${action}" ]; then
            if ! _SPAWN_PROCESS "${nakedFile}" "${state}" "${action}"; then
                PRINT "Could not spawn process for ${nakedFile}" "error" 0
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
    SPACE_SIGNATURE="nakedfile state action"
    SPACE_DEP="STRING_HASH _CREATE_RAMDISK PRINT"

    local nakedFile="${1}"
    shift

    local state="${1}"
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

    # If we have an action given, then we hijack the command at this point.
    if [ -n "${action}" ]; then
        command="${action}"
    elif [ "${state}" = "running" ]; then
        command="run"
        if [ "$(id -u)" = "0" ]; then
            # Check if to create ramdisks for this pod
            # Note: instead of running `pod create-ramdisks` as root and have it done with,
            # we drop privileges and get the ramdisk config. This is a security consideration
            # because we don't want to run any user provided pod code as root.
            local ramdisks=
            ramdisks="$(USER="${_USER}" HOME="${_HOME}" SPACE_LOG_LEVEL="${_SUBPROCESS_LOG_LEVEL}" ${exec} "${podFile} create-ramdisks -l")"
            if [ -n "${ramdisks}" ]; then
                local podDir="${nakedFile%/*}"
                local ramdisk=
                for ramdisk in ${ramdisks}; do
                    local name="${ramdisk%:*}"
                    local size="${ramdisk#*:}"
                    local error=
                    if ! error="$(_CREATE_RAMDISK "${podDir}" "${name}" "${size}" 2>&1)"; then
                        PRINT "Could not create ramdisk ${name}:${size} in ${podDir}, Error: ${error}" "error" 0
                        return 1
                    else
                        PRINT "Created ramdisk ${name}:${size} in ${podDir}" "info" 0
                    fi
                done
            fi
        fi
    elif [ "${state}" = "stopped" ]; then
        command="stop"
    elif [ "${state}" = "removed" ]; then
        command="rm"
    else
        PRINT "State file has unknown state." "debug" 0
        return 0
    fi

    local hash=
    if ! STRING_HASH "${nakedFile}" "hash"; then
        return 1
    fi

    local pid=
    (
        local error=
        local exitCode=
        # If running as root we will drop privileges here, thanks to ${exec}.
        error="$(USER="${_USER}" HOME="${_HOME}" SPACE_LOG_LEVEL="${_SUBPROCESS_LOG_LEVEL}" ${exec} "${podFile} ${command}" 2>&1)"
        exitCode="$?"
        if [ "${exitCode}" -gt 0 ]; then
            PRINT "Could not exec ${podFile} ${command}. Exit code: ${exitCode}. Error: ${error}" "error" 0
            return "${exitCode}"
        fi
    )&
    pid=$!

    _BUSYLIST="${_BUSYLIST}${_BUSYLIST:+ }${nakedFile},${pid}"
}

# For all pods which are in the running state and have readiness, concat
# their .pod.portmappings.conf files and if the result differs from the existing config
# then update the actual config.
_WRITE_PROXY_CONFIG()
{
    if [ -z "${_PROXYCONF}" ]; then
        return 0
    fi

    local nl="
"
    local contents=""
    local nakedFile=
    for nakedFile in ${_PODS}; do
        # Check so state is running
        local stateFile="${nakedFile}.state"
        if [ ! -f "${stateFile}" ]; then
            continue
        fi
        local state="$(cat "${stateFile}")"
        if [ "${state}" != "running" ]; then
            continue
        fi

        # Check readiness
        local proxyFile="${nakedFile}.portmappings.conf"
        # Make into dotfile
        proxyFile="${proxyFile%/*}/.${proxyFile##*/}"

        local statusFile="${nakedFile}.status"
        if [ ! -f "${statusFile}" ]; then
            continue
        fi
        local readiness="$(grep "^readiness:" "${statusFile}" |cut -d' ' -f2)"
        if [ "${readiness}" = "1" ]; then
            # Check that last update time is not too old
            local updated="$(grep "^updated:" "${statusFile}" |cut -d' ' -f2)"
            if [ -n "${updated}" ]; then
                local ts="$(date +%s)"
                # Allow a maximum 10 minutes old update.
                if [ $((ts-updated > 600)) -eq 1 ]; then
                    continue
                fi
            fi
            if [ -f "${proxyFile}" ]; then
                contents="${contents}${contents:+ $nl}$(cat "${proxyFile}")"
            fi
        fi
    done

    local proxyConf="$(mktemp 2>/dev/null || mktemp -t 'sometmpdir')"

    printf "%s\\n" "${contents}" |sort >"${proxyConf}"

    if diff "${_PROXYCONF}" "${proxyConf}" >/dev/null 2>&1; then
        rm "${proxyConf}"
        return 0
    fi

    mv -f "${proxyConf}" "${_PROXYCONF}"
    # Make file readable by regular user running the proxy pod.
    chmod 644 "${_PROXYCONF}"
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

    # If the pod was run without daemon prior and it created "fake" ramdisks which might be lingering from an abrupt shutdown,
    # that is fine, since a mount will shadow the existing directory contents.

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
    SPACE_DEP="PRINT"

    if [ -d "${podDir}/ramdisk" ]; then
        local dir=
        for dir in $(find "${podDir}/ramdisk" -maxdepth 1 -mindepth 1 -type d 2>/dev/null); do
            if mountpoint -q "${dir}"; then
                PRINT "Unmount ramdisk ${dir}" "info" 0
                umount "${dir}"
            fi
        done
    fi
}
