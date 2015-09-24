# Copyright 1999-2015 Gentoo Foundation
# Distributed under the terms of the GNU General Public License v2
# $Header: $

EAPI="5"

inherit golang-base

DESCRIPTION="Management Controller for UniFi APs"
HOMEPAGE="http://wiki.ubnt.com/UniFi_FAQ"
SRC_URI="https://gitlab.com/gitlab-org/gitlab-git-http-server/repository/archive.tar.bz2?ref=${PV} -> ${P}.tar.bz2"
SLOT="0"
LICENSE="MIT"
KEYWORDS="~amd64 ~x86"
IUSE=""

# TODO: depend on gitlab-shell to ensure git user?

src_unpack() {
	unpack "${A}"
	S="${WORKDIR}/$(basename "${WORKDIR}/${P}-"*)"
}

src_compile() {
	make
}

src_install() {
	keepdir /var/log/gitlab-git-http-server/
	fowners -R git:git /var/log/gitlab-git-http-server/
	into /usr
	dobin ${PN}
	newinitd "${FILESDIR}/${PN}.init" "${PN}"
	newconfd "${FILESDIR}/${PN}.conf" "${PN}"
}
