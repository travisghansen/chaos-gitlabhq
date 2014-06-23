#!/bin/bash


gitlab_rake_exec() {
        local COMMAND="${1}"
        local RAILS_ENV=${RAILS_ENV:-production}
        local RUBY=${RUBY:-ruby20}
        local BUNDLE="${RUBY} /usr/bin/bundle"

        su -l git -c "
		export PATH="/var/lib/gitlab/gitlab/bin:${PATH}"
                export LANG=en_US.UTF-8; export LC_ALL=en_US.UTF-8
                cd /var/lib/gitlab/gitlab
                ${BUNDLE} exec rake ${COMMAND} RAILS_ENV=${RAILS_ENV}"
}

gitlab_rake_exec ${@}

