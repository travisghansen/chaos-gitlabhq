# Copyright 1999-2016 Gentoo Foundation
# Distributed under the terms of the GNU General Public License v2
# $Header: $

EAPI="5"

inherit golang-base

DESCRIPTION="Reverse proxy for GitLab"
HOMEPAGE="https://gitlab.com/gitlab-org/gitlab-workhorse"
SRC_URI="https://gitlab.com/gitlab-org/${PN}/repository/archive.tar.bz2?ref=v${PV} -> ${P}.tar.bz2"
SLOT="0"
LICENSE="MIT"
KEYWORDS="~amd64 ~x86"
IUSE=""

DEPEND="!dev-vcs/gitlab-git-http-server
	>=dev-lang/go-1.6.3"
# TODO: depend on gitlab-shell to ensure git user?

src_unpack() {
	unpack ${A}
	S="${WORKDIR}/$(basename "${WORKDIR}/${PN}-v${PV}"*)"
}

src_compile() {
	emake clean-build
	emake
}

src_install() {
	keepdir /var/log/${PN}/
	fowners -R git:git /var/log/${PN}/

	## Install logrotate config ##
	dodir /etc/logrotate.d
	insinto /etc/logrotate.d
	newins "${FILESDIR}/${PN}.logrotate" ${PN}

	dodir /usr/bin
	emake install PREFIX="${D}/usr"
	newinitd "${FILESDIR}/${PN}.init" "${PN}"
	newconfd "${FILESDIR}/${PN}.conf" "${PN}"
}
