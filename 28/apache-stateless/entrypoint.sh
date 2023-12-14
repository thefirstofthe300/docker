#!/bin/bash
set -eu

# version_greater A B returns whether A > B
version_greater() {
    [ "$(printf '%s\n' "$@" | sort -t '.' -n -k1,1 -k2,2 -k3,3 -k4,4 | head -n 1)" != "$1" ]
}

# return true if specified directory is empty
directory_empty() {
    [ -z "$(ls -A "$1/")" ]
}

run_as() {
    if [ "$(id -u)" = 0 ]; then
        su -p "$user" -s /bin/sh -c "$1"
    else
        sh -c "$1"
    fi
}

# Execute all executable files in a given directory in alphanumeric order
run_path() {
    local hook_folder_path="/docker-entrypoint-hooks.d/$1"
    local return_code=0

    if ! [ -d "${hook_folder_path}" ]; then
        echo "=> Skipping the folder \"${hook_folder_path}\", because it doesn't exist"
        return 0
    fi

    echo "=> Searching for scripts (*.sh) to run, located in the folder: ${hook_folder_path}"

    (
        find "${hook_folder_path}" -type f -maxdepth 1 -iname '*.sh' -print | sort | while read -r script_file_path; do
            if ! [ -x "${script_file_path}" ]; then
                echo "==> The script \"${script_file_path}\" was skipped, because it didn't have the executable flag"
                continue
            fi

            echo "==> Running the script (cwd: $(pwd)): \"${script_file_path}\""

            run_as "${script_file_path}" || return_code="$?"

            if [ "${return_code}" -ne "0" ]; then
                echo "==> Failed at executing \"${script_file_path}\". Exit code: ${return_code}"
                exit 1
            fi

            echo "==> Finished the script: \"${script_file_path}\""
        done
    )
}

# usage: file_env VAR [DEFAULT]
#    ie: file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)
file_env() {
    local var="$1"
    local fileVar="${var}_FILE"
    local def="${2:-}"
    local varValue=$(env | grep -E "^${var}=" | sed -E -e "s/^${var}=//")
    local fileVarValue=$(env | grep -E "^${fileVar}=" | sed -E -e "s/^${fileVar}=//")
    if [ -n "${varValue}" ] && [ -n "${fileVarValue}" ]; then
        echo >&2 "error: both $var and $fileVar are set (but are exclusive)"
        exit 1
    fi
    if [ -n "${varValue}" ]; then
        export "$var"="${varValue}"
    elif [ -n "${fileVarValue}" ]; then
        export "$var"="$(cat "${fileVarValue}")"
    elif [ -n "${def}" ]; then
        export "$var"="$def"
    fi
    unset "$fileVar"
}

if expr "$1" : "apache" 1>/dev/null; then
    if [ -n "${APACHE_DISABLE_REWRITE_IP+x}" ]; then
        a2disconf remoteip
    fi
fi

if expr "$1" : "apache" 1>/dev/null || [ "$1" = "php-fpm" ] || [ "${NEXTCLOUD_UPDATE:-0}" -eq 1 ]; then
    uid="$(id -u)"
    gid="$(id -g)"
    if [ "$uid" = '0' ]; then
        case "$1" in
            apache2*)
                user="${APACHE_RUN_USER:-www-data}"
                group="${APACHE_RUN_GROUP:-www-data}"

                # strip off any '#' symbol ('#1000' is valid syntax for Apache)
                user="${user#'#'}"
                group="${group#'#'}"
                ;;
            *) # php-fpm
                user='www-data'
                group='www-data'
                ;;
        esac
    else
        user="$uid"
        group="$gid"
    fi

    if [ -n "${REDIS_HOST+x}" ]; then

        echo "Configuring Redis as session handler"
        {
            file_env REDIS_HOST_PASSWORD
            echo 'session.save_handler = redis'
            # check if redis host is an unix socket path
            if [ "$(echo "$REDIS_HOST" | cut -c1-1)" = "/" ]; then
              if [ -n "${REDIS_HOST_PASSWORD+x}" ]; then
                echo "session.save_path = \"unix://${REDIS_HOST}?auth=${REDIS_HOST_PASSWORD}\""
              else
                echo "session.save_path = \"unix://${REDIS_HOST}\""
              fi
            # check if redis password has been set
            elif [ -n "${REDIS_HOST_PASSWORD+x}" ]; then
                echo "session.save_path = \"tcp://${REDIS_HOST}:${REDIS_HOST_PORT:=6379}?auth=${REDIS_HOST_PASSWORD}\""
            else
                echo "session.save_path = \"tcp://${REDIS_HOST}:${REDIS_HOST_PORT:=6379}\""
            fi
            echo "redis.session.locking_enabled = 1"
            echo "redis.session.lock_retries = -1"
            # redis.session.lock_wait_time is specified in microseconds.
            # Wait 10ms before retrying the lock rather than the default 2ms.
            echo "redis.session.lock_wait_time = 10000"
        } > /usr/local/etc/php/conf.d/redis-session.ini
    fi
fi

chown -R $user:$group /var/www/html

if run_as 'php /var/www/html/occ status 2>&1' | grep "Nextcloud is not installed"; then
    echo "Nextcloud is not installed. Installing..."
    if directory_empty "/var/www/html/config"; then
        echo "Copying base config to /var/www/html/config"
        cp -r /usr/src/nextcloud/config/* /var/www/html/config
    fi
else
    echo "Nextcloud has been upgraded."
    if [[ $(run_as 'php /var/www/html/occ status --output json 2>/dev/null' | grep '{' | jq .needsDbUpgrade) == true ]]; then
        echo "Upgrading database"
        run_as 'php /var/www/html/occ upgrade'
    fi

    if [[ $(run_as 'php /var/www/html/occ status --output json 2>/dev/null' | grep '{' | jq .maintenance) == true ]]; then
        run_as 'php /var/www/html/occ maintenance:update:htaccess'
        run_as 'php /var/www/html/occ maintenance:mode --off'
    fi
fi

exec "$@"
