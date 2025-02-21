#!/usr/bin/env bash

# Manage the whole set of containers and run tests without having to learn Docker

# consts
BOOTSTRAP_OK_FILE=/var/run/bootstrap_ok
DEFAULT_CONTAINER_USER_UID=1000
DEFAULT_CONTAINER_USER_GID=1000
WEB_SERVICE=ez
WEB_USER=test
# vars
BOOTSTRAP_TIMEOUT=300
CLEANUP_UNUSED_IMAGES=false
CONFIG_FILE=
DEFAULT_CONFIG_FILE=.env
DOCKER_NO_CACHE=
PARALLEL_BUILD=
PULL_IMAGES=false
SILENT=false
REBUILD=false
RECREATE=false
SETUP_APP_ON_BOOT=
VERBOSITY=
WEB_CONTAINER=

help() {
    printf "Usage: teststack.sh [OPTIONS] COMMAND [OPTARGS]

Manages the Test Environment Docker Stack

Commands:
    build           build or rebuild the complete set of containers and set up eZ. Leaves the stack running
    cleanup WHAT    remove temporary data/logs/caches/etc... CATEGORY can be any of:
                        - data            NB: this removes all your data! Better done when containers are stopped
                        - docker-images   removes only unused images. Can be quite beneficial to free up space
                        - docker-logs     NB: for this to work, you'll need to run this script as root
                        - logs            removes log files from the databases, webservers
    enter           enter the test container
    exec \$cmd       execute a command in the test container
    images [\$svc]   list container images
    kill [\$svc]     kill containers
    logs [\$svc]     view output from containers
    pause [\$svc]    pause the containers
    ps [\$svc]       show the status of running containers
    setup           set up eZ without rebuilding the containers first
    resetdb         resets the database used for testing (normally executed as part of provisioning)
    runtests        execute the whole test suite using the test container
    services        list docker-compose services
    start [\$svc]    start the complete set of containers
    stop [\$svc]     stop the complete set of containers
    top [\$svc]      display the running container processes
    unpause [\$svc]  unpause the containers

Options:
    -c              clean up docker images which have become useless - when running 'build'
    -e FILE         name of an environment file to use instead of .env (has to be used for 'start', not for 'exec' or 'enter').
                    Path relative to the docker folder.
                    The env var TESTSTACK_CONFIG_FILE can also be used as an alternative to this option.
    -h              print help
    -f              force the app to be set up - when running 'build', 'start'
    -n              do not set up the app - when running 'build', 'start'
    -r              force containers to rebuild from scratch (this forces a full app set up as well) - when running 'build'
    -s              force app set up (via resetting containers to clean-build status besides updating them if needed) - when running 'build'
    -u              update containers by pulling the base images - when running 'build'
    -v              verbose mode
    -w SECONDS      wait timeout for completion of app and container set up - when running 'build' and 'start'. Defaults to ${BOOTSTRAP_TIMEOUT}
    -z              avoid using docker cache - when running 'build -r'
"
}

build() {

    if [ ${CLEANUP_UNUSED_IMAGES} = 'true' ]; then
        cleanup_dead_docker_images
    fi

    echo "[`date`] Stopping running Containers..."

    docker-compose ${VERBOSITY} stop

    if [ ${REBUILD} = 'true' ]; then
        echo "[`date`] Removing existing Containers..."

        docker-compose ${VERBOSITY} rm -f
    fi

    if [ ${PULL_IMAGES} = 'true' ]; then
        echo "[`date`] Pulling base Docker images..."
        # @todo fix this for variable base Debian images
        IMAGES=$(find . -name Dockerfile | xargs fgrep -h 'FROM' | sort -u | sed 's/FROM //g')
        for IMAGE in $IMAGES; do
            docker pull $IMAGE
        done
    fi

    echo "[`date`] Building Containers..."

    docker-compose ${VERBOSITY} build ${PARALLEL_BUILD} ${DOCKER_NO_CACHE}
    RETCODE=$?
    if [ ${RETCODE} -ne 0 ]; then
        exit ${RETCODE}
    fi

    # q: do we really need to have 2 different env vars and an EXPORT call?
    if [ "${SETUP_APP_ON_BOOT}" != '' ]; then
        export COMPOSE_SETUP_APP_ON_BOOT=${SETUP_APP_ON_BOOT}
    fi

    echo "[`date`] Starting Containers..."

    if [ ${RECREATE} = 'true' ]; then
        docker-compose ${VERBOSITY} up -d --force-recreate
    else
        docker-compose ${VERBOSITY} up -d
    fi

    wait_for_bootstrap all
    RETCODE=$?

    if [ ${CLEANUP_UNUSED_IMAGES} = 'true' ]; then
        cleanup_dead_docker_images
    fi

    if [ "${SETUP_APP_ON_BOOT}" = skip ]; then
        echo "[`date`] Build finished"
    else
        echo "[`date`] Build finished. Exit code: $(docker exec ${WEB_CONTAINER} cat /tmp/setup_ok)"
    fi

    exit ${RETCODE}
}

check_requirements() {
    which docker >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        printf "\n\e[31mPlease install docker & add it to \$PATH\e[0m\n\n" >&2
        exit 1
    fi

    which docker-compose >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        printf "\n\e[31mPlease install docker-compose & add it to \$PATH\e[0m\n\n" >&2
        exit 1
    fi
}

# @todo loop over all args instead of allowing just one
cleanup() {
    case "${1}" in
        data)
            if [ ${SILENT} != true ]; then
                echo "Do you really want to delete all database data?"
                select yn in "Yes" "No"; do
                    case $yn in
                        Yes ) break ;;
                        No ) exit 1 ;;
                    esac
                done
            fi

            find ./data/ -type f ! -name .gitkeep -delete
            # leftover sockets happen...
            find ./data/ -type s -delete
            find ./data/ -type d -empty -delete
        ;;
        docker-images)
            cleanup_dead_docker_images
        ;;
        docker-logs)
            for CONTAINER in $(docker-compose ps -q)
            do
                LOGFILE=$(docker inspect --format='{{.LogPath}}' ${CONTAINER})
                if [ -n "${LOGFILE}" ]; then
                    echo "" > ${LOGFILE}
                fi
            done
        ;;
        # @todo clean up ez caches
        #ez-cache)
        #    find ../app/var/cache/ -type f ! -name .gitkeep -delete
        #;;
        # @todo clean up ez logs
        #ez-logs)
        #    find ../app/var/cache/ -type f ! -name .gitkeep -delete
        #;;
        logs)
            find ./logs/ -type f ! -name .gitkeep -delete
            #find ../app/var/log/ -type f ! -name .gitkeep -delete
        ;;
        *)
            printf "\n\e[31mERROR: unknown cleanup target: ${1}\e[0m\n\n" >&2
            help
            exit 1
        ;;
    esac
}

cleanup_dead_docker_images() {
    echo "[`date`] Removing unused Docker images from disk..."
    DEAD_IMAGES=$(docker images | grep "<none>" | awk "{print \$3}")
    if [ -n "${DEAD_IMAGES}" ]; then
        docker rmi ${DEAD_IMAGES}
    fi
}

# @todo add support for setting up file Tests/docker/data/.composer/auth.json
create_default_config() {
    if [ ! -f ${DEFAULT_CONFIG_FILE} ]; then
        echo "[`date`] Setting up the configuration file..."

        CURRENT_USER_UID=$(id -u)
        CURRENT_USER_GID=$(id -g)

        touch ${DEFAULT_CONFIG_FILE}

        # @todo in case the file already has these vars, replace them instead of appending!
        if [ "${DEFAULT_CONTAINER_USER_UID}" != "${CURRENT_USER_UID}" ]; then
            echo "CONTAINER_USER_UID=${CURRENT_USER_UID}" >> ${DEFAULT_CONFIG_FILE}
        fi
        if [ "${DEFAULT_CONTAINER_USER_GID}" != "${CURRENT_USER_GID}" ]; then
            echo "CONTAINER_USER_GID=${CURRENT_USER_GID}" >> ${DEFAULT_CONFIG_FILE}
        fi
    fi
}

dotenv() {
    if [ ! -f "${1}" ]; then
        printf "WARNING: configuration file '${1}' not found\n" >&2
        return 1
    fi
    set -a
        . "${1}"
    set +a
}

# @todo shall we use paths for config files relative to the 'docker' folder, to teststack.sh, or to the current execution folder?
# @todo test again: why is docker-compose not picking up .env files? neither the default .env one nor the ones
#       we tried specifying using --env-file...
load_config() {
    if [ -z "${CONFIG_FILE}" ]; then
        CONFIG_FILE=${DEFAULT_CONFIG_FILE}
    else
        if [ -n "${VERBOSITY}" ]; then
            echo "Using config file: ${CONFIG_FILE}"
        fi
    fi

    dotenv ${CONFIG_FILE}

    # @todo check UID, GID from conf vs. current. If different, ask for confirmation before running
    #if []; then
    #fi
}

setup_app() {
    echo "[`date`] Starting all Containers..."

    # avoid automatic app setup being triggered here
    export COMPOSE_SETUP_APP_ON_BOOT=skip
    docker-compose ${VERBOSITY} up -d

    wait_for_bootstrap all
    RETCODE=$?
    if [ ${RETCODE} -ne 0 ]; then
        exit ${RETCODE}
    fi

    echo "[`date`] Setting up eZ..."
    docker exec ${WEB_CONTAINER} su ${WEB_USER} -c "cd /home/test/ezmigrationbundle && ./Tests/environment/setup.sh; echo \$? > /tmp/setup_ok"

    # @bug WEB_CONTAINER is not defined in subshell ?
    echo "[`date`] Setup finished. Exit code: $(docker exec ${WEB_CONTAINER} cat /tmp/setup_ok)"
}

# Wait until containers have fully booted
wait_for_bootstrap() {

    if [ ${BOOTSTRAP_TIMEOUT} -le 0 ]; then
        return 0
    fi

    case "${1}" in
        all)
            # q: check all services or only the running ones?
            #BOOTSTRAP_CONTAINERS=$(docker-compose config --services)
            BOOTSTRAP_CONTAINERS=$(docker-compose ps --services | tr '\n' ' ')
        ;;
        app)
            BOOTSTRAP_CONTAINERS='ez'
        ;;
        *)
            #printf "\n\e[31mERROR: unknown booting container: ${1}\e[0m\n\n" >&2
            #help
            #exit 1
            # @todo add check that this service is actually defined
            BOOTSTRAP_CONTAINERS=${1}
        ;;
    esac

    echo "[`date`] Waiting for containers bootstrap to finish..."

     i=0
     while [ $i -le "${BOOTSTRAP_TIMEOUT}" ]; do
        sleep 1
        BOOTSTRAP_OK=''
        for BS_CONTAINER in ${BOOTSTRAP_CONTAINERS}; do
            printf "Waiting for ${BS_CONTAINER} ... "
            # @todo fix this check for the case of container not running...
            # @todo speed this up... maybe go back to generating and checking files mounted on the host?
            docker-compose exec ${BS_CONTAINER} cat ${BOOTSTRAP_OK_FILE} >/dev/null 2>/dev/null
            RETCODE=$?
            if [ ${RETCODE} -eq 0 ]; then
                printf "\e[32mdone\e[0m\n"
                BOOTSTRAP_OK="${BOOTSTRAP_OK} ${BS_CONTAINER}"
            else
                echo;
            fi
        done
        if [ -n "${BOOTSTRAP_OK}" ]; then
            for BS_CONTAINER in ${BOOTSTRAP_OK}; do
                BOOTSTRAP_CONTAINERS=${BOOTSTRAP_CONTAINERS//${BS_CONTAINER}/}
            done
            if [ -z  "${BOOTSTRAP_CONTAINERS// /}" ]; then
                break
            fi
        fi
        i=$(( i + 1 ))
    done
    if [ $i -gt 0 ]; then echo; fi

    if [ -n "${BOOTSTRAP_CONTAINERS// /}" ]; then
        printf "\n\e[31mBootstrap process did not finish within ${BOOTSTRAP_TIMEOUT} seconds\e[0m\n\n" >&2
        return 1
    fi

    return 0
}

# @todo move to a function
# @todo allow parsing of cli options after args -- see fe. https://medium.com/@Drew_Stokes/bash-argument-parsing-54f3b81a6a8f
while getopts ":ce:fhnrsuvwyz" opt
do
    case $opt in
        c)
            CLEANUP_UNUSED_IMAGES=true
        ;;
        e)
            CONFIG_FILE=${OPTARG}
        ;;
        f)
            SETUP_APP_ON_BOOT=force
        ;;
        h)
            help
            exit 0
        ;;
        n)
            SETUP_APP_ON_BOOT=skip
        ;;
        r)
            REBUILD=true
        ;;
        s)
            RECREATE=true
        ;;
        u)
            PULL_IMAGES=true
        ;;
        v)
            VERBOSITY=--verbose
        ;;
        w)
            BOOTSTRAP_TIMEOUT=${OPTARG}
        ;;
        Y)
            SILENT=true
        ;;
        z)
            DOCKER_NO_CACHE=--no-cache
        ;;
        \?)
            printf "\n\e[31mERROR: unknown option -${OPTARG}\e[0m\n\n" >&2
            help
            exit 1
        ;;
    esac
done
shift $((OPTIND-1))

COMMAND=$1

check_requirements

cd $(dirname -- ${BASH_SOURCE[0]})/docker

if [ -z "${CONFIG_FILE}" ]; then
    if [ ! -z "${TESTSTACK_CONFIG_FILE}" ]; then
        CONFIG_FILE=${TESTSTACK_CONFIG_FILE}
    fi
fi

if [ -z "${CONFIG_FILE}" ]; then
    create_default_config
fi

load_config

WEB_CONTAINER=$(docker-compose ps ${WEB_SERVICE} | sed -e '1,2d' | awk '{print $1}')

case "${COMMAND}" in
    build)
        build
    ;;

    cleanup)
        # @todo allow to pass many cleanup targets in one go
        cleanup "${2}"
    ;;

    config)
        docker-compose ${VERBOSITY} config ${2}
    ;;

    # courtesy command alias - same as 'ps'
    containers)
        docker-compose ${VERBOSITY} ps ${2}
    ;;

    enter)
        docker exec -ti ${WEB_CONTAINER} su ${WEB_USER}
    ;;

    exec)
        # scary line ? found it at https://stackoverflow.com/questions/12343227/escaping-bash-function-arguments-for-use-by-su-c
        # q: do we need -ti ?
        docker exec -ti ${WEB_CONTAINER} su ${WEB_USER} -c '"$0" "$@"' -- "$@"
    ;;

    images)
        docker-compose ${VERBOSITY} images ${2}
    ;;

    kill)
        docker-compose ${VERBOSITY} kill ${2}
    ;;

    logs)
        docker-compose ${VERBOSITY} logs ${2}
    ;;

    pause)
        docker-compose ${VERBOSITY} pause ${2}
    ;;

    ps)
        docker-compose ${VERBOSITY} ps ${2}
    ;;

    resetdb)
        # q: do we need -ti ?
        docker exec -ti ${WEB_CONTAINER} su ${WEB_USER} -c './Tests/environment/create-db.sh'
    ;;

    runtests)
        # q: do we need -ti ?
        docker exec -ti ${WEB_CONTAINER} su ${WEB_USER} -c './vendor/phpunit/phpunit/phpunit --stderr --colors Tests/phpunit'
    ;;

    setup)
        setup_app
    ;;

    services)
        docker-compose config --services | sort
    ;;

    start)
        if [ "${SETUP_APP_ON_BOOT}" != '' ]; then
            export COMPOSE_SETUP_APP_ON_BOOT=${SETUP_APP_ON_BOOT}
        fi
        echo docker-compose ${VERBOSITY} up -d ${2}
        docker-compose ${VERBOSITY} up -d ${2}
        if [ -z "${2}" ]; then
            wait_for_bootstrap all
            exit $?
        else
            wait_for_bootstrap ${2}
            exit $?
        fi
    ;;

    stop)
        docker-compose ${VERBOSITY} stop ${2}
    ;;

    top)
        docker-compose ${VERBOSITY} top ${2}
    ;;

    unpause)
        docker-compose ${VERBOSITY} unpause ${2}
    ;;

    *)
        printf "\n\e[31mERROR: unknown command '${COMMAND}'\e[0m\n\n" >&2
        help
        exit 1
    ;;
esac
