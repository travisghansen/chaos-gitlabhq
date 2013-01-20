# Copyright 1999-2013 Gentoo Foundation
# Distributed under the terms of the GNU General Public License v2
# $Header: /var/cvsroot/gentoo-x86/dev-vcs/gitolite/gitolite-3.3.ebuild,v 1.1 2013/01/02 23:59:51 radhermit Exp $

EAPI=5

inherit eutils user
MY_P="gitlabhq"
MY_P_HOME="/var/lib/gitlab"
GITOLITE_BRANCH="gl-v320"
GLB_HOME="/var/lib/gitlab"
GLB_APP="${GLB_HOME}/gitlab"
GLI_HOME="/var/lib/gitolite"
GLI_APP="${GLI_HOME}/gitolite"

DESCRIPTION="Self hosted Git management software"
HOMEPAGE="http://gitlabhq.com/"
SRC_URI="https://github.com/${MY_P}/${MY_P}/archive/v${PV}.tar.gz -> ${P}.tar.gz"

LICENSE="GPL-2"
SLOT="0"
KEYWORDS="~amd64 ~x86"
IUSE=""

DEPEND="dev-vcs/gitolite
	>=dev-ruby/charlock_holmes-0.6.9
	dev-ruby/bundler
	dev-db/redis
	net-misc/openssh
	dev-lang/python:2.7
	>=dev-vcs/git-1.6.6"

RDEPEND="${DEPEND}"

S="${WORKDIR}/${MY_P}-${PV}"

#TODO: https://github.com/brianmario/charlock_holmes/issues/10#issuecomment-11899472

pkg_setup() {
	enewgroup gitlab
	enewuser gitlab -1 /bin/sh ${GLB_HOME} "git,gitlab"
}

src_prepare() {
	ewarn ""
	ewarn "if building charlock_holmes fails please view:"
	ewarn "https://github.com/brianmario/charlock_holmes/issues/10#issuecomment-11899472"
	ewarn ""
}

src_install() {
	keepdir ${GLB_HOME}

	## doins screws with standard executable bits
	dodir ${GLB_APP}
	cp -R "${S}"/* "${D}${GLB_APP}"
	
	cd "${D}"${GLB_APP}
	bundle install --deployment

	fowners -R gitlab:git ${GLB_HOME}
	fperms -R u=rwX,g=rX,o= ${GLB_HOME}
	
	insinto /etc/profile.d
	doins "${FILESDIR}"/${PN}-gitolite-bin-path.sh
	
	dodir ${GLI_HOME}
	git clone -b ${GITOLITE_BRANCH} https://github.com/gitlabhq/gitolite.git ${D}${GLI_APP}
	fowners -R git:git ${GLI_APP}

	dodir ${GLI_HOME}/bin
	fowners git:git ${GLI_HOME}/bin
}

pkg_postinst() {
	einfo "https://github.com/gitlabhq/gitlabhq/blob/v${PV}/doc/install/installation.md"
	ewarn ""
	ewarn "before running --config you must start the redis server"
	ewarn "and create ${GLB_APP}/config/{gitlab,database}.yml"
	ewarn "and create ${GLB_APP}/config/unicorn.rb"
	ewarn "samples are found in ${GLB_APP}/config"
	ewarn ""
}

pkg_config() {

	$(rc-service redis status &>/dev/null) || die \
	  "redis must be running. Please start it with /etc/init.d/redis start"
	[ -f "${GLB_APP}/config/database.yml" ] || die \
	  "must setup database.yml before running config"
	
	[ -f "${GLB_APP}/config/unicorn.rb" ] || die \
	  "must setup unicorn.rb before running config"
	
	[ -f "${GLB_APP}/config/gitlab.yml" ] || die \
	  "must setup gitlab.yml before running config"

	# link gitolite properly
	su - git -c "${GLI_APP}/install -ln ${GLI_HOME}/bin"
	
	# create ssh key
	if [ ! -f "${GLB_HOME}/.ssh/id_rsa" ];then
		su - gitlab -c "ssh-keygen -q -N '' -t rsa -f ${GLB_HOME}/.ssh/id_rsa"
		cp ${GLB_HOME}/.ssh/id_rsa.pub ${GLI_HOME}/gitlab.pub
		chown git:git ${GLI_HOME}/gitlab.pub
	fi

	su - git -c "gitolite setup -pk ${GLI_HOME}/gitlab.pub"
	chmod -R ug+rwXs,o= ${GLI_HOME}/repositories
	chown -R git:git ${GLI_HOME}/repositories
	
	cp ${GLB_APP}/lib/hooks/post-receive ${GLI_HOME}/.gitolite/hooks/common/post-receive
	chown git:git ${GLI_HOME}/.gitolite/hooks/common/post-receive
	
	for host in localhost $(hostname) $(hostname -f);do
		# TODO: make this match the *full* line
		grep "Host ${host}" ${GLB_HOME}/.ssh/config &>/dev/null
		RETURN=$?
		if [ $RETURN -ne 0 ]; then
			echo "Host ${host}
	StrictHostKeyChecking no
	UserKnownHostsFile=/dev/null" | tee -a ${GLB_HOME}/.ssh/config
		fi
	done

	chown gitlab:git ${GLB_HOME}/.ssh/config

	if [ ! -f "${GLB_HOME}/.gitconfig" ]; then
		echo "gitconfig details for gitlab user"
		read -rp "name (GitLab)              >" gitlab_gitconfig_name ; echo
		read -rp "email (gitlab@localhost)   >" gitlab_gitconfig_email ; echo
		git config -f ${GLB_HOME}/.gitconfig user.name "${gitlab_gitconfig_name:-GitLab}"
		git config -f ${GLB_HOME}/.gitconfig user.email "${gitlab_gitconfig_email:-gitlab@localhost}"
		chown gitlab:git ${GLB_HOME}/.gitconfig
	fi

	# just good measure
	# installs any new hooks etc
	su - git -c "gitolite setup"

	einfo ""
	einfo "you can ignore any lines that read:"
	einfo "fatal: Not a git repository (or any of the parent directories): .git"
	einfo ""

	# setup initial db etc and do checks
	su - gitlab -c "cd ${GLB_APP}; bundle exec rake gitlab:app:setup RAILS_ENV=production"
	su - gitlab -c "cd ${GLB_APP}; bundle exec rake gitlab:env:info RAILS_ENV=production"
	# fails currently due to apparently bad group checking
	# and our style of PATH setting in lieu of .profile
	#su - gitlab -c "cd ${GLB_APP}; bundle exec rake gitlab:check RAILS_ENV=production"
}
