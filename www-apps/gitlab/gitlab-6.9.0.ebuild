# Copyright 1999-2012 Gentoo Foundation
# Distributed under the terms of the GNU General Public License v2
# $Header: $

EAPI="5"

# https://raw2.github.com/gitlabhq/gitlab-recipes/master/web-server/apache/gitlab-ssl.conf
# rbelem in #gitlab has been very helpful

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

inherit eutils python ruby-ng systemd

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
	>=dev-vcs/gitlab-shell-1.9.4
	net-misc/curl
	virtual/ssh"
RDEPEND="${DEPEND}
	dev-db/redis
	virtual/mta
	dev-python/docutils"
ruby_add_bdepend "
	virtual/rubygems
	>=dev-ruby/bundler-1.0"

# gemfile problem here:
# https://github.com/brianmario/charlock_holmes/issues/10#issuecomment-11899472
RUBY_PATCHES=(
	"${PN}-fix-gemfile-final.patch"
)

# may work to no longer need above patch
# mkdir .bundle
# bundle config --local build.charlock_holmes --with-ldflags='-L. -Wl,-O1 -Wl,--as-needed -rdynamic -Wl,-export-dynamic -Wl,--no-undefined -lz -licuuc'

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
	local gitlab_shell="${HOME_DIR}/gitlab-shell/"
	sed -i \
		-e "s|\(\s*repos_path:\s\)/home/git.*|\1${gitolite_repos}/|" \
		-e "s|\(\s*hooks_path:\s\)/home/git.*|\1${gitolite_hooks}/|" \
		-e "s|/home/git/gitlab-satellites/|${gitlab_satellites}|" \
		-e "s|/home/git/gitlab-shell/|${gitlab_shell}|" \
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

	# shutup open_wr deny garbage due to nss/https
	addwrite "/etc/pki"
	einfo "Running bundle install ${bundle_args} ..."
	${RUBY} /usr/bin/bundle install ${bundle_args} || die "bundler failed"

	## Clean ##

	local gemsdir=vendor/bundle/ruby/$(ruby_rbconfig_value 'ruby_version')

	# remove gems cache
	rm -Rf ${gemsdir}/cache

	# fix permissions
	fowners -R ${MY_USER}:${MY_USER} "${HOME_DIR}" "${conf}" "${temp}" "${logs}"

	sed -i \
		-e "s|@GITLAB_HOME@|${dest}|" \
		-e "s|@LOG_DIR@|${logs}|" \
		"${D}/${conf}/gitlab_apache.conf" \
		|| die "failed to filter gitlab_apache.conf"
	
	sed -i \
		-e "s|/home/git/gitlab/tmp/pids/|/run/gitlab/|" \
		-e "s|/home/git/gitlab/tmp/sockets/|/run/gitlab/|" \
		-e "s|/home/git/gitlab|${dest}|" \
		"${D}/${conf}/unicorn.rb.example" \
		|| die "failed to filter unicorn.rb.example"

	## RC scripts ##
	
	local tfile;
	for tfile in ${PN}.init ${PN}.service ${PN}-worker.service ${PN}.tmpfile ; do
		cp "${FILESDIR}/${tfile}" "${T}" || die
		sed -i \
			-e "s|@USER@|${MY_USER}|" \
			-e "s|@GROUP@|${MY_USER}|" \
			-e "s|@GITLAB_HOME@|${dest}|" \
			-e "s|@LOG_DIR@|${logs}|" \
			"${T}/${tfile}" || die "failed to filter ${tfile}"
	done
	
	newinitd "${T}/gitlab.init" "${MY_NAME}"
	systemd_dounit "${T}"/${PN}.service ${T}/${PN}-worker.service 
	systemd_newtmpfilesd "${T}"/${PN}.tmpfile ${PN}.conf || die

	# logrotate
	# lib/support/logrotate/gitlab

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
        elog "      createdb -E UTF-8 -O gitlab gitlabhq_production"
		elog "  Note: You should change your password to something more random..."
		elog
 		elog "  GitLab uses polymorphic associations which are not SQL-standard friendly."
		elog "  To get it work you must use this ugly workaround:"
		elog "      psql -U postgres -d gitlabhq_production"
		elog "      CREATE CAST (integer AS text) WITH INOUT AS IMPLICIT;"
		elog
	fi
	elog "4. Finally execute the following command to initlize environment:"
	elog "   emerge --config \"=${CATEGORY}/${PF}\""
	elog
	elog "   Note: Do not forget to start Redis server."
	elog "   Note: to see all available commands: bundle exec rake -T"
	elog "   Note: upgrade help - https://github.com/gitlabhq/gitlabhq/wiki"
	elog

	## rack attack
	# https://github.com/gitlabhq/gitlabhq/blob/master/doc/update/6.1-to-6.2.md
	# Copy rack attack middleware config 
	# bash sudo -u git -H cp config/initializers/rack_attack.rb.example config/initializers/rack_attack.rb
	# Uncomment config.middleware.use Rack::Attack in /home/git/gitlab/config/application.rb 

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

	einfo "marking scripts as executable"
	chmod +x "${DEST_DIR}"/script/*

	## Initialize app ##
	# running wipes your DB
	# you *are* asked if you would like to continue
	einfo "Initializing database ..."
	gitlab_rake_exec "gitlab:setup"
	
	einfo "Upgrading/Migrating database ..."
	gitlab_rake_exec "db:migrate" || die "failed to migrate db"
	
	einfo "shell setup ..."
	gitlab_rake_exec "gitlab:shell:setup" || die "failed shell setup"
	
	einfo "building missing projects ..."
	gitlab_rake_exec "gitlab:shell:build_missing_projects" || die "failed to build missing projects"
	
	einfo "Creating satellites ..."
	gitlab_rake_exec "gitlab:satellites:create" || die "failed to create satellites"
	
	# 6.0 -> 6.1
	einfo "Migrating iids ..."
	gitlab_rake_exec "migrate_iids" || die "failed to clean assets"


	## standard items
	einfo "Cleaning assests ..."
	gitlab_rake_exec "assets:clean" || die "failed to clean assets"

	# sometimes does not return/exit
	einfo "Precompiling assests ..."
	gitlab_rake_exec "assets:precompile" || die "failed to precompile assets"
	
	einfo "Clearing cache ..."
	gitlab_rake_exec "cache:clear" || die "failed to clean assets"
}

gitlab_rake_exec() {
	local COMMAND="${1}"
	local RAILS_ENV=${RAILS_ENV:-production}
	local RUBY=${RUBY:-ruby19}
	local BUNDLE="${RUBY} /usr/bin/bundle"

	su -l ${MY_USER} -c "
		export LANG=en_US.UTF-8; export LC_ALL=en_US.UTF-8
		cd ${DEST_DIR}
		${BUNDLE} exec rake ${COMMAND} RAILS_ENV=${RAILS_ENV}"
}
