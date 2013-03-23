# Copyright 1999-2012 Gentoo Foundation
# Distributed under the terms of the GNU General Public License v2
# $Header: $

EAPI="5"

# Mainteiner notes:
# - This ebuild uses Bundler to download and install all gems in deployment mode
#   (i.e. into isolated directory inside application). That's not Gentoo way how
#   it should be done, but GitLab has too many dependencies that it will be too
#   difficult to maintain them via ebuilds.
# - USE flags analytics and public-projects applies our custom patches, see
#   https://github.com/cvut/gitlabhq for more information.
#

USE_RUBY="ruby19"
PYTHON_DEPEND="2:2.5"
MY_P="gitlabhq"

inherit eutils python ruby-ng

DESCRIPTION="GitLab is a free project and repository management application"
HOMEPAGE="https://github.com/gitlabhq/gitlabhq"
SRC_URI="https://github.com/${MY_P}/${MY_P}/archive/v${PV}.tar.gz -> ${P}.tar.gz"
SLOT="0"
LICENSE="MIT"
KEYWORDS="~amd64 ~x86"
IUSE="+mysql postgres +unicorn"
RUBY_S="${MY_P}-${PV}"

## Gems dependencies:
#   charlock_holmes		dev-libs/icu
#	grape, capybara		dev-libs/libxml2, dev-libs/libxslt
#   json				dev-util/ragel
#   yajl-ruby			dev-libs/yajl
#   pygments.rb			python 2.5+
#   execjs				net-libs/nodejs, or any other JS runtime
#   pg					dev-db/postgresql-base
#   mysql				virtual/mysql
#
GEMS_DEPEND="
	dev-libs/icu
	dev-libs/libxml2
	dev-libs/libxslt
	dev-util/ragel
	dev-libs/yajl
	net-libs/nodejs
	postgres? ( dev-db/postgresql-base )
	mysql? ( virtual/mysql )"
	#memcached? ( net-misc/memcached )
DEPEND="${GEMS_DEPEND}
	$(ruby_implementation_depend ruby19 '=' -1.9.3*)[readline,ssl,yaml]
	dev-vcs/gitlab-shell
	net-misc/curl
	virtual/ssh"
RDEPEND="${DEPEND}
	dev-db/redis
	virtual/mta"
ruby_add_bdepend "
	virtual/rubygems
	>=dev-ruby/bundler-1.0"

# gemfile problem here:
# https://github.com/brianmario/charlock_holmes/issues/10#issuecomment-11899472
RUBY_PATCHES=(
	"${PN}-fix-gemfile-final.patch"
)
	#"${P}-fix-checks-gentoo.patch"

MY_NAME="gitlab"
MY_USER="git"
HOME_DIR="/var/lib/gitlab"
DEST_DIR="${HOME_DIR}/${MY_NAME}"
CONF_DIR="/etc/${MY_NAME}"

each_ruby_prepare() {

	# fix Gitolite paths
	local gitolite_repos="${HOME_DIR}/repositories"
	local gitolite_hooks="${HOME_DIR}/gitlab-shell/hooks"
	local gitlab_satellites="${HOME_DIR}/gitlab-satellites/"
	sed -i \
		-e "s|\(\s*repos_path:\s\)/home/git.*|\1${gitolite_repos}/|" \
		-e "s|\(\s*hooks_path:\s\)/home/git.*|\1${gitolite_hooks}/|" \
		-e "s|/home/git/gitlab-satellites/|${gitlab_satellites}|" \
		config/gitlab.yml.example || die "failed to filter gitolite.yml.example"
	
	# modify database settings
	sed -i \
		-e 's|\(username:\) postgres.*|\1 gitlab|' \
		-e 's|\(password:\).*|\1 gitlab|' \
		-e 's|\(socket:\).*|/run/postgresql/.s.PGSQL.5432|' \
		config/database.yml.postgresql \
		|| die "failed to filter database.yml.postgresql"
	
	# replace "secret" token with random one
	local randpw=$(echo ${RANDOM}|sha512sum|cut -c 1-128)
	sed -i -e "/secret_token =/ s/=.*/= '${randpw}'/" \
		config/initializers/secret_token.rb \
		|| die "failed to filter secret_token.rb"
	
	# remove needless files
	rm .foreman .gitignore Procfile .travis.yml
	use unicorn || rm config/unicorn.rb.example
	use postgres || rm config/database.yml.postgresql
	use mysql || rm config/database.yml.mysql

	# remove zzet's stupid migration which expetcs that users are so foolish 
	# to use PostgreSQL's superuser in database.yml...
	rm db/migrate/20121009205010_postgres_create_integer_cast.rb

	# remove dependency on therubyracer and libv8 (we're using nodejs instead)
	local tfile; for tfile in Gemfile{,.lock}; do
		sed -i \
			-e '/therubyracer/d' \
			-e '/libv8/d' \
			"${tfile}" || die "failed to filter ${tfile}"
	done

	# change thin and unicorn dependencies to be optional
	sed -i \
		-e '/^gem "thin"/ s/$/, group: :thin/' \
		-e '/^gem "unicorn"/ s/$/, group: :unicorn/' \
		Gemfile || die "failed to modify Gemfile"
	
	# change cache_store
	#if use memcached; then
	#	sed -i \
	#		-e "/\w*config.cache_store / s/=.*/= :dalli_store, { namespace: 'gitlab' }/" \
	#		config/environments/production.rb \
	#		|| die "failed to modify production.rb"
	#fi
}

each_ruby_install() {
	local dest=${DEST_DIR}
	local conf=/etc/${MY_NAME}
	local temp=/var/tmp/${MY_NAME}
	local logs=/var/log/${MY_NAME}
	local gitlab_satellites="${HOME_DIR}/gitlab-satellites/"

	## Prepare directories ##

	diropts -m750
	keepdir "${logs}"
	keepdir "${gitlab_satellites}"
	dodir "${temp}"

	diropts -m755
	keepdir "${conf}"
	dodir "${dest}" 

	dosym "${temp}" "${dest}/tmp"
	dosym "${logs}" "${dest}/log"

	## Install configs ##

	insinto "${conf}"
	doins -r config/*
	doins "${FILESDIR}/gitlab_apache.conf"
	doins "${FILESDIR}/gitlab_apache_simple.conf"
	dosym "${conf}" "${dest}/config"

	insinto "${HOME_DIR}/.ssh"
	newins "${FILESDIR}/config.ssh" config

	echo "export RAILS_ENV=production" > "${D}/${HOME_DIR}/.profile"

	## Install all others ##

	# remove needless dirs
	rm -Rf config tmp log

	insinto "${dest}"
	doins -r ./

	## Install logrotate config ##

	dodir /etc/logrotate.d
	sed -e "s|@LOG_DIR@|${logs}|" \
		"${FILESDIR}"/gitlab.logrotate > "${D}"/etc/logrotate.d/${MY_NAME} \
		|| die "failed to filter gitlab.logrotate"

	## Install gems via bundler ##

	cd "${D}/${dest}"

	local without="development test thin"
	local flag; for flag in mysql postgres unicorn; do
		without+="$(use $flag || echo ' '$flag)"
	done
	local bundle_args="--deployment ${without:+--without ${without}}"

	einfo "Running bundle install ${bundle_args} ..."
	${RUBY} /usr/bin/bundle install ${bundle_args} || die "bundler failed"

	## Clean ##

	local gemsdir=vendor/bundle/ruby/$(ruby_rbconfig_value 'ruby_version')

	# remove gems cache
	rm -Rf ${gemsdir}/cache

	# fix permissions
	fowners -R ${MY_USER}:${MY_USER} "${HOME_DIR}" "${conf}" "${temp}" "${logs}"

	## RC scripts ##

	local rcscript=gitlab.init

	cp "${FILESDIR}/${rcscript}" "${T}" || die
	sed -i \
		-e "s|@USER@|${MY_USER}|" \
		-e "s|@GROUP@|${MY_USER}|" \
		-e "s|@GITLAB_HOME@|${dest}|" \
		-e "s|@LOG_DIR@|${logs}|" \
		"${T}/${rcscript}" \
		|| die "failed to filter ${rcscript}"
	
	sed -i \
		-e "s|@GITLAB_HOME@|${dest}|" \
		-e "s|@LOG_DIR@|${logs}|" \
		"${D}/${conf}/gitlab_apache.conf" \
		|| die "failed to filter gitlab_apache.conf"
	
	sed -i \
		-e "s|/home/gitlab/gitlab/|${dest}|" \
		-e "s|#{app_dir}/tmp/pids/|/run/gitlab/|" \
		-e "s|#{app_dir}/tmp/sockets/gitlab.socket|127.0.0.1:8080|" \
		"${D}/${conf}/unicorn.rb.example" \
		|| die "failed to filter unicorn.rb.example"

	newinitd "${T}/${rcscript}" "${MY_NAME}"
}

pkg_postinst() {
	# for some strange reason when the user account/home folder gets
	# created root is the group
	chown ${MY_USER}:${MY_USER} ${HOME_DIR}
	
	elog
	elog "1. Copy ${CONF_DIR}/gitlab.yml.example to ${CONF_DIR}/gitlab.yml"
	elog "   and edit this file in order to configure your GitLab settings."
	elog
	elog "2. Copy ${CONF_DIR}/database.yml.* to ${CONF_DIR}/database.yml"
	elog "   and edit this file in order to configure your database settings"
	elog "   for \"production\" environment."
	elog
	elog "3. Then you should create database for your GitLab instance."
	elog
	if use postgres; then
        elog   "If you have local PostgreSQL running, just copy&run:"
        elog "      su postgres"
        elog "      psql -c \"CREATE ROLE gitlab PASSWORD 'gitlab' \\"
        elog "          NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT LOGIN;\""
        elog "      createdb -E UTF-8 -O gitlab gitlab_production"
		elog "  Note: You should change your password to something more random..."
		elog
 		elog "  GitLab uses polymorphic associations which are not SQL-standard friendly."
		elog "  To get it work you must use this ugly workaround:"
		elog "      psql -U postgres -d gitlab"
		elog "      CREATE CAST (integer AS text) WITH INOUT AS IMPLICIT;"
		elog
	fi
	elog "4. Finally execute the following command to initlize environment:"
	elog "       emerge --config \"=${CATEGORY}/${PF}\""
	elog "   Note: Do not forget to start Redis server."
	elog "   Note: Do not run if performing an upgrade, you database will be deleted."
	elog
	elog "   Note: to see all available commands: bundle exec rake -T"
	elog "   Note: upgrade help - https://github.com/gitlabhq/gitlabhq/wiki"
	elog
}

pkg_config() {
	## Check config files existence ##

	einfo "Checking configuration files"

	if [ ! -r "${CONF_DIR}/database.yml" ] ; then
		eerror "Copy ${CONF_DIR}/database.yml.* to"
		eerror "${CONF_DIR}/database.yml and edit this file in order to configure your" 
		eerror "database settings for \"production\" environment."
		die
	fi
	if [ ! -r "${CONF_DIR}/gitlab.yml" ]; then
		eerror "Copy ${CONF_DIR}/gitlab.yml.example to ${CONF_DIR}/gitlab.yml"
		eerror "and edit this file in order to configure your GitLab settings"
		eerror "for \"production\" environment."
		die
	fi

	## Initialize app ##

	local RAILS_ENV=${RAILS_ENV:-production}
	local RUBY=${RUBY:-ruby19}
	local BUNDLE="${RUBY} /usr/bin/bundle"

	# running wipes your DB
	# you *are* asked if you would like to continue
	einfo "Initializing database ..."
	su -l ${MY_USER} -c "
		export LANG=en_US.UTF-8; export LC_ALL=en_US.UTF-8
		cd ${DEST_DIR}
		${BUNDLE} exec rake gitlab:setup RAILS_ENV=${RAILS_ENV}"
	
	einfo "Upgrading/Migrating database ..."
	su -l ${MY_USER} -c "
		export LANG=en_US.UTF-8; export LC_ALL=en_US.UTF-8
		cd ${DEST_DIR}
		${BUNDLE} exec rake db:migrate RAILS_ENV=${RAILS_ENV}"
	
	einfo "shell setup ..."
	su -l ${MY_USER} -c "
		export LANG=en_US.UTF-8; export LC_ALL=en_US.UTF-8
		cd ${DEST_DIR}
		${BUNDLE} exec rake gitlab:shell:setup RAILS_ENV=${RAILS_ENV}"
	
	einfo "building missing projects ..."
	su -l ${MY_USER} -c "
		export LANG=en_US.UTF-8; export LC_ALL=en_US.UTF-8
		cd ${DEST_DIR}
		${BUNDLE} exec rake gitlab:shell:build_missing_projects RAILS_ENV=${RAILS_ENV}"
	
	einfo "Creating satellites ..."
	su -l ${MY_USER} -c "
		export LANG=en_US.UTF-8; export LC_ALL=en_US.UTF-8
		cd ${DEST_DIR}
		${BUNDLE} exec rake gitlab:satellites:create RAILS_ENV=${RAILS_ENV}"
	
	einfo "Upgrading/Migrating wiki to git ..."
	su -l ${MY_USER} -c "
		export LANG=en_US.UTF-8; export LC_ALL=en_US.UTF-8
		cd ${DEST_DIR}
		${BUNDLE} exec rake gitlab:wiki:migrate RAILS_ENV=${RAILS_ENV}"

	# sometimes does not return/exit
	einfo "Precompiling assests ..."
	su -l ${MY_USER} -c "
		export LANG=en_US.UTF-8; export LC_ALL=en_US.UTF-8
		cd ${DEST_DIR}
		${BUNDLE} exec rake assets:precompile:all RAILS_ENV=${RAILS_ENV}" \
		|| die "failed to precompile assets"
}
