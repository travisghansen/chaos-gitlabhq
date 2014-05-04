# Copyright 1999-2012 Gentoo Foundation
# Distributed under the terms of the GNU General Public License v2
# $Header: $

EAPI="5"

USE_RUBY="ruby19"
PYTHON_DEPEND="2:2.5"

inherit eutils python ruby-ng user

DESCRIPTION="GitLab shell"
HOMEPAGE="https://github.com/gitlabhq/gitlab-shell"
SRC_URI="https://github.com/gitlabhq/${PN}/archive/v${PV}.tar.gz -> ${P}.tar.gz"
SLOT="0"
LICENSE="MIT"
KEYWORDS="~amd64 ~x86"
IUSE=""

GEMS_DEPEND=""
DEPEND="${GEMS_DEPEND}
	$(ruby_implementation_depend ruby19 '=' -1.9.3*)[readline,ssl,yaml]
	virtual/ssh"
RDEPEND="${DEPEND}"

MY_USER="git"
HOME_DIR="/var/lib/gitlab"
DEST_DIR="${HOME_DIR}/${PN}"

pkg_setup() {
    enewgroup ${MY_USER}
    enewuser ${MY_USER} -1 /bin/bash ${HOME_DIR} "${MY_USER}"
}

each_ruby_prepare() {
	# change default homedir
	# remove dependency on therubyracer and libv8 (we're using nodejs instead)
	local tfile; for tfile in config.yml.example support/rewrite-hooks.sh support/truncate_repositories.sh; do
		echo "${tfile}"
		sed -i \
			-e "s|/home/git|${HOME_DIR}|" \
			"${tfile}" || die "failed to filter ${tfile}"
	done
	
	# remove needless files
	rm .gitignore
	
	#cd support
	#local tfile; for tfile in rewrite-hooks.sh truncate_repositories.sh; do
	#	sed -i \
	#		-e "s|/home/git/|${HOME_DIR}/|" \
	#		"${tfile}" || die "failed to filter ${tfile}"
	#done
	#die "failed"
}

each_ruby_install() {
	local dest=${DEST_DIR}

	dodir "${dest}"
	cp -R ./ "${D}"/"${DEST_DIR}"
	
	# fix permissions
	fowners -R ${MY_USER}:${MY_USER} "${HOME_DIR}"

}

pkg_postinst() {
	if [ ! -e "${HOME_DIR}/.ssh/id_rsa" ]; then
		einfo "Generating SSH key for gitlab"
		su -l ${MY_USER} -c "
			ssh-keygen -q -N '' -t rsa -f ${HOME_DIR}/.ssh/id_rsa" \
			|| die "failed to generate SSH key"
	fi
	if [ ! -e "${HOME_DIR}/.gitconfig" ]; then
		einfo "Setting git user"
		su -l ${MY_USER} -c "
			git config --global user.email 'gitlab@localhost';
			git config --global user.name 'GitLab'" \
			|| die "failed to setup git name and email"
	fi

	# for some strange reason when the user account/home folder gets
	# created root is the group
	chown ${MY_USER}:${MY_USER} ${HOME_DIR}
	
	elog
	elog "1. Copy ${DEST_DIR}/config.yml.example to ${DEST_DIR}/config.yml"
	elog "   and edit this file in order to configure your GitLab settings."
	elog
	elog "2. emerge --config \"=${CATEGORY}/${PF}\""
	elog
}

pkg_config() {
	REAL_HOME_DIR=$(getent passwd | awk -F: -v v="${MY_USER}" '{if ($1==v) print $6}')
	if [ "x${REAL_HOME_DIR}" != "x${HOME_DIR}" ];then
		eerror "home directory for ${MY_USER} must be ${HOME_DIR}"
		eerror "it is currently ${REAL_HOME_DIR}"
		eerror "please correct manually and re-run"
		die "failed ${PN} setup"
	fi

	einfo "Performing setup ..."
	su -l ${MY_USER} -c "${DEST_DIR}/bin/install" || die "failed ${PN} setup"
	einfo "Updating hooks ..."
	su -l ${MY_USER} -c "${DEST_DIR}/support/rewrite-hooks.sh"
}
