# Copyright 1999-2015 Gentoo Foundation
# Distributed under the terms of the GNU General Public License v2
# $Header: $

EAPI="5"

inherit golang-base

DESCRIPTION="Management Controller for UniFi APs"
HOMEPAGE="http://wiki.ubnt.com/UniFi_FAQ"
SRC_URI="https://gitlab.com/gitlab-org/${PN}/repository/archive.tar.bz2?ref=${PV} -> ${P}.tar.bz2"
SLOT="0"
LICENSE="MIT"
KEYWORDS="~amd64 ~x86"
IUSE=""

DEPEND="!dev-vcs/gitlab-git-http-server"
# TODO: depend on gitlab-shell to ensure git user?

src_unpack() {
	unpack "${A}"
	S="${WORKDIR}/$(basename "${WORKDIR}/${P}-"*)"
}

src_compile() {
	emake
}

src_install() {
	keepdir /var/log/${PN}/
	fowners -R git:git /var/log/${PN}/
	dodir /usr/bin
	emake install PREFIX=${D}/usr
	newinitd "${FILESDIR}/${PN}.init" "${PN}"
	newconfd "${FILESDIR}/${PN}.conf" "${PN}"
}
