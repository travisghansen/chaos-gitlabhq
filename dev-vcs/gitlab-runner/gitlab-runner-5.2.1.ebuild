# Copyright 1999-2014 Gentoo Foundation
# Distributed under the terms of the GNU General Public License v2
# $Header: $

EAPI="5"

# Maintainer notes:
# - This ebuild uses Bundler to download and install all gems in deployment mode
#   (i.e. into isolated directory inside application). That's not Gentoo way how
#   it should be done, but GitLab Runner has too many dependencies that it
#    will be too difficult to maintain them via ebuilds.
#

USE_RUBY="ruby19 ruby20 ruby21"
PYTHON_DEPEND="2:2.7"

inherit eutils git-2 python ruby-ng user

EGIT_REPO_URI="https://gitlab.com/gitlab-org/gitlab-ci-runner.git"
if [[ ${PV} != *9999* ]] ; then
	:
	#EGIT_COMMIT="tags/$(echo ${PV//_/-} | tr '[:lower:]' '[:upper:]' )"
	#EGIT_COMMIT="4d3a9d1319cfbfd12c4a2070adc0ae276835f767"
	EGIT_COMMIT="3ba62db6a6d5f2f457e02f2b408a251fb74d3dad"
fi

DESCRIPTION="GitLab Runner is the build processor needed for GitLab CI"
HOMEPAGE="https://gitlab.com/gitlab-org/gitlab-ci-runner"
#SRC_URI="https://github.com/gitlabhq/gitlab-ci-runner/archive/v${PV}.tar.gz -> ${P}.tar.gz"

RESTRICT="mirror"

LICENSE="MIT"
SLOT="0"
KEYWORDS="~amd64 ~x86"
# IUSE=""

## Gems dependencies:
#   charlock_holmes		dev-libs/icu
#   grape, capybara		dev-libs/libxml2, dev-libs/libxslt
#

GEMS_DEPEND="
	dev-libs/icu
	dev-libs/libxml2
	dev-libs/libxslt"
DEPEND="${GEMS_DEPEND}
	dev-vcs/git"
RDEPEND="${DEPEND}
	virtual/mta"
ruby_add_bdepend "
	virtual/rubygems
	>=dev-ruby/bundler-1.0"

#
RUBY_PATCHES=(
	"${PN}-fix-gemfile.patch"
)

MY_NAME="gitlab-runner"
MY_USER="gitlab-runner"

DEST_DIR="/var/lib/${MY_NAME}"
LOGS_DIR="/var/log/${MY_NAME}"
TEMP_DIR="/var/tmp/${MY_NAME}"
RUN_DIR="/run/${MY_NAME}"

# this is for non-git
#RUBY_S="gitlab-ci-runner-${PV}"

# this is for git
RUBY_S="${PN}"
EGIT_SOURCEDIR="${S}/${PN}"

# only define this function if git is being used
src_unpack() {
	git-2_src_unpack
	ruby-ng_src_unpack
}

pkg_setup() {
	enewgroup ${MY_USER}
	enewuser ${MY_USER} -1 /bin/bash ${DEST_DIR} ${MY_USER}
}

# only define this function of git is being used
all_ruby_unpack() {
	mv "${EGIT_SOURCEDIR}" "${WORKDIR}/all"
}

all_ruby_prepare() {
	# remove useless files
	rm -r lib/support/{init.d,logrotate.d}
}

all_ruby_install() {
	local dest=${DEST_DIR}
	local logs=${LOGS_DIR}
	local temp=${TEMP_DIR}
	local runs=${RUN_DIR}

	# prepare directories
	diropts -m750
	dodir ${logs} ${temp}

	diropts -m755
	dodir ${dest}

	dosym ${temp} ${dest}/tmp
	dosym ${logs} ${dest}/log

	echo 'export RAILS_ENV=production' > "${D}/${dest}/.profile"

	# install the files using cp 'cause doins is slow
	cp -Rl * "${D}/${dest}"/

	# install logrotate config
	dodir /etc/logrotate.d
	cat > "${D}/etc/logrotate.d/${MY_NAME}" <<-EOF
		${logs}/*.log {
		    missingok
		    delaycompress
		    compress
		    copytruncate
		}
	EOF

	## Install gems via bundler ##

	cd "${D}/${dest}"

	local bundle_args="--deployment"

	einfo "Running bundle install ${bundle_args} ..."
	${RUBY} /usr/bin/bundle install ${bundle_args} || die "bundler failed"

	# clean gems cache
	rm -Rf vendor/bundle/ruby/*/cache
	
	# create a workdir
	dodir "${dest}/work"

	# fix permissions
	fowners -R ${MY_USER}:${MY_USER} ${dest} ${temp} ${logs}

	## RC script and conf.d file ##

	local rcscript=gitlab-runner.init
	local rcconf=gitlab-runner.conf

	cp "${FILESDIR}/${rcscript}" "${T}" || die
	sed -i \
		-e "s|@USER@|${MY_USER}|" \
		-e "s|@GITLAB_RUNNER_BASE@|${dest}|" \
		-e "s|@LOGS_DIR@|${logs}|" \
		-e "s|@RUN_DIR@|${runs}|" \
		"${T}/${rcscript}" \
		|| die "failed to filter ${rcscript}"

	cp "${FILESDIR}/${rcconf}" "${T}" || die
	sed -i \
		-e "s|@USER@|${MY_USER}|" \
		-e "s|@GITLAB_RUNNER_BASE@|${dest}|" \
		-e "s|@LOGS_DIR@|${logs}|" \
		-e "s|@RUN_DIR@|${runs}|" \
		"${T}/${rcconf}" \
		|| die "failed to filter ${rcconf}"
	
	
	newinitd "${T}/${rcscript}" "${MY_NAME}"
	newconfd "${T}/${rcconf}" "${MY_NAME}"
}

pkg_postinst() {
	elog
	elog "If this is a fresh install of GitLab Runner, please configure it"
	elog "with the following command:"
	elog "        emerge --config \"=${CATEGORY}/${PF}\""
}

pkg_config() {
	einfo "You need to register the runner with your GitLab CI instance. In"
	einfo "order to do so, you need to know the URL of GitLab CI and the"
	einfo "authentication token."
	einfo
	einfo "You can find the token on your GitLab CI website at"
	einfo
	einfo "        http://<GITLAB-CI-HOST>/admin/runners"
	einfo
	einfo "Now please follow the instructions on the screen."

	local RUBY=${RUBY:-/usr/bin/ruby}
	local BUNDLE="${RUBY} /usr/bin/bundle"

	su -l ${MY_USER} -c "
		cd ${DEST_DIR}
		${BUNDLE} exec ./bin/setup -C ${DEST_DIR}/work" \
		|| die "failed to run ${BUNDLE} exec ./bin/setup"
}
