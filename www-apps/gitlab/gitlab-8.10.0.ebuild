# Copyright 1999-2015 Gentoo Foundation
# Distributed under the terms of the GNU General Public License v2
# $Header: $

EAPI="5"

# Mainteiner notes:
# - This ebuild uses Bundler to download and install all gems in deployment mode
#   (i.e. into isolated directory inside application). That's not Gentoo way how
#   it should be done, but GitLab has too many dependencies that it will be too
#   difficult to maintain them via ebuilds.
#
# - rbelem in #gitlab has been very helpful
#

USE_RUBY="ruby21 ruby22"
#MY_RUBY="ruby21"
MY_P="gitlabhq"

inherit eutils ruby-ng systemd

DESCRIPTION="GitLab is a free project and repository management application"
HOMEPAGE="https://about.gitlab.com"
SRC_URI="https://github.com/${MY_P}/${MY_P}/archive/v${PV}.tar.gz -> ${P}.tar.gz"
SLOT="0"
LICENSE="MIT"
KEYWORDS="~amd64 ~x86"
RESTRICT="mirror"
IUSE="+mysql postgres +unicorn"
RUBY_S="${MY_P}-${PV}"

## Gems dependencies:
#   charlock_holmes		dev-libs/icu
#	grape, capybara		dev-libs/libxml2, dev-libs/libxslt
#   json				dev-util/ragel
#   yajl-ruby			dev-libs/yajl
#   execjs				net-libs/nodejs, or any other JS runtime
#   pg					dev-db/postgresql
#   mysql				virtual/mysql
#
GEMS_DEPEND="
	dev-libs/icu
	dev-libs/libxml2
	dev-libs/libxslt
	dev-util/ragel
	dev-libs/yajl
	net-libs/nodejs
	postgres? ( dev-db/postgresql )
	mysql? ( virtual/mysql )"

DEPEND="${GEMS_DEPEND}
	|| (
		$(ruby_implementation_depend ruby21 '=' -2.1*)[readline,ssl]
		$(ruby_implementation_depend ruby22 '=' -2.2*)[readline,ssl]
	)
	>=dev-vcs/git-2.7.3-r1
	=dev-vcs/gitlab-shell-3.2.0*
	dev-libs/libxml2
	dev-libs/libxslt
	net-misc/curl
	net-libs/nodejs
	virtual/ssh"

# v8.5.x an up require 0/24
#	dev-libs/libgit2:0/23

# deps to support different doctypes, etc
# https://github.com/gitlabhq/markup#markups
RDEPEND="${DEPEND}
	app-text/asciidoc
	dev-db/redis
	dev-python/docutils
	virtual/mta"

ruby_add_bdepend "
	virtual/rubygems
	>=dev-ruby/bundler-1.0"

# gemfile problem here:
# https://github.com/brianmario/charlock_holmes/issues/10#issuecomment-11899472
#RUBY_PATCHES=(
#	"${PN}-fix-gemfile-final.patch"
#)

MY_NAME="gitlab"
MY_USER="git"
HOME_DIR="/var/lib/gitlab"
DEST_DIR="${HOME_DIR}/${MY_NAME}"
CONF_DIR="/etc/${MY_NAME}"

all_ruby_prepare() {
	local dest=${DEST_DIR}
	local gitlab_repos="${HOME_DIR}/repositories"
	local gitlab_hooks="${HOME_DIR}/gitlab-shell/hooks"
	local gitlab_satellites="${HOME_DIR}/gitlab-satellites/"
	local gitlab_shell="${HOME_DIR}/gitlab-shell/"
	local tfile;

	sed -i \
		-e "s|\(\s*repos_path:\s\)/home/git.*|\1${gitlab_repos}/|" \
		-e "s|\(\s*hooks_path:\s\)/home/git.*|\1${gitlab_hooks}/|" \
		-e "s|/home/git/gitlab-satellites/|${gitlab_satellites}|" \
		-e "s|/home/git/gitlab-shell/|${gitlab_shell}|" \
		config/gitlab.yml.example || die "failed to filter gitlab.yml.example"

	# modify database settings
	sed -i \
		-e 's|\(username:\) postgres.*|\1 gitlab|' \
		-e 's|\(password:\).*|\1 gitlab|' \
		-e 's|\(socket:\).*|/run/postgresql/.s.PGSQL.5432|' \
		config/database.yml.postgresql \
		|| die "failed to filter database.yml.postgresql"

	sed -i \
		-e "s|/home/git/gitlab/log|/var/log/gitlab|" \
		-e "s|/home/git/gitlab-shell|/var/lib/gitlab/gitlab-shell|" \
		lib/support/logrotate/gitlab \
		|| die "failed to filter gitlab.logrotate"

	sed -i \
		-e "s|/home/git/gitlab/tmp/pids/|/run/gitlab/|" \
		-e "s|/home/git/gitlab/tmp/sockets/|/run/gitlab/|" \
		-e "s|/home/git/gitlab|${dest}|" \
		config/unicorn.rb.example \
		|| die "failed to filter unicorn.rb.example"

	sed -i \
		-e "s|require_relative '../lib/|require_relative '${dest}/lib/|" \
		config/application.rb \
		|| die "failed to filter unicorn.rb.example"

	# remove needless files
	rm .foreman .gitignore Procfile
	use unicorn || rm config/unicorn.rb.example
	use postgres || rm config/database.yml.postgresql
	use mysql || rm config/database.yml.mysql
}

all_ruby_install() {
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

	# remove needless dirs
	rm -Rf config tmp log

	#insinto "${dest}"
	#doins -r ./
	cp -a ./ "${D}${dest}"

	## Install logrotate config ##
	dodir /etc/logrotate.d
	insinto /etc/logrotate.d
	doins lib/support/logrotate/gitlab

	## Install gems via bundler ##
	cd "${D}/${dest}"

	local without="kerberos development test thin"
	local flag; for flag in mysql postgres unicorn; do
		without+="$(use $flag || echo ' '$flag)"
	done
	local bundle_args="--deployment ${without:+--without ${without}} --jobs $(nproc)"

	# may work to no longer need above patch
	mkdir .bundle
	#bundle config --local build.charlock_holmes --with-ldflags='-L. -Wl,-O1 -Wl,--as-needed -rdynamic -Wl,-export-dynamic -Wl,--no-undefined -lz -licuuc'
	bundle config --local build.charlock_holmes --with-ldflags='-L. -Wl,-O1 -Wl,--as-needed -rdynamic -Wl,-export-dynamic'

	# require dev-libs/libxml2 and dev-libs/libxslt
	bundle config --local build.nokogiri --use-system-libraries

	# https://github.com/fritteli/gentoo-overlay/issues/22
	# basically if http-parser is installed locally then rugged fails to build
	# require dev-libs/libgit2 and net-libs/http-parser
	#bundle config --local build.rugged --use-system-libraries

	# shutup open_wr deny garbage due to nss/https
	addwrite "/etc/pki"

	# hacky way to install gems for all implementations while still using all_ruby_install
	for B_RUBY in `ruby_get_use_implementations`;do
		B_RUBY=$(ruby_implementation_command ${B_RUBY})
		einfo "Running ${B_RUBY} /usr/bin/bundle install ${bundle_args} ..."
		${B_RUBY} /usr/bin/bundle install ${bundle_args} || die "bundler failed"
	done

	# remove gems cache
	rm -Rf vendor/bundle/ruby/*/cache


	sed -i \
		-e "s|@GITLAB_HOME@|${dest}|" \
		-e "s|@LOG_DIR@|${logs}|" \
		"${D}/${conf}/gitlab_apache.conf" \
		|| die "failed to filter gitlab_apache.conf"

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

	# copy gentoo init in place to ensure gitlab:check rake command works
	cp -f "${T}/gitlab.init" "${D}${dest}/lib/support/init.d/gitlab"
	newinitd "${T}/gitlab.init" "${MY_NAME}"
	
	systemd_dounit "${T}"/${PN}.service "${T}"/${PN}-worker.service
	systemd_newtmpfilesd "${T}"/${PN}.tmpfile ${PN}.conf || die

	dosbin "${FILESDIR}"/gitlab_rake.sh
	
	# fix permissions
	fowners -R ${MY_USER}:${MY_USER} "${HOME_DIR}" "${conf}" "${temp}" "${logs}"
}

pkg_postinst() {
	# for some strange reason when the user account/home folder gets
	# created root is the group
	chown ${MY_USER}:${MY_USER} ${HOME_DIR}
	chmod +x "${DEST_DIR}"/bin/*

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
	elog
	elog "Version 8.x has added several new features and integrated CI directly into the package"
	elog "Pleare review the following if updating from 7.x:"
	elog "   https://about.gitlab.com/2015/09/22/gitlab-8-0-released/"
	elog "   http://doc.gitlab.com/ce/update/7.14-to-8.0.html"
	elog "   https://gitlab.com/gitlab-org/gitlab-ce/blob/master/doc/update/7.14-to-8.0.md"
	elog "   https://gitlab.com/gitlab-org/gitlab-workhorse"
	elog "   http://doc.gitlab.com/ce/migrate_ci_to_ce/README.html"
	elog "   http://doc.gitlab.com/ce/incoming_email/README.html" 
}

pkg_config() {
	local RUBY=${RUBY:-/usr/bin/ruby}
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
	chmod +x "${DEST_DIR}"/bin/*

	local answer
	while [ "${answer}" != "yes" ] && [ "${answer}" != "no" ]; do
		read -p "Would you like to initialize the database (new install)? (yes/no)  " answer
	done
	if [ "${answer}" == "yes" ];then
		## Initialize app ##
		# running wipes your DB
		# you *are* asked if you would like to continue
		einfo "Initializing database ..."
		gitlab_rake_exec "gitlab:setup"
	fi

	einfo "Upgrading/Migrating database ..."
	gitlab_rake_exec "db:migrate" || die "failed to migrate db"

	#einfo "shell setup ..."
	#gitlab_rake_exec "gitlab:shell:setup" || die "failed shell setup"

	## standard items
	einfo "Preparing assets/cache ..."
	gitlab_rake_exec "assets:clean assets:precompile cache:clear" || die "failed to prepare assets/cache"

	## gitlab:check sanity
	GITLAB_REPO_PATH=`$RUBY -e "require 'yaml'; @config = YAML.load_file('${CONF_DIR}/gitlab.yml'); puts @config['production']['gitlab_shell']['repos_path'];"`
	GITLAB_EMAIL_FROM=`$RUBY -e "require 'yaml'; @config = YAML.load_file('${CONF_DIR}/gitlab.yml'); puts @config['production']['gitlab']['email_from'];"`

	if [ -d "${GITLAB_REPO_PATH}" ] ; then
		einfo "Ensuring proper permissions on repositories (${GITLAB_REPO_PATH})"
		chmod -R ug+rwX,o-rwx "${GITLAB_REPO_PATH}"
		chmod -R ug-s "${GITLAB_REPO_PATH}"
		find "${GITLAB_REPO_PATH}" -type d -print0 | xargs -0 chmod g+s
	fi

	if [ "x${GITLAB_EMAIL_FROM}" != "x" ] ; then
		einfo "Ensuring proper git config values"
		su -l ${MY_USER} -c "git config --global user.email '${GITLAB_EMAIL_FROM}';"
	fi
	
	su -l ${MY_USER} -c "git config --global core.autocrlf input;"
	su -l ${MY_USER} -c "git config --global gc.auto 0;"
}

gitlab_rake_exec() {
	local COMMAND="${1}"
	local RAILS_ENV=${RAILS_ENV:-production}
	local RUBY=${RUBY:-/usr/bin/ruby}
	local BUNDLE="${RUBY} /usr/bin/bundle"

	su -l ${MY_USER} -c "
		export PATH="/var/lib/gitlab/gitlab/bin:${PATH}"
		export LANG=en_US.UTF-8; export LC_ALL=en_US.UTF-8
		cd ${DEST_DIR}
		${BUNDLE} exec rake ${COMMAND} RAILS_ENV=${RAILS_ENV}"
}
